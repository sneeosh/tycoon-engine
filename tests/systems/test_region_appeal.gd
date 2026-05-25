extends GutTest
# Tests for Region Appeal.
# Spec: design/algorithms/region_appeal.md
#
# Each test_row_* method mirrors one row of the spec's Worked Examples table.
# Drift between the table and the implementation must turn a test red.
#
# Happiness values in the spec table are *stipulated*. Real happiness is the
# job of the registered IPlaceableHappiness implementation; for unit-testing
# the aggregation math we register a lookup-table implementation that returns
# pre-set values by (region_id, index).
#
# Placeables (appeal_contribution shown):
#   P_A: {axis1: 0.8, axis2: 0.6}
#   P_B: {axis1: 0.7, axis2: 0.7, axis3: 0.4}
#   P_C: {axis2: 0.4}
#   P_D: {axis2: 0.5, axis3: 0.7}
#   P_E: {axis2: 0.6, axis4: 0.8}
#
# Regions:
#   R_4:  area 4
#   R_9:  area 9
#   R_16: area 16

const EPSILON: float = 0.001

const ZT_ALPHA := &"zt_alpha_appeal"

const PL_A := &"p_a"
const PL_B := &"p_b"
const PL_C := &"p_c"
const PL_D := &"p_d"
const PL_E := &"p_e"


# --- Stipulated-happiness IPlaceableHappiness impl -----------------------
# Inner class to feed deterministic happiness values into the aggregator
# without touching any real happiness model.

class StipulatedHappiness extends IPlaceableHappiness:
	# (region_id, index) -> float
	var table: Dictionary = {}

	func set_happiness(region_id: int, index: int, value: float) -> void:
		table[Vector2i(region_id, index)] = value

	func compute_happiness(region: Region, index: int) -> float:
		return table.get(Vector2i(region.region_id, index), 1.0)


var _happiness: StipulatedHappiness


func before_each() -> void:
	Ledger.reset(1_000_000)
	EntityRegistry.reset()
	RegionRegistry.reset()

	_happiness = StipulatedHappiness.new()
	EffectResolver.register_happiness_model(_happiness)

	# Single zone tile def — kind alpha, provides every tag any placeable
	# below requires, so placements aren't blocked by compatibility checks
	# (which are tested separately in test_placement_compatibility.gd).
	var zt := EntityDef.new()
	zt.id = ZT_ALPHA
	zt.display_name = "Appeal Alpha"
	zt.footprint = Vector2i(1, 1)
	zt.zone_kind = &"alpha"
	zt.zone_tags = [&"any"] as Array[StringName]
	ContentDB.entity_defs[ZT_ALPHA] = zt

	_define_placeable(PL_A, "P_A", {&"axis1": 0.8, &"axis2": 0.6})
	_define_placeable(PL_B, "P_B", {&"axis1": 0.7, &"axis2": 0.7, &"axis3": 0.4})
	_define_placeable(PL_C, "P_C", {&"axis2": 0.4})
	_define_placeable(PL_D, "P_D", {&"axis2": 0.5, &"axis3": 0.7})
	_define_placeable(PL_E, "P_E", {&"axis2": 0.6, &"axis4": 0.8})


func after_each() -> void:
	ContentDB.entity_defs.erase(ZT_ALPHA)
	for id in [PL_A, PL_B, PL_C, PL_D, PL_E]:
		ContentDB.placeable_defs.erase(id)
	# Restore default happiness model (engine impl returns 1.0).
	EffectResolver.register_happiness_model(IPlaceableHappiness.new())


# --- Helpers --------------------------------------------------------------

func _define_placeable(id: StringName, name: String, contribution: Dictionary) -> void:
	var p := PlaceableDef.new()
	p.id = id
	p.display_name = name
	p.space_required = 1  # so we never run into area limits while testing math
	p.required_zone_tags = [] as Array[StringName]
	p.appeal_contribution = contribution
	ContentDB.placeable_defs[id] = p


# Build a region of `area` cells by placing single-cell alpha tiles in a line.
# `y_row` keeps each test's region in its own row.
func _build_region(area: int, y_row: int) -> Region:
	for x in area:
		EntityRegistry.place(ZT_ALPHA, Vector2i(x, y_row))
	var region := RegionRegistry.region_at_cell(Vector2i(0, y_row))
	assert_eq(region.area, area, "region built with the expected area")
	return region


func _add_with_happiness(region: Region, def_id: StringName, happiness: float) -> int:
	var idx := region.placements.size()
	var placement := RegionRegistry.add_placement(region.region_id, def_id)
	assert_not_null(placement, "add_placement must succeed for %s" % def_id)
	_happiness.set_happiness(region.region_id, idx, happiness)
	return idx


func _assert_axes(profile: Dictionary, expected: Dictionary) -> void:
	assert_eq(profile.size(), expected.size(),
		"axis count mismatch: got %s, expected %s" % [profile.keys(), expected.keys()])
	for axis in expected.keys():
		assert_true(profile.has(axis), "missing axis %s" % axis)
		assert_almost_eq(float(profile[axis]), float(expected[axis]), EPSILON,
			"axis %s" % axis)


# --- Spec rows ------------------------------------------------------------

# Row 1: R_4, no placements → {} (empty).
func test_row_1_empty_region_returns_empty_profile() -> void:
	var r := _build_region(4, 0)
	var profile: Dictionary = EffectResolver.compute_region_appeal(r)
	assert_eq(profile, {})


