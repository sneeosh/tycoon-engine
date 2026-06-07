extends GutTest
# Tests for agent navigation on a WalkableNetwork.
# Spec: design/algorithms/navigation.md
#
# Each test_row_N_* mirrors one row of the spec's Worked Examples table.
# Drift between the table and the implementation must turn a test red.

var nav: AStarNetworkNavigator


func before_each() -> void:
	nav = AStarNetworkNavigator.new()


# --- Map builders ---------------------------------------------------------

func _corridor(length: int) -> WalkableNetwork:
	var net := WalkableNetwork.new()
	for x in length:
		net.add_cell(Vector2i(x, 0), 1.0)
	return net


# 3x3 block minus the centre (1,1).
func _ring() -> WalkableNetwork:
	var net := WalkableNetwork.new()
	for x in 3:
		for y in 3:
			if Vector2i(x, y) != Vector2i(1, 1):
				net.add_cell(Vector2i(x, y), 1.0)
	return net


# Two rows: (0..2, 0) and (0..2, 1), all cost 1.
func _loop() -> WalkableNetwork:
	var net := WalkableNetwork.new()
	for x in 3:
		net.add_cell(Vector2i(x, 0), 1.0)
		net.add_cell(Vector2i(x, 1), 1.0)
	return net


func _cost(net: WalkableNetwork, route: Array[Vector2i]) -> float:
	var c := 0.0
	for i in range(1, route.size()):
		c += net.traversal_cost(route[i])
	return c


# --- Row 1: simple straight route -----------------------------------------

func test_row_1_simple_straight_route() -> void:
	var net := _corridor(4)
	var route := nav.find_path(net, Vector2i(0, 0), Vector2i(3, 0))
	assert_eq(route, [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)] as Array[Vector2i])
	assert_eq(_cost(net, route), 3.0)


# --- Row 2: blocked / unreachable -----------------------------------------

func test_row_2_unreachable_returns_empty() -> void:
	var net := WalkableNetwork.new()
	net.add_cell(Vector2i(0, 0), 1.0)
	net.add_cell(Vector2i(5, 5), 1.0)
	assert_eq(nav.find_path(net, Vector2i(0, 0), Vector2i(5, 5)), [] as Array[Vector2i])
	# Goal not a network cell at all.
	assert_eq(nav.find_path(net, Vector2i(0, 0), Vector2i(9, 9)), [] as Array[Vector2i])


# --- Row 3: route around an obstacle, deterministic tie-break --------------

func test_row_3_routes_around_gap_tiebreak_left() -> void:
	var net := _ring()
	var route := nav.find_path(net, Vector2i(1, 0), Vector2i(1, 2))
	assert_eq(route,
		[Vector2i(1, 0), Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2), Vector2i(1, 2)] as Array[Vector2i])
	assert_eq(_cost(net, route), 4.0)


# --- Row 4: cost-aware routing --------------------------------------------

func test_row_4_prefers_cheaper_detour() -> void:
	var net := _loop()
	net.add_cell(Vector2i(1, 0), 5.0)  # make the top-middle cell expensive
	var route := nav.find_path(net, Vector2i(0, 0), Vector2i(2, 0))
	assert_eq(route,
		[Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(2, 0)] as Array[Vector2i])
	assert_eq(_cost(net, route), 4.0)


# --- Row 5: agent-tag-restricted route ------------------------------------

func test_row_5_tag_gating_blocks_then_allows() -> void:
	var net := _loop()
	net.add_cell(Vector2i(1, 0), 1.0, [&"staff_only"] as Array[StringName])

	# Public agent (no tags) is forced around the staff-only cell.
	var public_route := nav.find_path(net, Vector2i(0, 0), Vector2i(2, 0))
	assert_eq(public_route,
		[Vector2i(0, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(2, 0)] as Array[Vector2i])
	assert_eq(_cost(net, public_route), 4.0)

	# Staff agent takes the direct route through the gated cell.
	var staff_route := nav.find_path(net, Vector2i(0, 0), Vector2i(2, 0), [&"staff_only"] as Array[StringName])
	assert_eq(staff_route, [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)] as Array[Vector2i])
	assert_eq(_cost(net, staff_route), 2.0)


# --- Row 6: engagement distance (Manhattan) -------------------------------

func test_row_6_engagement_distance_manhattan() -> void:
	var net := WalkableNetwork.new()
	net.add_cell(Vector2i(3, 3), 1.0)
	var anchors: Array[Vector2i] = [Vector2i(3, 8)]
	assert_true(net.within_engagement_distance(Vector2i(3, 3), anchors, 10))
	assert_false(net.within_engagement_distance(Vector2i(3, 3), anchors, 4))
	var multi: Array[Vector2i] = [Vector2i(20, 20), Vector2i(3, 6)]
	assert_true(net.within_engagement_distance(Vector2i(3, 3), multi, 3))


