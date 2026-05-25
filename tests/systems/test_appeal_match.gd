extends GutTest
# Tests for EffectResolver.appeal_match — Prompt 7.
# Spec: docs/build-plan.md §7 (Prompt 7), §3 (appeal matching)
#
# Score formula per axis (preferred, tolerance):
#   score = max(0, 1 - |actual - preferred| / tolerance)
# Aggregate: arithmetic mean across axes. Empty preferences → 1.0.

const EPSILON: float = 0.0001


func _agent(preferences: Dictionary) -> AgentType:
	var t := AgentType.new()
	t.id = &"test"
	t.preferences = preferences
	return t


func _entity(profile: Dictionary) -> EntityDef:
	var d := EntityDef.new()
	d.id = &"test"
	d.appeal_profile = profile
	return d


# --- Empty cases ---------------------------------------------------------

func test_no_preferences_returns_one() -> void:
	var t := _agent({})
	var d := _entity({&"thrill": 0.9})
	assert_eq(EffectResolver.appeal_match(t, d), 1.0)


# --- Single-axis cases ---------------------------------------------------

func test_perfect_match_returns_one() -> void:
	var t := _agent({&"thrill": Vector2(0.5, 0.3)})
	var d := _entity({&"thrill": 0.5})
	assert_almost_eq(EffectResolver.appeal_match(t, d), 1.0, EPSILON)


func test_mismatch_within_tolerance_scores_between_zero_and_one() -> void:
	# preferred=0.5, tolerance=0.4, actual=0.7 → diff=0.2, score=1-0.2/0.4=0.5
	var t := _agent({&"thrill": Vector2(0.5, 0.4)})
	var d := _entity({&"thrill": 0.7})
	assert_almost_eq(EffectResolver.appeal_match(t, d), 0.5, EPSILON)


func test_mismatch_beyond_tolerance_clamps_to_zero() -> void:
	# preferred=0.2, tolerance=0.1, actual=0.9 → diff=0.7 ≫ tolerance → 0
	var t := _agent({&"thrill": Vector2(0.2, 0.1)})
	var d := _entity({&"thrill": 0.9})
	assert_eq(EffectResolver.appeal_match(t, d), 0.0)


func test_missing_axis_treated_as_zero() -> void:
	# entity lacks the axis the agent prefers → actual=0
	# preferred=0.6, tolerance=1.0 → diff=0.6, score=0.4
	var t := _agent({&"thrill": Vector2(0.6, 1.0)})
	var d := _entity({})
	assert_almost_eq(EffectResolver.appeal_match(t, d), 0.4, EPSILON)


# --- Multi-axis aggregation ----------------------------------------------

func test_multi_axis_mean() -> void:
	# Axis 1: perfect (1.0). Axis 2: half (0.5). Mean → 0.75.
	var t := _agent({
		&"thrill": Vector2(0.5, 0.4),     # preferred=0.5, tol=0.4
		&"variety": Vector2(0.3, 0.4),    # preferred=0.3, tol=0.4
	})
	var d := _entity({
		&"thrill": 0.5,                    # exact → 1.0
		&"variety": 0.5,                   # diff=0.2, tol=0.4 → 0.5
	})
	assert_almost_eq(EffectResolver.appeal_match(t, d), 0.75, EPSILON)


func test_aligned_preferences_score_higher_than_mismatched() -> void:
	# Build plan calls this out explicitly: aligned should beat mismatched.
	var aligned := _agent({&"thrill": Vector2(0.8, 0.3)})
	var mismatched := _agent({&"thrill": Vector2(0.2, 0.3)})
	var d := _entity({&"thrill": 0.8})
	var a_score := EffectResolver.appeal_match(aligned, d)
	var m_score := EffectResolver.appeal_match(mismatched, d)
	assert_gt(a_score, m_score)
	assert_almost_eq(a_score, 1.0, EPSILON, "aligned → perfect")


# --- Edge case: zero/negative tolerance ----------------------------------

func test_zero_tolerance_only_exact_match_scores_above_zero() -> void:
	# tolerance clamped to a tiny epsilon, so non-exact match → 0
	var t := _agent({&"thrill": Vector2(0.5, 0.0)})
	var d_exact := _entity({&"thrill": 0.5})
	var d_off := _entity({&"thrill": 0.51})
	assert_almost_eq(EffectResolver.appeal_match(t, d_exact), 1.0, EPSILON)
	assert_eq(EffectResolver.appeal_match(t, d_off), 0.0)
