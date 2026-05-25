extends GutTest
# Tests for the headless scripted-session harness.
# Spec: addons/tycoon_core/harness/scripted_session.gd top comment.
#
# We don't exercise quit / screenshot / save-load here — those would entangle
# the GUT runner with the SceneTree. We test that:
#   * env / arg discovery works,
#   * each built-in action mutates the right autoload,
#   * custom actions get dispatched and their return values affect the
#     failure count,
#   * malformed actions are surfaced as failures rather than crashes.


var _host: Node


func before_each() -> void:
	# Many actions touch engine autoloads; reset them so tests don't bleed
	# state between cases.
	SimClock.current_tick = 0
	SimClock.current_day = 0
	SimClock.current_period = 0
	SimClock.set_speed(1.0)
	Ledger.reset()
	EntityRegistry.reset()
	AgentPool.reset()
	# A fresh Node is fine for `host` — the harness only uses it for
	# get_tree() (which the autoload Node inherits) and get_viewport()
	# (not exercised here).
	_host = Node.new()
	add_child_autofree(_host)


# --- Discovery -------------------------------------------------------------

func test_env_discovery_picks_up_TYCOON_SCRIPT() -> void:
	OS.set_environment(ScriptedSession.ENV_VAR, "/tmp/fake.json")
	assert_eq(ScriptedSession.get_script_path(), "/tmp/fake.json")
	OS.set_environment(ScriptedSession.ENV_VAR, "")


func test_create_from_env_returns_null_when_unset() -> void:
	OS.set_environment(ScriptedSession.ENV_VAR, "")
	assert_null(ScriptedSession.create_from_env(_host))


# --- Built-in actions ------------------------------------------------------

func test_set_speed_action_updates_simclock() -> void:
	var s := ScriptedSession.new(_host)
	s._do_set_speed({"value": 4.0})
	assert_eq(SimClock.speed, 4.0)


func test_place_action_creates_entity_when_def_known() -> void:
	# Use a minimal handcrafted EntityDef rather than loading the tuning
	# files (those depend on a game-defined balance config).
	var def := EntityDef.new()
	def.id = &"test_widget"
	def.display_name = "Test Widget"
	def.build_cost = 10
	def.footprint = Vector2i(1, 1)
	ContentDB.entity_defs[def.id] = def
	Ledger.reset(100)
	var s := ScriptedSession.new(_host)
	s._do_place({"def": "test_widget", "pos": [3, 4]})
	assert_eq(EntityRegistry.instances.size(), 1)
	assert_eq(s.failure_count(), 0)
	ContentDB.entity_defs.erase(def.id)


func test_place_action_fails_loudly_on_unknown_def() -> void:
	var s := ScriptedSession.new(_host)
	s._do_place({"def": "no_such_thing", "pos": [0, 0]})
	assert_eq(s.failure_count(), 1)


func test_assert_balance_at_least_passes_and_fails() -> void:
	Ledger.reset(500)
	var s := ScriptedSession.new(_host)
	s._do_assert_balance_at_least({"value": 400})
	assert_eq(s.failure_count(), 0)
	s._do_assert_balance_at_least({"value": 1000})
	assert_eq(s.failure_count(), 1)


func test_assert_alive_count_window() -> void:
	var s := ScriptedSession.new(_host)
	s._do_assert_alive_count({"min": 0, "max": 0})
	assert_eq(s.failure_count(), 0, "0 alive should be within [0,0]")
	s._do_assert_alive_count({"min": 1, "max": 99})
	assert_eq(s.failure_count(), 1, "0 alive is below 1")


# --- Custom action registration -------------------------------------------

var _custom_called_with: Dictionary = {}


func _custom_handler(action: Dictionary) -> Variant:
	_custom_called_with = action
	return true


func _custom_handler_failing(_action: Dictionary) -> Variant:
	return false


func test_custom_action_dispatched_with_action_dict() -> void:
	_custom_called_with = {}
	var s := ScriptedSession.new(_host)
	s.register_action("custom_thing", _custom_handler)
	await s._execute({"type": "custom_thing", "extra": 42}, 0)
	assert_eq(_custom_called_with.get("extra"), 42)
	assert_eq(s.failure_count(), 0)


func test_custom_action_returning_false_increments_failures() -> void:
	var s := ScriptedSession.new(_host)
	s.register_action("flaky", _custom_handler_failing)
	await s._execute({"type": "flaky"}, 0)
	assert_eq(s.failure_count(), 1)


# --- Malformed input -------------------------------------------------------

func test_unknown_action_type_marks_failure() -> void:
	var s := ScriptedSession.new(_host)
	await s._execute({"type": "no_such_action"}, 0)
	assert_eq(s.failure_count(), 1)


func test_spawn_without_agent_field_marks_failure() -> void:
	var s := ScriptedSession.new(_host)
	s._do_spawn({"pos": [0, 0]})
	assert_eq(s.failure_count(), 1)
