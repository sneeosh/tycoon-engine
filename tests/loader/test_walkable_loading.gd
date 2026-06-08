extends GutTest
# Regression tests for loading walkable-network fields from markdown tuning.
# Spec: design/algorithms/navigation.md
#
# The v0.6.0 navigation seam was shipped with a scope bug: the walkable
# column parsing was nested inside the `useful_life_days` branch, so an
# entities.md row without a `useful_life_days` column never parsed
# `walkable` — no tile ever registered as walkable. The original tests only
# constructed EntityDefs in code and missed it. These tests drive the full
# markdown → ContentDB → NavigationRegistry path.

const TMP := "user://test_walkable_loading/"


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP))


func after_all() -> void:
	# Restore the real tuning so later test scripts see canonical content.
	ContentDB.load_all()


func _write(name: String, content: String) -> void:
	var f := FileAccess.open(TMP + name, FileAccess.WRITE)
	f.store_string(content)
	f.close()


func _write_base() -> void:
	_write("balance.md", "## Time\nticks_per_day = 480\ndays_per_period = 7\n\n## Spawn curve\nspawn_curve_min_multiplier = 0.25\nspawn_curve_max_multiplier = 3.0\nspawn_curve_midpoint = 0.5\nspawn_curve_steepness = 6.0\n")
	_write("economy.md", "## Globals\nstarting_cash = 1000\ndaily_settlement_enabled = true\n")


# A walkable row WITHOUT a useful_life_days column must still parse walkable
# (this is exactly the shipped bug).
func test_walkable_parses_without_useful_life_column() -> void:
	_write_base()
	_write("entities.md", "## Entities\n" +
		"| id | display_name | build_cost | maintenance_cost | footprint_x | footprint_y | sprite_key | satisfies | appeal_profile | walkable | traversal_cost | network_id | walkable_tags |\n" +
		"| -- | ------------ | ---------- | ---------------- | ----------- | ----------- | ---------- | --------- | -------------- | -------- | -------------- | ---------- | ------------- |\n" +
		"| walk_tile | Walkway | 10 | 0 | 1 | 1 | w | | | true  | 2.0 | outdoor | paid |\n" +
		"| solid     | Solid   | 10 | 0 | 1 | 1 | s | | | false | 1.0 | default | |\n")

	ContentDB.load_all(TMP)
	assert_eq(ContentDB.load_errors, [] as Array[String],
		"fixture must load clean: %s" % str(ContentDB.load_errors))

	var wt := ContentDB.get_entity_def(&"walk_tile")
	assert_not_null(wt)
	assert_true(wt.walkable, "walkable must parse true even with no useful_life_days column")
	assert_eq(wt.traversal_cost, 2.0)
	assert_eq(wt.network_id, &"outdoor")
	assert_eq(wt.walkable_tags, [&"paid"] as Array[StringName])
	assert_false(ContentDB.get_entity_def(&"solid").walkable)


# End-to-end: a markdown-declared walkable tile, once placed, registers a
# cell in the NavigationRegistry network it names.
func test_markdown_walkable_tile_registers_network_cell() -> void:
	_write_base()
	_write("entities.md", "## Entities\n" +
		"| id | display_name | build_cost | maintenance_cost | footprint_x | footprint_y | sprite_key | satisfies | appeal_profile | walkable | network_id |\n" +
		"| -- | ------------ | ---------- | ---------------- | ----------- | ----------- | ---------- | --------- | -------------- | -------- | ---------- |\n" +
		"| walk_tile | Walkway | 0 | 0 | 1 | 1 | w | | | true | outdoor |\n")

	ContentDB.load_all(TMP)
	assert_eq(ContentDB.load_errors, [] as Array[String], str(ContentDB.load_errors))

	Ledger.reset(1000)
	EntityRegistry.reset()
	NavigationRegistry.reset()
	EntityRegistry.place(&"walk_tile", Vector2i(4, 7))

	var net := NavigationRegistry.get_network(&"outdoor")
	assert_not_null(net, "named network must exist after placing a walkable tile")
	assert_true(net != null and net.has_cell(Vector2i(4, 7)), "tile must register as walkable")
