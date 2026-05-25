extends GutTest
# Tests for Placement Compatibility.
# Spec: design/algorithms/placement_compatibility.md
#
# Each test_row_* method mirrors one row of the spec's Worked Examples table.
# Drift between the table and the implementation must turn a test red.
#
# Fixtures (PlaceableDef):
#   P_A: space_req 3, required_zone_tags [t1],     own [markX], incompat [markY]
#   P_B: space_req 2, required_zone_tags [t1],     own [markY], incompat [markX]
#   P_C: space_req 1, required_zone_tags [t2],     own [markZ], incompat []
#   P_D: space_req 1, required_zone_tags [t2, t3], own [markZ], incompat []
#
# Regions (constructed by placing zone tiles via EntityRegistry; not authored):
#   R1: kind=alpha, area=4,  provided=[t1]
#   R2: kind=alpha, area=9,  provided=[t1, t4]
#   R3: kind=beta,  area=8,  provided=[t2, t1]
#   R4: kind=alpha, area=12, provided=[t1, t3]

const ZT_ALPHA_T1 := &"zt_alpha_t1"
const ZT_ALPHA_T1_T4 := &"zt_alpha_t1_t4"
const ZT_BETA_T2_T1 := &"zt_beta_t2_t1"
const ZT_ALPHA_T1_T3 := &"zt_alpha_t1_t3"

const PL_A := &"p_a"
const PL_B := &"p_b"
const PL_C := &"p_c"
const PL_D := &"p_d"


func before_each() -> void:
	Ledger.reset(1_000_000)
	EntityRegistry.reset()
	RegionRegistry.reset()

	# --- Zone tile defs --------------------------------------------------
	var zt_a := EntityDef.new()
	zt_a.id = ZT_ALPHA_T1
	zt_a.display_name = "Alpha-t1"
	zt_a.footprint = Vector2i(1, 1)
	zt_a.zone_kind = &"alpha"
	zt_a.zone_tags = [&"t1"] as Array[StringName]
	ContentDB.entity_defs[ZT_ALPHA_T1] = zt_a

	var zt_b := EntityDef.new()
	zt_b.id = ZT_ALPHA_T1_T4
	zt_b.display_name = "Alpha-t1-t4"
	zt_b.footprint = Vector2i(1, 1)
	zt_b.zone_kind = &"alpha"
	zt_b.zone_tags = [&"t1", &"t4"] as Array[StringName]
	ContentDB.entity_defs[ZT_ALPHA_T1_T4] = zt_b

	var zt_c := EntityDef.new()
	zt_c.id = ZT_BETA_T2_T1
	zt_c.display_name = "Beta-t2-t1"
	zt_c.footprint = Vector2i(1, 1)
	zt_c.zone_kind = &"beta"
	zt_c.zone_tags = [&"t2", &"t1"] as Array[StringName]
	ContentDB.entity_defs[ZT_BETA_T2_T1] = zt_c

	var zt_d := EntityDef.new()
	zt_d.id = ZT_ALPHA_T1_T3
	zt_d.display_name = "Alpha-t1-t3"
	zt_d.footprint = Vector2i(1, 1)
	zt_d.zone_kind = &"alpha"
	zt_d.zone_tags = [&"t1", &"t3"] as Array[StringName]
	ContentDB.entity_defs[ZT_ALPHA_T1_T3] = zt_d

	# --- Placeables -------------------------------------------------------
	var p_a := PlaceableDef.new()
	p_a.id = PL_A
	p_a.display_name = "P_A"
	p_a.space_required = 3
	p_a.required_zone_tags = [&"t1"] as Array[StringName]
	p_a.own_tags = [&"markX"] as Array[StringName]
	p_a.incompatible_tags = [&"markY"] as Array[StringName]
	ContentDB.placeable_defs[PL_A] = p_a

	var p_b := PlaceableDef.new()
	p_b.id = PL_B
	p_b.display_name = "P_B"
	p_b.space_required = 2
	p_b.required_zone_tags = [&"t1"] as Array[StringName]
	p_b.own_tags = [&"markY"] as Array[StringName]
	p_b.incompatible_tags = [&"markX"] as Array[StringName]
	ContentDB.placeable_defs[PL_B] = p_b

	var p_c := PlaceableDef.new()
	p_c.id = PL_C
	p_c.display_name = "P_C"
	p_c.space_required = 1
	p_c.required_zone_tags = [&"t2"] as Array[StringName]
	p_c.own_tags = [&"markZ"] as Array[StringName]
	p_c.incompatible_tags = [] as Array[StringName]
	ContentDB.placeable_defs[PL_C] = p_c

	var p_d := PlaceableDef.new()
	p_d.id = PL_D
	p_d.display_name = "P_D"
	p_d.space_required = 1
	p_d.required_zone_tags = [&"t2", &"t3"] as Array[StringName]
	p_d.own_tags = [&"markZ"] as Array[StringName]
	p_d.incompatible_tags = [] as Array[StringName]
	ContentDB.placeable_defs[PL_D] = p_d


