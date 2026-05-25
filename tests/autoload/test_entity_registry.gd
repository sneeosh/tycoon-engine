extends GutTest
# Tests for EntityRegistry — Prompt 5.
# Spec: docs/build-plan.md §7 (Prompt 5)
#
# Tests inject custom EntityDefs into ContentDB rather than relying on the
# shipped tuning, so cost/footprint scenarios stay independent of balance
# changes elsewhere.

const TEST_SMALL := &"test_small"
const TEST_BIG := &"test_big"
const TEST_UPGRADABLE := &"test_upgradable"


func before_each() -> void:
	EntityRegistry.reset()
	EntityRegistry.configure(0.5)
	Ledger.reset(1000)

	# 1x1, cheap
	var small := EntityDef.new()
	small.id = TEST_SMALL
	small.display_name = "Small"
	small.build_cost = 100
	small.footprint = Vector2i(1, 1)
	ContentDB.entity_defs[TEST_SMALL] = small

	# 2x2, more expensive
	var big := EntityDef.new()
	big.id = TEST_BIG
	big.display_name = "Big"
	big.build_cost = 300
	big.footprint = Vector2i(2, 2)
	ContentDB.entity_defs[TEST_BIG] = big

	# 1x1 with two upgrade tiers
	var up := EntityDef.new()
	up.id = TEST_UPGRADABLE
	up.display_name = "Upgradable"
	up.build_cost = 100
	up.footprint = Vector2i(1, 1)
	var t1 := UpgradeTier.new()
	t1.label = "T1"
	t1.cost = 50
	var t2 := UpgradeTier.new()
	t2.label = "T2"
	t2.cost = 200
	up.upgrade_chain = [t1, t2]
	ContentDB.entity_defs[TEST_UPGRADABLE] = up


func after_each() -> void:
	ContentDB.entity_defs.erase(TEST_SMALL)
	ContentDB.entity_defs.erase(TEST_BIG)
	ContentDB.entity_defs.erase(TEST_UPGRADABLE)


# --- place ----------------------------------------------------------------

func test_place_returns_instance_id_and_records_instance() -> void:
	var id := EntityRegistry.place(TEST_SMALL, Vector2i(0, 0))
	assert_ne(id, 0)
	var inst := EntityRegistry.get_instance(id)
	assert_not_null(inst)
	assert_eq(inst.entity_def_id, TEST_SMALL)
	assert_eq(inst.position, Vector2i(0, 0))
	assert_eq(inst.upgrade_tier, 0)


func test_place_deducts_build_cost_from_ledger() -> void:
	var pre := Ledger.get_balance()
	EntityRegistry.place(TEST_SMALL, Vector2i(0, 0))
	assert_eq(Ledger.get_balance(), pre - 100)


func test_place_unknown_def_returns_zero() -> void:
	var id := EntityRegistry.place(&"does_not_exist", Vector2i(0, 0))
	assert_eq(id, 0)


func test_place_insufficient_funds_returns_zero() -> void:
	Ledger.reset(50)
	var id := EntityRegistry.place(TEST_SMALL, Vector2i(0, 0))
	assert_eq(id, 0, "build_cost=100 with balance=50 should fail")
	assert_eq(Ledger.get_balance(), 50, "balance untouched on failed placement")


func test_place_collision_with_existing_returns_zero() -> void:
	EntityRegistry.place(TEST_BIG, Vector2i(0, 0))  # claims (0,0)..(1,1)
	var id := EntityRegistry.place(TEST_SMALL, Vector2i(1, 1))  # overlaps
	assert_eq(id, 0)


func test_place_adjacent_no_collision() -> void:
	EntityRegistry.place(TEST_BIG, Vector2i(0, 0))  # (0,0)..(1,1)
	var id := EntityRegistry.place(TEST_SMALL, Vector2i(2, 0))  # (2,0) — clear
	assert_ne(id, 0)


func test_place_emits_entity_placed_signal() -> void:
	var captured: Array[int] = []
	var capture := func(id: int) -> void: captured.append(id)
	EventBus.entity_placed.connect(capture)
	var id := EntityRegistry.place(TEST_SMALL, Vector2i(5, 5))
	assert_eq(captured, [id] as Array[int])
	EventBus.entity_placed.disconnect(capture)


# --- remove ---------------------------------------------------------------

func test_remove_refunds_half_of_invested() -> void:
	var id := EntityRegistry.place(TEST_SMALL, Vector2i(0, 0))  # -100
	var balance_after_build := Ledger.get_balance()
	var ok := EntityRegistry.remove(id)
	assert_true(ok)
	# refund_fraction = 0.5, total_invested = 100 → refund 50
	assert_eq(Ledger.get_balance(), balance_after_build + 50)


