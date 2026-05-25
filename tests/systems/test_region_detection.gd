extends GutTest
# Tests for Region Detection.
# Spec: design/algorithms/region_detection.md
#
# Each test_row_* method mirrors one row of the spec's Worked Examples table.
# Drift between the table and the implementation must turn a test red.
#
# Fixtures (see spec):
#   α  = EntityDef zone_kind="alpha", zone_tags=[t1]
#   α' = EntityDef zone_kind="alpha", zone_tags=[t1, t2]   (variant)
#   β  = EntityDef zone_kind="beta",  zone_tags=[t3, t1]
#
# Placeables used in rows 9-11:
#   Q  = space_required=1, required_zone_tags=[t1]
#   Q3 = space_required=3, required_zone_tags=[t1]
#   Q2 = space_required=1, required_zone_tags=[t2]

const ZT_ALPHA := &"zt_alpha"
const ZT_ALPHA_PRIME := &"zt_alpha_prime"
const ZT_BETA := &"zt_beta"

const PL_Q := &"pl_q"
const PL_Q3 := &"pl_q3"
const PL_Q2 := &"pl_q2"


func before_each() -> void:
	Ledger.reset(1_000_000)
	EntityRegistry.reset()
	RegionRegistry.reset()

	var alpha := EntityDef.new()
	alpha.id = ZT_ALPHA
	alpha.display_name = "Alpha Tile"
	alpha.build_cost = 0
	alpha.footprint = Vector2i(1, 1)
	alpha.zone_kind = &"alpha"
	alpha.zone_tags = [&"t1"] as Array[StringName]
	ContentDB.entity_defs[ZT_ALPHA] = alpha

	var alpha_prime := EntityDef.new()
	alpha_prime.id = ZT_ALPHA_PRIME
	alpha_prime.display_name = "Alpha+ Tile"
	alpha_prime.build_cost = 0
	alpha_prime.footprint = Vector2i(1, 1)
	alpha_prime.zone_kind = &"alpha"
	alpha_prime.zone_tags = [&"t1", &"t2"] as Array[StringName]
	ContentDB.entity_defs[ZT_ALPHA_PRIME] = alpha_prime

	var beta := EntityDef.new()
	beta.id = ZT_BETA
	beta.display_name = "Beta Tile"
	beta.build_cost = 0
	beta.footprint = Vector2i(1, 1)
	beta.zone_kind = &"beta"
	beta.zone_tags = [&"t3", &"t1"] as Array[StringName]
	ContentDB.entity_defs[ZT_BETA] = beta

	var q := PlaceableDef.new()
	q.id = PL_Q
	q.display_name = "Q"
	q.space_required = 1
	q.required_zone_tags = [&"t1"] as Array[StringName]
	ContentDB.placeable_defs[PL_Q] = q

	var q3 := PlaceableDef.new()
	q3.id = PL_Q3
	q3.display_name = "Q3"
	q3.space_required = 3
	q3.required_zone_tags = [&"t1"] as Array[StringName]
	ContentDB.placeable_defs[PL_Q3] = q3

	var q2 := PlaceableDef.new()
	q2.id = PL_Q2
	q2.display_name = "Q2"
	q2.space_required = 1
	q2.required_zone_tags = [&"t2"] as Array[StringName]
	ContentDB.placeable_defs[PL_Q2] = q2


func after_each() -> void:
	ContentDB.entity_defs.erase(ZT_ALPHA)
	ContentDB.entity_defs.erase(ZT_ALPHA_PRIME)
	ContentDB.entity_defs.erase(ZT_BETA)
	ContentDB.placeable_defs.erase(PL_Q)
	ContentDB.placeable_defs.erase(PL_Q3)
	ContentDB.placeable_defs.erase(PL_Q2)


# --- Helpers --------------------------------------------------------------

func _region_for_cell(cell: Vector2i) -> Region:
	return RegionRegistry.region_at_cell(cell)


# --- Spec rows ------------------------------------------------------------

# Row 1: empty grid; place α at (1,1) → Region #1 with kind alpha, area 1.
func test_row_1_first_tile_creates_isolated_region() -> void:
	var created_ids: Array[int] = []
	var capture := func(rid: int) -> void: created_ids.append(rid)
	RegionRegistry.region_created.connect(capture)

	var iid := EntityRegistry.place(ZT_ALPHA, Vector2i(1, 1))
	assert_ne(iid, 0)

	assert_eq(created_ids.size(), 1, "exactly one region_created signal")
	var region := RegionRegistry.get_region(created_ids[0])
	assert_not_null(region)
	assert_eq(region.kind, &"alpha")
	assert_eq(region.area, 1)
	assert_eq(region.cells, [Vector2i(1, 1)] as Array[Vector2i])
	assert_true(region.provided_zone_tags.has(&"t1"))
	assert_eq(region.provided_zone_tags.size(), 1)

	RegionRegistry.region_created.disconnect(capture)


