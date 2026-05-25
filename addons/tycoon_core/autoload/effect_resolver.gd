extends Node
# Spec: docs/build-plan.md §3 (systems — effect resolution, appeal matching),
# Prompt 7.
#
# Bridges placed EntityInstances and simulation outcomes:
#   - At `day_ending` (NEW in v0.3.0 — formerly `day_ended`): posts revenue
#     Effects to Ledger and multiplies spawn-rate Effects into
#     AgentPool.current_spawn_multiplier. Running pre-settlement means
#     revenue earned today shows up in *today's* yesterday-breakdown, not
#     the following day's.
#   - Per tick: AgentPool pulls satisfaction and need-decay modifiers via
#     compute_*_modifier_for(...) on the hot path.
#   - Games pull quality via compute_quality_modifier() in their
#     IQualityRating implementations.
#
# Also exposes the generic `appeal_match(agent_type, entity_def)` scoring —
# the bridge from EntityDef.appeal_profile to AgentType.preferences.
# Game IValueModel / ISatisfactionModel implementations call it.
#
# Performance: the per-tick `compute_*_for(agent)` calls used to iterate
# `EntityRegistry.instances.values()` and traverse each entity's effect
# chain. v0.3.0 added a flat `(instance, effect)` cache that's rebuilt only
# when entities are placed/removed/upgraded. Hot-path scaling is now
# O(effects) instead of O(entities × effects per entity).

# Each entry: {"inst": EntityInstance, "eff": Effect}
var _effect_cache: Array = []
var _cache_dirty: bool = true

# v0.4.0 — pluggable per-placement happiness multiplier consumed by
# compute_region_appeal. Default returns 1.0 (so happiness-agnostic games
# get straightforward "sum of contributions" automatically). Games override
# via register_happiness_model. See design/algorithms/zone_pattern.md.
var _happiness_model: IPlaceableHappiness = IPlaceableHappiness.new()


func _ready() -> void:
	# Revenue runs at day_ending (before Ledger settles) so the income
	# lands in the day it was earned for. Spawn-rate runs at day_ended
	# (after AgentPool recomputes the base curve from aggregate
	# satisfaction) so our multiplier composes on top of it instead of
	# being overwritten.
	EventBus.day_ending.connect(_on_day_ending)
	EventBus.day_ended.connect(_on_day_ended)
	EventBus.entity_placed.connect(_invalidate_cache)
	EventBus.entity_removed.connect(_invalidate_cache)
	EventBus.entity_upgraded.connect(_invalidate_cache_upgraded)


# --- day boundary handlers ------------------------------------------------

func _on_day_ending(_day: int) -> void:
	_apply_revenue_effects()


func _on_day_ended(_day: int) -> void:
	_apply_spawn_rate_effects()


func _apply_revenue_effects() -> void:
	var total_income: int = 0
	var total_expense: int = 0
	for entry: Dictionary in _ensure_cache():
		var eff: Effect = entry["eff"]
		if eff.target != Effect.TARGET_REVENUE:
			continue
		if not _conditions_active(eff):
			continue
		var inst: EntityInstance = entry["inst"]
		var nearby_count := _agents_in_effect_range(inst, eff.proximity).size()
		# Revenue effects are "magnitude per nearby agent". For
		# global (proximity=0), nearby_count is the live agent total.
		var amount := int(eff.magnitude * nearby_count)
		if amount > 0:
			total_income += amount
		elif amount < 0:
			total_expense += -amount
	if total_income > 0:
		Ledger.post_income(total_income, "Effect revenue")
	if total_expense > 0:
		Ledger.post_expense(total_expense, "Effect expense")


func _apply_spawn_rate_effects() -> void:
	var mult := compute_spawn_rate_modifier()
	if mult != 1.0:
		AgentPool.current_spawn_multiplier *= mult


# --- Pull queries (called by AgentPool hot path + game code) -------------

