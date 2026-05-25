extends GutTest
# Tests for ContentDB — Prompt 4.
# Spec: docs/build-plan.md §7 (Prompt 4)
#
# Two layers of test:
#   1. Happy-path against the real `design/tuning/*.md` files — proves the
#      shipped tuning content parses, compiles, and validates clean.
#   2. Error cases against fixture .md files written to user:// — proves the
#      loader fails loud with file/line context on malformed input and on
#      broken cross-references.

const TMP_DIR := "user://test_content_db/"


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))


func _write(name: String, content: String) -> void:
	var f := FileAccess.open(TMP_DIR + name, FileAccess.WRITE)
	f.store_string(content)
	f.close()


# Clear fixture dir between fixture-based tests so each test owns its files.
func _clear_fixtures() -> void:
	var d := DirAccess.open(TMP_DIR)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)


# --- Happy path: real design/tuning/ ---------------------------------------

func test_real_tuning_loads_clean() -> void:
	ContentDB.load_all()
	assert_eq(ContentDB.load_errors, [] as Array[String],
		"real design/tuning/*.md must parse with zero errors")
	assert_true(ContentDB.is_loaded)


func test_real_balance_config_matches_tuning() -> void:
	ContentDB.load_all()
	# Mirrors design/tuning/balance.md
	assert_eq(ContentDB.balance_config.ticks_per_day, 480)
	assert_eq(ContentDB.balance_config.days_per_period, 7)
	assert_eq(ContentDB.balance_config.spawn_curve_min_multiplier, 0.25)
	assert_eq(ContentDB.balance_config.spawn_curve_max_multiplier, 3.0)


func test_real_economy_applied_to_ledger() -> void:
	ContentDB.load_all()
	# Mirrors design/tuning/economy.md
	assert_eq(Ledger.get_balance(), 1000, "starting_cash applied")
	assert_true(Ledger.recurring_rules.has(&"utilities_base"))
	assert_true(Ledger.recurring_rules.has(&"insurance"))


func test_real_simclock_configured_from_balance() -> void:
	ContentDB.load_all()
	assert_eq(SimClock.ticks_per_day, 480)
	assert_eq(SimClock.days_per_period, 7)


func test_real_needs_loaded() -> void:
	ContentDB.load_all()
	assert_not_null(ContentDB.get_need(&"hunger"))
	assert_eq(ContentDB.get_need(&"hunger").base_decay_per_tick, 0.005)


func test_real_agents_loaded_with_need_specs() -> void:
	ContentDB.load_all()
	var visitor: AgentType = ContentDB.get_agent_type(&"visitor")
	assert_not_null(visitor)
	assert_eq(visitor.needs.size(), 2, "visitor has hunger + thirst specs")
	assert_eq(visitor.needs[0].need.id, &"hunger")


func test_real_entities_loaded_with_effects_and_appeal() -> void:
	ContentDB.load_all()
	var stand: EntityDef = ContentDB.get_entity_def(&"food_stand")
	assert_not_null(stand)
	assert_eq(stand.build_cost, 300)
	assert_eq(stand.footprint, Vector2i(2, 2))
	assert_eq(stand.satisfies, [&"hunger"] as Array[StringName])
	assert_eq(stand.appeal_profile.get(&"variety"), 0.6)
	assert_eq(stand.effects.size(), 1)
	assert_eq(stand.effects[0].magnitude, 5.0)


func test_real_progression_loaded_with_cross_refs() -> void:
	ContentDB.load_all()
	assert_not_null(ContentDB.get_unlock_node(&"basic_food"))
	var premium: UnlockNode = ContentDB.get_unlock_node(&"premium_visitor")
	assert_not_null(premium)
	assert_eq(premium.prerequisites, [&"basic_food"] as Array[StringName])
	assert_eq(premium.unlocks, [&"premium"] as Array[StringName])


# --- Error cases against fixtures -----------------------------------------

func test_missing_required_file_errors_loudly() -> void:
	_clear_fixtures()
	# Only balance.md present — economy.md is required and absent.
	_write("balance.md", _minimal_balance_md())
	ContentDB.load_all(TMP_DIR)
	assert_true(ContentDB.has_errors())
	var joined := "\n".join(ContentDB.load_errors)
	assert_string_contains(joined, "economy.md")
	assert_string_contains(joined, "missing")


func test_missing_required_section_errors_loudly() -> void:
	_clear_fixtures()
	_write("balance.md", "## Time\nticks_per_day = 480\ndays_per_period = 7\n")
	# Missing `## Spawn curve`
	_write("economy.md", _minimal_economy_md())
	ContentDB.load_all(TMP_DIR)
	assert_true(ContentDB.has_errors())
	assert_string_contains("\n".join(ContentDB.load_errors), "Spawn curve")


