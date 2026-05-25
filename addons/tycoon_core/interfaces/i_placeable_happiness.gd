extends RefCounted
class_name IPlaceableHappiness
# Spec: design/algorithms/zone_pattern.md (extension points §)
#
# Computes per-placement happiness in [0, 1]. The engine multiplies the
# returned value into a placement's `appeal_contribution` when aggregating
# a region's effective appeal (see region_appeal.md).
#
# Engine ships a no-op default that returns 1.0 — happiness-agnostic
# games get the simple "sum of contributions" behavior automatically.
# Games that care about happiness register their own implementation:
#
#     EffectResolver.register_happiness_model(MyAnimalHappiness.new())
#
# The zoo's example impl is at zoo-tycoon/src/models/animal_happiness.gd
# and follows zoo-tycoon/design/algorithms/animal_happiness.md.


# Override to return a happiness multiplier in [0, 1] for
# `region.placements[index]`. Caller clamps; impls don't have to.
func compute_happiness(_region: Region, _index: int) -> float:
	return 1.0