# Sum of satisfaction Effects affecting this agent right now. Caller applies
# the result (typically: agent.satisfaction += result, then clamp).
func compute_satisfaction_modifier_for(agent: Agent) -> float:
	var total: float = 0.0
	for entry: Dictionary in _ensure_cache():
		var eff: Effect = entry["eff"]
		if eff.target != Effect.TARGET_SATISFACTION:
			continue
		if not _conditions_active(eff):
			continue
		if not _agent_in_effect_range(agent, entry["inst"], eff.proximity):
			continue
		total += eff.magnitude
	return total


# Sum of need-decay Effects affecting this agent and this need right now.
# Added to the base decay rate (positive = faster decay, negative = slower).
func compute_need_decay_modifier_for(agent: Agent, _need_id: StringName) -> float:
	var total: float = 0.0
	for entry: Dictionary in _ensure_cache():
		var eff: Effect = entry["eff"]
		if eff.target != Effect.TARGET_NEED_DECAY:
			continue
		if not _conditions_active(eff):
			continue
		if not _agent_in_effect_range(agent, entry["inst"], eff.proximity):
			continue
		total += eff.magnitude
	return total


# Aggregate spawn-rate modifier from all currently-active spawn-rate Effects.
# ADD operations contribute additively; MULTIPLY operations multiply. The
# final multiplier is (1.0 + sum_add) * product_mul.
func compute_spawn_rate_modifier() -> float:
	var add: float = 0.0
	var mul: float = 1.0
	for entry: Dictionary in _ensure_cache():
		var eff: Effect = entry["eff"]
		if eff.target != Effect.TARGET_SPAWN_RATE:
			continue
		if not _conditions_active(eff):
			continue
		if eff.operation == Effect.OP_MULTIPLY:
			mul *= eff.magnitude
		else:
			add += eff.magnitude
	return (1.0 + add) * mul


# Sum of quality Effects active globally. Games pull this in their
# IQualityRating implementation.
func compute_quality_modifier() -> float:
	var total: float = 0.0
	for entry: Dictionary in _ensure_cache():
		var eff: Effect = entry["eff"]
		if eff.target != Effect.TARGET_QUALITY:
			continue
		if not _conditions_active(eff):
			continue
		total += eff.magnitude
	return total


# --- Appeal match --------------------------------------------------------

# Generic appeal-match score. Higher = better fit between this AgentType's
# preferences and this EntityDef's appeal_profile.
#
# For each axis in agent_type.preferences:
#   preferred, tolerance = preferences[axis]  (Vector2(preferred, tolerance))
#   actual                = entity_def.appeal_profile.get(axis, 0.0)
#   score                 = max(0, 1 - |actual - preferred| / tolerance)
# Aggregate: arithmetic mean across axes.
#
# Empty preferences → 1.0 (no preferences = anything is fine).
# Tolerance ≤ 0 → treated as a tiny epsilon to avoid division by zero
# (effectively makes any non-exact match score 0).
func appeal_match(agent_type: AgentType, entity_def: EntityDef) -> float:
	return _appeal_match_against_profile(agent_type, entity_def.appeal_profile)


func _appeal_match_against_profile(agent_type: AgentType, profile: Dictionary) -> float:
	if agent_type.preferences.is_empty():
		return 1.0
	var sum: float = 0.0
	var n: int = 0
	for axis in agent_type.preferences.keys():
		var pref: Vector2 = agent_type.preferences[axis]
		var preferred: float = pref.x
		var tolerance: float = maxf(pref.y, 0.0001)
		var actual: float = profile.get(axis, 0.0)
		var diff: float = absf(actual - preferred)
		var score: float = maxf(0.0, 1.0 - diff / tolerance)
		sum += score
		n += 1
	return sum / n if n > 0 else 1.0


# --- Region appeal (v0.4.0 — see design/algorithms/region_appeal.md) ----

