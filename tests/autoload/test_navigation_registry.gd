extends GutTest
# Tests for NavigationRegistry — the reactive WalkableNetwork builder.
# Spec: design/algorithms/navigation.md
#
# Networks are derived from placed walkable EntityInstances, exactly the way
# RegionRegistry derives regions from zone tiles. These tests place/remove
# entities through EntityRegistry and assert the networks track them.

const PATH_DEF := &"nav_path"
const SLOW_DEF := &"nav_slow"
const STAFF_DEF := &"nav_staff"
const WALL_DEF := &"nav_wall"           # non-walkable
const INDOOR_DEF := &"nav_indoor"

var _defs: Array[StringName] = []


func before_each() -> void:
	Ledger.reset(1_000_000)
	EntityRegistry.reset()
	NavigationRegistry.reset()
	_defs.clear()

	_make_def(PATH_DEF, true, 1.0, &"default", [])
	_make_def(SLOW_DEF, true, 4.0, &"default", [])
	_make_def(STAFF_DEF, true, 1.0, &"default", [&"staff_only"])
	_make_def(WALL_DEF, false, 1.0, &"default", [])
	_make_def(INDOOR_DEF, true, 1.0, &"indoor", [])


func after_each() -> void:
	for id in _defs:
		ContentDB.entity_defs.erase(id)


func _make_def(id: StringName, walkable: bool, cost: float, net: StringName, tags: Array[StringName]) -> void:
	var ed := EntityDef.new()
	ed.id = id
	ed.display_name = String(id)
	ed.build_cost = 0
	ed.footprint = Vector2i(1, 1)
	ed.walkable = walkable
	ed.traversal_cost = cost
	ed.network_id = net
	ed.walkable_tags = tags
	ContentDB.entity_defs[id] = ed
	_defs.append(id)


func _place_line(def: StringName, length: int) -> void:
	for x in length:
		EntityRegistry.place(def, Vector2i(x, 0))


# --- Reactive build -------------------------------------------------------

func test_placing_walkable_entity_creates_network_cell() -> void:
	EntityRegistry.place(PATH_DEF, Vector2i(2, 3))
	var net := NavigationRegistry.get_network()
	assert_not_null(net)
	assert_true(net.has_cell(Vector2i(2, 3)))
	assert_eq(net.cell_count(), 1)


func test_non_walkable_entity_adds_no_cells() -> void:
	EntityRegistry.place(WALL_DEF, Vector2i(0, 0))
	var net := NavigationRegistry.get_network()
	# No walkable entity placed → network may not even exist yet.
	assert_true(net == null or net.cell_count() == 0)


func test_removing_entity_drops_its_cells() -> void:
	var iid := EntityRegistry.place(PATH_DEF, Vector2i(0, 0))
	var net := NavigationRegistry.get_network()
	assert_true(net.has_cell(Vector2i(0, 0)))
	EntityRegistry.remove(iid)
	assert_false(net.has_cell(Vector2i(0, 0)))


func test_network_changed_signal_fires_with_dirty_rect() -> void:
	var events: Array = []
	var capture := func(nid: StringName, rect: Rect2i) -> void: events.append([nid, rect])
	NavigationRegistry.network_changed.connect(capture)
	EntityRegistry.place(PATH_DEF, Vector2i(5, 5))
	NavigationRegistry.network_changed.disconnect(capture)

	assert_eq(events.size(), 1)
	assert_eq(events[0][0], &"default")
	assert_eq(events[0][1], Rect2i(Vector2i(5, 5), Vector2i(1, 1)))


func test_multiple_networks_stay_separate() -> void:
	# Distinct grid cells (same cell would be a footprint collision).
	EntityRegistry.place(PATH_DEF, Vector2i(0, 0))
	EntityRegistry.place(INDOOR_DEF, Vector2i(5, 5))
	var outdoor := NavigationRegistry.get_network(&"default")
	var indoor := NavigationRegistry.get_network(&"indoor")
	assert_true(outdoor.has_cell(Vector2i(0, 0)))
	assert_true(indoor.has_cell(Vector2i(5, 5)))
	assert_eq(outdoor.cell_count(), 1)
	assert_eq(indoor.cell_count(), 1)