func after_each() -> void:
	ContentDB.entity_defs.erase(ZT_ALPHA_T1)
	ContentDB.entity_defs.erase(ZT_ALPHA_T1_T4)
	ContentDB.entity_defs.erase(ZT_BETA_T2_T1)
	ContentDB.entity_defs.erase(ZT_ALPHA_T1_T3)
	ContentDB.placeable_defs.erase(PL_A)
	ContentDB.placeable_defs.erase(PL_B)
	ContentDB.placeable_defs.erase(PL_C)
	ContentDB.placeable_defs.erase(PL_D)


# --- Region builders ------------------------------------------------------
# Each builder lays out a connected line of zone tiles starting at row y
# (y unique per region to avoid collisions) so the tests stay independent.

func _build_r1() -> Region:
	# 4 alpha tiles with tag t1, area 4.
	for x in 4:
		EntityRegistry.place(ZT_ALPHA_T1, Vector2i(x, 0))
	return RegionRegistry.region_at_cell(Vector2i(0, 0))


func _build_r2() -> Region:
	# 9 alpha tiles, mix of (t1) and (t1,t4) so provided = [t1, t4], area 9.
	for x in 6:
		EntityRegistry.place(ZT_ALPHA_T1, Vector2i(x, 2))
	for x in range(6, 9):
		EntityRegistry.place(ZT_ALPHA_T1_T4, Vector2i(x, 2))
	return RegionRegistry.region_at_cell(Vector2i(0, 2))


func _build_r3() -> Region:
	# 8 beta tiles, provided = [t2, t1] via beta tile's own zone_tags. area 8.
	for x in 8:
		EntityRegistry.place(ZT_BETA_T2_T1, Vector2i(x, 4))
	return RegionRegistry.region_at_cell(Vector2i(0, 4))


func _build_r4() -> Region:
	# 12 alpha tiles, provided = [t1, t3]. area 12.
	for x in 12:
		EntityRegistry.place(ZT_ALPHA_T1_T3, Vector2i(x, 6))
	return RegionRegistry.region_at_cell(Vector2i(0, 6))


# --- Spec rows ------------------------------------------------------------

# Row 1: R1, no existing, candidate P_A → ok.
func test_row_1_first_placeable_fits() -> void:
	var r := _build_r1()
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_A)
	assert_true(result["ok"])


# Row 2: R1, [P_A], candidate P_A → over space: need 3, have 1.
func test_row_2_second_placeable_over_space() -> void:
	var r := _build_r1()
	RegionRegistry.add_placement(r.region_id, PL_A)
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_A)
	assert_false(result["ok"])
	assert_eq(result["reason"], "over space: need 3, have 1")


# Row 3: R1, [P_A], candidate P_B → incompatible with P_A.
func test_row_3_incompatible_with_existing_via_candidate_decl() -> void:
	var r := _build_r1()
	RegionRegistry.add_placement(r.region_id, PL_A)
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_B)
	assert_false(result["ok"])
	assert_eq(result["reason"], "incompatible with P_A")


# Row 4: R1, [P_B], candidate P_A → incompatible with P_B (symmetric).
func test_row_4_incompatible_via_existing_decl() -> void:
	var r := _build_r1()
	# R1 area=4; P_B space_req=2 fits.
	RegionRegistry.add_placement(r.region_id, PL_B)
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_A)
	assert_false(result["ok"])
	assert_eq(result["reason"], "incompatible with P_B")


