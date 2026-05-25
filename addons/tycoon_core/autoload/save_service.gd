extends Node
# Spec: docs/build-plan.md §3 (autoloads — SaveService), Prompt 9.
#
# Serializes and restores engine state across SimClock, Ledger,
# EntityRegistry, and ProgressionManager. AgentPool is intentionally NOT
# included — alive agents are transient (the spawn loop refills the park
# after load). Games that need persistent agent state register via
# `register_game_state_provider(...)`.
#
# Format: JSON at user://saves/<slot>.save.json. Top-level `version` lets us
# refuse mismatched payloads cleanly rather than corrupt state silently.
#
# Autosave fires on EventBus.day_ended when autosave_enabled is true. Tests
# disable autosave during setup to avoid file-write side effects.

const SAVE_VERSION: int = 1
const SAVE_DIR := "user://saves/"
const AUTOSAVE_SLOT := "autosave"

var autosave_enabled: bool = true

# key -> { "save": Callable, "load": Callable }
var _game_state_handlers: Dictionary = {}

# from_version (int) -> Callable that takes a payload Dict and returns the
# migrated Dict (one step forward). Walked in ascending order on load when
# the file's version is below SAVE_VERSION.
var _migrations: Dictionary = {}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_DIR))
	EventBus.day_ended.connect(_on_day_ended)


func _on_day_ended(_d: int) -> void:
	if autosave_enabled:
		save_to_slot(AUTOSAVE_SLOT)


# Game-side registration for additional saved state. Pass two Callables:
# `save_fn` returns a Dictionary; `load_fn` accepts a Dictionary.
# The engine never inspects the contents — game owns its schema.
func register_game_state_provider(key: String, save_fn: Callable, load_fn: Callable) -> void:
	_game_state_handlers[key] = {"save": save_fn, "load": load_fn}


func unregister_game_state_provider(key: String) -> void:
	_game_state_handlers.erase(key)


# Register a one-step migration that upgrades a payload from `from_version`
# to `from_version + 1`. Migrations chain: loading a v1 payload when
# SAVE_VERSION is 3 walks 1→2 then 2→3. The Callable receives the payload
# Dict and must return a Dict for the next version (in-place mutation is
# fine, return the same dict). Engines should register migrations for any
# SAVE_VERSION bump that changes the schema; games can register their own
# for their game_extras payloads.
func register_migration(from_version: int, migrate_fn: Callable) -> void:
	_migrations[from_version] = migrate_fn


func unregister_migration(from_version: int) -> void:
	_migrations.erase(from_version)


# Returns the upgraded payload or null if no migration path covers the gap.
func _apply_migrations(payload: Dictionary, from_version: int) -> Variant:
	var v: int = from_version
	while v < SAVE_VERSION:
		if not _migrations.has(v):
			return null
		var fn: Callable = _migrations[v]
		var result: Variant = fn.call(payload)
		if not (result is Dictionary):
			push_error("SaveService migration %d→%d returned non-Dict (%s)" %
				[v, v + 1, typeof(result)])
			return null
		payload = result
		v += 1
	payload["version"] = SAVE_VERSION
	return payload


# --- Slot operations -----------------------------------------------------

func save_to_slot(slot: String) -> bool:
	var payload := {
		"version": SAVE_VERSION,
		"sim_clock": SimClock.save_state(),
		"ledger": Ledger.save_state(),
		"entity_registry": EntityRegistry.save_state(),
		"progression_manager": ProgressionManager.save_state(),
		"game_extras": {},
	}
	for key in _game_state_handlers.keys():
		var handler: Dictionary = _game_state_handlers[key]
		payload["game_extras"][key] = (handler["save"] as Callable).call()

	var path := _slot_path(slot)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("SaveService: could not open '%s' for write (err %d)" %
			[path, FileAccess.get_open_error()])
		return false
	f.store_string(JSON.stringify(payload))
	f.close()
	EventBus.save_completed.emit(slot)
	return true


func load_from_slot(slot: String) -> bool:
	var path := _slot_path(slot)
	if not FileAccess.file_exists(path):
		EventBus.load_failed.emit(slot, "file not found: %s" % path)
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		EventBus.load_failed.emit(slot, "could not open '%s' (err %d)" %
			[path, FileAccess.get_open_error()])
		return false
	var raw := f.get_as_text()
	f.close()
	# Use a JSON instance (not JSON.parse_string) so a malformed file returns
	# an error code rather than pushing one — GUT would otherwise flag the
	# "invalid JSON" intentional-failure test as having unexpected errors.
	var json := JSON.new()
	var parse_err := json.parse(raw)
	if parse_err != OK:
		EventBus.load_failed.emit(slot,
			"invalid JSON in '%s': %s (line %d)" %
			[path, json.get_error_message(), json.get_error_line()])
		return false
	if not (json.data is Dictionary):
		EventBus.load_failed.emit(slot, "save file is not a JSON object: %s" % path)
		return false
	var payload: Dictionary = json.data
	var version: int = payload.get("version", 0)
	if version > SAVE_VERSION:
		EventBus.load_failed.emit(slot,
			"save version %d is newer than engine version %d" %
			[version, SAVE_VERSION])
		return false
	if version < SAVE_VERSION:
		var migrated: Variant = _apply_migrations(payload, version)
		if migrated == null:
			EventBus.load_failed.emit(slot,
				"save version %d cannot be migrated to %d (missing migration step)" %
				[version, SAVE_VERSION])
			return false
		payload = migrated

	# Order matters slightly: restore SimClock first so anything that reads
	# `current_day` during restore sees the loaded value. AgentPool is reset
	# to clear transients before any game-extras handler might re-spawn.
	SimClock.load_state(payload.get("sim_clock", {}))
	Ledger.load_state(payload.get("ledger", {}))
	EntityRegistry.load_state(payload.get("entity_registry", {}))
	ProgressionManager.load_state(payload.get("progression_manager", {}))
	AgentPool.reset()

	var extras: Dictionary = payload.get("game_extras", {})
	for key in _game_state_handlers.keys():
		if extras.has(key):
			var handler: Dictionary = _game_state_handlers[key]
			(handler["load"] as Callable).call(extras[key])

	EventBus.load_completed.emit(slot)
	return true


func slot_exists(slot: String) -> bool:
	return FileAccess.file_exists(_slot_path(slot))


func delete_slot(slot: String) -> bool:
	var path := _slot_path(slot)
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK


func _slot_path(slot: String) -> String:
	return "%s%s.save.json" % [SAVE_DIR, slot]
