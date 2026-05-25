extends Node
# Spec: design/algorithms/zone_pattern.md (RegionRegistry §) +
#       design/algorithms/region_detection.md +
#       design/algorithms/placement_compatibility.md
#
# Tracks Regions — connected components of edge-adjacent same-kind zone
# tiles in EntityRegistry. Reactively recomputes regions on
# entity_placed / entity_removed and exposes placement management.
#
# Theme-agnostic; the engine doesn't know what "kind" a region is beyond
# matching string names.

# Signals mirrored from EventBus for caller convenience — either works.
# Game code can do `RegionRegistry.region_created.connect(...)` or
# `EventBus.region_created.connect(...)`; both fire at the same time.
signal region_created(region_id: int)
signal region_destroyed(region_id: int)
signal region_changed(region_id: int)
signal placement_added(region_id: int, index: int)
signal placement_removed(region_id: int, index: int)
signal placement_stranded(region_id: int, index: int)


const ADJACENCY: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(0, 1),
	Vector2i(-1, 0),
	Vector2i(1, 0),
]

# region_id -> Region
var regions: Dictionary = {}

# instance_id (zone tile) -> region_id
var _tile_membership: Dictionary = {}

# Vector2i cell -> region_id (for region_at_cell queries)
var _cell_to_region: Dictionary = {}

var _next_region_id: int = 1


func _ready() -> void:
	EventBus.entity_placed.connect(_on_entity_placed)
	EventBus.entity_removed.connect(_on_entity_removed)


func reset() -> void:
	regions.clear()
	_tile_membership.clear()
	_cell_to_region.clear()
	_next_region_id = 1


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func get_region(region_id: int) -> Region:
	return regions.get(region_id)


func region_for_tile(instance_id: int) -> Region:
	if not _tile_membership.has(instance_id):
		return null
	return regions.get(_tile_membership[instance_id])


func region_at_cell(cell: Vector2i) -> Region:
	if not _cell_to_region.has(cell):
		return null
	return regions.get(_cell_to_region[cell])


func all_regions() -> Array[Region]:
	var out: Array[Region] = []
	for r in regions.values():
		out.append(r)
	return out


# ---------------------------------------------------------------------------
# Placement management — see placement_compatibility.md
# ---------------------------------------------------------------------------

# Returns {"ok": bool, "reason": String}. Tied to the worked examples in
# placement_compatibility.md.
func can_add_placement(region_id: int, placeable_def_id: StringName) -> Dictionary:
	var region: Region = regions.get(region_id)
	if region == null:
		return {"ok": false, "reason": "unknown region"}
	var candidate: PlaceableDef = ContentDB.placeable_defs.get(placeable_def_id)
	if candidate == null:
		return {"ok": false, "reason": "unknown placeable"}

	# Order: incompatibility → zone tags → space.
	# Incompat is the most informative error to surface first (the player
	# can't fix it by expanding the region), then habitat mismatch, then
	# space (which they can fix by extending the region). See spec.

	# 1. Incompatibility — symmetric.
	for existing: Placement in region.placements:
		var ex_def: PlaceableDef = ContentDB.placeable_defs.get(existing.placeable_def_id)
		if ex_def == null:
			continue
		for tag in ex_def.own_tags:
			if tag in candidate.incompatible_tags:
				return {
					"ok": false,
					"reason": "incompatible with %s" % ex_def.display_name,
				}
		for tag in candidate.own_tags:
			if tag in ex_def.incompatible_tags:
				return {
					"ok": false,
					"reason": "incompatible with %s" % ex_def.display_name,
				}

	# 2. Zone tags
	for tag in candidate.required_zone_tags:
		if tag not in region.provided_zone_tags:
			return {"ok": false, "reason": "missing zone tag: %s" % tag}

	# 3. Space
	var space_used: int = 0
	for p: Placement in region.placements:
		var p_def: PlaceableDef = ContentDB.placeable_defs.get(p.placeable_def_id)
		if p_def != null:
			space_used += p_def.space_required
	var space_free: int = region.area - space_used
	if candidate.space_required > space_free:
		return {
			"ok": false,
			"reason": "over space: need %d, have %d" %
				[candidate.space_required, space_free],
		}

	return {"ok": true, "reason": ""}


