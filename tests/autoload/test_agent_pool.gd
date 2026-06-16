extends GutTest
# Tests for AgentPool — Prompt 6.
# Spec: docs/build-plan.md §7 (Prompt 6)
#
# Tests inject custom AgentType + Need fixtures into ContentDB so need-decay
# math is independent of the shipped tuning. Behavior/satisfaction tests use
# spy doubles defined inline.

const TEST_NEED := &"test_hunger"
const TEST_TYPE := &"test_visitor"
const TEST_TYPE_B := &"test_premium"
const TEST_DEF := &"test_food"


class SpyBehavior extends RefCounted:
	var calls: Array = []
	func on_spawn(agent: Agent) -> void:
		calls.append(["on_spawn", agent.agent_id])
	func on_tick(agent: Agent) -> void:
		calls.append(["on_tick", agent.agent_id])
	func on_need_threshold_crossed(agent: Agent, need_id: StringName) -> void:
		calls.append(["on_need_threshold_crossed", agent.agent_id, need_id])
	func on_despawn(agent: Agent) -> void:
		calls.append(["on_despawn", agent.agent_id])


class SpySatisfactionModel extends RefCounted:
	var calls: int = 0
	func update_satisfaction(agent: Agent) -> void:
		calls += 1
		# Set to a known value so tests can verify it was called.
		agent.satisfaction = 0.42


func before_each() -> void:
	AgentPool.reset()
	AgentPool.configure(0.0)  # disable auto-spawn loop so tests are deterministic
	EntityRegistry.reset()
	SimClock.current_tick = 0
	SimClock.current_day = 0
	SimClock.current_period = 0
	SimClock.ticks_per_day = 1000  # large so day_ended doesn't fire mid-tick test
	SimClock.set_seed(1234)

	# Need + type fixtures.
	var need := Need.new()
	need.id = TEST_NEED
	need.display_name = "Test Hunger"
	need.base_decay_per_tick = 0.1  # 10 ticks to empty from 1.0
	ContentDB.needs[TEST_NEED] = need

	var spec := NeedSpec.new()
	spec.need = need
	spec.initial_level = 1.0
	spec.decay_rate_multiplier = 1.0
	spec.threshold = 0.5

	var type := AgentType.new()
	type.id = TEST_TYPE
	type.display_name = "Test Visitor"
	type.spawn_weight = 1.0
	type.needs = [spec]
	type.trait_ranges = {&"patience": Vector2(0.2, 0.8)}
	ContentDB.agent_types[TEST_TYPE] = type

	var type_b := AgentType.new()
	type_b.id = TEST_TYPE_B
	type_b.spawn_weight = 2.0
	type_b.needs = [spec]
	ContentDB.agent_types[TEST_TYPE_B] = type_b


func after_each() -> void:
	ContentDB.needs.erase(TEST_NEED)
	ContentDB.agent_types.erase(TEST_TYPE)
	ContentDB.agent_types.erase(TEST_TYPE_B)
	AgentPool.unregister_behavior(TEST_TYPE)
	AgentPool.unregister_satisfaction_model(TEST_TYPE)


# --- Spawn / despawn ------------------------------------------------------

func test_spawn_returns_id_and_initializes_agent() -> void:
	var id := AgentPool.spawn(TEST_TYPE, Vector2(3, 4))
	assert_ne(id, 0)
	var a := AgentPool.get_agent(id)
	assert_not_null(a)
	assert_eq(a.agent_type_id, TEST_TYPE)
	assert_eq(a.position, Vector2(3, 4))
	assert_true(a.alive)
	assert_eq(a.need_levels.get(TEST_NEED), 1.0, "initial_level applied")


func test_spawn_samples_traits_within_ranges() -> void:
	var id := AgentPool.spawn(TEST_TYPE)
	var a := AgentPool.get_agent(id)
	var t: float = a.traits.get(&"patience", -1.0)
	assert_true(t >= 0.2 and t <= 0.8, "trait sampled within range")


func test_spawn_unknown_type_returns_zero() -> void:
	assert_eq(AgentPool.spawn(&"does_not_exist"), 0)


