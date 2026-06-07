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
# Spec: design/algorithms/accounting.md
# Straight-line depreciation horizon for the Accounting subsystem (v0.5.0).
# 0 = no depreciation; the full build_cost is recognized as an immediate
# operating expense on the IS (matches the cash story). >0 = the cost is
# capitalized as PP&E and recognized as depreciation expense over N days.
# Optional column in design/tuning/entities.md; defaults to 0 when absent.
@export var useful_life_days: int = 0
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

# --- Walkable-network fields (v0.6.0 — see design/algorithms/navigation.md) ---
#
# `walkable = false` means this entity contributes nothing to any
# WalkableNetwork (existing behavior — every pre-v0.6 EntityDef defaults to
# false). When true, NavigationRegistry adds this entity's footprint cells
# to the network named by `network_id` as agents traverse them.
@export var walkable: bool = false

# Cost of *entering* one of this entity's cells. <= 0 means "use the tuning
# default" (BalanceConfig.nav_default_traversal_cost).
@export var traversal_cost: float = 1.0

# Which WalkableNetwork these cells belong to. Multiple disjoint networks
# let a game keep indoor/outdoor or staff/public routing separate; a simple
# game leaves everything on the default network.
@export var network_id: StringName = &"default"

# Access tags an agent must carry (all of them) to enter these cells.
# Empty = open to everyone. Games define meaning (`staff_only`, `paid`, …).
@export var walkable_tags: Array[StringName] = []
