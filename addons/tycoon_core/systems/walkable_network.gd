extends RefCounted
class_name WalkableNetwork
# Spec: design/algorithms/navigation.md
#
# The set of grid cells an agent may stand on, plus the 4-neighbour
# adjacency graph they induce. Each cell carries a `traversal_cost` (the
# cost of *entering* it) and an optional set of access `tags`.
#
# Runtime data, not authored content (like Region — derived from placed
# entities, never hand-built). NavigationRegistry owns the lifecycle and
# rebuilds networks reactively from walkable EntityInstances. The search
# itself lives in INetworkNavigator; this class holds the graph, the cheap
# structural queries, the engagement-distance helper, and the route cache.
#
# Theme-agnostic: a zoo path, a mall aisle, and a hospital corridor are all
# just cells with `walkable = true`.

# 4-neighbourhood, fixed order (up, down, left, right). Mirrors
# RegionRegistry.ADJACENCY — diagonal movement is intentionally excluded.
const ADJACENCY: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(0, 1),
	Vector2i(-1, 0),
	Vector2i(1, 0),
]

# Metric for within_engagement_distance. MANHATTAN is the default (matches
# original Zoo Tycoon viewing distance and ignores walls); NETWORK measures
# graph distance (the agent must actually be able to walk that close).
enum Metric { MANHATTAN, NETWORK }

var network_id: StringName = &""

# Vector2i cell -> float traversal cost (cost of *entering* the cell).
var _costs: Dictionary = {}
# Vector2i cell -> Array[StringName] access tags.
var _tags: Dictionary = {}

# Route cache: String key -> Array[Vector2i]. Keyed by (from, to, tags) via
# route_key(); invalidated wholesale on any mutation (see clear_cache).
var _route_cache: Dictionary = {}

# Cached minimum traversal cost across all cells, for the A* heuristic.
# -1.0 = dirty (recompute on next min_cost()).
var _min_cost_cache: float = -1.0


# ---------------------------------------------------------------------------
# Mutation
# ---------------------------------------------------------------------------

# Add or overwrite a cell. `cost` is the cost of entering the cell; `tags`
# are the access requirements an agent must satisfy to enter. Any mutation
# clears the route cache.
func add_cell(cell: Vector2i, cost: float = 1.0, tags: Array[StringName] = []) -> void:
	_costs[cell] = cost
	if tags.is_empty():
		_tags.erase(cell)
	else:
		_tags[cell] = tags.duplicate()
	_invalidate()


func remove_cell(cell: Vector2i) -> void:
	if not _costs.has(cell):
		return
	_costs.erase(cell)
	_tags.erase(cell)
	_invalidate()


func clear() -> void:
	_costs.clear()
	_tags.clear()
	_invalidate()


func _invalidate() -> void:
	_min_cost_cache = -1.0
	clear_cache()


# ---------------------------------------------------------------------------
# Structural queries
# ---------------------------------------------------------------------------

func has_cell(cell: Vector2i) -> bool:
	return _costs.has(cell)


func cell_count() -> int:
	return _costs.size()


func traversal_cost(cell: Vector2i) -> float:
	return _costs.get(cell, INF)


func tags_at(cell: Vector2i) -> Array[StringName]:
	var out: Array[StringName] = []
	if _tags.has(cell):
		out.append_array(_tags[cell])
	return out


# An agent carrying `agent_tags` may enter `cell` iff the cell exists and
# every tag on the cell is present in agent_tags (untagged cell = open).
func can_enter(cell: Vector2i, agent_tags: Array[StringName] = []) -> bool:
	if not _costs.has(cell):
		return false
	if not _tags.has(cell):
		return true
	for t in (_tags[cell] as Array):
		if t not in agent_tags:
			return false
	return true


# Enterable 4-neighbours of `cell`, in ADJACENCY order.
func neighbors(cell: Vector2i, agent_tags: Array[StringName] = []) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for offset in ADJACENCY:
		var n: Vector2i = cell + offset
		if can_enter(n, agent_tags):
			out.append(n)
	return out


# Cheapest cell cost in the network — the per-step lower bound for the A*
# heuristic. Returns 1.0 for an empty network (harmless; nothing to search).
func min_cost() -> float:
	if _min_cost_cache >= 0.0:
		return _min_cost_cache
	var m: float = INF
	for c in _costs.values():
		if c < m:
			m = c
	_min_cost_cache = 1.0 if m == INF else m
	return _min_cost_cache


# ---------------------------------------------------------------------------
# Engagement distance — see spec "Engagement distance".
# ---------------------------------------------------------------------------

func within_engagement_distance(cell: Vector2i, target_anchors: Array[Vector2i],
		d: int, metric: Metric = Metric.MANHATTAN) -> bool:
	if target_anchors.is_empty() or d < 0:
		return false
	if metric == Metric.MANHATTAN:
		for anchor in target_anchors:
			var md: int = absi(cell.x - anchor.x) + absi(cell.y - anchor.y)
			if md <= d:
				return true
		return false
	# NETWORK: BFS hop distances from `cell` over the graph (ignoring tags —
	# engagement is about line-of-walk proximity, not access), up to depth
	# d + 1 so an anchor reached via an adjacent cell still counts.
	if not _costs.has(cell):
		return false
	var dist: Dictionary = {cell: 0}
	var queue: Array[Vector2i] = [cell]
	var head: int = 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		var cur_d: int = dist[cur]
		if cur_d >= d + 1:
			continue
		for offset in ADJACENCY:
			var n: Vector2i = cur + offset
			if _costs.has(n) and not dist.has(n):
				dist[n] = cur_d + 1
				queue.append(n)
	for anchor in target_anchors:
		# Anchor itself a network cell within d.
		if dist.has(anchor) and dist[anchor] <= d:
			return true
		# Or a network cell adjacent to the anchor within d-1 (so anchor is d).
		for offset in ADJACENCY:
			var c: Vector2i = anchor + offset
			if dist.has(c) and dist[c] + 1 <= d:
				return true
	return false


# ---------------------------------------------------------------------------
# Route cache
# ---------------------------------------------------------------------------

static func route_key(from: Vector2i, to: Vector2i, agent_tags: Array[StringName] = []) -> String:
	var sorted_tags: Array = agent_tags.duplicate()
	sorted_tags.sort()
	return "%d,%d>%d,%d|%s" % [from.x, from.y, to.x, to.y, ",".join(sorted_tags)]


func has_cached_route(key: String) -> bool:
	return _route_cache.has(key)


func get_cached_route(key: String) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _route_cache.has(key):
		out.append_array(_route_cache[key])
	return out


func cache_route(key: String, route: Array[Vector2i]) -> void:
	_route_cache[key] = route.duplicate()


func clear_cache() -> void:
	_route_cache.clear()