func test_out_of_range_value_errors_loudly() -> void:
	_clear_fixtures()
	# midpoint must be in [0, 1]; 5 is out of range.
	_write("balance.md", """## Time
ticks_per_day = 480
days_per_period = 7

## Spawn curve
spawn_curve_min_multiplier = 0.25
spawn_curve_max_multiplier = 3.0
spawn_curve_midpoint = 5.0
spawn_curve_steepness = 6.0
""")
	_write("economy.md", _minimal_economy_md())
	ContentDB.load_all(TMP_DIR)
	assert_true(ContentDB.has_errors())
	var joined := "\n".join(ContentDB.load_errors)
	assert_string_contains(joined, "out of range")
	assert_string_contains(joined, "spawn_curve_midpoint")


func test_malformed_scalar_value_errors_loudly() -> void:
	_clear_fixtures()
	_write("balance.md", """## Time
ticks_per_day = totally_not_a_number
days_per_period = 7

## Spawn curve
spawn_curve_min_multiplier = 0.25
spawn_curve_max_multiplier = 3.0
spawn_curve_midpoint = 0.5
spawn_curve_steepness = 6.0
""")
	_write("economy.md", _minimal_economy_md())
	ContentDB.load_all(TMP_DIR)
	assert_true(ContentDB.has_errors())
	assert_string_contains("\n".join(ContentDB.load_errors), "not an integer")


func test_broken_satisfies_reference_errors_loudly() -> void:
	_clear_fixtures()
	_write("balance.md", _minimal_balance_md())
	_write("economy.md", _minimal_economy_md())
	_write("needs.md", """## Needs
| id     | display_name | base_decay_per_tick |
| ------ | ------------ | ------------------- |
| hunger | Hunger       | 0.005               |
""")
	# Entity satisfies a need that doesn't exist.
	_write("entities.md", """## Entities
| id    | display_name | build_cost | maintenance_cost | footprint_x | footprint_y | sprite_key | satisfies   | appeal_profile |
| ----- | ------------ | ---------- | ---------------- | ----------- | ----------- | ---------- | ----------- | -------------- |
| stand | Stand        | 100        | 0                | 1           | 1           | k          | ghost_need  |                |
""")
	ContentDB.load_all(TMP_DIR)
	assert_true(ContentDB.has_errors())
	assert_string_contains("\n".join(ContentDB.load_errors), "ghost_need")


func test_broken_effect_entity_id_errors_loudly() -> void:
	_clear_fixtures()
	_write("balance.md", _minimal_balance_md())
	_write("economy.md", _minimal_economy_md())
	_write("entities.md", """## Effects
| id  | entity_id   | target  | operation | magnitude | proximity | conditions |
| --- | ----------- | ------- | --------- | --------- | --------- | ---------- |
| e1  | ghost_stand | revenue | add       | 5         | 0         |            |
""")
	ContentDB.load_all(TMP_DIR)
	assert_true(ContentDB.has_errors())
	assert_string_contains("\n".join(ContentDB.load_errors), "ghost_stand")


func test_broken_prerequisite_errors_loudly() -> void:
	_clear_fixtures()
	_write("balance.md", _minimal_balance_md())
	_write("economy.md", _minimal_economy_md())
	_write("progression.md", """## Unlock nodes
| id   | label | prerequisites  | cost | reputation_required | unlocks |
| ---- | ----- | -------------- | ---- | ------------------- | ------- |
| node | Node  | does_not_exist | 0    | 0                   |         |
""")
	ContentDB.load_all(TMP_DIR)
	assert_true(ContentDB.has_errors())
	assert_string_contains("\n".join(ContentDB.load_errors), "does_not_exist")


func test_errors_do_not_apply_to_ledger() -> void:
	_clear_fixtures()
	# Bad balance, but otherwise structurally fine.
	_write("balance.md", """## Time
ticks_per_day = -5
days_per_period = 7

## Spawn curve
spawn_curve_min_multiplier = 0.25
spawn_curve_max_multiplier = 3.0
spawn_curve_midpoint = 0.5
spawn_curve_steepness = 6.0
""")
	_write("economy.md", """## Globals
starting_cash = 9999
daily_settlement_enabled = true
""")
	# Snapshot pre-load state so we can assert nothing applied.
	Ledger.reset()
	var pre_balance := Ledger.get_balance()
	ContentDB.load_all(TMP_DIR)
	assert_true(ContentDB.has_errors())
	assert_false(ContentDB.is_loaded)
	assert_eq(Ledger.get_balance(), pre_balance,
		"on load errors, Ledger.reset must not be called with the bad value")


# --- Fixture content snippets ---------------------------------------------

func _minimal_balance_md() -> String:
	return """## Time
ticks_per_day = 480
days_per_period = 7

## Spawn curve
spawn_curve_min_multiplier = 0.25
spawn_curve_max_multiplier = 3.0
spawn_curve_midpoint = 0.5
spawn_curve_steepness = 6.0
"""


func _minimal_economy_md() -> String:
	return """## Globals
starting_cash = 1000
daily_settlement_enabled = true
"""


# --- v0.3.0: unlock cycle detection --------------------------------------

