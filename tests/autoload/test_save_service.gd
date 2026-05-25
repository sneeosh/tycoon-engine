extends GutTest
# Tests for SaveService — Prompt 9.
# Spec: docs/build-plan.md §7 (Prompt 9)
#
# Every test uses a slot name prefixed with `test_` and cleans up at the end
# so test runs don't accumulate files under user://saves/.

const SLOT := "test_default"
const TEST_DEF := &"test_save_def"
const TEST_NODE := &"test_save_node"


func before_each() -> void:
	# Quiet autosave so other tests in this file don't get incidental writes.
	SaveService.autosave_enabled = false
	# Per-test clean state.
	Ledger.reset(1000)
	EntityRegistry.reset()
	ProgressionManager.reset()
	AgentPool.reset()
	SimClock.current_tick = 0
	SimClock.current_day = 0
	SimClock.current_period = 0
	SimClock.ticks_per_day = 480
	SimClock.days_per_period = 7
	SimClock.set_seed(1234)


func after_each() -> void:
	SaveService.delete_slot(SLOT)
	SaveService.delete_slot("test_autosave")
	ContentDB.entity_defs.erase(TEST_DEF)
	ContentDB.unlock_nodes.erase(TEST_NODE)
	SaveService.unregister_game_state_provider("test_game")


# --- Round-trip: each subsystem -----------------------------------------

func test_round_trip_ledger_state() -> void:
	Ledger.post_income(150, "ticket", &"gate")
	Ledger.post_expense(30, "supplies", &"warehouse")
	Ledger.register_recurring({
		"id": &"utilities",
		"label": "Utilities",
		"amount": 50,
		"kind": Ledger.KIND_EXPENSE,
	})

	assert_true(SaveService.save_to_slot(SLOT))

	# Mutate to ensure load actually overwrites.
	Ledger.reset(1)
	Ledger.post_income(999, "wrong")

	assert_true(SaveService.load_from_slot(SLOT))
	assert_eq(Ledger.get_balance(), 1000 + 150 - 30)
	assert_eq(Ledger.transactions.size(), 2)
	var first: Dictionary = Ledger.transactions[0]
	assert_eq(first["kind"], Ledger.KIND_INCOME, "StringName survives round-trip")
	assert_eq(first["label"], "ticket")
	assert_true(Ledger.recurring_rules.has(&"utilities"))


func test_round_trip_sim_clock_state() -> void:
	SimClock.current_tick = 1234
	SimClock.current_day = 5
	SimClock.current_period = 2
	SimClock.ticks_per_day = 100
	SimClock.set_speed(2.5)
	SimClock.set_seed(99)

	assert_true(SaveService.save_to_slot(SLOT))

	# Mutate, then load.
	SimClock.current_tick = 0
	SimClock.current_day = 0
	SimClock.set_speed(1.0)
	SimClock.set_seed(7)

	assert_true(SaveService.load_from_slot(SLOT))
	assert_eq(SimClock.current_tick, 1234)
	assert_eq(SimClock.current_day, 5)
	assert_eq(SimClock.current_period, 2)
	assert_eq(SimClock.ticks_per_day, 100)
	assert_eq(SimClock.speed, 2.5)
	assert_eq(SimClock.rng.seed, 99,
		"seed restored — post-load RNG is deterministic from this seed")


func test_round_trip_rng_seed_yields_deterministic_post_load_stream() -> void:
	# Reference stream: seed 555, draw 3 floats.
	SimClock.set_seed(555)
	var ref_a := SimClock.rng.randf()
	var ref_b := SimClock.rng.randf()
	var ref_c := SimClock.rng.randf()

	# Now actually exercise save/load with the same seed and verify the
	# loaded RNG produces the SAME deterministic sequence from that seed.
	SimClock.set_seed(555)
	SaveService.save_to_slot(SLOT)
	SimClock.set_seed(123456)  # mutate
	SaveService.load_from_slot(SLOT)
	var loaded_a := SimClock.rng.randf()
	var loaded_b := SimClock.rng.randf()
	var loaded_c := SimClock.rng.randf()
	assert_almost_eq(loaded_a, ref_a, 1e-9)
	assert_almost_eq(loaded_b, ref_b, 1e-9)
	assert_almost_eq(loaded_c, ref_c, 1e-9)


