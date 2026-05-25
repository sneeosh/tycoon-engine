extends GutTest
# Tests for content Resource schemas — Prompt 3.
# Spec: docs/build-plan.md §7 (Prompt 3)
#
# Each schema gets two tests: (1) construction with sane defaults, and
# (2) round-trip save/load via .tres. The round-trip catches export-hint
# mistakes that pure construction tests miss — if the @export type is wrong,
# the loaded value won't match the saved value.

const TMP_DIR := "user://test_schemas/"


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))


func _roundtrip(res: Resource, name: String) -> Resource:
	var path := TMP_DIR + name + ".tres"
	var err := ResourceSaver.save(res, path)
	assert_eq(err, OK, "ResourceSaver.save(%s) returned err=%d" % [name, err])
	# take_over_path forces a fresh load instead of returning the cached instance.
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)


# --- Effect ----------------------------------------------------------------

func test_effect_defaults() -> void:
	var e := Effect.new()
	assert_eq(e.target, Effect.TARGET_REVENUE)
	assert_eq(e.operation, Effect.OP_ADD)
	assert_eq(e.magnitude, 0.0)
	assert_eq(e.proximity, 0.0)
	assert_eq(e.conditions, [] as Array[StringName])


func test_effect_roundtrip() -> void:
	var e := Effect.new()
	e.id = &"pro_shop_proximity"
	e.target = Effect.TARGET_REVENUE
	e.operation = Effect.OP_ADD
	e.magnitude = 15.0
	e.proximity = 4.0
	e.conditions = [&"daylight"] as Array[StringName]
	var loaded := _roundtrip(e, "effect") as Effect
	assert_eq(loaded.id, &"pro_shop_proximity")
	assert_eq(loaded.magnitude, 15.0)
	assert_eq(loaded.proximity, 4.0)
	assert_eq(loaded.conditions, [&"daylight"] as Array[StringName])


# --- Need + NeedSpec -------------------------------------------------------

func test_need_defaults() -> void:
	var n := Need.new()
	assert_eq(n.id, &"")
	assert_eq(n.base_decay_per_tick, 0.01)
	assert_null(n.penalty_curve)


func test_need_roundtrip_with_curve() -> void:
	var n := Need.new()
	n.id = &"hunger"
	n.display_name = "Hunger"
	n.base_decay_per_tick = 0.005
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.0))
	curve.add_point(Vector2(1.0, 1.0))
	n.penalty_curve = curve
	var loaded := _roundtrip(n, "need") as Need
	assert_eq(loaded.id, &"hunger")
	assert_eq(loaded.base_decay_per_tick, 0.005)
	assert_not_null(loaded.penalty_curve, "Curve should survive round-trip")


func test_need_spec_defaults() -> void:
	var ns := NeedSpec.new()
	assert_eq(ns.initial_level, 1.0)
	assert_eq(ns.decay_rate_multiplier, 1.0)
	assert_eq(ns.threshold, 0.3)
	assert_null(ns.need)


func test_need_spec_roundtrip_with_need_ref() -> void:
	var n := Need.new()
	n.id = &"thirst"
	ResourceSaver.save(n, TMP_DIR + "need_for_spec.tres")
	var ns := NeedSpec.new()
	ns.need = ResourceLoader.load(TMP_DIR + "need_for_spec.tres")
	ns.threshold = 0.5
	var loaded := _roundtrip(ns, "need_spec") as NeedSpec
	assert_eq(loaded.threshold, 0.5)
	assert_not_null(loaded.need, "Need ref should round-trip")
	assert_eq(loaded.need.id, &"thirst")


# --- UpgradeTier -----------------------------------------------------------

func test_upgrade_tier_defaults() -> void:
	var u := UpgradeTier.new()
	assert_eq(u.cost, 0)
	assert_eq(u.added_effects.size(), 0)


func test_upgrade_tier_roundtrip_with_effects() -> void:
	var e := Effect.new()
	e.id = &"tier1_revenue"
	e.target = Effect.TARGET_REVENUE
	e.magnitude = 10.0
	var u := UpgradeTier.new()
	u.label = "Tier 1"
	u.cost = 500
	u.new_sprite_key = &"shop_tier_1"
	u.added_effects = [e]
	var loaded := _roundtrip(u, "upgrade_tier") as UpgradeTier
	assert_eq(loaded.cost, 500)
	assert_eq(loaded.added_effects.size(), 1)
	assert_eq(loaded.added_effects[0].magnitude, 10.0)


# --- EntityDef -------------------------------------------------------------

func test_entity_def_defaults() -> void:
	var ed := EntityDef.new()
	assert_eq(ed.build_cost, 0)
	assert_eq(ed.footprint, Vector2i(1, 1))
	assert_eq(ed.satisfies.size(), 0)
	assert_eq(ed.effects.size(), 0)


