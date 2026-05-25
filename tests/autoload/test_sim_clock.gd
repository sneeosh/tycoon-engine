extends GutTest
# Tests for SimClock — Prompt 1.
# Spec: docs/build-plan.md §7 (Prompt 1)


func before_each() -> void:
	# Reset SimClock state. ticks_per_day kept small so day rollover is testable.
	SimClock.current_tick = 0
	SimClock.current_day = 0
	SimClock.current_period = 0
	SimClock.ticks_per_day = 5
	SimClock.days_per_period = 2
	SimClock.speed = 1.0
	SimClock._accumulator = 0.0


func test_advance_tick_increments_counter_and_emits() -> void:
	# GDScript lambdas can read outer locals but reassignments inside the
	# lambda don't propagate — so we use a mutable container.
	var captured: Array[int] = []
	var capture := func(t: int) -> void: captured.append(t)
	EventBus.tick.connect(capture)
	SimClock.advance_tick()
	SimClock.advance_tick()
	assert_eq(SimClock.current_tick, 2, "two manual ticks → counter at 2")
	assert_eq(captured.size(), 2, "tick signal fires once per advance")
	assert_eq(captured, [1, 2], "tick signal payload is the new current_tick")
	EventBus.tick.disconnect(capture)


func test_day_rollover_emits_day_ended() -> void:
	var days: Array[int] = []
	var capture := func(d: int) -> void: days.append(d)
	EventBus.day_ended.connect(capture)
	for i in range(5):
		SimClock.advance_tick()
	assert_eq(SimClock.current_day, 1, "5 ticks at ticks_per_day=5 → day 1")
	assert_eq(days, [1] as Array[int], "day_ended fires exactly once on rollover")
	EventBus.day_ended.disconnect(capture)


func test_period_rollover_emits_period_ended() -> void:
	# ticks_per_day=5, days_per_period=2 → period boundary at tick 10
	var periods: Array[int] = []
	var capture := func(p: int) -> void: periods.append(p)
	EventBus.period_ended.connect(capture)
	for i in range(10):
		SimClock.advance_tick()
	assert_eq(SimClock.current_period, 1, "10 ticks → period 1")
	assert_eq(periods, [1] as Array[int], "period_ended fires exactly once on rollover")
	EventBus.period_ended.disconnect(capture)


func test_pause_blocks_process_advancement() -> void:
	SimClock.pause()
	assert_true(SimClock.is_paused())
	SimClock._process(1.0)
	assert_eq(SimClock.current_tick, 0, "paused clock does not advance via _process")


func test_play_resumes_process_advancement() -> void:
	SimClock.pause()
	SimClock.play()
	assert_false(SimClock.is_paused())
	# 1 second at speed 1.0 with a 20 Hz interval → 20 ticks.
	SimClock._process(1.0)
	assert_eq(SimClock.current_tick, 20)


func test_set_speed_multiplies_tick_rate() -> void:
	SimClock.set_speed(4.0)
	SimClock._process(1.0)
	# 1 second at speed 4.0 with a 20 Hz interval → 80 ticks.
	assert_eq(SimClock.current_tick, 80)


func test_set_speed_clamps_negative_to_zero() -> void:
	SimClock.set_speed(-2.0)
	assert_eq(SimClock.speed, 0.0)
	assert_true(SimClock.is_paused())


func test_manual_advance_works_even_when_paused() -> void:
	# advance_tick() is the deterministic entry point for tests and scripted
	# advancement; pause only gates _process, not the direct call.
	SimClock.pause()
	SimClock.advance_tick()
	assert_eq(SimClock.current_tick, 1)


func test_configure_overrides_defaults() -> void:
	SimClock.configure(100, 30)
	assert_eq(SimClock.ticks_per_day, 100)
	assert_eq(SimClock.days_per_period, 30)
