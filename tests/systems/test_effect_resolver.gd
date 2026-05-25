extends GutTest
# Tests for EffectResolver — Prompt 7.
# Spec: docs/build-plan.md §7 (Prompt 7)
#
# Covers the two things the build plan explicitly calls out:
#   (a) a proximity revenue Effect produces correct Ledger income given
#       nearby agents, and
#   (b) appeal-match scoring behaves correctly for aligned vs mismatched
#       preferences (separate test file: test_appeal_match.gd).
# Plus: conditions gating, satisfaction modifier, need-decay modifier,
# spawn-rate modifier composition.

const TEST_NEED := &"test_need"
const TEST_TYPE := &"test_agent"
const TEST_DEF := &"test_revenue_entity"
const TEST_COND := &"test_cond"


func before_each() -> void:
	AgentPool.reset()
	AgentPool.configure(0.0)  # disable auto-spawn loop
	EntityRegistry.reset()
	Ledger.reset(1000)
	SimClock.current_tick = 0
	SimClock.current_day = 0
	SimClock.ticks_per_day = 1000  # day_ended doesn't fire mid-test
	SimClock.set_seed(42)

	# Minimal Need + AgentType so we can spawn.
	var need := Need.new()
	need.id = TEST_NEED
	need.base_decay_per_tick = 0.0  # avoid decay during tests
	ContentDB.needs[TEST_NEED] = need

	var spec := NeedSpec.new()
	spec.need = need
	spec.initial_level = 1.0
	spec.threshold = 0.5
	spec.decay_rate_multiplier = 1.0

	var type := AgentType.new()
	type.id = TEST_TYPE
	type.spawn_weight = 1.0
	type.needs = [spec]
	ContentDB.agent_types[TEST_TYPE] = type


func after_each() -> void:
	ContentDB.needs.erase(TEST_NEED)
	ContentDB.agent_types.erase(TEST_TYPE)
	ContentDB.entity_defs.erase(TEST_DEF)
	ContentDB.conditions.erase(TEST_COND)


# --- Helpers --------------------------------------------------------------

func _make_entity_with_effects(id: StringName, footprint: Vector2i, effects: Array[Effect]) -> EntityDef:
	var def := EntityDef.new()
	def.id = id
	def.display_name = String(id)
	def.build_cost = 0
	def.maintenance_cost = 0
	def.footprint = footprint
	def.effects = effects
	ContentDB.entity_defs[id] = def
	return def


func _make_revenue_effect(magnitude: float, proximity: float, conditions: Array = []) -> Effect:
	var e := Effect.new()
	e.target = Effect.TARGET_REVENUE
	e.operation = Effect.OP_ADD
	e.magnitude = magnitude
	e.proximity = proximity
	var typed: Array[StringName] = []
	for c in conditions:
		typed.append(c)
	e.conditions = typed
	return e


# --- (a) Proximity revenue effect produces correct Ledger income ---------

func test_revenue_effect_posts_magnitude_times_nearby_agent_count() -> void:
	# +5 revenue per nearby agent, range 3 tiles around the entity center.
	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [
		_make_revenue_effect(5.0, 3.0)
	])
	var ent_id := EntityRegistry.place(TEST_DEF, Vector2i(10, 10))
	assert_ne(ent_id, 0)
	# Entity center = (10.5, 10.5). Spawn 2 agents within radius, 1 outside.
	var near_a := AgentPool.spawn(TEST_TYPE, Vector2(10.5, 10.5))
	var near_b := AgentPool.spawn(TEST_TYPE, Vector2(11.5, 11.5))
	var far := AgentPool.spawn(TEST_TYPE, Vector2(20.0, 20.0))

	var pre_balance := Ledger.get_balance()
	# v0.3.0: revenue effects fire on day_ending (before Ledger settles)
	# so income lands in the day it was earned for.
	EventBus.day_ending.emit(1)
	# Expected: 2 nearby * 5 = +10
	assert_eq(Ledger.get_balance(), pre_balance + 10)


func test_revenue_effect_with_zero_proximity_counts_all_live_agents() -> void:
	# proximity=0 → global. magnitude=3 → 3 per agent everywhere.
	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [
		_make_revenue_effect(3.0, 0.0)
	])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	AgentPool.spawn(TEST_TYPE, Vector2(0, 0))
	AgentPool.spawn(TEST_TYPE, Vector2(99, 99))  # far, still counts
	AgentPool.spawn(TEST_TYPE, Vector2(-50, -50))
	var pre_balance := Ledger.get_balance()
	EventBus.day_ending.emit(1)
	assert_eq(Ledger.get_balance(), pre_balance + 9)  # 3 * 3


func test_revenue_effect_with_no_nearby_agents_posts_nothing() -> void:
	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [
		_make_revenue_effect(5.0, 2.0)
	])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	AgentPool.spawn(TEST_TYPE, Vector2(20, 20))  # far away
	var pre_balance := Ledger.get_balance()
	EventBus.day_ending.emit(1)
	assert_eq(Ledger.get_balance(), pre_balance, "no nearby agents → no revenue")