func test_entity_def_roundtrip_full() -> void:
	var e := Effect.new()
	e.id = &"food_revenue"
	e.target = Effect.TARGET_REVENUE
	e.magnitude = 5.0
	var u := UpgradeTier.new()
	u.label = "Deluxe"
	u.cost = 250
	var ed := EntityDef.new()
	ed.id = &"food_stand"
	ed.display_name = "Food Stand"
	ed.build_cost = 300
	ed.maintenance_cost = 5
	ed.footprint = Vector2i(2, 2)
	ed.sprite_key = &"food_stand_basic"
	ed.satisfies = [&"hunger"] as Array[StringName]
	ed.appeal_profile = {&"variety": 0.6, &"price": 0.3}
	ed.effects = [e]
	ed.upgrade_chain = [u]
	var loaded := _roundtrip(ed, "entity_def") as EntityDef
	assert_eq(loaded.id, &"food_stand")
	assert_eq(loaded.build_cost, 300)
	assert_eq(loaded.footprint, Vector2i(2, 2))
	assert_eq(loaded.satisfies, [&"hunger"] as Array[StringName])
	assert_eq(loaded.appeal_profile.get(&"variety"), 0.6)
	assert_eq(loaded.effects.size(), 1)
	assert_eq(loaded.effects[0].magnitude, 5.0)
	assert_eq(loaded.upgrade_chain.size(), 1)
	assert_eq(loaded.upgrade_chain[0].cost, 250)


# --- AgentType -------------------------------------------------------------

func test_agent_type_defaults() -> void:
	var at := AgentType.new()
	assert_eq(at.spawn_weight, 1.0)
	assert_eq(at.needs.size(), 0)
	assert_null(at.behavior_script)


func test_agent_type_roundtrip() -> void:
	var n := Need.new()
	n.id = &"hunger"
	var ns := NeedSpec.new()
	ns.need = n
	ns.threshold = 0.4
	var at := AgentType.new()
	at.id = &"visitor"
	at.display_name = "Visitor"
	at.spawn_weight = 2.5
	at.trait_ranges = {&"patience": Vector2(0.3, 0.9)}
	at.preferences = {&"variety": Vector2(0.7, 0.2)}
	at.needs = [ns]
	var loaded := _roundtrip(at, "agent_type") as AgentType
	assert_eq(loaded.id, &"visitor")
	assert_eq(loaded.spawn_weight, 2.5)
	assert_eq(loaded.trait_ranges.get(&"patience"), Vector2(0.3, 0.9))
	assert_eq(loaded.preferences.get(&"variety"), Vector2(0.7, 0.2))
	assert_eq(loaded.needs.size(), 1)
	assert_eq(loaded.needs[0].threshold, 0.4)


# --- UnlockNode ------------------------------------------------------------

func test_unlock_node_defaults() -> void:
	var un := UnlockNode.new()
	assert_eq(un.cost, 0)
	assert_eq(un.reputation_required, 0)
	assert_eq(un.prerequisites.size(), 0)


func test_unlock_node_roundtrip() -> void:
	var un := UnlockNode.new()
	un.id = &"tier_2_buildings"
	un.label = "Tier 2 Buildings"
	un.prerequisites = [&"tier_1_buildings"] as Array[StringName]
	un.cost = 2000
	un.reputation_required = 50
	un.unlocks = [&"deluxe_stand", &"premium_seating"] as Array[StringName]
	var loaded := _roundtrip(un, "unlock_node") as UnlockNode
	assert_eq(loaded.id, &"tier_2_buildings")
	assert_eq(loaded.cost, 2000)
	assert_eq(loaded.prerequisites, [&"tier_1_buildings"] as Array[StringName])
	assert_eq(loaded.unlocks.size(), 2)


# --- ConditionModifier -----------------------------------------------------

func test_condition_modifier_defaults() -> void:
	var c := ConditionModifier.new()
	assert_eq(c.active, false)
	assert_eq(c.effects.size(), 0)


func test_condition_modifier_roundtrip() -> void:
	var e := Effect.new()
	e.target = Effect.TARGET_SATISFACTION
	e.operation = Effect.OP_ADD
	e.magnitude = -0.1
	var c := ConditionModifier.new()
	c.id = &"rain"
	c.label = "Rain"
	c.active = true
	c.effects = [e]
	var loaded := _roundtrip(c, "condition_modifier") as ConditionModifier
	assert_eq(loaded.id, &"rain")
	assert_eq(loaded.active, true)
	assert_eq(loaded.effects.size(), 1)
	assert_eq(loaded.effects[0].magnitude, -0.1)


# --- BalanceConfig ---------------------------------------------------------

func test_balance_config_defaults_mirror_tuning_md() -> void:
	# These defaults must match design/tuning/balance.md exactly. If you change
	# one, change the other.
	var b := BalanceConfig.new()
	assert_eq(b.ticks_per_day, 480)
	assert_eq(b.days_per_period, 7)
	assert_eq(b.spawn_curve_min_multiplier, 0.25)
	assert_eq(b.spawn_curve_max_multiplier, 3.0)
	assert_eq(b.spawn_curve_midpoint, 0.5)
	assert_eq(b.spawn_curve_steepness, 6.0)
	assert_eq(b.starting_cash, 1000)


func test_balance_config_roundtrip() -> void:
	var b := BalanceConfig.new()
	b.ticks_per_day = 240
	b.spawn_curve_steepness = 8.0
	b.starting_cash = 2500
	var loaded := _roundtrip(b, "balance_config") as BalanceConfig
	assert_eq(loaded.ticks_per_day, 240)
	assert_eq(loaded.spawn_curve_steepness, 8.0)
	assert_eq(loaded.starting_cash, 2500)
