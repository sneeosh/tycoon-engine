extends Resource
class_name Placement
# Spec: design/algorithms/zone_pattern.md (Schema additions §)
#
# Runtime state for one placement inside a Region. PlaceableDef is the
# *type* (authored content); Placement is the *individual* (added to a
# specific region at a specific tick). RegionRegistry owns the lifecycle.

@export var placeable_def_id: StringName = &""
@export var added_at_tick: int = 0
# Anchor cell within the region — stamped at add-time. Used by region
# detection to figure out which split-component a placement belongs to
# when its region splits. Set by RegionRegistry.add_placement.
@export var primary_cell: Vector2i = Vector2i.ZERO

# Game-owned per-individual state. The engine READS one key:
#   `attitude: float in [0, 1]` — a multiplier on this individual's
#   happiness (consumed by games' IPlaceableHappiness implementations;
#   default 1.0). Games may write whatever else they want here
#   (mood, age, illness, name, …). Engine never writes this dict.
@export var state: Dictionary = {}


func get_def() -> PlaceableDef:
	return ContentDB.placeable_defs.get(placeable_def_id)