func test_despawn_removes_from_alive_and_adds_to_free_pool() -> void:
	var id := AgentPool.spawn(TEST_TYPE)
	assert_eq(AgentPool.alive_count(), 1)
	assert_eq(AgentPool.pool_size(), 0)
	assert_true(AgentPool.despawn(id))
	assert_eq(AgentPool.alive_count(), 0)
	assert_eq(AgentPool.pool_size(), 1)
	assert_null(AgentPool.get_agent(id), "id no longer maps to a live agent")


func test_pool_reuses_agent_object_with_fresh_id() -> void:
	var first_id := AgentPool.spawn(TEST_TYPE)
	var first_agent := AgentPool.get_agent(first_id)
	AgentPool.despawn(first_id)
	var second_id := AgentPool.spawn(TEST_TYPE)
	var second_agent := AgentPool.get_agent(second_id)
	assert_true(is_same(first_agent, second_agent),
		"pool reused the same Agent object instance")
	assert_ne(first_id, second_id, "but a fresh id was issued")
	assert_eq(AgentPool.pool_size(), 0, "pool drained on reuse")


func test_spawn_emits_signal() -> void:
	var captured: Array[int] = []
	EventBus.agent_spawned.connect(func(id: int) -> void: captured.append(id))
	var id := AgentPool.spawn(TEST_TYPE)
	assert_eq(captured, [id] as Array[int])


# --- Need decay + thresholds ---------------------------------------------

func test_needs_decay_each_tick() -> void:
	var id := AgentPool.spawn(TEST_TYPE)
	for i in range(3):
		SimClock.advance_tick()
	var a := AgentPool.get_agent(id)
	# 3 ticks * 0.1 decay = 0.3 below initial
	assert_almost_eq(a.need_levels[TEST_NEED], 0.7, 0.0001)


func test_needs_clamp_at_zero() -> void:
	var id := AgentPool.spawn(TEST_TYPE)
	for i in range(20):
		SimClock.advance_tick()
	var a := AgentPool.get_agent(id)
	assert_eq(a.need_levels[TEST_NEED], 0.0, "decay floors at 0")


func test_threshold_crossing_emits_signal_once() -> void:
	var captured: Array = []
	EventBus.agent_need_threshold_crossed.connect(func(aid: int, nid: StringName) -> void:
		captured.append([aid, nid]))
	var id := AgentPool.spawn(TEST_TYPE)
	# threshold = 0.5; initial = 1.0; decay = 0.1/tick → crosses at tick 6
	for i in range(10):
		SimClock.advance_tick()
	assert_eq(captured.size(), 1, "threshold crossing fires exactly once")
	assert_eq(captured[0], [id, TEST_NEED])


func test_threshold_crossing_calls_behavior() -> void:
	var spy := SpyBehavior.new()
	AgentPool.register_behavior(TEST_TYPE, spy)
	var id := AgentPool.spawn(TEST_TYPE)
	for i in range(10):
		SimClock.advance_tick()
	var threshold_calls := spy.calls.filter(func(c: Array) -> bool: return c[0] == "on_need_threshold_crossed")
	assert_eq(threshold_calls.size(), 1)
	assert_eq(threshold_calls[0][2], TEST_NEED)


# --- Behavior dispatch ----------------------------------------------------

func test_behavior_on_spawn_called_at_spawn() -> void:
	var spy := SpyBehavior.new()
	AgentPool.register_behavior(TEST_TYPE, spy)
	var id := AgentPool.spawn(TEST_TYPE)
	var spawns := spy.calls.filter(func(c: Array) -> bool: return c[0] == "on_spawn")
	assert_eq(spawns.size(), 1)
	assert_eq(spawns[0][1], id)


func test_behavior_on_tick_called_every_tick() -> void:
	var spy := SpyBehavior.new()
	AgentPool.register_behavior(TEST_TYPE, spy)
	AgentPool.spawn(TEST_TYPE)
	for i in range(5):
		SimClock.advance_tick()
	var ticks := spy.calls.filter(func(c: Array) -> bool: return c[0] == "on_tick")
	assert_eq(ticks.size(), 5)


func test_behavior_on_despawn_called() -> void:
	var spy := SpyBehavior.new()
	AgentPool.register_behavior(TEST_TYPE, spy)
	var id := AgentPool.spawn(TEST_TYPE)
	AgentPool.despawn(id)
	var despawns := spy.calls.filter(func(c: Array) -> bool: return c[0] == "on_despawn")
	assert_eq(despawns.size(), 1)