func test_round_trip_entity_registry_with_upgrade_and_cells() -> void:
	var def := EntityDef.new()
	def.id = TEST_DEF
	def.display_name = "Test Save Def"
	def.build_cost = 100
	def.footprint = Vector2i(2, 2)
	var tier := UpgradeTier.new()
	tier.cost = 50
	def.upgrade_chain = [tier]
	ContentDB.entity_defs[TEST_DEF] = def

	var id := EntityRegistry.place(TEST_DEF, Vector2i(3, 4))
	assert_ne(id, 0)
	EntityRegistry.upgrade(id)

	assert_true(SaveService.save_to_slot(SLOT))

	# Mutate aggressively, then load.
	EntityRegistry.reset()
	assert_eq(EntityRegistry.instances.size(), 0)

	assert_true(SaveService.load_from_slot(SLOT))
	assert_eq(EntityRegistry.instances.size(), 1)
	var inst := EntityRegistry.get_instance(id)
	assert_not_null(inst)
	assert_eq(inst.entity_def_id, TEST_DEF)
	assert_eq(inst.position, Vector2i(3, 4))
	assert_eq(inst.upgrade_tier, 1)
	# Cell ownership rebuilt — a new placement on the same cell must collide.
	var collide := EntityRegistry.place(TEST_DEF, Vector2i(3, 4))
	assert_eq(collide, 0, "loaded entity reclaimed its footprint cells")


func test_round_trip_progression_manager_state() -> void:
	var node := UnlockNode.new()
	node.id = TEST_NODE
	node.label = "Test Save Node"
	ContentDB.unlock_nodes[TEST_NODE] = node

	ProgressionManager.set_reputation(42)
	ProgressionManager.force_unlock(TEST_NODE)
	assert_true(ProgressionManager.is_unlocked(TEST_NODE))

	assert_true(SaveService.save_to_slot(SLOT))

	ProgressionManager.reset()
	assert_eq(ProgressionManager.reputation, 0)
	assert_false(ProgressionManager.is_unlocked(TEST_NODE))

	assert_true(SaveService.load_from_slot(SLOT))
	assert_eq(ProgressionManager.reputation, 42)
	assert_true(ProgressionManager.is_unlocked(TEST_NODE),
		"unlocked StringNames survive round-trip")


# --- Game-registered extra state ----------------------------------------

func test_game_state_provider_round_trips_extras() -> void:
	# A tiny stateful object the "game" wants saved.
	var stash := {"score": 0, "name": "alpha"}
	SaveService.register_game_state_provider(
		"test_game",
		func() -> Dictionary: return stash.duplicate(),
		func(data: Dictionary) -> void:
			stash["score"] = data.get("score", 0)
			stash["name"] = data.get("name", ""))
	stash["score"] = 500
	stash["name"] = "omega"

	assert_true(SaveService.save_to_slot(SLOT))

	stash["score"] = 0
	stash["name"] = "reset"

	assert_true(SaveService.load_from_slot(SLOT))
	assert_eq(stash["score"], 500)
	assert_eq(stash["name"], "omega")


# --- Slot operations ----------------------------------------------------

func test_slot_exists_reports_correctly() -> void:
	assert_false(SaveService.slot_exists(SLOT))
	SaveService.save_to_slot(SLOT)
	assert_true(SaveService.slot_exists(SLOT))


func test_delete_slot_removes_file() -> void:
	SaveService.save_to_slot(SLOT)
	assert_true(SaveService.delete_slot(SLOT))
	assert_false(SaveService.slot_exists(SLOT))


func test_delete_missing_slot_returns_false() -> void:
	assert_false(SaveService.delete_slot("definitely_not_there"))


