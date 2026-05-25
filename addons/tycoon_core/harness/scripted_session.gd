extends RefCounted
class_name ScriptedSession
# Headless scenario driver. Reads a JSON action sequence and replays it
# against the engine's autoloads so an AI assistant, CI job, or any other
# unattended harness can drive a built game end-to-end without manual input.
#
# Theme-agnostic: every built-in action targets a generic engine API
# (SimClock, Ledger, EntityRegistry, AgentPool, ContentDB, ProgressionManager,
# SaveService). Game-specific actions plug in via `register_action()`.
#
# Activation: set `TYCOON_SCRIPT=/abs/path.json` (env) or pass
# `++ --tycoon-script=/abs/path.json` on the command line. From the game's
# main scene `_ready()`:
#
#     var sess := ScriptedSession.create_from_env(self)
#     if sess != null:
#         sess.register_action("assert_my_thing", _check_my_thing)
#         await sess.run()
#         return
#     # ... normal startup ...
#
# Action schema (one object per element of "actions"):
#   {"type": "warmup",     "ticks": 480}
#   {"type": "set_speed",  "value": 8.0}
#   {"type": "place",      "def": "lion_exhibit", "pos": [5, 5]}
#   {"type": "remove_at",  "pos": [5, 5]}
#   {"type": "spawn",      "agent": "visitor", "pos": [2, 2], "count": 4}
#   {"type": "screenshot", "path": "/tmp/zoo.png"}
#   {"type": "wait_frames","value": 2}
#   {"type": "print_state"}
#   {"type": "save",       "slot": "scripted"}
#   {"type": "load",       "slot": "scripted"}
#   {"type": "force_unlock","node": "start"}
#   {"type": "assert_balance_at_least", "value": 0,         "label": "solvent"}
#   {"type": "assert_balance_at_most",  "value": 99999,     "label": "not absurd"}
#   {"type": "assert_alive_count",      "min": 1, "max": 99}
#   {"type": "assert_entity_count",     "def": "lion_exhibit", "value": 1}
#   {"type": "quit"}
#
# All log lines are prefixed `[script]` / `[state]` / `[assert OK]` /
# `[assert FAIL]` so the wrapping shell can grep them out of Godot's startup
# noise. `run()` quits the SceneTree with an exit code equal to the failure
# count, which lets CI detect regressions without parsing stdout.

const ARG_PREFIX := "--tycoon-script="
const ENV_VAR := "TYCOON_SCRIPT"

const _ACTIONS_KEY := "actions"
const _CLEAN_START_KEY := "clean_start"

var _host: Node
var _failures: int = 0
var _custom_actions: Dictionary = {}  # String -> Callable


# ---------------------------------------------------------------------------
# Entry-point helpers
# ---------------------------------------------------------------------------

static func get_script_path() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(ARG_PREFIX):
			return arg.substr(ARG_PREFIX.length())
	return OS.get_environment(ENV_VAR)


# Returns a ready-to-run session if a script path is set, else null. The
# returned instance is *not* started — register custom actions, then await
# `run()`.
static func create_from_env(host: Node) -> ScriptedSession:
	var path := get_script_path()
	if path.is_empty():
		return null
	var s := ScriptedSession.new(host)
	s._script_path = path
	return s


var _script_path: String = ""


func _init(host: Node) -> void:
	_host = host


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Register a game-specific action. `fn` receives the action dict and may
# return:
#   - null / void → success
#   - false       → marks one failure (counted in the exit code)
#   - true        → success
# May `await` internally.
func register_action(type_name: String, fn: Callable) -> void:
	_custom_actions[type_name] = fn


# Run the script found via create_from_env. Quits the SceneTree with the
# accumulated failure count when finished. If the script can't be loaded the
# process exits with code 2.
func run(path: String = "") -> void:
	if path.is_empty():
		path = _script_path
	if path.is_empty():
		push_error("[script] no path given and TYCOON_SCRIPT unset")
		_host.get_tree().quit(2)
		return
	var doc := _load_json(path)
	if doc.is_empty():
		_host.get_tree().quit(2)
		return
	var clean: bool = doc.get(_CLEAN_START_KEY, true)
	if clean:
		_wipe_world()
	var actions: Array = doc.get(_ACTIONS_KEY, [])
	print("[script] running %d action(s) from %s (clean_start=%s)" %
		[actions.size(), path, clean])
	for i in actions.size():
		var action_v: Variant = actions[i]
		if not (action_v is Dictionary):
			_fail("action %d is not an object" % i)
			continue
		await _execute(action_v, i)
	print("[script] done: %d action(s), %d failure(s)" %
		[actions.size(), _failures])
	_host.get_tree().quit(_failures)


