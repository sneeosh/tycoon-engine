# Enclosure / Region / Placeable Pattern — Overview

Every tycoon eventually wants the same shape: the player builds a region by
placing modular **enclosure tiles** on the grid, then drops specific
**placeables** inside the region. There is no predefined "Small Pen" or
"Large Pen" entity — instead, the player decides the shape and size of the
region by how many enclosure tiles they connect together, and what kind
they pick.

This makes the build flow analogous to placing a golf hole (tee + fairway
+ green segments form an emergent "Hole" region) or a hospital ward
(multiple "ward floor" tiles connected together form a "Ward" region that
holds beds and equipment).

This document is the overview. Four companion specs detail the math:

- [`region_detection.md`](region_detection.md) — given enclosure tiles on
  the grid, find connected regions and their cells
- [`placement_compatibility.md`](placement_compatibility.md) — can this
  placeable go in this region?
- [`placeable_happiness.md`](placeable_happiness.md) — how happy is each
  placeable inside its region?
- [`region_appeal.md`](region_appeal.md) — what's the region's effective
  `appeal_profile` given its placeables + their happiness?

The pattern lives in the engine. Specific enclosure kinds (zoo pen tiles,
golf fairway segments, hospital ward flooring, hotel room flooring) live
in each game's tuning.

---

## Schema additions

### `EntityDef` (existing — gains two optional fields)

```gdscript
# Existing fields unchanged: id, display_name, build_cost, footprint,
# maintenance_cost, sprite_key, satisfies, appeal_profile, effects, …

# Enclosure annotation. Empty means "this entity is not an enclosure tile."
# Any non-empty value flags this EntityDef as a tile that participates in
# region detection. Two adjacent enclosure tiles with kinds that are
# considered compatible (see region_detection.md) join the same Region.
@export var enclosure_kind: StringName = &""

# Habitat tags this enclosure tile contributes when it's part of a region.
# A region's effective provided_habitats is the union across all its
# constituent enclosure tiles.
@export var enclosure_habitats: Array[StringName] = []
```

Enclosure tiles are placed via the **existing** `EntityRegistry.place(...)`
path — they're just `EntityDef`s with the annotation set. Their
`footprint` is typically `Vector2i(1, 1)` (single-cell), but the system
doesn't require it.

### `PlaceableDef` (new Resource)

Placeables are what goes inside a region — zoo animals, hospital
equipment, golf hazards, hotel furniture.

```gdscript
class_name PlaceableDef extends Resource

@export var id: StringName = &""
@export var display_name: String = ""
@export var sprite_key: StringName = &""
@export var build_cost: int = 0
@export var maintenance_cost: int = 0          # auto-registered per-placement

@export var space_required: int = 1            # cells consumed in the region
@export var space_ideal: int = 4               # per-individual ideal cells

@export var required_habitats: Array[StringName] = []
@export var incompatible_tags: Array[StringName] = []
@export var own_tags: Array[StringName] = []

# Tags this placeable needs in its region's "provided pool" (= the union
# of own_tags from every OTHER placement in the same region). Each missing
# tag applies a happiness penalty. Empty for infrastructure placeables
# that PROVIDE tags instead of requiring them. See placeable_happiness.md.
@export var needs_provided_tags: Array[StringName] = []

@export var appeal_contribution: Dictionary = {}
@export var social_min: int = 0
@export var social_max: int = 99
```

This lets the game express things like:
- A `lion` needs `provides_food` + `provides_water` in its region.
- A `feeding_trough` placeable provides `[provides_food, infrastructure]`
  via `own_tags`.
- A region with a lion but no trough → lion's happiness penalised; that
  penalty flows through into the region's appeal score → visitors see a
  worse exhibit.

### `Region` (new runtime concept — not a Resource, derived state)

```gdscript
class_name Region extends RefCounted

var region_id: int = 0
var kind: StringName = &""                     # primary kind — see region_detection.md
var member_instance_ids: Array[int] = []       # enclosure EntityInstance ids
var cells: Array[Vector2i] = []                # every grid cell the region covers
var provided_habitats: Array[StringName] = []  # union across members
var area: int = 0                              # cells.size() — convenience
var placements: Array[Placement] = []          # contents
```

Regions are not authored content — they're computed by `RegionRegistry`
(new autoload) from `EntityRegistry`'s enclosure tiles whenever placement
changes. Region ids are stable within a session; on save/load, the
detector recomputes them and games re-resolve any region references.

### `Placement` (new Resource, lives in Region.placements)