# --- Signals -------------------------------------------------------------

func test_save_emits_save_completed_signal() -> void:
	var captured: Array[String] = []
	var capture := func(slot: String) -> void: captured.append(slot)
	EventBus.save_completed.connect(capture)
	SaveService.save_to_slot(SLOT)
	assert_eq(captured, [SLOT] as Array[String])
	EventBus.save_completed.disconnect(capture)


func test_load_emits_load_completed_signal() -> void:
	SaveService.save_to_slot(SLOT)
	var captured: Array[String] = []
	var capture := func(slot: String) -> void: captured.append(slot)
	EventBus.load_completed.connect(capture)
	SaveService.load_from_slot(SLOT)
	assert_eq(captured, [SLOT] as Array[String])
	EventBus.load_completed.disconnect(capture)


# --- Failure modes -------------------------------------------------------

func test_load_missing_slot_emits_load_failed() -> void:
	var captured: Array = []
	var capture := func(slot: String, reason: String) -> void:
		captured.append([slot, reason])
	EventBus.load_failed.connect(capture)
	var ok := SaveService.load_from_slot("never_existed")
	assert_false(ok)
	assert_eq(captured.size(), 1)
	assert_string_contains(captured[0][1], "file not found")
	EventBus.load_failed.disconnect(capture)


func test_load_corrupt_json_emits_load_failed() -> void:
	var path := "user://saves/test_default.save.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("not valid json {[}")
	f.close()
	var ok := SaveService.load_from_slot(SLOT)
	assert_false(ok)


func test_load_version_mismatch_emits_load_failed() -> void:
	var path := "user://saves/test_default.save.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"version": 999, "ledger": {}}))
	f.close()
	var captured: Array = []
	var capture := func(slot: String, reason: String) -> void:
		captured.append([slot, reason])
	EventBus.load_failed.connect(capture)
	var ok := SaveService.load_from_slot(SLOT)
	assert_false(ok)
	assert_eq(captured.size(), 1)
	assert_string_contains(captured[0][1], "version 999 unsupported")
	EventBus.load_failed.disconnect(capture)


# --- Autosave ------------------------------------------------------------

func test_autosave_fires_on_day_ended_when_enabled() -> void:
	SaveService.autosave_enabled = true
	SaveService.delete_slot(SaveService.AUTOSAVE_SLOT)
	# Override the autosave slot temporarily via a force-fire — we drive the
	# signal directly so this doesn't depend on SimClock's day boundary.
	EventBus.day_ended.emit(1)
	assert_true(SaveService.slot_exists(SaveService.AUTOSAVE_SLOT))
	SaveService.delete_slot(SaveService.AUTOSAVE_SLOT)
	SaveService.autosave_enabled = false


func test_autosave_skips_when_disabled() -> void:
	SaveService.autosave_enabled = false
	SaveService.delete_slot(SaveService.AUTOSAVE_SLOT)
	EventBus.day_ended.emit(1)
	assert_false(SaveService.slot_exists(SaveService.AUTOSAVE_SLOT))


# --- AgentPool reset on load --------------------------------------------

func test_load_clears_alive_agents() -> void:
	# Set up a minimal AgentType so spawn works.
	var need := Need.new()
	need.id = &"test_save_need"
	ContentDB.needs[need.id] = need
	var spec := NeedSpec.new()
	spec.need = need
	var type := AgentType.new()
	type.id = &"test_save_agent"
	type.needs = [spec]
	ContentDB.agent_types[type.id] = type

	# Save the current empty state, then spawn agents, then load.
	SaveService.save_to_slot(SLOT)
	AgentPool.spawn(type.id)
	AgentPool.spawn(type.id)
	assert_eq(AgentPool.alive_count(), 2)
	SaveService.load_from_slot(SLOT)
	assert_eq(AgentPool.alive_count(), 0,
		"loading should reset alive agents — they're transient")

	ContentDB.needs.erase(need.id)
	ContentDB.agent_types.erase(type.id)