# Row 2: Region #1 with α at (1,1); place α at (1,2) → #1 extends to area 2.
func test_row_2_same_kind_adjacent_extends_region() -> void:
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 1))
	var initial_region := _region_for_cell(Vector2i(1, 1))
	var initial_id := initial_region.region_id

	var changed_ids: Array[int] = []
	var capture := func(rid: int) -> void: changed_ids.append(rid)
	RegionRegistry.region_changed.connect(capture)

	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 2))

	assert_eq(changed_ids, [initial_id] as Array[int])
	var region := RegionRegistry.get_region(initial_id)
	assert_eq(region.area, 2)
	assert_eq(region.cells.size(), 2)
	assert_true(region.cells.has(Vector2i(1, 1)))
	assert_true(region.cells.has(Vector2i(1, 2)))

	RegionRegistry.region_changed.disconnect(capture)


# Row 3: Region #1 covers (1,1),(1,2). Place α at (3,3) → new Region #2; #1
# unchanged.
func test_row_3_disjoint_same_kind_creates_new_region() -> void:
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 1))
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 2))
	var r1_id := _region_for_cell(Vector2i(1, 1)).region_id

	var created_ids: Array[int] = []
	var capture := func(rid: int) -> void: created_ids.append(rid)
	RegionRegistry.region_created.connect(capture)

	EntityRegistry.place(ZT_ALPHA, Vector2i(3, 3))

	assert_eq(created_ids.size(), 1, "second region created")
	var r2 := RegionRegistry.get_region(created_ids[0])
	assert_ne(r2.region_id, r1_id)
	assert_eq(r2.area, 1)
	assert_eq(r2.cells, [Vector2i(3, 3)] as Array[Vector2i])

	var r1 := RegionRegistry.get_region(r1_id)
	assert_eq(r1.area, 2, "#1 untouched")

	RegionRegistry.region_created.disconnect(capture)


# Row 4: Region #1 at (1,1),(1,2); Region #2 at (3,3). Place α at (2,3) →
# Region #2 extends to [(3,3),(2,3)]; no merge with #1.
func test_row_4_extends_neighbour_region_without_merge() -> void:
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 1))
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 2))
	EntityRegistry.place(ZT_ALPHA, Vector2i(3, 3))
	var r1_id := _region_for_cell(Vector2i(1, 1)).region_id
	var r2_id := _region_for_cell(Vector2i(3, 3)).region_id

	EntityRegistry.place(ZT_ALPHA, Vector2i(2, 3))

	var r2 := RegionRegistry.get_region(r2_id)
	assert_eq(r2.area, 2)
	assert_true(r2.cells.has(Vector2i(3, 3)))
	assert_true(r2.cells.has(Vector2i(2, 3)))

	var r1 := RegionRegistry.get_region(r1_id)
	assert_eq(r1.area, 2, "#1 untouched")
	assert_ne(r1.region_id, r2.region_id, "still separate regions")


# Row 5: Region #1 at (1,1),(1,2); Region #2 at (2,3),(3,3). Place α at (1,3)
# → merge: #1 absorbs #2 → area 5; #2 destroyed.
func test_row_5_bridging_tile_merges_regions() -> void:
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 1))
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 2))
	EntityRegistry.place(ZT_ALPHA, Vector2i(3, 3))
	EntityRegistry.place(ZT_ALPHA, Vector2i(2, 3))
	var r1_id := _region_for_cell(Vector2i(1, 1)).region_id
	var r2_id := _region_for_cell(Vector2i(3, 3)).region_id
	assert_ne(r1_id, r2_id)

	var destroyed_ids: Array[int] = []
	var changed_ids: Array[int] = []
	var capture_destroy := func(rid: int) -> void: destroyed_ids.append(rid)
	var capture_change := func(rid: int) -> void: changed_ids.append(rid)
	RegionRegistry.region_destroyed.connect(capture_destroy)
	RegionRegistry.region_changed.connect(capture_change)

	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 3))

	assert_eq(destroyed_ids, [r2_id] as Array[int], "#2 destroyed by merge")
	assert_true(changed_ids.has(r1_id), "#1 changed by merge")

	var merged := _region_for_cell(Vector2i(1, 3))
	assert_eq(merged.region_id, r1_id)
	assert_eq(merged.area, 5)
	assert_true(merged.cells.has(Vector2i(1, 1)))
	assert_true(merged.cells.has(Vector2i(1, 2)))
	assert_true(merged.cells.has(Vector2i(1, 3)))
	assert_true(merged.cells.has(Vector2i(2, 3)))
	assert_true(merged.cells.has(Vector2i(3, 3)))

	assert_null(RegionRegistry.get_region(r2_id), "#2 gone")

	RegionRegistry.region_destroyed.disconnect(capture_destroy)
	RegionRegistry.region_changed.disconnect(capture_change)


