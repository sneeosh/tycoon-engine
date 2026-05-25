extends Node
# Spec: docs/build-plan.md §3 (systems — effect resolution, appeal matching),
# Prompt 7.
#
# Bridges placed EntityInstances and simulation outcomes:
#   - At day_ended: posts revenue Effects to Ledger, multiplies spawn-rate
#     Effects into AgentPool.current_spawn_multiplier.
#   - Per tick: AgentPool pulls satisfaction and need-decay modifiers via
#     compute_*_modifier_for(...) on the hot path.
#   - Games pull quality via compute_quality_modifier() in their
#     IQualityRating implementations.
#
# Also exposes the generic `appeal_match(agent_type, entity_def)` scoring —
# the bridge from EntityDef.appeal_profile to AgentType.preferences.
# Game IValueModel / ISatisfactionModel implementations call it.
#
# Ordering note: EffectResolver runs AFTER Ledger and AgentPool on day_ended
# (autoload order). Revenue posted here lands in the *next* day's
# yesterday-breakdown, not the one just settled. Balance reflects immediately.
# A pre-settlement signal could fix this; deferred until needed.

func _ready() -> void:
	EventBus.day_ended.connect(_on_day_ended)


# --- day_ended handlers ---------------------------------------------------

func _on_day_ended(_day: int) -> void:
	_apply_revenue_effects()
	_apply_spawn_rate_effects()


func _apply_revenue_effects() -> void:
	var total_income: int = 0
	var total_expense: int = 0
	for inst: EntityInstance in EntityRegistry.instances.values():
		for eff: Effect in inst.get_active_effects():
			if eff.target != Effect.TARGET_REVENUE:
				continue
			if not _conditions_active(eff):
				continue
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
	for inst: EntityInstance in EntityRegistry.instances.values():
		for eff: Effect in inst.get_active_effects():
			if eff.target != Effect.TARGET_SATISFACTION:
				continue
			if not _conditions_active(eff):
				continue
			if not _agent_in_effect_range(agent, inst, eff.proximity):
				continue
			total += eff.magnitude
	return total


# Sum of need-decay Effects affecting this agent and this need right now.
# Added to the base decay rate (positive = faster decay, negative = slower).
func compute_need_decay_modifier_for(agent: Agent, _need_id: StringName) -> float:
	var total: float = 0.0
	for inst: EntityInstance in EntityRegistry.instances.values():
		for eff: Effect in inst.get_active_effects():
			if eff.target != Effect.TARGET_NEED_DECAY:
				continue
			if not _conditions_active(eff):
				continue
			if not _agent_in_effect_range(agent, inst, eff.proximity):
				continue
			total += eff.magnitude
	return total


# Aggregate spawn-rate modifier from all currently-active spawn-rate Effects.
# ADD operations contribute additively; MULTIPLY operations multiply. The
# final multiplier is (1.0 + sum_add) * product_mul.
func compute_spawn_rate_modifier() -> float:
	var add: float = 0.0
	var mul: float = 1.0
	for inst: EntityInstance in EntityRegistry.instances.values():
		for eff: Effect in inst.get_active_effects():
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
	for inst: EntityInstance in EntityRegistry.instances.values():
		for eff: Effect in inst.get_active_effects():
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
	if agent_type.preferences.is_empty():
		return 1.0
	var sum: float = 0.0
	var n: int = 0
	for axis in agent_type.preferences.keys():
		var pref: Vector2 = agent_type.preferences[axis]
		var preferred: float = pref.x
		var tolerance: float = maxf(pref.y, 0.0001)
		var actual: float = entity_def.appeal_profile.get(axis, 0.0)
		var diff: float = absf(actual - preferred)
		var score: float = maxf(0.0, 1.0 - diff / tolerance)
		sum += score
		n += 1
	return sum / n if n > 0 else 1.0


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