# --- Satisfaction model + day_ended feedback loop -------------------------

func test_satisfaction_model_called_each_tick() -> void:
	var spy := SpySatisfactionModel.new()
	AgentPool.register_satisfaction_model(TEST_TYPE, spy)
	AgentPool.spawn(TEST_TYPE)
	for i in range(4):
		SimClock.advance_tick()
	assert_eq(spy.calls, 4)


func test_compute_aggregate_satisfaction_averages_live_agents() -> void:
	var spy := SpySatisfactionModel.new()  # sets satisfaction = 0.42
	AgentPool.register_satisfaction_model(TEST_TYPE, spy)
	AgentPool.spawn(TEST_TYPE)
	AgentPool.spawn(TEST_TYPE)
	SimClock.advance_tick()
	assert_almost_eq(AgentPool.compute_aggregate_satisfaction(), 0.42, 0.0001)


func test_compute_aggregate_satisfaction_with_no_agents_returns_neutral() -> void:
	assert_eq(AgentPool.compute_aggregate_satisfaction(), 0.5)


# --- v0.7.0 spawn-balance flag -------------------------------------------

func test_default_agent_type_drives_spawn_balance() -> void:
	# Additive flag defaults to true → pre-v0.7 averaging is unchanged.
	assert_true(AgentType.new().drives_spawn_balance)


func test_aggregate_excludes_non_spawn_driving_population() -> void:
	# TEST_TYPE drives balance (default true); TEST_TYPE_B opts out.
	ContentDB.get_agent_type(TEST_TYPE_B).drives_spawn_balance = false
	var driving := AgentPool.spawn(TEST_TYPE)
	var welfare_a := AgentPool.spawn(TEST_TYPE_B)
	var welfare_b := AgentPool.spawn(TEST_TYPE_B)
	AgentPool.get_agent(driving).satisfaction = 0.8
	AgentPool.get_agent(welfare_a).satisfaction = 0.0  # miserable, must NOT count
	AgentPool.get_agent(welfare_b).satisfaction = 0.0
	# Only the driving agent counts → aggregate is its 0.8, not the blended
	# (0.8 + 0 + 0) / 3 ≈ 0.27 you'd get if the welfare population leaked in.
	assert_almost_eq(AgentPool.compute_aggregate_satisfaction(), 0.8, 0.0001)


func test_aggregate_neutral_when_only_non_driving_agents_present() -> void:
	ContentDB.get_agent_type(TEST_TYPE_B).drives_spawn_balance = false
	var w := AgentPool.spawn(TEST_TYPE_B)
	AgentPool.get_agent(w).satisfaction = 0.0
	# No spawn-driving agents → neutral 0.5, so an all-welfare park doesn't
	# collapse arrival demand to zero.
	assert_eq(AgentPool.compute_aggregate_satisfaction(), 0.5)


func test_non_driving_population_does_not_move_spawn_multiplier() -> void:
	# A park with only driving agents vs. the same park that ALSO has a
	# miserable non-driving population must produce an identical spawn
	# multiplier — the hungry-animal-suppresses-visitors bug, proven absent.
	ContentDB.get_agent_type(TEST_TYPE_B).drives_spawn_balance = false
	var d := AgentPool.spawn(TEST_TYPE)
	AgentPool.get_agent(d).satisfaction = 0.7
	EventBus.day_ended.emit(1)
	var mult_without := AgentPool.current_spawn_multiplier

	var w := AgentPool.spawn(TEST_TYPE_B)
	AgentPool.get_agent(w).satisfaction = 0.0  # hungry second population
	EventBus.day_ended.emit(2)
	var mult_with := AgentPool.current_spawn_multiplier
	assert_almost_eq(mult_with, mult_without, 0.0001,
		"a miserable non-driving population must not change arrival demand")