# --- Row 7: reachable_from / nearest --------------------------------------

func test_row_7_reachable_and_nearest() -> void:
	var net := _ring()
	var reach := nav.reachable_from(net, Vector2i(0, 0))
	assert_eq(reach.size(), 8, "all 8 ring cells reachable")
	assert_true(reach.has(Vector2i(2, 2)))

	var goals := {Vector2i(2, 0): true, Vector2i(2, 2): true}
	var is_goal := func(c: Vector2i) -> bool: return goals.has(c)
	assert_eq(nav.nearest(net, Vector2i(0, 0), is_goal), Vector2i(2, 0),
		"(2,0) at 2 hops beats (2,2) at 4")


# --- Row 8: route invalidation on mutation --------------------------------

func test_row_8_cache_invalidated_by_mutation() -> void:
	var net := _corridor(3)
	var key := WalkableNetwork.route_key(Vector2i(0, 0), Vector2i(2, 0))
	var route := nav.find_path(net, Vector2i(0, 0), Vector2i(2, 0))
	net.cache_route(key, route)
	assert_true(net.has_cached_route(key))

	# Mutating the network clears the cache and breaks the route.
	net.remove_cell(Vector2i(1, 0))
	assert_false(net.has_cached_route(key), "mutation must clear the route cache")
	assert_eq(nav.find_path(net, Vector2i(0, 0), Vector2i(2, 0)), [] as Array[Vector2i])

	# Re-adding restores the route.
	net.add_cell(Vector2i(1, 0), 1.0)
	assert_eq(nav.find_path(net, Vector2i(0, 0), Vector2i(2, 0)),
		[Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)] as Array[Vector2i])


# --- Row 9: incremental stepping ------------------------------------------

func test_row_9_step_walks_route_then_stops() -> void:
	var net := _corridor(3)
	var agent := Agent.new()
	agent.position = Vector2(0, 0)
	agent.behavior_state["nav_target"] = Vector2i(2, 0)

	assert_eq(nav.step(agent, net), Vector2i(1, 0))
	agent.position = Vector2(1, 0)
	assert_eq(nav.step(agent, net), Vector2i(2, 0))
	agent.position = Vector2(2, 0)
	assert_eq(nav.step(agent, net), AStarNetworkNavigator.NO_STEP, "arrived → NO_STEP")


# --- Supporting behavior (not spec rows) ----------------------------------

func test_same_cell_path_is_single_cell() -> void:
	var net := _corridor(3)
	assert_eq(nav.find_path(net, Vector2i(1, 0), Vector2i(1, 0)), [Vector2i(1, 0)] as Array[Vector2i])


func test_fail_soft_budget_returns_empty() -> void:
	# A long corridor with a budget too small to reach the goal must fail
	# soft (empty), not stall.
	var net := _corridor(50)
	var bounded := nav.find_path(net, Vector2i(0, 0), Vector2i(49, 0), [], 3)
	assert_eq(bounded, [] as Array[Vector2i], "budget exhausted → empty")
	# Unbounded still finds it.
	assert_eq(nav.find_path(net, Vector2i(0, 0), Vector2i(49, 0)).size(), 50)


func test_engagement_distance_network_metric() -> void:
	# A bent corridor: (0,0)-(1,0)-(2,0)-(2,1)-(2,2). Manhattan from (0,0) to
	# anchor (2,2) is 4, but the graph distance is 4 hops too here; test a
	# case where the wall matters is covered structurally — assert the
	# network metric agrees on a reachable anchor and rejects a far one.
	var net := WalkableNetwork.new()
	for c in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(2, 1), Vector2i(2, 2)]:
		net.add_cell(c, 1.0)
	var anchor: Array[Vector2i] = [Vector2i(2, 2)]
	assert_true(net.within_engagement_distance(Vector2i(0, 0), anchor, 4, WalkableNetwork.Metric.NETWORK))
	assert_false(net.within_engagement_distance(Vector2i(0, 0), anchor, 3, WalkableNetwork.Metric.NETWORK))


func test_score_goals_sorts_by_cost_reachable_first() -> void:
	var net := _corridor(4)
	var agent := Agent.new()
	agent.position = Vector2(0, 0)
	var scored := nav.score_goals(agent, net,
		[Vector2i(3, 0), Vector2i(2, 0), Vector2i(9, 9)] as Array[Vector2i])
	assert_eq(scored.size(), 3)
	assert_eq(scored[0]["cell"], Vector2i(2, 0), "cheapest reachable first")
	assert_eq(scored[1]["cell"], Vector2i(3, 0))
	assert_false(scored[2]["reachable"], "unreachable goal sorts last")