# Adds a placement to a region. Returns the new Placement on success, null
# on failure (compatibility check failed; same shape as can_add_placement
# would have returned). Posts the build cost and registers per-placement
# maintenance via the same pattern EntityRegistry uses since v0.3.0.
func add_placement(region_id: int, placeable_def_id: StringName) -> Placement:
	var check := can_add_placement(region_id, placeable_def_id)
	if not check["ok"]:
		push_warning("RegionRegistry.add_placement: %s" % check["reason"])
		return null
	var region: Region = regions[region_id]
	var def: PlaceableDef = ContentDB.placeable_defs[placeable_def_id]
	var p := Placement.new()
	p.placeable_def_id = placeable_def_id
	p.added_at_tick = SimClock.current_tick
	# Anchor cell = first available cell in the region. Stable, deterministic.
	p.primary_cell = region.cells[0] if not region.cells.is_empty() else Vector2i.ZERO
	region.placements.append(p)
	Ledger.post_expense(def.build_cost, "Place %s" % def.display_name, def.id)
	_register_placement_maintenance(region_id, region.placements.size() - 1, def)
	EventBus.placement_added.emit(region_id, region.placements.size() - 1); placement_added.emit(region_id, region.placements.size() - 1)
	return p


func remove_placement(region_id: int, index: int) -> bool:
	var region: Region = regions.get(region_id)
	if region == null:
		return false
	if index < 0 or index >= region.placements.size():
		return false
	var p: Placement = region.placements[index]
	var def: PlaceableDef = ContentDB.placeable_defs.get(p.placeable_def_id)
	_unregister_placement_maintenance(region_id, index)
	region.placements.remove_at(index)
	EventBus.placement_removed.emit(region_id, index); placement_removed.emit(region_id, index)
	if def != null:
		# Half-refund mirrors EntityRegistry.remove's convention.
		var refund: int = int(def.build_cost * 0.5)
		if refund > 0:
			Ledger.post_income(refund, "Remove %s" % def.display_name, def.id)
	return true


# ---------------------------------------------------------------------------
# Region detection — see region_detection.md
# ---------------------------------------------------------------------------

func _on_entity_placed(instance_id: int) -> void:
	var inst: EntityInstance = EntityRegistry.get_instance(instance_id)
	if inst == null:
		return
	var def := inst.get_def()
	if def == null or def.zone_kind == &"":
		return  # not a zone tile

	# Find same-kind neighbour regions.
	var neighbour_region_ids: Array[int] = []
	for offset in ADJACENCY:
		for cell in _cells_of(inst, def):
			var n := cell + offset
			if not _cell_to_region.has(n):
				continue
			var rid: int = _cell_to_region[n]
			var r: Region = regions[rid]
			if r.kind == def.zone_kind and rid not in neighbour_region_ids:
				neighbour_region_ids.append(rid)

	if neighbour_region_ids.is_empty():
		# Isolated new region.
		var r := Region.new()
		r.region_id = _next_region_id
		_next_region_id += 1
		r.kind = def.zone_kind
		r.member_instance_ids = [instance_id]
		r.cells = _cells_of(inst, def)
		r.provided_zone_tags = def.zone_tags.duplicate()
		regions[r.region_id] = r
		_tile_membership[instance_id] = r.region_id
		for c in r.cells:
			_cell_to_region[c] = r.region_id
		EventBus.region_created.emit(r.region_id); region_created.emit(r.region_id)
		return

	if neighbour_region_ids.size() == 1:
		# Extend.
		var rid: int = neighbour_region_ids[0]
		var r: Region = regions[rid]
		r.member_instance_ids.append(instance_id)
		for c in _cells_of(inst, def):
			r.cells.append(c)
			_cell_to_region[c] = rid
		_merge_zone_tags(r, def.zone_tags)
		_tile_membership[instance_id] = rid
		EventBus.region_changed.emit(rid); region_changed.emit(rid)
		return

	# Multi-neighbour merge: keep first, absorb rest.
	var primary_id: int = neighbour_region_ids[0]
	var primary: Region = regions[primary_id]
	for other_id in neighbour_region_ids.slice(1):
		var other: Region = regions[other_id]
		primary.member_instance_ids.append_array(other.member_instance_ids)
		primary.cells.append_array(other.cells)
		_merge_zone_tags(primary, other.provided_zone_tags)
		primary.placements.append_array(other.placements)
		for tid in other.member_instance_ids:
			_tile_membership[tid] = primary_id
		for c in other.cells:
			_cell_to_region[c] = primary_id
		regions.erase(other_id)
		EventBus.region_destroyed.emit(other_id); region_destroyed.emit(other_id)
	primary.member_instance_ids.append(instance_id)
	for c in _cells_of(inst, def):
		primary.cells.append(c)
		_cell_to_region[c] = primary_id
	_merge_zone_tags(primary, def.zone_tags)
	_tile_membership[instance_id] = primary_id
	EventBus.region_changed.emit(primary_id); region_changed.emit(primary_id)


