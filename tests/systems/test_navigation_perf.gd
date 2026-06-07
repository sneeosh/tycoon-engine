extends GutTest
# Performance guard for navigation.
# Spec: design/algorithms/navigation.md ("Performance").
#
# Seam-report budget (zoo-tycoon/design/engine_seam_agent_navigation.md §5):
# 60 fps with 100+ agents on a ~200-cell network. We assert that planning is
# bounded and that per-tick incremental stepping of 100 agents stays well
# inside a 16 ms frame.
#
# Thresholds are deliberately generous (CI hardware varies); they still fail
# loudly if a change makes per-agent stepping recompute full routes each tick.

const COLS := 20
const ROWS := 10            # 20 * 10 = 200 cells
const AGENTS := 100
const WARM_FRAMES := 59     # frames measured after the cold-plan frame

var nav: AStarNetworkNavigator
var net: WalkableNetwork


func before_each() -> void:
	nav = AStarNetworkNavigator.new()
	net = WalkableNetwork.new()
	for x in COLS:
		for y in ROWS:
			net.add_cell(Vector2i(x, y), 1.0)


func _make_agents() -> Array[Agent]:
	var agents: Array[Agent] = []
	var goal := Vector2i(COLS - 1, ROWS - 1)
	for i in AGENTS:
		var a := Agent.new()
		# Spread starts across the grid, deterministically.
		a.position = Vector2(i % COLS, (i / COLS) % ROWS)
		a.behavior_state["nav_target"] = goal
		agents.append(a)
	return agents


func _step_all(agents: Array[Agent]) -> void:
	for a in agents:
		var next := nav.step(a, net)
		if next != AStarNetworkNavigator.NO_STEP and net.has_cell(next):
			a.position = Vector2(next)


func test_cold_planning_100_agents_is_bounded() -> void:
	var agents := _make_agents()
	var t0 := Time.get_ticks_usec()
	_step_all(agents)  # first frame: every agent plans its route
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	gut.p("cold-plan frame (100 agents, 200 cells): %.2f ms" % ms)
	assert_lt(ms, 200.0, "planning 100 routes over a 200-cell network must be well bounded")


func test_warm_stepping_holds_frame_budget() -> void:
	var agents := _make_agents()
	_step_all(agents)  # cold plan, not measured

	var t0 := Time.get_ticks_usec()
	for _frame in WARM_FRAMES:
		_step_all(agents)
	var total_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var per_frame := total_ms / WARM_FRAMES
	gut.p("warm stepping: %.2f ms total, %.3f ms/frame for %d agents" % [total_ms, per_frame, AGENTS])
	assert_lt(per_frame, 16.0, "stepping 100 agents must hold a 60 fps frame budget")


func test_agents_actually_advance_toward_goal() -> void:
	# Sanity: the perf loop does real work — an agent near the goal reaches it.
	var a := Agent.new()
	a.position = Vector2(COLS - 3, ROWS - 1)
	a.behavior_state["nav_target"] = Vector2i(COLS - 1, ROWS - 1)
	var arrived := false
	for _frame in 10:
		var next := nav.step(a, net)
		if next == AStarNetworkNavigator.NO_STEP:
			arrived = Vector2i(a.position.round()) == Vector2i(COLS - 1, ROWS - 1)
			break
		a.position = Vector2(next)
	assert_true(arrived, "agent should reach the goal and then report NO_STEP")