func test_traversal_cost_from_entity_def() -> void:
	EntityRegistry.place(SLOW_DEF, Vector2i(1, 1))
	var net := NavigationRegistry.get_network()
	assert_eq(net.traversal_cost(Vector2i(1, 1)), 4.0)


func test_zero_cost_def_falls_back_to_tuning_default() -> void:
	if ContentDB.balance_config == null:
		ContentDB.balance_config = BalanceConfig.new()
	var prev := ContentDB.balance_config.nav_default_traversal_cost
	ContentDB.balance_config.nav_default_traversal_cost = 3.0
	_make_def(&"nav_zero", true, 0.0, &"default", [])
	EntityRegistry.place(&"nav_zero", Vector2i(0, 0))
	var net := NavigationRegistry.get_network()
	assert_eq(net.traversal_cost(Vector2i(0, 0)), 3.0, "cost<=0 → tuning default")
	ContentDB.balance_config.nav_default_traversal_cost = prev


# --- Convenience queries --------------------------------------------------

func test_path_convenience_caches_route() -> void:
	_place_line(PATH_DEF, 3)
	var route := NavigationRegistry.path(Vector2i(0, 0), Vector2i(2, 0))
	assert_eq(route, [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)] as Array[Vector2i])
	var key := WalkableNetwork.route_key(Vector2i(0, 0), Vector2i(2, 0))
	assert_true(NavigationRegistry.get_network().has_cached_route(key), "registry caches on the network")


func test_nearest_and_reachable_convenience() -> void:
	_place_line(PATH_DEF, 4)
	var reach := NavigationRegistry.reachable_from(Vector2i(0, 0))
	assert_eq(reach.size(), 4)
	var is_end := func(c: Vector2i) -> bool: return c == Vector2i(3, 0)
	assert_eq(NavigationRegistry.nearest(Vector2i(0, 0), is_end), Vector2i(3, 0))


func test_engagement_distance_uses_tuning_default_when_d_negative() -> void:
	EntityRegistry.place(PATH_DEF, Vector2i(0, 0))
	var d := ContentDB.balance_config.nav_default_engagement_distance if ContentDB.balance_config != null else 10
	var near: Array[Vector2i] = [Vector2i(0, d)]
	var far: Array[Vector2i] = [Vector2i(0, d + 1)]
	assert_true(NavigationRegistry.within_engagement_distance(Vector2i(0, 0), near))
	assert_false(NavigationRegistry.within_engagement_distance(Vector2i(0, 0), far))


func test_rebuild_all_reconstructs_from_registry() -> void:
	_place_line(PATH_DEF, 3)
	NavigationRegistry.reset()
	assert_null(NavigationRegistry.get_network())
	NavigationRegistry.rebuild_all()
	var net := NavigationRegistry.get_network()
	assert_not_null(net)
	assert_eq(net.cell_count(), 3)


# --- IAgentBehavior.decide_next_step default ------------------------------

func test_decide_next_step_default_delegates_to_navigator() -> void:
	_place_line(PATH_DEF, 3)
	var behavior := IAgentBehavior.new()
	var agent := Agent.new()
	agent.position = Vector2(0, 0)
	agent.behavior_state["nav_target"] = Vector2i(2, 0)
	assert_eq(behavior.decide_next_step(agent), Vector2i(1, 0))


func test_decide_next_step_returns_no_step_without_network() -> void:
	var behavior := IAgentBehavior.new()
	var agent := Agent.new()
	agent.behavior_state["nav_target"] = Vector2i(2, 0)
	assert_eq(behavior.decide_next_step(agent), INetworkNavigator.NO_STEP)
