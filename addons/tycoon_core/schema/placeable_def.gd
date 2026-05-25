extends Resource
class_name PlaceableDef
# Spec: design/algorithms/zone_pattern.md (Schema additions §)
#
# Definition of a thing that goes INSIDE a Region — a zoo animal, hospital
# bed, golf hazard, hotel chair. Placeables are not placed directly on the
# grid; they're added to an existing Region (a connected component of
# zone-kind EntityInstances) via `RegionRegistry.add_placement(...)`.
# Theme-agnostic: zoo animals and golf bunkers are both PlaceableDefs.

@export var id: StringName = &""
@export var display_name: String = ""
@export var sprite_key: StringName = &""
@export var build_cost: int = 0
@export var maintenance_cost: int = 0   # auto-registered per-placement on add

# Cells this placement consumes within its region. The space-accounting
# rule is in placement_compatibility.md: a region with `area` cells can
# hold any combination of placements whose `space_required` sums to ≤ area.
@export var space_required: int = 1

# Ideal per-individual cell allocation. Used by IPlaceableHappiness impls
# that care about crowding (e.g. zoo's animal_happiness.md). Engine doesn't
# read this field; it's metadata for game-side happiness models.
@export var space_ideal: int = 4

# Tags this placeable needs in its region's `provided_zone_tags`. Missing
# tags fail `placement_compatibility.can_place(...)`. Empty = no zone tag
# requirement (typical for infrastructure placeables like feeding troughs
# that go in any region).
@export var required_zone_tags: Array[StringName] = []

# Tags this placeable advertises. Other placeables' incompatibility checks
# read these. Also the "provided pool" that game-side IPlaceableHappiness
# implementations may scan to detect things like "is there a food source
# in this region?"
@export var own_tags: Array[StringName] = []

# Tags this placeable refuses to coexist with. Compatibility check is
# symmetric: either side's incompatible_tags matching the other's
# own_tags blocks placement (see placement_compatibility.md).
@export var incompatible_tags: Array[StringName] = []

# Same as `EntityDef.appeal_profile` but contributed at the placement
# level. The region's aggregate appeal is computed via the saturation
# formula in region_appeal.md (each placement's contribution is multiplied
# by its happiness from the registered IPlaceableHappiness impl).
@export var appeal_contribution: Dictionary = {}

# Game-side metadata for happiness models — engine doesn't read.
# (zoo's ZooAnimalHappiness uses these; a golf game might not.)
@export var social_min: int = 0
@export var social_max: int = 99
@export var needs_provided_tags: Array[StringName] = []