func _on_entity_removed(instance_id: int) -> void:
	if not _tile_membership.has(instance_id):
		return
	var rid: int = _tile_membership[instance_id]
	_tile_membership.erase(instance_id)
	var r: Region = regions[rid]
	r.member_instance_ids.erase(instance_id)
	# Free this tile's cells from the cell index. Compute first since the
	# EntityInstance is already gone from EntityRegistry by the time
	# entity_removed fires.
	var freed_cells: Array[Vector2i] = []
	for cell in _cell_to_region.keys():
		if _cell_to_region[cell] == rid:
			# We need to know which cells belonged to the REMOVED tile vs
			# others in the region. Easiest: recompute the region's cell
			# set from its remaining members.
			pass
	# Recompute the region's cell set from remaining members.
	r.cells = _cells_for_members(r.member_instance_ids)
	# Drop _cell_to_region entries no longer present.
	for cell in _cell_to_region.keys():
		if _cell_to_region[cell] == rid and cell not in r.cells:
			_cell_to_region.erase(cell)

	if r.member_instance_ids.is_empty():
		for i in r.placements.size():
			EventBus.placement_stranded.emit(rid, i); placement_stranded.emit(rid, i)
		regions.erase(rid)
		EventBus.region_destroyed.emit(rid); region_destroyed.emit(rid)
		return

	# Recompute zone tags from remaining members.
	r.provided_zone_tags = _zone_tags_for_members(r.member_instance_ids)

	# Flood-fill the remaining members to detect splits.
	var components: Array = _flood_fill_components(r.member_instance_ids)

	if components.size() == 1:
		# Still one component — just shrunk in place.
		_check_strandings(r)
		EventBus.region_changed.emit(rid); region_changed.emit(rid)
		return

	# Split: keep the largest component on the existing region id.
	components.sort_custom(func(a, b): return a.size() > b.size())
	var kept: Array = components[0]
	r.member_instance_ids = kept
	r.cells = _cells_for_members(kept)
	r.provided_zone_tags = _zone_tags_for_members(kept)
	for c in r.cells:
		_cell_to_region[c] = rid

	# Reassign placements based on primary_cell membership. Games may
	# override the engine-stamped primary_cell via state["primary_cell"]
	# (e.g. when the player picks a specific cell at add time).
	var kept_placements: Array[Placement] = []
	var migrated_by_component: Array = []
	for _i in components.size() - 1:
		migrated_by_component.append([] as Array[Placement])
	for p: Placement in r.placements:
		var primary: Vector2i = p.state.get("primary_cell", p.primary_cell)
		if primary in r.cells:
			kept_placements.append(p)
			continue
		# Find which other component owns it; if none, it stays in `kept`
		# (stranded — primary cell removed).
		var placed := false
		for i in range(components.size() - 1):
			var component_cells := _cells_for_members(components[i + 1])
			if primary in component_cells:
				migrated_by_component[i].append(p)
				placed = true
				break
		if not placed:
			kept_placements.append(p)
	r.placements = kept_placements

	# Create new regions for the other components.
	for i in range(components.size() - 1):
		var new_r := Region.new()
		new_r.region_id = _next_region_id
		_next_region_id += 1
		new_r.kind = r.kind
		new_r.member_instance_ids = components[i + 1]
		new_r.cells = _cells_for_members(new_r.member_instance_ids)
		new_r.provided_zone_tags = _zone_tags_for_members(new_r.member_instance_ids)
		new_r.placements = migrated_by_component[i]
		regions[new_r.region_id] = new_r
		for tid in new_r.member_instance_ids:
			_tile_membership[tid] = new_r.region_id
		for c in new_r.cells:
			_cell_to_region[c] = new_r.region_id
		EventBus.region_created.emit(new_r.region_id); region_created.emit(new_r.region_id)
		_check_strandings(new_r)

	_check_strandings(r)
	EventBus.region_changed.emit(rid); region_changed.emit(rid)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _cells_of(inst: EntityInstance, def: EntityDef) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dx in def.footprint.x:
		for dy in def.footprint.y:
			out.append(inst.position + Vector2i(dx, dy))
	return out