# Saturation aggregation of per-placement appeal contributions, modulated
# by the registered IPlaceableHappiness model. Returns an appeal_profile
# Dict[axis -> float in [0,1]] suitable for _appeal_match_against_profile.
func compute_region_appeal(region: Region) -> Dictionary:
	# axis (StringName) -> running PRODUCT of (1 - effective_contrib)
	var remaining: Dictionary = {}
	for i in region.placements.size():
		var placement: Placement = region.placements[i]
		var p_def: PlaceableDef = ContentDB.placeable_defs.get(placement.placeable_def_id)
		if p_def == null:
			continue
		var happiness: float = clampf(_happiness_model.compute_happiness(region, i), 0.0, 1.0)
		for axis in p_def.appeal_contribution.keys():
			var raw_contrib: float = p_def.appeal_contribution[axis]
			var effective: float = clampf(raw_contrib * happiness, 0.0, 1.0)
			var current: float = remaining.get(axis, 1.0)
			remaining[axis] = current * (1.0 - effective)
	var appeal: Dictionary = {}
	for axis in remaining.keys():
		appeal[axis] = clampf(1.0 - remaining[axis], 0.0, 1.0)
	return appeal


# Region-aware appeal_match — same scoring math as appeal_match, applied
# to the region's *computed* appeal_profile from its placements.
func appeal_match_region(agent_type: AgentType, region: Region) -> float:
	return _appeal_match_against_profile(agent_type, compute_region_appeal(region))


# Games register their IPlaceableHappiness implementation at startup. Reset
# to the engine default by passing null.
func register_happiness_model(impl: IPlaceableHappiness) -> void:
	if impl == null:
		_happiness_model = IPlaceableHappiness.new()
	else:
		_happiness_model = impl


# --- Cache management ----------------------------------------------------

# Returns a flat array of {inst, eff} entries covering every active effect
# on every placed entity. Rebuilt lazily on first access after a placement
# change. Callers MUST treat the result as read-only.
func _ensure_cache() -> Array:
	if _cache_dirty:
		_rebuild_cache()
	return _effect_cache


func _rebuild_cache() -> void:
	_effect_cache.clear()
	for inst: EntityInstance in EntityRegistry.instances.values():
		for eff: Effect in inst.get_active_effects():
			_effect_cache.append({"inst": inst, "eff": eff})
	_cache_dirty = false


func _invalidate_cache(_inst_id: int) -> void:
	_cache_dirty = true


# entity_upgraded has a different signature (id, new_tier); separate handler
# so we don't need to bind args.
func _invalidate_cache_upgraded(_inst_id: int, _new_tier: int) -> void:
	_cache_dirty = true


# --- Internal helpers ----------------------------------------------------

func _conditions_active(eff: Effect) -> bool:
	# Empty conditions list = always active.
	if eff.conditions.is_empty():
		return true
	for cond_id in eff.conditions:
		var c: ConditionModifier = ContentDB.get_condition(cond_id)
		if c == null or not c.active:
			return false
	return true


# Agents within `proximity` of an entity's footprint center.
# proximity = 0 means "global" — returns every live agent.
func _agents_in_effect_range(inst: EntityInstance, proximity: float) -> Array[int]:
	var out: Array[int] = []
	if proximity <= 0.0:
		for id in AgentPool.agents.keys():
			out.append(id)
		return out
	var def := inst.get_def()
	if def == null:
		return out
	var center := Vector2(inst.position) + Vector2(def.footprint) * 0.5
	var radius_sq := proximity * proximity
	for id in AgentPool.agents.keys():
		var a: Agent = AgentPool.agents[id]
		if a.position.distance_squared_to(center) <= radius_sq:
			out.append(id)
	return out


func _agent_in_effect_range(agent: Agent, inst: EntityInstance, proximity: float) -> bool:
	if proximity <= 0.0:
		return true
	var def := inst.get_def()
	if def == null:
		return false
	var center := Vector2(inst.position) + Vector2(def.footprint) * 0.5
	return agent.position.distance_squared_to(center) <= proximity * proximity