# Row 5: R1 (provided=[t1]), candidate P_C (needs t2) → missing zone tag: t2.
func test_row_5_missing_single_zone_tag() -> void:
	var r := _build_r1()
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_C)
	assert_false(result["ok"])
	assert_eq(result["reason"], "missing zone tag: t2")


# Row 6: R1 (provided=[t1]), candidate P_D (needs t2 and t3) → first missing
# tag reported (t2).
func test_row_6_missing_first_of_multiple_zone_tags() -> void:
	var r := _build_r1()
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_D)
	assert_false(result["ok"])
	assert_eq(result["reason"], "missing zone tag: t2")


# Row 7: R2 area=9, [P_A], candidate P_A → ok (6 of 9 used after).
func test_row_7_second_pa_fits_in_larger_region() -> void:
	var r := _build_r2()
	RegionRegistry.add_placement(r.region_id, PL_A)
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_A)
	assert_true(result["ok"])


# Row 8: R2, [P_A, P_A], candidate P_A → ok (9 of 9 used after — exact fit).
func test_row_8_third_pa_fits_exactly() -> void:
	var r := _build_r2()
	RegionRegistry.add_placement(r.region_id, PL_A)
	RegionRegistry.add_placement(r.region_id, PL_A)
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_A)
	assert_true(result["ok"])


# Row 9: R2, [P_A, P_A, P_A], candidate P_A → over space: need 3, have 0.
func test_row_9_fourth_pa_over_space() -> void:
	var r := _build_r2()
	RegionRegistry.add_placement(r.region_id, PL_A)
	RegionRegistry.add_placement(r.region_id, PL_A)
	RegionRegistry.add_placement(r.region_id, PL_A)
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_A)
	assert_false(result["ok"])
	assert_eq(result["reason"], "over space: need 3, have 0")


# Row 10: R3 (provided=[t2,t1], area=8), no existing, candidate P_C → ok.
func test_row_10_pc_fits_in_r3() -> void:
	var r := _build_r3()
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_C)
	assert_true(result["ok"])


# Row 11: R3, [P_C]×8, candidate P_C → over space: need 1, have 0.
func test_row_11_ninth_pc_over_space() -> void:
	var r := _build_r3()
	for _i in 8:
		RegionRegistry.add_placement(r.region_id, PL_C)
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_C)
	assert_false(result["ok"])
	assert_eq(result["reason"], "over space: need 1, have 0")


# Row 12: R4 (provided=[t1,t3]), candidate P_D (needs [t2,t3]) → missing t2.
func test_row_12_r4_missing_t2_for_pd() -> void:
	var r := _build_r4()
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_D)
	assert_false(result["ok"])
	assert_eq(result["reason"], "missing zone tag: t2")


# Row 13: R4, [P_A, P_A, P_A], candidate P_B → incompatible with P_A.
# (incompatibility wins even when space would also fail — but P_B fits the
# remaining 3 space, so this isolates the incompat check.)
func test_row_13_incompat_overrides_when_space_ok() -> void:
	var r := _build_r4()
	RegionRegistry.add_placement(r.region_id, PL_A)
	RegionRegistry.add_placement(r.region_id, PL_A)
	RegionRegistry.add_placement(r.region_id, PL_A)
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_B)
	assert_false(result["ok"])
	assert_eq(result["reason"], "incompatible with P_A")


# Row 14: R4, [P_A]×3, candidate P_A → ok (12 area, 12 used after — full).
func test_row_14_exact_fill_with_pa() -> void:
	var r := _build_r4()
	RegionRegistry.add_placement(r.region_id, PL_A)
	RegionRegistry.add_placement(r.region_id, PL_A)
	RegionRegistry.add_placement(r.region_id, PL_A)
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_A)
	assert_true(result["ok"])


# Row 15: R4, [P_A]×4, candidate P_A → over space: need 3, have 0.
func test_row_15_over_space_after_exact_fill() -> void:
	var r := _build_r4()
	RegionRegistry.add_placement(r.region_id, PL_A)
	RegionRegistry.add_placement(r.region_id, PL_A)
	RegionRegistry.add_placement(r.region_id, PL_A)
	RegionRegistry.add_placement(r.region_id, PL_A)
	var result: Dictionary = RegionRegistry.can_add_placement(r.region_id, PL_A)
	assert_false(result["ok"])
	assert_eq(result["reason"], "over space: need 3, have 0")