```gdscript
class_name Placement extends Resource

@export var placeable_def_id: StringName = &""
@export var added_at_tick: int = 0

# Game-owned per-individual state. The one key the engine READS (but never
# writes) is `attitude: float in [0, 1]` — a multiplier on this individual's
# computed happiness (see placeable_happiness.md). Games drive attitude
# from whatever per-individual systems they want (trauma, age, illness,
# personality, time-since-last-feed). Default 1.0 (no modifier).
@export var state: Dictionary = {}
```

---

## New autoload: `RegionRegistry`

```gdscript
# Tracks computed regions, recomputed reactively on enclosure tile changes.
# Subscribes to EventBus.entity_placed / .entity_removed and runs region
# detection (see region_detection.md) when an enclosure tile is involved.

# region_id -> Region
var regions: Dictionary = {}

# instance_id (enclosure tile) -> region_id (membership lookup)
var _tile_membership: Dictionary = {}

# --- Queries ----------------------------------------------------------------
func get_region(region_id: int) -> Region
func region_for_tile(instance_id: int) -> Region   # null if not an enclosure
func region_at_cell(cell: Vector2i) -> Region      # null if cell isn't in any
func all_regions() -> Array[Region]

# --- Placement management ---------------------------------------------------
# Returns {"ok": bool, "reason": String} — see placement_compatibility.md
func can_add_placement(region_id: int, placeable_def_id: StringName) -> Dictionary

# Returns the new Placement on success, null on failure.
func add_placement(region_id: int, placeable_def_id: StringName) -> Placement

# Returns true on success, false if index out of range.
func remove_placement(region_id: int, index: int) -> bool

# --- Signals (emitted into EventBus) ---------------------------------------
signal region_created(region_id: int)
signal region_destroyed(region_id: int)
signal region_changed(region_id: int)              # cells/members changed
signal placement_added(region_id: int, index: int)
signal placement_removed(region_id: int, index: int)
```

---

## ContentDB additions

`design/tuning/placeables.md` is the new tuning file (parser pattern same as
`agents.md`):

```markdown
## Placeables

| id             | display_name   | sprite_key     | build_cost | maintenance_cost | space_required | space_ideal | social_min | social_max | required_habitats | incompatible_tags | own_tags                       | needs_provided_tags        | appeal_contribution     |
| -------------- | -------------- | -------------- | ---------- | ---------------- | -------------- | ----------- | ---------- | ---------- | ----------------- | ----------------- | ------------------------------ | -------------------------- | ----------------------- |
| lion           | Lion           | lion           | 800        | 8                | 3              | 4           | 1          | 3          | grass,rocks       | prey              | predator,big                   | provides_food,provides_water | thrill:0.8,danger:0.6   |
| zebra          | Zebra          | zebra          | 400        | 4                | 2              | 3           | 3          | 8          | grass             | predator          | prey,herd                      | provides_food,provides_water | beauty:0.4              |
| parrot         | Parrot         | parrot         | 200        | 1                | 1              | 1           | 2          | 8          | tall_cage         |                   | bird,colorful                  | provides_food              | beauty:0.5,exotic:0.7   |
| feeding_trough | Feeding Trough | feeding_trough | 80         | 2                | 1              | 1           | 0          | 99         |                   |                   | provides_food,infrastructure   |                            |                         |
| water_trough   | Water Trough   | water_trough   | 60         | 1                | 1              | 1           | 0          | 99         |                   |                   | provides_water,infrastructure  |                            |                         |
```

`entities.md` grows the two optional enclosure fields (existing rows
unaffected):

```markdown
| id            | display_name    | build_cost | maintenance_cost | footprint_x | footprint_y | sprite_key    | enclosure_kind | enclosure_habitats |
| ------------- | --------------- | ---------- | ---------------- | ----------- | ----------- | ------------- | -------------- | ------------------ |
| grass_pen     | Grass Enclosure | 80         | 1                | 1           | 1           | grass_pen     | pen            | grass              |
| rocky_pen     | Rocky Enclosure | 120        | 1                | 1           | 1           | rocky_pen     | pen            | grass,rocks        |
| water_pen     | Water Enclosure | 200        | 2                | 1           | 1           | water_pen     | pen            | water              |
| aviary_pen    | Aviary Cage     | 220        | 2                | 1           | 1           | aviary_pen    | aviary         | tall_cage,grass    |
```

Two adjacent tiles join the same region if they share `enclosure_kind`
(simple rule) — see [`region_detection.md`](region_detection.md) for the
full join rule and the option for kind-compatibility tables.

ContentDB cross-ref validation: every `required_habitats` tag on a
`PlaceableDef` must appear in at least one `EntityDef.enclosure_habitats`
list; else loud error.