func test_cycle_detection_flags_two_node_back_edge() -> void:
	ContentDB.load_errors.clear()
	ContentDB.unlock_nodes.clear()
	var a := UnlockNode.new(); a.id = &"node_a"; a.prerequisites = [&"node_b"] as Array[StringName]
	var b := UnlockNode.new(); b.id = &"node_b"; b.prerequisites = [&"node_a"] as Array[StringName]
	ContentDB.unlock_nodes[a.id] = a
	ContentDB.unlock_nodes[b.id] = b
	ContentDB._validate_cross_refs()
	var found_cycle := false
	for err in ContentDB.load_errors:
		if "cycle" in err:
			found_cycle = true
			break
	assert_true(found_cycle, "expected a 'cycle' error, got: %s" % str(ContentDB.load_errors))
	ContentDB.unlock_nodes.clear()
	ContentDB.load_errors.clear()


func test_cycle_detection_accepts_acyclic_chain() -> void:
	ContentDB.load_errors.clear()
	ContentDB.unlock_nodes.clear()
	var root := UnlockNode.new(); root.id = &"root"; root.prerequisites = [] as Array[StringName]
	var mid := UnlockNode.new(); mid.id = &"mid"; mid.prerequisites = [&"root"] as Array[StringName]
	var leaf := UnlockNode.new(); leaf.id = &"leaf"; leaf.prerequisites = [&"mid"] as Array[StringName]
	ContentDB.unlock_nodes[root.id] = root
	ContentDB.unlock_nodes[mid.id] = mid
	ContentDB.unlock_nodes[leaf.id] = leaf
	ContentDB._validate_cross_refs()
	var cycle_errors: int = 0
	for err in ContentDB.load_errors:
		if "cycle" in err:
			cycle_errors += 1
	assert_eq(cycle_errors, 0, "expected 0 cycle errors in acyclic graph")
	ContentDB.unlock_nodes.clear()
	ContentDB.load_errors.clear()


# --- v0.3.1: traits + preferences from tuning -----------------------------

func test_real_agents_traits_populated_from_tuning() -> void:
	ContentDB.load_all()
	var visitor: AgentType = ContentDB.get_agent_type(&"visitor")
	assert_not_null(visitor)
	assert_true(visitor.trait_ranges.has(&"walking_speed"))
	var range_v: Vector2 = visitor.trait_ranges[&"walking_speed"]
	assert_almost_eq(range_v.x, 0.12, 0.0001)
	assert_almost_eq(range_v.y, 0.26, 0.0001)


func test_real_agents_preferences_populated_from_tuning() -> void:
	ContentDB.load_all()
	var premium: AgentType = ContentDB.get_agent_type(&"premium")
	assert_not_null(premium)
	assert_true(premium.preferences.has(&"thrill"))
	var pref: Vector2 = premium.preferences[&"thrill"]
	assert_almost_eq(pref.x, 0.7, 0.0001)
	assert_almost_eq(pref.y, 0.3, 0.0001)


func test_traits_section_with_unknown_agent_id_records_error() -> void:
	_clear_fixtures()
	_write("balance.md", _minimal_balance_md())
	_write("economy.md", _minimal_economy_md())
	_write("needs.md", "## Needs\n\n| id | display_name | base_decay_per_tick |\n| -- | ------------ | ------------------- |\n| h  | H            | 0.001               |\n")
	_write("agents.md",
		"## Agent types\n\n| id  | display_name | spawn_weight |\n| --- | ------------ | ------------ |\n| v   | V            | 1.0          |\n\n" +
		"## Traits\n\n| agent_id | trait | min  | max |\n| -------- | ----- | ---- | --- |\n| ghost    | speed | 0.1  | 0.2 |\n")
	ContentDB.load_all(TMP_DIR)
	var has_ghost_error := false
	for e in ContentDB.load_errors:
		if "ghost" in e:
			has_ghost_error = true
			break
	assert_true(has_ghost_error, "unknown agent_id in traits should be flagged; got: %s" % str(ContentDB.load_errors))


func test_traits_with_inverted_range_records_error() -> void:
	_clear_fixtures()
	_write("balance.md", _minimal_balance_md())
	_write("economy.md", _minimal_economy_md())
	_write("needs.md", "## Needs\n\n| id | display_name | base_decay_per_tick |\n| -- | ------------ | ------------------- |\n| h  | H            | 0.001               |\n")
	_write("agents.md",
		"## Agent types\n\n| id  | display_name | spawn_weight |\n| --- | ------------ | ------------ |\n| v   | V            | 1.0          |\n\n" +
		"## Traits\n\n| agent_id | trait | min  | max |\n| -------- | ----- | ---- | --- |\n| v        | speed | 0.5  | 0.1 |\n")
	ContentDB.load_all(TMP_DIR)
	var bad_range := false
	for e in ContentDB.load_errors:
		if "min" in e and "max" in e:
			bad_range = true
			break
	assert_true(bad_range, "inverted trait range should be flagged; got: %s" % str(ContentDB.load_errors))