func test_negative_magnitude_revenue_effect_posts_expense() -> void:
	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [
		_make_revenue_effect(-4.0, 0.0)  # -4 per agent globally
	])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	AgentPool.spawn(TEST_TYPE)
	AgentPool.spawn(TEST_TYPE)
	var pre_balance := Ledger.get_balance()
	EventBus.day_ending.emit(1)
	assert_eq(Ledger.get_balance(), pre_balance - 8)


# --- Conditions gating ---------------------------------------------------

func test_effect_with_active_condition_applies() -> void:
	var c := ConditionModifier.new()
	c.id = TEST_COND
	c.active = true
	ContentDB.conditions[TEST_COND] = c

	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [
		_make_revenue_effect(5.0, 0.0, [TEST_COND])
	])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	AgentPool.spawn(TEST_TYPE)
	var pre := Ledger.get_balance()
	EventBus.day_ending.emit(1)
	assert_eq(Ledger.get_balance(), pre + 5)


func test_effect_with_inactive_condition_skipped() -> void:
	var c := ConditionModifier.new()
	c.id = TEST_COND
	c.active = false
	ContentDB.conditions[TEST_COND] = c

	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [
		_make_revenue_effect(5.0, 0.0, [TEST_COND])
	])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	AgentPool.spawn(TEST_TYPE)
	var pre := Ledger.get_balance()
	EventBus.day_ending.emit(1)
	assert_eq(Ledger.get_balance(), pre, "inactive condition gates effect off")


# --- Satisfaction modifier -----------------------------------------------

func test_satisfaction_modifier_sums_active_effects_in_range() -> void:
	var e1 := Effect.new()
	e1.target = Effect.TARGET_SATISFACTION
	e1.magnitude = 0.1
	e1.proximity = 5.0
	var e2 := Effect.new()
	e2.target = Effect.TARGET_SATISFACTION
	e2.magnitude = 0.05
	e2.proximity = 5.0
	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [e1, e2])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	var aid := AgentPool.spawn(TEST_TYPE, Vector2(0.5, 0.5))
	var a := AgentPool.get_agent(aid)
	assert_almost_eq(
		EffectResolver.compute_satisfaction_modifier_for(a),
		0.15, 0.0001)


func test_satisfaction_modifier_excludes_out_of_range() -> void:
	var e := Effect.new()
	e.target = Effect.TARGET_SATISFACTION
	e.magnitude = 0.2
	e.proximity = 2.0
	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [e])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	var aid := AgentPool.spawn(TEST_TYPE, Vector2(20, 20))  # far
	var a := AgentPool.get_agent(aid)
	assert_eq(EffectResolver.compute_satisfaction_modifier_for(a), 0.0)


# --- Need-decay modifier -------------------------------------------------

func test_need_decay_modifier_affects_in_range_agent() -> void:
	var e := Effect.new()
	e.target = Effect.TARGET_NEED_DECAY
	e.magnitude = 0.05  # faster decay
	e.proximity = 3.0
	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [e])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	var aid := AgentPool.spawn(TEST_TYPE, Vector2(0.5, 0.5))
	var a := AgentPool.get_agent(aid)
	assert_almost_eq(
		EffectResolver.compute_need_decay_modifier_for(a, TEST_NEED),
		0.05, 0.0001)


# --- Spawn-rate modifier composition --------------------------------------

func test_spawn_rate_modifier_combines_add_and_mul() -> void:
	var add_eff := Effect.new()
	add_eff.target = Effect.TARGET_SPAWN_RATE
	add_eff.operation = Effect.OP_ADD
	add_eff.magnitude = 0.5  # +50% additive
	var mul_eff := Effect.new()
	mul_eff.target = Effect.TARGET_SPAWN_RATE
	mul_eff.operation = Effect.OP_MULTIPLY
	mul_eff.magnitude = 2.0  # 2x multiplicative
	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [add_eff, mul_eff])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	# Expected: (1.0 + 0.5) * 2.0 = 3.0
	assert_almost_eq(EffectResolver.compute_spawn_rate_modifier(), 3.0, 0.0001)


func test_spawn_rate_modifier_applies_to_agent_pool_at_day_end() -> void:
	var mul_eff := Effect.new()
	mul_eff.target = Effect.TARGET_SPAWN_RATE
	mul_eff.operation = Effect.OP_MULTIPLY
	mul_eff.magnitude = 2.0
	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [mul_eff])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	# AgentPool.current_spawn_multiplier starts at 1.0; after day_ended,
	# AgentPool sets it to curve(neutral=0.5) ≈ 1.625, then EffectResolver
	# multiplies by 2.0 → ≈ 3.25.
	var expected_after_curve := AgentPool.spawn_curve(0.5)
	EventBus.day_ended.emit(1)
	assert_almost_eq(
		AgentPool.current_spawn_multiplier,
		expected_after_curve * 2.0, 0.0001)


# --- Quality modifier ----------------------------------------------------

func test_quality_modifier_sums_global_effects() -> void:
	var e1 := Effect.new()
	e1.target = Effect.TARGET_QUALITY
	e1.magnitude = 0.3
	var e2 := Effect.new()
	e2.target = Effect.TARGET_QUALITY
	e2.magnitude = -0.1
	_make_entity_with_effects(TEST_DEF, Vector2i(1, 1), [e1, e2])
	EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	assert_almost_eq(EffectResolver.compute_quality_modifier(), 0.2, 0.0001)