# Row 6: Region #1 with α at (1,1),(1,2); place α' (variant) at (1,3) →
# same kind so #1 extends; zone_tags now include t2.
func test_row_6_variant_tile_extends_and_adds_tag() -> void:
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 1))
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 2))
	var r1_id := _region_for_cell(Vector2i(1, 1)).region_id

	EntityRegistry.place(ZT_ALPHA_PRIME, Vector2i(1, 3))

	var r1 := RegionRegistry.get_region(r1_id)
	assert_eq(r1.area, 3)
	assert_true(r1.provided_zone_tags.has(&"t1"))
	assert_true(r1.provided_zone_tags.has(&"t2"))


# Row 7: Region #1 with α at (1,1),(1,2); place β at (1,3) → different kind,
# new Region #2 of kind beta; #1 unchanged.
func test_row_7_different_kind_does_not_join() -> void:
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 1))
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 2))
	var r1_id := _region_for_cell(Vector2i(1, 1)).region_id

	var created_ids: Array[int] = []
	var capture := func(rid: int) -> void: created_ids.append(rid)
	RegionRegistry.region_created.connect(capture)

	EntityRegistry.place(ZT_BETA, Vector2i(1, 3))

	assert_eq(created_ids.size(), 1, "beta forms its own region")
	var r2 := RegionRegistry.get_region(created_ids[0])
	assert_eq(r2.kind, &"beta")
	assert_eq(r2.area, 1)
	assert_ne(r2.region_id, r1_id)

	var r1 := RegionRegistry.get_region(r1_id)
	assert_eq(r1.area, 2, "alpha region unchanged")

	RegionRegistry.region_created.disconnect(capture)


# Row 8: Region #1 with α at (1,1)..(1,4) vertical line; remove α at (1,2) →
# split: #1 keeps the larger component (1,3),(1,4); a new region holds (1,1).
func test_row_8_removal_splits_region_keeping_largest() -> void:
	var top := EntityRegistry.place(ZT_ALPHA, Vector2i(1, 1))
	var second := EntityRegistry.place(ZT_ALPHA, Vector2i(1, 2))
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 3))
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 4))
	var r1_id := _region_for_cell(Vector2i(1, 1)).region_id

	var created_ids: Array[int] = []
	var changed_ids: Array[int] = []
	var capture_created := func(rid: int) -> void: created_ids.append(rid)
	var capture_changed := func(rid: int) -> void: changed_ids.append(rid)
	RegionRegistry.region_created.connect(capture_created)
	RegionRegistry.region_changed.connect(capture_changed)

	EntityRegistry.remove(second)

	assert_eq(created_ids.size(), 1, "one new region for the orphan side")
	assert_true(changed_ids.has(r1_id), "#1 changed")

	var kept := RegionRegistry.get_region(r1_id)
	assert_eq(kept.area, 2, "kept side has two tiles")
	assert_true(kept.cells.has(Vector2i(1, 3)))
	assert_true(kept.cells.has(Vector2i(1, 4)))

	var spawned := RegionRegistry.get_region(created_ids[0])
	assert_eq(spawned.area, 1)
	assert_eq(spawned.cells, [Vector2i(1, 1)] as Array[Vector2i])

	assert_eq(EntityRegistry.get_instance(top).instance_id, top, "top tile still placed")

	RegionRegistry.region_created.disconnect(capture_created)
	RegionRegistry.region_changed.disconnect(capture_changed)