func test_day_ended_updates_spawn_multiplier_from_aggregate() -> void:
	# Force a known satisfaction via a spy, then trigger day_ended.
	var spy := SpySatisfactionModel.new()  # sets satisfaction = 0.42
	AgentPool.register_satisfaction_model(TEST_TYPE, spy)
	AgentPool.spawn(TEST_TYPE)
	SimClock.advance_tick()
	# Manually drive day_ended via EventBus, mirroring SimClock's emit.
	EventBus.day_ended.emit(1)
	# Expected multiplier = spawn_curve(0.42) under current BalanceConfig.
	var expected := AgentPool.spawn_curve(0.42)
	assert_almost_eq(AgentPool.current_spawn_multiplier, expected, 0.0001)


func test_day_ended_emits_aggregate_satisfaction_signal() -> void:
	var captured: Array = []
	EventBus.aggregate_satisfaction_changed.connect(func(sat: float, mult: float) -> void:
		captured.append([sat, mult]))
	AgentPool.spawn(TEST_TYPE)
	SimClock.advance_tick()
	EventBus.day_ended.emit(1)
	assert_eq(captured.size(), 1)


# --- Queries --------------------------------------------------------------

func test_get_agents_by_type_filters_correctly() -> void:
	var a := AgentPool.spawn(TEST_TYPE)
	var b := AgentPool.spawn(TEST_TYPE)
	var c := AgentPool.spawn(TEST_TYPE_B)
	var visitors := AgentPool.get_agents_by_type(TEST_TYPE)
	assert_eq(visitors.size(), 2)
	assert_true(visitors.has(a) and visitors.has(b))
	assert_false(visitors.has(c))


# --- Demo behavior integration (proves the full need→seek→refill loop) ---

func test_demo_behavior_seeks_and_refills_need() -> void:
	# Inject a tiny entity def that satisfies TEST_NEED.
	var food_def := EntityDef.new()
	food_def.id = TEST_DEF
	food_def.display_name = "Test Food"
	food_def.build_cost = 0
	food_def.footprint = Vector2i(1, 1)
	food_def.satisfies = [TEST_NEED] as Array[StringName]
	ContentDB.entity_defs[TEST_DEF] = food_def
	# Make balance fine for the placement.
	Ledger.reset(1000)
	var ent_id := EntityRegistry.place(TEST_DEF, Vector2i(0, 0))
	assert_ne(ent_id, 0)

	# Drive agent toward starvation; demo behavior should detect threshold,
	# walk to the entity, and refill the need.
	AgentPool.register_behavior(TEST_TYPE, DemoAgentBehavior.new())
	var aid := AgentPool.spawn(TEST_TYPE, Vector2(0, 0))
	# Decay rate is 0.1/tick from 1.0; threshold crosses at tick 6. Agent at
	# (0,0), entity center at (0.5, 0.5), distance √0.5 ≈ 0.707. With speed
	# 0.1/tick and reach 0.5, the agent needs ~3 ticks of walking after the
	# threshold crossing to land within reach. 15 ticks is comfortable.
	for i in range(15):
		SimClock.advance_tick()
	var a := AgentPool.get_agent(aid)
	assert_eq(a.need_levels[TEST_NEED], 1.0, "demo behavior refilled the need")
	# Cleanup
	ContentDB.entity_defs.erase(TEST_DEF)


# --- v0.3.0: count_targeting ---------------------------------------------

func test_count_targeting_returns_zero_for_untargeted_entity() -> void:
	assert_eq(AgentPool.count_targeting(42), 0)


func test_count_targeting_reflects_agent_target_entity_id() -> void:
	# Use whatever the existing test fixture provides — set targets manually
	# without needing a behavior implementation.
	var id1 := AgentPool.spawn(TEST_TYPE)
	var id2 := AgentPool.spawn(TEST_TYPE)
	var id3 := AgentPool.spawn(TEST_TYPE)
	AgentPool.get_agent(id1).target_entity_id = 100
	AgentPool.get_agent(id2).target_entity_id = 100
	AgentPool.get_agent(id3).target_entity_id = 200
	assert_eq(AgentPool.count_targeting(100), 2)
	assert_eq(AgentPool.count_targeting(200), 1)
	assert_eq(AgentPool.count_targeting(999), 0)


func test_count_targeting_excludes_despawned_agents() -> void:
	var id := AgentPool.spawn(TEST_TYPE)
	AgentPool.get_agent(id).target_entity_id = 50
	assert_eq(AgentPool.count_targeting(50), 1)
	AgentPool.despawn(id)
	assert_eq(AgentPool.count_targeting(50), 0)
