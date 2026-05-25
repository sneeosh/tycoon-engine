# Container / Placeable Pattern — Overview

Every tycoon game eventually wants the same shape: a player builds an empty
"container" entity (a zoo exhibit, a hospital room, a golf hole, a hotel room,
a restaurant kitchen), then drops specific "placeables" inside it (animals,
medical equipment, hazards, furniture, appliances). The container's value to
visitors is computed from what's inside it, not from a fixed `appeal_profile`
on the entity itself.

This document is the overview. Three companion algorithm specs detail the
math:

- [`placement_compatibility.md`](placement_compatibility.md) — can this
  placeable go in this container?
- [`placeable_happiness.md`](placeable_happiness.md) — how happy is each
  placeable inside its container?
- [`container_appeal.md`](container_appeal.md) — what's the container's
  effective `appeal_profile` given its placeables + their happiness?

The pattern lives in the engine. Specific placeable kinds (zoo animals, golf
hazards, hospital equipment, hotel furniture) live in each game's tuning.

---

## Schema additions

### `EntityDef` (existing — gains container fields)

```gdscript
# Existing fields unchanged: id, display_name, build_cost, footprint, …

# Container fields — all default to 0/empty, meaning "not a container."
@export var container_capacity: int = 0              # max placeables
@export var container_space_total: int = 0           # arbitrary units; see specs
@export var container_provided_habitats: Array[StringName] = []
```

A container is any `EntityDef` with `container_capacity > 0`. Generic-only
fields; the game decides what `provided_habitats` axes mean (`grass`,
`water`, `tall_cage`, `sterile`, `tee_box`, etc.).

### `PlaceableDef` (new Resource)

```gdscript
class_name PlaceableDef extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var sprite_key: StringName = &""
@export var build_cost: int = 0                      # one-shot cost to place
@export var maintenance_cost: int = 0                # daily upkeep, like EntityDef

@export var space_required: int = 1                  # space units consumed
@export var space_ideal: int = 4                     # per-individual ideal

@export var required_habitats: Array[StringName] = []
@export var incompatible_tags: Array[StringName] = []
@export var own_tags: Array[StringName] = []

@export var appeal_contribution: Dictionary = {}     # axis → float in [0,1]
@export var social_min: int = 0                      # ideal min same-species in container
@export var social_max: int = 99                     # ideal max
```

### `EntityInstance` (existing — gains placements)

```gdscript
# Existing fields unchanged: instance_id, entity_def_id, position, upgrade_tier, state

# Each entry is one placed individual (a Placement). Same placeable_def_id
# can appear multiple times — two lions = two entries. Per-individual
# state (name, age, mood) is stored alongside as the game wants.
var placements: Array[Placement] = []
```

```gdscript
class_name Placement extends Resource

@export var placeable_def_id: StringName = &""
@export var added_at_tick: int = 0
@export var state: Dictionary = {}                   # game-owned per-individual
```

### Engine APIs (`EntityRegistry`)

```gdscript
# Returns {"ok": bool, "reason": String} — see placement_compatibility.md
func can_add_placement(instance_id: int, placeable_def_id: StringName) -> Dictionary

# Returns the new Placement on success, null on failure (also push_warns).
func add_placement(instance_id: int, placeable_def_id: StringName) -> Placement

# Returns true on success, false if index out of range.
func remove_placement(instance_id: int, index: int) -> bool

# Convenience: every placement in this container.
func get_placements(instance_id: int) -> Array[Placement]
```

### Engine APIs (`EffectResolver`)

```gdscript
# Effective appeal for the container, derived from placements — see
# container_appeal.md. Returns {} for non-containers and empty containers.
# Replaces the static EntityDef.appeal_profile lookup for any entity that
# is a container.
func compute_container_appeal(instance_id: int) -> Dictionary

# Per-placeable happiness in [0, 1] — see placeable_happiness.md.
# Game IValueModel / ISatisfactionModel may also call this to gate
# behavior (e.g. unhappy animals don't draw a crowd).
func compute_placeable_happiness(instance_id: int, placement_index: int) -> float
```

The existing `EffectResolver.appeal_match(agent_type, entity_def)` keeps
working unchanged for non-container entities. For containers, callers should
use `appeal_match_container(agent_type, instance)` (new helper that calls
`compute_container_appeal` and feeds the result through the same scoring
math). Both helpers live in `EffectResolver`.