# Row 2: R_4, [P_A], happiness [0.90].
# eff axis1 = 0.8 * 0.9 = 0.72; appeal = 1 - (1 - 0.72) = 0.72
# eff axis2 = 0.6 * 0.9 = 0.54; appeal = 1 - (1 - 0.54) = 0.54
func test_row_2_single_placement_with_happiness() -> void:
	var r := _build_region(4, 1)
	_add_with_happiness(r, PL_A, 0.90)
	var profile: Dictionary = EffectResolver.compute_region_appeal(r)
	_assert_axes(profile, {&"axis1": 0.72, &"axis2": 0.54})


# Row 3: R_9, [P_A, P_A], happiness [1.00, 1.00].
# axis1: 1 - (1 - 0.8)^2 = 1 - 0.04 = 0.96
# axis2: 1 - (1 - 0.6)^2 = 1 - 0.16 = 0.84
func test_row_3_two_identical_full_happiness() -> void:
	var r := _build_region(9, 2)
	_add_with_happiness(r, PL_A, 1.00)
	_add_with_happiness(r, PL_A, 1.00)
	var profile: Dictionary = EffectResolver.compute_region_appeal(r)
	_assert_axes(profile, {&"axis1": 0.96, &"axis2": 0.84})


# Row 4: R_16, [P_A]×4, happiness 1.00 each.
# axis1: 1 - 0.2^4 = 0.9984
# axis2: 1 - 0.4^4 = 0.9744
func test_row_4_four_identical_full_happiness() -> void:
	var r := _build_region(16, 3)
	for _i in 4:
		_add_with_happiness(r, PL_A, 1.00)
	var profile: Dictionary = EffectResolver.compute_region_appeal(r)
	_assert_axes(profile, {&"axis1": 0.9984, &"axis2": 0.9744})


# Row 5: R_16, [P_A]×5, happiness 0.85 each.
# eff axis1 = 0.8 * 0.85 = 0.68; 1 - 0.32^5 ≈ 0.9966
# eff axis2 = 0.6 * 0.85 = 0.51; 1 - 0.49^5 ≈ 0.9718
func test_row_5_five_identical_partial_happiness() -> void:
	var r := _build_region(16, 4)
	for _i in 5:
		_add_with_happiness(r, PL_A, 0.85)
	var profile: Dictionary = EffectResolver.compute_region_appeal(r)
	var expected_axis1 := 1.0 - pow(0.32, 5)
	var expected_axis2 := 1.0 - pow(0.49, 5)
	_assert_axes(profile, {&"axis1": expected_axis1, &"axis2": expected_axis2})


# Row 6: R_9, [P_A, P_B], happiness [0.90, 0.90].
# axis1: P_A eff 0.72, P_B eff 0.63 → 1 - 0.28 * 0.37 = 0.8964
# axis2: P_A eff 0.54, P_B eff 0.63 → 1 - 0.46 * 0.37 = 0.8298
# axis3: P_B only, eff 0.36 → 0.36
func test_row_6_mixed_placeables_overlapping_axes() -> void:
	var r := _build_region(9, 5)
	_add_with_happiness(r, PL_A, 0.90)
	_add_with_happiness(r, PL_B, 0.90)
	var profile: Dictionary = EffectResolver.compute_region_appeal(r)
	_assert_axes(profile, {
		&"axis1": 1.0 - 0.28 * 0.37,   # 0.8964
		&"axis2": 1.0 - 0.46 * 0.37,   # 0.8298
		&"axis3": 0.36,
	})


# Row 7: R_9, [P_D]×5, happiness 1.00 each.
# eff axis2 = 0.5, axis3 = 0.7
# axis2: 1 - 0.5^5 = 0.96875
# axis3: 1 - 0.3^5 = 0.99757
func test_row_7_five_pd_full_happiness() -> void:
	var r := _build_region(9, 6)
	for _i in 5:
		_add_with_happiness(r, PL_D, 1.00)
	var profile: Dictionary = EffectResolver.compute_region_appeal(r)
	_assert_axes(profile, {
		&"axis2": 1.0 - pow(0.5, 5),
		&"axis3": 1.0 - pow(0.3, 5),
	})


# Row 8: R_9, [P_D], happiness [0.80].
# eff axis2 = 0.5 * 0.8 = 0.40
# eff axis3 = 0.7 * 0.8 = 0.56
func test_row_8_single_pd_partial_happiness() -> void:
	var r := _build_region(9, 7)
	_add_with_happiness(r, PL_D, 0.80)
	var profile: Dictionary = EffectResolver.compute_region_appeal(r)
	_assert_axes(profile, {&"axis2": 0.40, &"axis3": 0.56})


# Row 9: R_16, [P_E]×4, happiness 0.90 each.
# eff axis2 = 0.54; 1 - 0.46^4 ≈ 0.9552
# eff axis4 = 0.72; 1 - 0.28^4 ≈ 0.9939
func test_row_9_four_pe_partial_happiness() -> void:
	var r := _build_region(16, 8)
	for _i in 4:
		_add_with_happiness(r, PL_E, 0.90)
	var profile: Dictionary = EffectResolver.compute_region_appeal(r)
	_assert_axes(profile, {
		&"axis2": 1.0 - pow(0.46, 4),
		&"axis4": 1.0 - pow(0.28, 4),
	})


# Row 10: R_4, [P_C], happiness [0.70].
# eff axis2 = 0.4 * 0.7 = 0.28
func test_row_10_single_pc_partial_happiness() -> void:
	var r := _build_region(4, 9)
	_add_with_happiness(r, PL_C, 0.70)
	var profile: Dictionary = EffectResolver.compute_region_appeal(r)
	_assert_axes(profile, {&"axis2": 0.28})
