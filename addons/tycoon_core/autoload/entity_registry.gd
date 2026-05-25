extends Node
# Spec: docs/build-plan.md §3 (autoloads — EntityRegistry), Prompt 5.
#
# Tracks all placed EntityInstances. Place / remove / upgrade operations all
# go through the Ledger for cost reporting. Indexes for type and spatial
# queries — proximity is needed by Effect resolution (Prompt 7).
# Theme-agnostic: this is the generic placement layer.

const DEFAULT_REFUND_FRACTION: float = 0.5

var refund_fraction: float = DEFAULT_REFUND_FRACTION

# instance_id -> EntityInstance
var instances: Dictionary = {}
# entity_def_id -> Array[int] (instance ids)
var _by_def_id: Dictionary = {}
# Vector2i (tile) -> int (instance_id). O(1) footprint-collision check.
var _cell_owners: Dictionary = {}

var _next_id: int = 1


func reset() -> void:
	instances.clear()
	_by_def_id.clear()
	_cell_owners.clear()
	_next_id = 1


# Called by ContentDB.load_all once BalanceConfig is loaded.
func configure(p_refund_fraction: float) -> void:
	refund_fraction = p_refund_fraction


# Place an EntityDef at `position`. Returns the new instance_id (>= 1) on
# success, or 0 on failure (with push_warning).
func place(def_id: StringName, position: Vector2i) -> int:
	var def: EntityDef = ContentDB.get_entity_def(def_id)
	if def == null:
		push_warning("EntityRegistry.place: unknown entity def_id '%s'" % def_id)
		return 0
	if Ledger.get_balance() < def.build_cost:
		push_warning("EntityRegistry.place: insufficient funds for '%s' (need %d, have %d)" %
			[def_id, def.build_cost, Ledger.get_balance()])
		return 0
	if _has_collision(position, def.footprint):
		push_warning("EntityRegistry.place: footprint collision at %s" % position)
		return 0

	var inst := EntityInstance.new()
	inst.instance_id = _next_id
	_next_id += 1
	inst.entity_def_id = def_id
	inst.position = position
	inst.upgrade_tier = 0

	instances[inst.instance_id] = inst
	if not _by_def_id.has(def_id):
		_by_def_id[def_id] = [] as Array[int]
	(_by_def_id[def_id] as Array[int]).append(inst.instance_id)
	_claim_cells(inst.instance_id, position, def.footprint)

	Ledger.post_expense(def.build_cost, "Build %s" % def.display_name, def_id)
	EventBus.entity_placed.emit(inst.instance_id)
	return inst.instance_id


# Returns true if removed; false if id was unknown.
func remove(instance_id: int) -> bool:
	if not instances.has(instance_id):
		return false
	var inst: EntityInstance = instances[instance_id]
	var def := inst.get_def()
	if def == null:
		return false

	var refund := int(inst.get_total_invested() * refund_fraction)
	if refund > 0:
		Ledger.post_income(refund, "Sell %s" % def.display_name, inst.entity_def_id)

	_release_cells(instance_id, inst.position, def.footprint)
	var by_def: Array = _by_def_id[inst.entity_def_id]
	by_def.erase(instance_id)
	if by_def.is_empty():
		_by_def_id.erase(inst.entity_def_id)
	instances.erase(instance_id)
	EventBus.entity_removed.emit(instance_id)
	return true


# Advance one tier along the def's upgrade_chain. Returns true on success.
func upgrade(instance_id: int) -> bool:
	if not instances.has(instance_id):
		return false
	var inst: EntityInstance = instances[instance_id]
	var def := inst.get_def()
	if def == null:
		return false
	var next_tier_idx := inst.upgrade_tier
	if next_tier_idx >= def.upgrade_chain.size():
		push_warning("EntityRegistry.upgrade: no more tiers for instance %d (def '%s')" %
			[instance_id, inst.entity_def_id])
		return false
	var tier: UpgradeTier = def.upgrade_chain[next_tier_idx]
	if Ledger.get_balance() < tier.cost:
		push_warning("EntityRegistry.upgrade: insufficient funds (need %d, have %d)" %
			[tier.cost, Ledger.get_balance()])
		return false

	Ledger.post_expense(tier.cost, "Upgrade %s" % def.display_name, inst.entity_def_id)
	inst.upgrade_tier += 1
	EventBus.entity_upgraded.emit(instance_id, inst.upgrade_tier)
	return true