func test_remove_includes_upgrade_costs_in_refund() -> void:
	var id := EntityRegistry.place(TEST_UPGRADABLE, Vector2i(0, 0))  # -100
	EntityRegistry.upgrade(id)  # -50 (tier 1)
	var balance_pre_remove := Ledger.get_balance()
	EntityRegistry.remove(id)
	# invested = 100 + 50 = 150, refund 0.5 = 75
	assert_eq(Ledger.get_balance(), balance_pre_remove + 75)


func test_remove_frees_cells_so_replace_works() -> void:
	var id := EntityRegistry.place(TEST_SMALL, Vector2i(3, 3))
	EntityRegistry.remove(id)
	var new_id := EntityRegistry.place(TEST_SMALL, Vector2i(3, 3))
	assert_ne(new_id, 0)
	assert_ne(new_id, id, "fresh id, not reused yet")


func test_remove_unknown_id_returns_false() -> void:
	assert_false(EntityRegistry.remove(999))


func test_remove_emits_entity_removed_signal() -> void:
	var captured: Array[int] = []
	var capture := func(id: int) -> void: captured.append(id)
	EventBus.entity_removed.connect(capture)
	var id := EntityRegistry.place(TEST_SMALL, Vector2i(0, 0))
	EntityRegistry.remove(id)
	assert_eq(captured, [id] as Array[int])
	EventBus.entity_removed.disconnect(capture)


# --- upgrade --------------------------------------------------------------

func test_upgrade_advances_tier_and_charges_cost() -> void:
	var id := EntityRegistry.place(TEST_UPGRADABLE, Vector2i(0, 0))  # -100
	var balance := Ledger.get_balance()
	var ok := EntityRegistry.upgrade(id)
	assert_true(ok)
	var inst := EntityRegistry.get_instance(id)
	assert_eq(inst.upgrade_tier, 1)
	assert_eq(Ledger.get_balance(), balance - 50)


func test_upgrade_chain_completes_then_fails() -> void:
	var id := EntityRegistry.place(TEST_UPGRADABLE, Vector2i(0, 0))
	assert_true(EntityRegistry.upgrade(id))  # 0 → 1, costs 50
	assert_true(EntityRegistry.upgrade(id))  # 1 → 2, costs 200
	assert_false(EntityRegistry.upgrade(id), "no more tiers")
	var inst := EntityRegistry.get_instance(id)
	assert_eq(inst.upgrade_tier, 2)


func test_upgrade_fails_when_insufficient_funds() -> void:
	var id := EntityRegistry.place(TEST_UPGRADABLE, Vector2i(0, 0))  # -100, leaves 900
	# T2 costs 200; spend down to fail tier 2
	EntityRegistry.upgrade(id)  # 0 → 1, -50, leaves 850
	Ledger.reset(50)  # force shortage
	assert_false(EntityRegistry.upgrade(id))


func test_upgrade_emits_entity_upgraded_signal_with_tier() -> void:
	var captured: Array[Array] = []
	var capture := func(id: int, tier: int) -> void: captured.append([id, tier])
	EventBus.entity_upgraded.connect(capture)
	var id := EntityRegistry.place(TEST_UPGRADABLE, Vector2i(0, 0))
	EntityRegistry.upgrade(id)
	EntityRegistry.upgrade(id)
	assert_eq(captured.size(), 2)
	assert_eq(captured[0], [id, 1])
	assert_eq(captured[1], [id, 2])
	EventBus.entity_upgraded.disconnect(capture)


# --- Queries --------------------------------------------------------------

func test_get_instances_by_def_returns_matching_ids() -> void:
	var a := EntityRegistry.place(TEST_SMALL, Vector2i(0, 0))
	var b := EntityRegistry.place(TEST_SMALL, Vector2i(2, 0))
	EntityRegistry.place(TEST_BIG, Vector2i(4, 0))
	var ids := EntityRegistry.get_instances_by_def(TEST_SMALL)
	assert_eq(ids.size(), 2)
	assert_true(ids.has(a))
	assert_true(ids.has(b))


func test_get_instances_by_def_excludes_removed() -> void:
	var a := EntityRegistry.place(TEST_SMALL, Vector2i(0, 0))
	var b := EntityRegistry.place(TEST_SMALL, Vector2i(2, 0))
	EntityRegistry.remove(a)
	var ids := EntityRegistry.get_instances_by_def(TEST_SMALL)
	assert_eq(ids, [b] as Array[int])


func test_get_instances_in_radius_includes_close_excludes_far() -> void:
	# Small entity at (5,5) → center (5.5, 5.5)
	var near_id := EntityRegistry.place(TEST_SMALL, Vector2i(5, 5))
	# Small entity at (20, 20) → center (20.5, 20.5)
	EntityRegistry.place(TEST_SMALL, Vector2i(20, 20))
	var ids := EntityRegistry.get_instances_in_radius(Vector2(5.5, 5.5), 3.0)
	assert_eq(ids, [near_id] as Array[int])