func failure_count() -> int:
	return _failures


# ---------------------------------------------------------------------------
# Action dispatch
# ---------------------------------------------------------------------------

func _execute(action: Dictionary, idx: int) -> void:
	var t: String = action.get("type", "")
	print("[script] [%d] %s %s" % [idx, t, JSON.stringify(action)])
	if _custom_actions.has(t):
		await _dispatch_custom(t, action)
		return
	match t:
		"warmup":           await _do_warmup(action)
		"set_speed":        _do_set_speed(action)
		"place":            _do_place(action)
		"remove_at":        _do_remove_at(action)
		"spawn":            _do_spawn(action)
		"screenshot":       await _do_screenshot(action)
		"wait_frames":      await _do_wait_frames(action)
		"print_state":      _do_print_state()
		"save":             _do_save(action)
		"load":             _do_load(action)
		"force_unlock":     _do_force_unlock(action)
		"assert_balance_at_least": _do_assert_balance_at_least(action)
		"assert_balance_at_most":  _do_assert_balance_at_most(action)
		"assert_alive_count":      _do_assert_alive_count(action)
		"assert_entity_count":     _do_assert_entity_count(action)
		"quit":             _host.get_tree().quit(_failures)
		_:                  _fail("unknown action type '%s'" % t)


func _dispatch_custom(type_name: String, action: Dictionary) -> void:
	var fn: Callable = _custom_actions[type_name]
	var result: Variant = await fn.call(action)
	if result is bool and not result:
		_fail("custom action '%s' returned false" % type_name)


# ---------------------------------------------------------------------------
# Built-in actions
# ---------------------------------------------------------------------------

func _do_warmup(action: Dictionary) -> void:
	var ticks: int = action.get("ticks", 30)
	# Auto-nudge: warmup with a paused clock would block forever waiting on
	# tick signals that will never fire.
	if SimClock.speed <= 0.0:
		SimClock.set_speed(8.0)
	for _i in ticks:
		await EventBus.tick


func _do_set_speed(action: Dictionary) -> void:
	var v: float = float(action.get("value", 1.0))
	SimClock.set_speed(v)


func _do_place(action: Dictionary) -> void:
	var def_id := StringName(action.get("def", ""))
	var pos := _vec2i_from(action.get("pos", [0, 0]))
	var inst_id := EntityRegistry.place(def_id, pos)
	if inst_id == 0:
		_fail("place failed: %s" % JSON.stringify(action))


func _do_remove_at(action: Dictionary) -> void:
	var cell := _vec2i_from(action.get("pos", [0, 0]))
	for inst_id in EntityRegistry.instances.keys():
		var inst: EntityInstance = EntityRegistry.instances[inst_id]
		var def := inst.get_def()
		if def == null:
			continue
		if cell.x >= inst.position.x and cell.x < inst.position.x + def.footprint.x \
		and cell.y >= inst.position.y and cell.y < inst.position.y + def.footprint.y:
			if not EntityRegistry.remove(inst_id):
				_fail("remove failed at (%d,%d)" % [cell.x, cell.y])
			return
	_fail("no entity found at (%d,%d)" % [cell.x, cell.y])


func _do_spawn(action: Dictionary) -> void:
	var agent_id := StringName(action.get("agent", ""))
	if agent_id == &"":
		_fail("spawn requires 'agent' field")
		return
	var pos := _vec2_from(action.get("pos", [0, 0]))
	var count: int = action.get("count", 1)
	for _i in count:
		if AgentPool.spawn(agent_id, pos) == 0:
			_fail("spawn failed: %s" % agent_id)
			return


func _do_screenshot(action: Dictionary) -> void:
	var path: String = action.get("path", "/tmp/tycoon_shot.png")
	# Two frame waits let HUD labels and the map redraw with the latest
	# state — without them, screenshots can lag behind by a tick.
	await _host.get_tree().process_frame
	await _host.get_tree().process_frame
	var img := _host.get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	if err != OK:
		_fail("screenshot failed: %s" % error_string(err))
		return
	print("[script] saved %s" % path)


