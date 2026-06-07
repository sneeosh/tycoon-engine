extends Node
# Spec: design/algorithms/navigation.md
#
# Owns the WalkableNetworks and the bound INetworkNavigator. Rebuilds
# networks reactively from placed walkable EntityInstances — exactly the way
# RegionRegistry derives regions from zone tiles. Multiple disjoint networks
# are supported (seam report open question 1, "default to plural"): each
# walkable EntityDef names its `network_id` (default &"default"), so a game
# can keep indoor/outdoor or staff/public networks separate; a simple game
# uses one.
#
# Theme-agnostic: knows cells, costs, and access tags — never what a "path"
# or a "goal" is.

const DEFAULT_NETWORK := &"default"

# Mirrored on EventBus too (same pattern as RegionRegistry): consumers can
# listen here or on EventBus. dirty_rect bounds the cells that changed so a
# game can scope its own cache invalidation.
signal network_changed(network_id: StringName, dirty_rect: Rect2i)

# network_id (StringName) -> WalkableNetwork
var networks: Dictionary = {}

# The bound navigator. Defaults to the engine's A* impl; games may swap in
# their own (path preference, per-archetype routing, avoidance) via
# set_navigator().
var navigator: INetworkNavigator

# instance_id -> { "network_id": StringName, "cells": Array[Vector2i] } so a
# removal knows exactly which cells to drop.
var _instance_cells: Dictionary = {}


func _ready() -> void:
	navigator = AStarNetworkNavigator.new()
	EventBus.entity_placed.connect(_on_entity_placed)
	EventBus.entity_removed.connect(_on_entity_removed)


func reset() -> void:
	networks.clear()
	_instance_cells.clear()


func set_navigator(p_navigator: INetworkNavigator) -> void:
	navigator = p_navigator


# ---------------------------------------------------------------------------
# Network access
# ---------------------------------------------------------------------------

func get_network(network_id: StringName = DEFAULT_NETWORK) -> WalkableNetwork:
	return networks.get(network_id)


func _ensure_network(network_id: StringName) -> WalkableNetwork:
	if not networks.has(network_id):
		var net := WalkableNetwork.new()
		net.network_id = network_id
		networks[network_id] = net
	return networks[network_id]


# ---------------------------------------------------------------------------
# Reactive build from EntityRegistry
# ---------------------------------------------------------------------------

func _on_entity_placed(instance_id: int) -> void:
	var inst: EntityInstance = EntityRegistry.get_instance(instance_id)
	if inst == null:
		return
	var def := inst.get_def()
	if def == null or not def.walkable:
		return
	var net_id: StringName = def.network_id if def.network_id != &"" else DEFAULT_NETWORK
	var net := _ensure_network(net_id)
	var cost := _cell_cost(def)
	var cells := _cells_of(inst, def)
	for c in cells:
		net.add_cell(c, cost, def.walkable_tags)
	_instance_cells[instance_id] = {"network_id": net_id, "cells": cells}
	_emit_changed(net_id, cells)


func _on_entity_removed(instance_id: int) -> void:
	if not _instance_cells.has(instance_id):
		return
	var rec: Dictionary = _instance_cells[instance_id]
	var net_id: StringName = rec["network_id"]
	var cells: Array[Vector2i] = rec["cells"]
	var net: WalkableNetwork = networks.get(net_id)
	_instance_cells.erase(instance_id)
	if net == null:
		return
	for c in cells:
		net.remove_cell(c)
	_emit_changed(net_id, cells)


# Scan the whole EntityRegistry and rebuild every network from scratch.
# Useful after a load (EntityRegistry.load_state restores instances without
# re-emitting entity_placed, same as RegionRegistry's reactive model).
func rebuild_all() -> void:
	reset()
	for instance_id in EntityRegistry.instances.keys():
		_on_entity_placed(instance_id)


# Cell cost: the source EntityDef's traversal_cost, falling back to the
# tuning default when it is unset (<= 0).
func _cell_cost(def: EntityDef) -> float:
	if def.traversal_cost > 0.0:
		return def.traversal_cost
	var bc: BalanceConfig = ContentDB.balance_config
	return bc.nav_default_traversal_cost if bc != null else 1.0


func _cells_of(inst: EntityInstance, def: EntityDef) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dx in def.footprint.x:
		for dy in def.footprint.y:
			out.append(inst.position + Vector2i(dx, dy))
	return out


func _emit_changed(network_id: StringName, cells: Array[Vector2i]) -> void:
	var rect := _bounds(cells)
	EventBus.network_changed.emit(network_id, rect)
	network_changed.emit(network_id, rect)


func _bounds(cells: Array[Vector2i]) -> Rect2i:
	if cells.is_empty():
		return Rect2i()
	var min_c: Vector2i = cells[0]
	var max_c: Vector2i = cells[0]
	for c in cells:
		min_c.x = mini(min_c.x, c.x)
		min_c.y = mini(min_c.y, c.y)
		max_c.x = maxi(max_c.x, c.x)
		max_c.y = maxi(max_c.y, c.y)
	# +1 so a single cell yields a 1x1 rect.
	return Rect2i(min_c, max_c - min_c + Vector2i.ONE)


# ---------------------------------------------------------------------------
# Convenience queries (delegate to the bound navigator; cache on the network)
# ---------------------------------------------------------------------------

func path(from: Vector2i, to: Vector2i, agent_tags: Array[StringName] = [],
		network_id: StringName = DEFAULT_NETWORK) -> Array[Vector2i]:
	var net: WalkableNetwork = networks.get(network_id)
	if net == null:
		return [] as Array[Vector2i]
	var key := WalkableNetwork.route_key(from, to, agent_tags)
	if net.has_cached_route(key):
		return net.get_cached_route(key)
	var bc: BalanceConfig = ContentDB.balance_config
	var budget: int = bc.nav_max_path_expansions if bc != null else -1
	var route := navigator.find_path(net, from, to, agent_tags, budget)
	net.cache_route(key, route)
	return route


func reachable_from(origin: Vector2i, agent_tags: Array[StringName] = [],
		network_id: StringName = DEFAULT_NETWORK) -> Dictionary:
	var net: WalkableNetwork = networks.get(network_id)
	if net == null:
		return {}
	return navigator.reachable_from(net, origin, agent_tags)


func nearest(origin: Vector2i, predicate: Callable, agent_tags: Array[StringName] = [],
		network_id: StringName = DEFAULT_NETWORK) -> Vector2i:
	var net: WalkableNetwork = networks.get(network_id)
	if net == null:
		return INetworkNavigator.NO_STEP
	return navigator.nearest(net, origin, predicate, agent_tags)


func within_engagement_distance(cell: Vector2i, target_anchors: Array[Vector2i],
		d: int = -1, metric: WalkableNetwork.Metric = WalkableNetwork.Metric.MANHATTAN,
		network_id: StringName = DEFAULT_NETWORK) -> bool:
	var net: WalkableNetwork = networks.get(network_id)
	if net == null:
		return false
	var dist := d
	if dist < 0:
		var bc: BalanceConfig = ContentDB.balance_config
		dist = bc.nav_default_engagement_distance if bc != null else 10
	return net.within_engagement_distance(cell, target_anchors, dist, metric)