---

## Lifecycle

```
1. Player opens build menu → picks "Grass Enclosure" → places at (5, 5).
   Engine: EntityRegistry.place(&"grass_pen", (5,5)) — same path as today.
   RegionRegistry sees a new enclosure tile → runs region detection →
   creates Region #7 with cells=[(5,5)], area=1, habitats=[grass].
   region_created(7) fires.

2. Player places another at (5, 6).
   RegionRegistry sees adjacency to Region #7 → extends it.
   Region #7 now: cells=[(5,5),(5,6)], area=2, habitats=[grass].
   region_changed(7) fires.

3. Player extends until Region #7 has 9 cells and area >= some minimum.
   Game UI flags it as a viable exhibit.

4. Player clicks anywhere in Region #7 → game UI opens "Manage Region"
   panel. Pulls region from RegionRegistry.region_at_cell((5,5)).

5. Player clicks "Add Animal" → picker shows every PlaceableDef whose
   required_habitats ⊆ region.provided_habitats. Greys out placeables
   that fail can_add_placement.

6. Player picks "Lion" → RegionRegistry.add_placement(7, &"lion").
   Engine deducts lion.build_cost from Ledger, registers a per-placement
   maintenance recurring rule (same pattern as EntityDef.maintenance_cost
   since v0.3.0).

7. Visitors arrive → EffectResolver.appeal_match_region(visitor_type,
   region) gives the score (see region_appeal.md). Lion's appeal flows.

8. Player places a "Rocky Enclosure" adjacent to Region #7.
   Adjacency + same kind (both "pen") → joined. Region #7 now has area=10
   and provided_habitats=[grass, rocks].
   region_changed(7) fires; cached appeals invalidate.

9. Player removes one of the original grass tiles in the middle, splitting
   the connected component in two. Region detection:
   - If the split makes Region #7 invalid (animal's required_habitats no
     longer satisfied), the placement is "stranded" — see below.
   - Otherwise: Region #7 shrinks to one connected component, a new
     Region #N is created for the other. Engine emits region_changed(7)
     and region_created(N). Existing placements stay in Region #7;
     placements that cells now belonging to N transfer there.
```

---

## Stranded placements

When an enclosure tile is removed and the placement's region either:
- shrinks below `placement.space_required`, OR
- loses one of `placement.required_habitats`,

the placement is **stranded** — still in the region, but no longer happily
contained. The engine emits a `placement_stranded(region_id, placement_index)`
signal; the game decides whether to auto-remove the placeable (with refund?),
just penalize happiness, or flag the player. Engine's default behavior:
mark stranded, never auto-remove (player keeps full control).

---

## Numbers worth deciding before implementation

- **Adjacency rule** — 4-neighborhood (N/S/E/W) or 8-neighborhood
  (including diagonals)? See [`region_detection.md`](region_detection.md)
  for the choice and rationale.
- **Kind compatibility** — simple "same kind joins" rule or an explicit
  compatibility table (e.g., `aviary` and `pen` tiles cannot merge but
  `pen` and `rocky_pen` can)? Simple rule for MVP; table later.
- **Space accounting** — `region.area == cells.size()`, and a placeable's
  `space_required` consumes that many cells. So 5 lions × 3 = 15 cells
  needed; a 16-cell region holds them. Differs from the v1 spec where
  `space_total` was a separate authored value.

---

## MVP scope (v0.4.0)

Land everything in one release (per review feedback):

1. `EntityDef.enclosure_kind` + `enclosure_habitats` parsing in ContentDB
2. `PlaceableDef` Resource + `placeables.md` parsing
3. `RegionRegistry` autoload with full region-detection logic
4. Placement add/remove with compatibility checks (with happiness math)
5. Per-placement maintenance recurring (mirrors `EntityDef.maintenance_cost`)
6. `EffectResolver.appeal_match_region` using saturation aggregation
7. Tests for all four algorithm specs

The zoo demo on top of this:
- Replace the five hardcoded exhibit EntityDefs with enclosure tiles
  (grass_pen, rocky_pen, water_pen, aviary_pen) + a set of animal
  PlaceableDefs (lion, zebra, elephant, parrot, penguin)
- New build menu groups: "Enclosures" / "Animals" / "Amenities"
- Region selection UI: click any cell in a region → opens management panel
- Repurpose existing sprites: the lion_exhibit.png becomes the lion
  placeable sprite (just the animal); enclosure tiles get new 1-cell
  sprites (grass patch, rock patch, water patch, cage panel)
