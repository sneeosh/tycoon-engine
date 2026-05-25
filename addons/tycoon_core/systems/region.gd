extends RefCounted
class_name Region
# Spec: design/algorithms/zone_pattern.md (Region §) +
#       design/algorithms/region_detection.md
#
# Runtime grouping of edge-adjacent same-kind zone tiles. Computed by
# RegionRegistry from the EntityRegistry's zone-kind EntityInstances —
# games never construct Regions directly. Region ids are stable within
# a session; on load they're recomputed.

var region_id: int = 0
var kind: StringName = &""
var member_instance_ids: Array[int] = []   # zone EntityInstance ids
var cells: Array[Vector2i] = []            # every grid cell the region covers
var provided_zone_tags: Array[StringName] = []  # union across members
var placements: Array[Placement] = []      # contents (PlaceableDefs)

# area = number of cells in this region. Used by placement_compatibility
# for the space-required check and by IPlaceableHappiness impls for the
# space-per-individual penalty. Derived from cells so it can't drift.
var area: int:
	get:
		return cells.size()
