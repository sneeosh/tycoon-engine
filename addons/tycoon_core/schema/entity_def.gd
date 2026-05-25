extends Resource
class_name EntityDef
# Spec: docs/build-plan.md §3 (content schema — EntityDef), Prompt 3.
#
# Definition of a placeable thing. EntityDef is *data*; the placed instance
# (managed by EntityRegistry, Prompt 5) is what carries runtime state.
# Theme-agnostic: a golf hole, a zoo exhibit, and a hospital ICU are all
# expressed as EntityDef + Effects + an `appeal_profile`.

@export var id: StringName = &""
@export var display_name: String = ""
@export var build_cost: int = 0
@export var maintenance_cost: int = 0
# Tile-grid footprint. Vector2i(1, 1) = single-tile.
@export var footprint: Vector2i = Vector2i(1, 1)
# Logical key into the asset manifest, not a file path.
@export var sprite_key: StringName = &""
# Which Needs this entity covers (matches Need.id).
@export var satisfies: Array[StringName] = []
# Named axes → numeric value. Generalizes RCT's excitement/intensity/nausea.
# Axis names are game-defined; the engine just scores the match against an
# AgentType's `preferences`.
@export var appeal_profile: Dictionary = {}
@export var effects: Array[Effect] = []
@export var upgrade_chain: Array[UpgradeTier] = []

# --- Zone tile fields (v0.4.0 — see design/algorithms/zone_pattern.md) ---
#
# Empty `zone_kind` means this entity is NOT a zone tile (existing behavior
# — every pre-v0.4 EntityDef has empty zone_kind by default). Non-empty
# flags this EntityDef as a tile that participates in region detection:
# two edge-adjacent tiles with the same `zone_kind` join the same Region.
@export var zone_kind: StringName = &""

# Zone tags this tile contributes when it's part of a region. A region's
# effective `provided_zone_tags` is the union across all member tiles.
# Games define what these tags mean (`grass`, `water`, `sterile`, …).
@export var zone_tags: Array[StringName] = []