func _do_wait_frames(action: Dictionary) -> void:
	var n: int = action.get("value", 1)
	for _i in n:
		await _host.get_tree().process_frame


func _do_print_state() -> void:
	var by_type: Dictionary = {}
	for def_id in ContentDB.entity_defs.keys():
		var n: int = EntityRegistry.get_instances_by_def(def_id).size()
		if n > 0:
			by_type[String(def_id)] = n
	print("[state] balance=$%d  day=%d  tick=%d  entities=%d  agents_alive=%d  pool=%d  by_type=%s" % [
		Ledger.get_balance(),
		SimClock.current_day,
		SimClock.current_tick,
		EntityRegistry.instances.size(),
		AgentPool.alive_count(),
		AgentPool.pool_size(),
		JSON.stringify(by_type)])
	var br: Dictionary = Ledger.get_yesterday_breakdown()
	print("[state] yesterday: income=$%d expense=$%d net=$%d" %
		[br["income"], br["expense"], br["net"]])


func _do_save(action: Dictionary) -> void:
	var slot: String = action.get("slot", "scripted")
	SaveService.save_to_slot(slot)


func _do_load(action: Dictionary) -> void:
	var slot: String = action.get("slot", "scripted")
	SaveService.load_from_slot(slot)


func _do_force_unlock(action: Dictionary) -> void:
	var node_id := StringName(action.get("node", ""))
	ProgressionManager.force_unlock(node_id)


# --- assertions -----------------------------------------------------------

func _do_assert_balance_at_least(action: Dictionary) -> void:
	var min_v: int = action.get("value", 0)
	var label: String = action.get("label", "balance >= %d" % min_v)
	var actual := Ledger.get_balance()
	_assert(actual >= min_v, label, "balance=%d, min=%d" % [actual, min_v])


func _do_assert_balance_at_most(action: Dictionary) -> void:
	var max_v: int = action.get("value", 0)
	var label: String = action.get("label", "balance <= %d" % max_v)
	var actual := Ledger.get_balance()
	_assert(actual <= max_v, label, "balance=%d, max=%d" % [actual, max_v])


func _do_assert_alive_count(action: Dictionary) -> void:
	var min_v: int = action.get("min", 0)
	var max_v: int = action.get("max", 99999)
	var label: String = action.get("label", "alive in [%d,%d]" % [min_v, max_v])
	var actual := AgentPool.alive_count()
	_assert(actual >= min_v and actual <= max_v, label,
		"alive=%d, want [%d,%d]" % [actual, min_v, max_v])


func _do_assert_entity_count(action: Dictionary) -> void:
	var def_id := StringName(action.get("def", ""))
	var want: int = action.get("value", 0)
	var label: String = action.get("label", "%s count = %d" % [def_id, want])
	var actual := EntityRegistry.get_instances_by_def(def_id).size()
	_assert(actual == want, label, "actual=%d, want=%d" % [actual, want])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _wipe_world() -> void:
	for agent_type_id in ContentDB.agent_types.keys():
		for agent_id in AgentPool.get_agents_by_type(agent_type_id):
			AgentPool.despawn(agent_id)
	for inst_id in EntityRegistry.instances.keys():
		EntityRegistry.remove(inst_id)


func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[script] cannot open %s" % path)
		return {}
	var raw := f.get_as_text()
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		push_error("[script] %s: top-level JSON must be an object" % path)
		return {}
	return parsed


func _vec2i_from(v: Variant) -> Vector2i:
	if v is Array and v.size() >= 2:
		return Vector2i(int(v[0]), int(v[1]))
	return Vector2i.ZERO


func _vec2_from(v: Variant) -> Vector2:
	if v is Array and v.size() >= 2:
		return Vector2(float(v[0]), float(v[1]))
	return Vector2.ZERO


func _assert(ok: bool, label: String, detail: String) -> void:
	if ok:
		print("[assert OK ] %s  (%s)" % [label, detail])
	else:
		print("[assert FAIL] %s  (%s)" % [label, detail])
		_failures += 1


func _fail(msg: String) -> void:
	push_warning("[script] " + msg)
	print("[script FAIL] " + msg)
	_failures += 1