func _cells_for_members(ids: Array[int]) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for id in ids:
		var inst: EntityInstance = EntityRegistry.get_instance(id)
		if inst == null:
			continue
		var def := inst.get_def()
		if def == null:
			continue
		out.append_array(_cells_of(inst, def))
	return out


func _zone_tags_for_members(ids: Array[int]) -> Array[StringName]:
	var out: Array[StringName] = []
	for id in ids:
		var inst: EntityInstance = EntityRegistry.get_instance(id)
		if inst == null:
			continue
		var def := inst.get_def()
		if def == null:
			continue
		for tag in def.zone_tags:
			if tag not in out:
				out.append(tag)
	return out


func _merge_zone_tags(r: Region, new_tags: Array[StringName]) -> void:
	for tag in new_tags:
		if tag not in r.provided_zone_tags:
			r.provided_zone_tags.append(tag)


# Returns an Array of Array[int] — each sub-array is a connected component
# of `member_ids` under same-kind 4-adjacency.
func _flood_fill_components(member_ids: Array[int]) -> Array:
	var components: Array = []
	var unvisited: Dictionary = {}
	for id in member_ids:
		unvisited[id] = true
	# Build a cell → member id lookup for the input set.
	var cell_owner: Dictionary = {}
	for id in member_ids:
		var inst: EntityInstance = EntityRegistry.get_instance(id)
		if inst == null:
			continue
		var def := inst.get_def()
		if def == null:
			continue
		for c in _cells_of(inst, def):
			cell_owner[c] = id

	while not unvisited.is_empty():
		var seed_id: int = unvisited.keys()[0]
		var component: Array[int] = []
		var stack: Array[int] = [seed_id]
		while not stack.is_empty():
			var id: int = stack.pop_back()
			if not unvisited.has(id):
				continue
			unvisited.erase(id)
			component.append(id)
			var inst: EntityInstance = EntityRegistry.get_instance(id)
			if inst == null:
				continue
			var def := inst.get_def()
			if def == null:
				continue
			for cell in _cells_of(inst, def):
				for offset in ADJACENCY:
					var n := cell + offset
					if not cell_owner.has(n):
						continue
					var neighbour_id: int = cell_owner[n]
					if neighbour_id != id and unvisited.has(neighbour_id):
						stack.append(neighbour_id)
		components.append(component)
	return components


func _check_strandings(r: Region) -> void:
	for i in r.placements.size():
		var p: Placement = r.placements[i]
		var def: PlaceableDef = ContentDB.placeable_defs.get(p.placeable_def_id)
		if def == null:
			continue
		var stranded := false
		# Space stranding.
		var space_used: int = 0
		for other: Placement in r.placements:
			var od: PlaceableDef = ContentDB.placeable_defs.get(other.placeable_def_id)
			if od != null:
				space_used += od.space_required
		if space_used > r.area:
			stranded = true
		# Zone tag stranding.
		if not stranded:
			for tag in def.required_zone_tags:
				if tag not in r.provided_zone_tags:
					stranded = true
					break
		if stranded:
			EventBus.placement_stranded.emit(r.region_id, i); placement_stranded.emit(r.region_id, i)


# ---------------------------------------------------------------------------
# Per-placement maintenance (mirrors EntityRegistry.maintenance pattern)
# ---------------------------------------------------------------------------

func _register_placement_maintenance(region_id: int, index: int, def: PlaceableDef) -> void:
	if def.maintenance_cost <= 0:
		return
	Ledger.register_recurring({
		"id": _placement_rule_id(region_id, index),
		"label": "Maintain %s" % def.display_name,
		"amount": def.maintenance_cost,
		"kind": Ledger.KIND_EXPENSE,
		"period": Ledger.PERIOD_DAILY,
	})


func _unregister_placement_maintenance(region_id: int, index: int) -> void:
	Ledger.unregister_recurring(_placement_rule_id(region_id, index))


func _placement_rule_id(region_id: int, index: int) -> StringName:
	return StringName("place_maint_%d_%d" % [region_id, index])
