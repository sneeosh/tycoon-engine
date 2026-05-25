extends GutTest
# Worked examples from design/algorithms/spawn-curve.md, mirrored 1:1.
# CLAUDE.md §3b requires this: every worked example becomes a test, so code
# drift from the documented formula fails the build.

const EPSILON: float = 0.005


# Tuning for every example in this file. Must match the spec's table and
# the defaults in design/tuning/balance.md.
func before_each() -> void:
	# Force the BalanceConfig to the spec's tuning so this test is hermetic
	# even if someone changes design/tuning/balance.md.
	var bc := BalanceConfig.new()
	bc.spawn_curve_min_multiplier = 0.25
	bc.spawn_curve_max_multiplier = 3.0
	bc.spawn_curve_midpoint = 0.5
	bc.spawn_curve_steepness = 6.0
	ContentDB.balance_config = bc


# spec table row #1 — satisfaction 0.00 → 0.380
func test_spawn_curve_example_1_satisfaction_zero() -> void:
	assert_almost_eq(AgentPool.spawn_curve(0.0), 0.380, EPSILON)


# spec table row #2 — satisfaction 0.25 → 0.752
func test_spawn_curve_example_2_quarter() -> void:
	assert_almost_eq(AgentPool.spawn_curve(0.25), 0.752, EPSILON)


# spec table row #3 — satisfaction 0.50 → 1.625 (exact midpoint)
func test_spawn_curve_example_3_midpoint() -> void:
	assert_almost_eq(AgentPool.spawn_curve(0.5), 1.625, EPSILON)


# spec table row #4 — satisfaction 0.75 → 2.498
func test_spawn_curve_example_4_three_quarters() -> void:
	assert_almost_eq(AgentPool.spawn_curve(0.75), 2.498, EPSILON)


# spec table row #5 — satisfaction 1.00 → 2.870
func test_spawn_curve_example_5_satisfaction_one() -> void:
	assert_almost_eq(AgentPool.spawn_curve(1.0), 2.870, EPSILON)


# Off-spec but worth asserting: input is clamped to [0, 1].
func test_spawn_curve_clamps_below_zero() -> void:
	assert_almost_eq(AgentPool.spawn_curve(-1.0), AgentPool.spawn_curve(0.0), EPSILON)


func test_spawn_curve_clamps_above_one() -> void:
	assert_almost_eq(AgentPool.spawn_curve(2.0), AgentPool.spawn_curve(1.0), EPSILON)
