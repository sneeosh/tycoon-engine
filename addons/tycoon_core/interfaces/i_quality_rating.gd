extends RefCounted
class_name IQualityRating
# Spec: docs/build-plan.md §3 (extension points — IQualityRating), Prompt 7.
#
# How the establishment's quality/star rating is computed. Games implement
# this — typically a blend of EntityDef appeal profiles, ConditionModifier
# state, and aggregate agent satisfaction. Generalizes RCT's
# `CourseRatingSystem`.
#
# Duck-typed contract. Engine never implements this; demos and games do.


# Returns the establishment's current quality rating (typical scale: 0.0–5.0,
# but the engine doesn't enforce a range — the game's UI/balance decides).
func compute_rating() -> float:
	return 0.0