# Row 9: same split as row 8, plus a placement Q at (1,3). Q's primary_cell
# (1,3) lies in the kept component, so Q stays in #1.
func test_row_9_split_redistributes_placement_to_primary_cell_component() -> void:
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 1))
	var second := EntityRegistry.place(ZT_ALPHA, Vector2i(1, 2))
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 3))
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 4))
	var r1_id := _region_for_cell(Vector2i(1, 3)).region_id

	# Add Q at (1,3). add_placement is the API; the impl is responsible for
	# stamping primary_cell in placement.state.
	var placement := RegionRegistry.add_placement(r1_id, PL_Q)
	assert_not_null(placement)
	placement.state["primary_cell"] = Vector2i(1, 3)

	var stranded_payloads: Array = []
	var capture := func(rid: int, idx: int) -> void: stranded_payloads.append([rid, idx])
	RegionRegistry.placement_stranded.connect(capture)

	EntityRegistry.remove(second)

	# Q's primary cell stays with the larger component → still in #1.
	var kept := RegionRegistry.get_region(r1_id)
	assert_eq(kept.placements.size(), 1, "Q stays in kept region")
	assert_eq(kept.placements[0].placeable_def_id, PL_Q)
	assert_eq(stranded_payloads.size(), 0,
		"area still >= space_required and t1 still provided → no stranding")

	RegionRegistry.placement_stranded.disconnect(capture)


# Row 10: Region #1 with α' at (1,1) only; placement Q2 (needs t2). Remove the
# tile → region_destroyed for #1; placement_stranded fires *before* destroy.
func test_row_10_last_tile_removal_strands_then_destroys() -> void:
	EntityRegistry.place(ZT_ALPHA_PRIME, Vector2i(1, 1))
	var r1 := _region_for_cell(Vector2i(1, 1))
	var r1_id := r1.region_id

	var placement := RegionRegistry.add_placement(r1_id, PL_Q2)
	assert_not_null(placement, "Q2 placeable should fit (t2 provided by α')")
	placement.state["primary_cell"] = Vector2i(1, 1)

	# Find the tile instance id at (1,1).
	var tile_id: int = 0
	for id in EntityRegistry.get_instances_by_def(ZT_ALPHA_PRIME):
		tile_id = id
		break
	assert_ne(tile_id, 0)

	var order: Array[String] = []
	var capture_strand := func(_rid: int, _idx: int) -> void: order.append("stranded")
	var capture_destroy := func(_rid: int) -> void: order.append("destroyed")
	RegionRegistry.placement_stranded.connect(capture_strand)
	RegionRegistry.region_destroyed.connect(capture_destroy)

	EntityRegistry.remove(tile_id)

	assert_eq(order, ["stranded", "destroyed"] as Array[String],
		"strand must fire before destroy so listeners can react")
	assert_null(RegionRegistry.get_region(r1_id), "region gone")

	RegionRegistry.placement_stranded.disconnect(capture_strand)
	RegionRegistry.region_destroyed.disconnect(capture_destroy)


# Row 11: Region #1 with α at (1,1),(1,2),(1,3) and a Q3 (space_required=3,
# primary_cell=(1,1)). Remove α at (1,2) → split into [(1,1)] and [(1,3)],
# each area 1. Q3 space_required 3 > area 1 → placement_stranded fires; Q3
# stays in its primary cell's component (so it lands with (1,1)).
func test_row_11_split_strands_oversized_placement_in_primary_component() -> void:
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 1))
	var middle := EntityRegistry.place(ZT_ALPHA, Vector2i(1, 2))
	EntityRegistry.place(ZT_ALPHA, Vector2i(1, 3))
	var r1_id := _region_for_cell(Vector2i(1, 1)).region_id

	var placement := RegionRegistry.add_placement(r1_id, PL_Q3)
	assert_not_null(placement)
	placement.state["primary_cell"] = Vector2i(1, 1)

	var stranded_payloads: Array = []
	var capture := func(rid: int, idx: int) -> void: stranded_payloads.append([rid, idx])
	RegionRegistry.placement_stranded.connect(capture)

	EntityRegistry.remove(middle)

	assert_eq(stranded_payloads.size(), 1, "Q3 stranded — area 1 < space_required 3")

	# Q3 ends up wherever its primary cell (1,1) belongs. Whichever region
	# holds cell (1,1) should also hold the placement.
	var host := _region_for_cell(Vector2i(1, 1))
	assert_not_null(host)
	var has_q3 := false
	for p in host.placements:
		if p.placeable_def_id == PL_Q3:
			has_q3 = true
			break
	assert_true(has_q3, "Q3 follows its primary cell (1,1)")

	# The other component must NOT carry the Q3.
	var other := _region_for_cell(Vector2i(1, 3))
	assert_not_null(other)
	assert_ne(other.region_id, host.region_id, "split happened")
	for p in other.placements:
		assert_ne(p.placeable_def_id, PL_Q3,
			"Q3 must only live in primary cell's component")

	RegionRegistry.placement_stranded.disconnect(capture)