func test_get_instances_in_radius_includes_zero_distance() -> void:
	var id := EntityRegistry.place(TEST_SMALL, Vector2i(0, 0))
	# Center of 1x1 at (0,0) is (0.5, 0.5). Query at same point with tiny
	# radius should still include it.
	var ids := EntityRegistry.get_instances_in_radius(Vector2(0.5, 0.5), 0.1)
	assert_eq(ids, [id] as Array[int])


# --- EntityInstance helpers -----------------------------------------------

func test_instance_active_effects_includes_upgrade_added_effects() -> void:
	var def: EntityDef = ContentDB.get_entity_def(TEST_UPGRADABLE)
	var base_eff := Effect.new()
	base_eff.id = &"base"
	base_eff.magnitude = 1.0
	def.effects = [base_eff]
	var t1_eff := Effect.new()
	t1_eff.id = &"t1"
	t1_eff.magnitude = 2.0
	(def.upgrade_chain[0] as UpgradeTier).added_effects = [t1_eff]

	var id := EntityRegistry.place(TEST_UPGRADABLE, Vector2i(0, 0))
	var inst := EntityRegistry.get_instance(id)
	assert_eq(inst.get_active_effects().size(), 1, "tier 0 → only base effect")
	EntityRegistry.upgrade(id)
	assert_eq(inst.get_active_effects().size(), 2, "tier 1 → base + tier 1 added")


func test_instance_current_sprite_key_follows_upgrade_tier() -> void:
	var def: EntityDef = ContentDB.get_entity_def(TEST_UPGRADABLE)
	def.sprite_key = &"base_sprite"
	(def.upgrade_chain[0] as UpgradeTier).new_sprite_key = &"t1_sprite"

	var id := EntityRegistry.place(TEST_UPGRADABLE, Vector2i(0, 0))
	var inst := EntityRegistry.get_instance(id)
	assert_eq(inst.get_current_sprite_key(), &"base_sprite")
	EntityRegistry.upgrade(id)
	assert_eq(inst.get_current_sprite_key(), &"t1_sprite")


# --- v0.3.0: maintenance auto-registration -------------------------------

const TEST_MAINT := &"test_maint_def"


func _make_maint_def(cost: int) -> void:
	var def := EntityDef.new()
	def.id = TEST_MAINT
	def.display_name = "Maint Test"
	def.build_cost = 10
	def.maintenance_cost = cost
	def.footprint = Vector2i(1, 1)
	ContentDB.entity_defs[TEST_MAINT] = def


func test_place_with_maintenance_registers_per_instance_rule() -> void:
	_make_maint_def(7)
	var iid := EntityRegistry.place(TEST_MAINT, Vector2i(0, 0))
	var rule_id := StringName("maint_%d" % iid)
	assert_true(Ledger.recurring_rules.has(rule_id))
	var rule: Dictionary = Ledger.recurring_rules[rule_id]
	assert_eq(rule["amount"], 7)
	assert_eq(rule["kind"], Ledger.KIND_EXPENSE)
	ContentDB.entity_defs.erase(TEST_MAINT)


func test_place_with_zero_maintenance_registers_no_rule() -> void:
	_make_maint_def(0)
	var iid := EntityRegistry.place(TEST_MAINT, Vector2i(0, 0))
	var rule_id := StringName("maint_%d" % iid)
	assert_false(Ledger.recurring_rules.has(rule_id))
	ContentDB.entity_defs.erase(TEST_MAINT)


func test_remove_unregisters_maintenance_rule() -> void:
	_make_maint_def(5)
	var iid := EntityRegistry.place(TEST_MAINT, Vector2i(0, 0))
	var rule_id := StringName("maint_%d" % iid)
	assert_true(Ledger.recurring_rules.has(rule_id))
	EntityRegistry.remove(iid)
	assert_false(Ledger.recurring_rules.has(rule_id))
	ContentDB.entity_defs.erase(TEST_MAINT)


func test_maintenance_deducted_at_day_end() -> void:
	_make_maint_def(12)
	var pre := Ledger.get_balance()
	EntityRegistry.place(TEST_MAINT, Vector2i(0, 0))
	# place() also posts the build_cost expense.
	assert_eq(Ledger.get_balance(), pre - 10, "build_cost deducted")
	# Roll a full day.
	for i in range(SimClock.ticks_per_day):
		SimClock.advance_tick()
	assert_eq(Ledger.get_balance(), pre - 10 - 12, "maintenance recurring deducted on day end")
	ContentDB.entity_defs.erase(TEST_MAINT)