---

## ContentDB additions

`design/tuning/placeables.md` is a new optional tuning file. Same parser
style as the existing schemas:

```markdown
## Placeables

| id     | display_name | sprite_key | build_cost | maintenance_cost | space_required | space_ideal | social_min | social_max | required_habitats | incompatible_tags | own_tags        | appeal_contribution     |
| ------ | ------------ | ---------- | ---------- | ---------------- | -------------- | ----------- | ---------- | ---------- | ----------------- | ----------------- | --------------- | ----------------------- |
| lion   | Lion         | lion       | 800        | 8                | 3              | 4           | 1          | 3          | grass,rocks       | prey              | predator,big    | thrill:0.8,danger:0.6   |
| zebra  | Zebra        | zebra      | 400        | 4                | 2              | 3           | 3          | 8          | grass             | predator          | prey,herd       | beauty:0.4              |
| parrot | Parrot       | parrot     | 200        | 1                | 1              | 1           | 2          | 8          | tall_cage         |                   | bird,colorful   | beauty:0.5,exotic:0.7   |
```

`ContentDB.placeable_defs: Dictionary` becomes the public lookup.
Cross-ref validation: every `required_habitats` tag must appear in at least
one container's `container_provided_habitats`; else loud error.

Container annotations move to the existing `entities.md`:

```markdown
| id        | display_name | build_cost | maintenance_cost | footprint_x | footprint_y | sprite_key | container_capacity | container_space_total | container_provided_habitats |
| --------- | ------------ | ---------- | ---------------- | ----------- | ----------- | ---------- | ------------------ | --------------------- | --------------------------- |
| small_pen | Small Pen    | 500        | 5                | 3           | 3           | small_pen  | 2                  | 9                     | grass                       |
| large_pen | Large Pen    | 900        | 10               | 4           | 4           | large_pen  | 5                  | 16                    | grass,rocks                 |
| aviary    | Bird Aviary  | 600        | 6                | 3           | 3           | aviary     | 8                  | 9                     | tall_cage,grass             |
| aquarium  | Aquarium     | 1200       | 8                | 4           | 3           | aquarium   | 4                  | 12                    | water                       |
```

Old-style EntityDefs without container fields keep working — they're just
not containers.

---

## Lifecycle

```
1. Player opens build menu → picks "Small Pen" → places at (5, 5).
   EntityRegistry.place(&"small_pen", (5,5)) — same path as today.

2. Player clicks the placed Pen → game UI opens "Manage Exhibit" panel.
   Panel pulls the Pen's container_capacity / placements via EntityRegistry.

3. Player clicks "Add Animal" → picker shows every PlaceableDef whose
   required_habitats ⊆ Pen.container_provided_habitats. Greys out
   placeables that fail can_add_placement (over capacity, hostile mix, etc).

4. Player picks "Lion" → EntityRegistry.add_placement(pen_id, &"lion").
   Engine deducts lion.build_cost from Ledger, registers maintenance
   recurring expense (per-placement, like entities already do), bumps
   the Pen's effective appeal_profile.

5. Visitor approaches → EffectResolver.appeal_match_container(visitor_type,
   pen_instance) gives the new score. Lion's appeal flows through.

6. Player adds 2nd Lion → social_min satisfied → happiness up. Visitor
   appeal up.

7. Player tries to add a Zebra → can_add_placement returns
   {ok:false, reason:"incompatible with Lion"} → UI greys out Zebra.

8. Player removes the Pen → EntityRegistry.remove() unregisters every
   placement's maintenance rule before destroying the instance.
```

---

## MVP vs. full scope

For the first cut (v0.4.0), implement:

- Placement add/remove with capacity + habitat compatibility check
- Per-placement maintenance recurring (mirrors current entity maintenance)
- Effective appeal_profile from placements (no happiness modulation yet —
  treat happiness as 1.0 if `can_add_placement` passed at placement time)

Defer to v0.4.1+:

- `placeable_happiness.md` (space/social math)
- Happiness-modulated appeal contribution
- Companion bonus / hostile penalty
- Condition-driven effects ("Fed" / "Hungry" placeables, fed by nearby
  feeding-trough entities)
- Re-evaluating placement validity if container loses a habitat post hoc

Specs cover the full scope so we can wire the math straight in; MVP just
short-circuits the happiness function to `1.0`.
