# Placeable Happiness — How happy is each placeable inside its region?

Once a placement has passed [`placement_compatibility.md`](placement_compatibility.md),
it is *valid* — but valid isn't the same as *happy*. A lone wolf in a pack
animal's body, a herd of zebras crammed into a starter pen, an aviary with
half the parrots a flock wants — all valid placements, all unhappy
placeables. Happiness flows through into the region's effective appeal
([`region_appeal.md`](region_appeal.md)): unhappy contents drag the visit
experience down.

## Intent

Each placeable inside a region scores `[0, 1]`. Start at 1.0 and subtract
penalties for the things the placeable cares about — space-per-individual
below ideal, social group too small or too large. Don't reward beyond the
baseline; "perfect conditions" = 1.0, anything less reduces. This keeps the
sign convention with the region appeal math (happiness multiplies
contribution, capped at 1).

Happiness is **per placeable instance**, not per species. Five lions in one
region all share the same space-and-social context, so all five score the
same number. A single lion and a single tiger in a region score
differently because their `social_min` / `social_max` differ.

## Inputs

- `region` — `Region` from `RegionRegistry` (uses `region.area` and
  `region.placements`)
- `self_index` — which placement we're scoring (the `region.placements[self_index]`)
- For each placement, look up its `PlaceableDef` via `ContentDB.placeable_defs`

## Output

- `happiness` — float in `[0.0, 1.0]`

## Pseudocode

```
function placeable_happiness(region, self_index):
    self_def = ContentDB.placeable_defs[region.placements[self_index].placeable_def_id]
    penalty = 0.0

    # --- Space penalty ----------------------------------------------------
    # Even-split model: the region's cells divided across all placements.
    # Coarse but matches player intuition that "the bigger the pen, the
    # better, and crowding hurts everyone."
    actual_space = region.area / max(len(region.placements), 1)
    if actual_space < self_def.space_ideal:
        deficit = 1.0 - actual_space / self_def.space_ideal
        penalty += deficit * SPACE_WEIGHT  # SPACE_WEIGHT = 0.5

    # --- Social penalty ---------------------------------------------------
    # Count companions of the SAME species (excluding self).
    companions = count(p for p in region.placements
                       if p.placeable_def_id == self_def.id) - 1

    if companions < self_def.social_min:
        # Lonely — penalty grows with each missing companion.
        missing = self_def.social_min - companions
        penalty += missing * SOCIAL_DEFICIT_WEIGHT  # 0.1 per missing

    if companions > self_def.social_max:
        # Crowded — gentler penalty than loneliness (extra friends are
        # less bad than missing ones).
        excess = companions - self_def.social_max
        penalty += excess * SOCIAL_EXCESS_WEIGHT  # 0.05 per excess

    return clamp(1.0 - penalty, 0.0, 1.0)
```

Tuning constants (`SPACE_WEIGHT`, `SOCIAL_DEFICIT_WEIGHT`,
`SOCIAL_EXCESS_WEIGHT`) live in `design/tuning/balance.md` under a new
`## Happiness` section so designers can shift the curve without editing
code. Initial values in the comments above.

## Worked Examples

Tuning shared across specs:

```
Placeables:
  lion:    space_ideal 4, social [1, 3]
  zebra:   space_ideal 3, social [3, 8]
  parrot:  space_ideal 1, social [2, 8]
  penguin: space_ideal 1, social [4, 20]

Weights:
  SPACE_WEIGHT           = 0.5
  SOCIAL_DEFICIT_WEIGHT  = 0.1
  SOCIAL_EXCESS_WEIGHT   = 0.05
```

Regions (built up from enclosure tiles in region_detection.md):
- R_small: area=4   (small grass pen)
- R_med:   area=9   (medium pen)
- R_big:   area=16  (large pen)
- R_aviary:area=9   (8 tiles? — use 9 for math symmetry)

| # | region   | placements                     | scoring   | actual_space | companions | penalty                              | happiness |
|---|----------|--------------------------------|-----------|-------------:|-----------:|--------------------------------------|----------:|
| 1 | R_small  | [lion]                         | lion #0   | 4.0          | 0          | social (1-0)*0.1 = 0.10              | 0.90      |
| 2 | R_med    | [lion, lion]                   | lion #0   | 4.5          | 1          | none (4.5≥4, 1 in [1,3])             | 1.00      |
| 3 | R_big    | [lion, lion, lion, lion]       | lion #0   | 4.0          | 3          | none (=ideal, =max companions)       | 1.00      |
| 4 | R_big    | [lion, lion, lion, lion, lion] | lion #0   | 3.2          | 4          | space (1-3.2/4)*0.5 = 0.10; social (4-3)*0.05 = 0.05 → 0.15 | 0.85 |
| 5 | R_aviary | [parrot]                       | parrot #0 | 9.0          | 0          | social (2-0)*0.1 = 0.20              | 0.80      |
| 6 | R_aviary | [parrot, parrot]               | parrot #0 | 4.5          | 1          | social (2-1)*0.1 = 0.10              | 0.90      |
| 7 | R_aviary | [parrot]×5                     | parrot #0 | 1.8          | 4          | none (1.8≥1, 4 in [2,8])             | 1.00      |
| 8 | R_aviary | [parrot]×9                     | parrot #0 | 1.0          | 8          | none (1.0≥1, 8 in [2,8])             | 1.00      |
| 9 | R_big    | [zebra]×3                      | zebra #0  | 5.33         | 2          | social (3-2)*0.1 = 0.10              | 0.90      |
| 10| R_big    | [zebra]×5                      | zebra #0  | 3.2          | 4          | none (3.2≥3, 4 in [3,8])             | 1.00      |
| 11| R_med    | [penguin]×4                    | penguin #0| 2.25         | 3          | space none (2.25≥1); social (4-3)*0.1 = 0.10 | 0.90 |
| 12| R_med    | [lion, tiger]                  | lion #0   | 4.5          | 0          | social (1-0)*0.1 = 0.10              | 0.90      |

Row 4 compounds penalties — over space *and* over social max.
Row 8 shows a fully-stocked aviary is still ideal because parrots have
tiny space needs.
Row 12 (lion + tiger): lion has 0 companions of its own species (tiger
doesn't count) → lonely. Same logic applies to the tiger.

Each row above mirrors one-to-one as a GUT test in
`tests/systems/test_placeable_happiness.gd`. Drift between table and code
is a build failure.

## What this spec deliberately does NOT model (yet)

- **Mixed-species companion bonuses** — currently a lion alone with five
  zebras is lonely (zebras don't count as lions). Future: optional
  `social_kin: Array[StringName]` tags so a lion sees other big
  predators as "tolerable company."
- **Per-individual age / mood / personality.** `Placement.state` holds
  whatever the game wants here, but this happiness function ignores it.
- **Condition-driven bonuses** — a `Fed` `ConditionModifier` toggled on
  when a feeding-trough placement exists in the same region. Engine's
  existing `ConditionModifier` system can hook this without changing
  this spec.
- **Habitat *quality*** beyond presence — every region with a `grass` tag
  currently provides grass equally. Future: tile-count weighted habitat
  scoring (a region with 8 grass tiles provides "more grass" than one
  with 1, useful for placeables that want lots of one terrain).