# --- Queries --------------------------------------------------------------

func get_instance(instance_id: int) -> EntityInstance:
	return instances.get(instance_id)


func get_instances_by_def(def_id: StringName) -> Array[int]:
	var out: Array[int] = []
	if _by_def_id.has(def_id):
		out.append_array(_by_def_id[def_id])
	return out


# Returns instance ids whose footprint *center* lies within `radius` of
# `center`. Linear scan — adequate for early-stage; revisit with a spatial
# hash if the registry grows past a few hundred entities.
func get_instances_in_radius(center: Vector2, radius: float) -> Array[int]:
	var out: Array[int] = []
	var radius_sq := radius * radius
	for id in instances.keys():
		var inst: EntityInstance = instances[id]
		var def := inst.get_def()
		if def == null:
			continue
		var entity_center := Vector2(inst.position) + Vector2(def.footprint) * 0.5
		if entity_center.distance_squared_to(center) <= radius_sq:
			out.append(id)
	return out


# --- Internal --------------------------------------------------------------

func _has_collision(pos: Vector2i, footprint: Vector2i) -> bool:
	for dx in footprint.x:
		for dy in footprint.y:
			var cell := pos + Vector2i(dx, dy)
			if _cell_owners.has(cell):
				return true
	return false


func _claim_cells(instance_id: int, pos: Vector2i, footprint: Vector2i) -> void:
	for dx in footprint.x:
		for dy in footprint.y:
			_cell_owners[pos + Vector2i(dx, dy)] = instance_id


func _release_cells(instance_id: int, pos: Vector2i, footprint: Vector2i) -> void:
	for dx in footprint.x:
		for dy in footprint.y:
			var cell := pos + Vector2i(dx, dy)
			if _cell_owners.get(cell) == instance_id:
				_cell_owners.erase(cell)


# Save / load (Prompt 9). Instances serialize as a flat array; indexes
# (by_def_id, cell_owners) are rebuilt on load from the canonical data.
func save_state() -> Dictionary:
	var ser: Array = []
	for id in instances.keys():
		var inst: EntityInstance = instances[id]
		ser.append({
			"instance_id": inst.instance_id,
			"entity_def_id": String(inst.entity_def_id),
			"position": [inst.position.x, inst.position.y],
			"upgrade_tier": inst.upgrade_tier,
			"state": inst.state,
		})
	return {
		"instances": ser,
		"next_id": _next_id,
	}


func load_state(data: Dictionary) -> void:
	reset()  # clears instances, by_def_id, cell_owners; keeps refund_fraction
	for entry in data.get("instances", []):
		var inst := EntityInstance.new()
		inst.instance_id = entry.get("instance_id", 0)
		inst.entity_def_id = StringName(entry.get("entity_def_id", ""))
		var pos_arr: Array = entry.get("position", [0, 0])
		inst.position = Vector2i(pos_arr[0], pos_arr[1])
		inst.upgrade_tier = entry.get("upgrade_tier", 0)
		inst.state = entry.get("state", {})

		instances[inst.instance_id] = inst
		if not _by_def_id.has(inst.entity_def_id):
			_by_def_id[inst.entity_def_id] = [] as Array[int]
		(_by_def_id[inst.entity_def_id] as Array[int]).append(inst.instance_id)
		var def := inst.get_def()
		if def != null:
			_claim_cells(inst.instance_id, inst.position, def.footprint)
	_next_id = data.get("next_id", _next_id)
