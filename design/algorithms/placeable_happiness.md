# Placeable Happiness — How happy is each placeable inside its container?

Once a placement has passed [`placement_compatibility.md`](placement_compatibility.md),
it is *valid* — but valid isn't the same as *happy*. A lone wolf in a pack
animal's body, a herd of zebras crammed into a starter pen, an aviary with
half the parrots a flock wants — all valid placements, all unhappy
placeables. Happiness flows through into the container's effective appeal
([`container_appeal.md`](container_appeal.md)): unhappy contents drag the
visit experience down.

## Intent

Each placeable inside a container scores `[0, 1]`. Start at 1.0 and subtract
penalties for the things the placeable cares about — space-per-individual
below ideal, social group too small or too large. Don't reward beyond the
baseline; "perfect conditions" = 1.0, anything less reduces. This keeps the
sign convention with the container appeal math (happiness multiplies
contribution, capped at 1).

Happiness is **per placeable instance**, not per species. Five lions in one
pen all share the same space-and-social context, so all five score the
same number. A single lion and a single tiger in a Large Pen score
differently because their `social_min` / `social_max` differ.

## Inputs

- `container_def` — `EntityDef` with container fields
- `placements` — `Array[Placement]` in this container
- `self_index` — which placement we're scoring (the `placements[self_index]`)
- For each placement, look up its `PlaceableDef` via `ContentDB.placeable_defs`

## Output

- `happiness` — float in `[0.0, 1.0]`

## Pseudocode

```
function placeable_happiness(container_def, placements, self_index):
    self_def = ContentDB.placeable_defs[placements[self_index].placeable_def_id]
    penalty = 0.0

    # --- Space penalty ----------------------------------------------------
    # actual_space = container's total space divided across all placeables
    # (an even split — a coarse model, but matches player intuition that
    # "the bigger the pen, the better, and crowding hurts everyone").
    actual_space = container_def.container_space_total / len(placements)
    if actual_space < self_def.space_ideal:
        deficit = 1.0 - actual_space / self_def.space_ideal
        penalty += deficit * SPACE_WEIGHT  # SPACE_WEIGHT = 0.5

    # --- Social penalty ---------------------------------------------------
    # Count companions of the SAME species (excluding self).
    companions = count(p for p in placements
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
code. Initial values in the table above.

## Worked Examples

Tuning shared with [`placement_compatibility.md`](placement_compatibility.md):

```
Placeables:
  lion:    space_req 3, space_ideal 4, social [1, 3]
  zebra:   space_req 2, space_ideal 3, social [3, 8]
  parrot:  space_req 1, space_ideal 1, social [2, 8]
  penguin: space_req 1, space_ideal 1, social [4, 20]

Weights:
  SPACE_WEIGHT           = 0.5
  SOCIAL_DEFICIT_WEIGHT  = 0.1
  SOCIAL_EXCESS_WEIGHT   = 0.05

Containers (capacity / space_total):
  small_pen (2 / 9), large_pen (5 / 16), aviary (8 / 9), aquarium (4 / 12)
```

| # | container | placements                   | scoring   | actual_space | companions | penalty                              | happiness |
|---|-----------|------------------------------|-----------|-------------:|-----------:|--------------------------------------|----------:|
| 1 | small_pen | [lion]                       | lion #0   | 9.0          | 0          | social (1-0)*0.1 = 0.10              | 0.90      |
| 2 | small_pen | [lion, lion]                 | lion #0   | 4.5          | 1          | none (4.5≥4, 1 in [1,3])             | 1.00      |
| 3 | large_pen | [lion, lion, lion, lion]     | lion #0   | 4.0          | 3          | none (=ideal, =max)                  | 1.00      |
| 4 | large_pen | [lion, lion, lion, lion, lion] | lion #0 | 3.2          | 4          | space (1-3.2/4)*0.5 = 0.10; social (4-3)*0.05 = 0.05 → 0.15 | 0.85 |
| 5 | aviary    | [parrot]                     | parrot #0 | 9.0          | 0          | social (2-0)*0.1 = 0.20              | 0.80      |
| 6 | aviary    | [parrot, parrot]             | parrot #0 | 4.5          | 1          | social (2-1)*0.1 = 0.10              | 0.90      |
| 7 | aviary    | [parrot]×5                   | parrot #0 | 1.8          | 4          | none (1.8≥1, 4 in [2,8])             | 1.00      |
| 8 | aviary    | [parrot]×8                   | parrot #0 | 1.125        | 7          | none (1.125≥1, 7 in [2,8])           | 1.00      |
| 9 | large_pen | [zebra]×3                    | zebra #0  | 5.33         | 2          | social (3-2)*0.1 = 0.10              | 0.90      |
| 10| large_pen | [zebra]×5                    | zebra #0  | 3.2          | 4          | none (3.2≥3, 4 in [3,8])             | 1.00      |
| 11| aquarium  | [penguin]×4                  | penguin #0| 3.0          | 3          | social (4-3)*0.1 = 0.10              | 0.90      |

Row 4 demonstrates compounding penalties — over capacity *and* over social
max. Row 8 shows a fully-stocked aviary is still ideal because parrots are
flock animals with tiny space needs.

Each row above mirrors one-to-one as a GUT test in
`tests/systems/test_placeable_happiness.gd`. Drift between table and code
is a build failure.

## What this spec deliberately does NOT model (yet)

- **Mixed-species companion bonuses** — currently a lion alone in a Large Pen
  with five zebras would be lonely (zebras don't count as lions). Future:
  optional `social_kin: Array[StringName]` tags so a lion sees other big
  predators as "tolerable company."
- **Per-individual age / mood / personality.** `Placement.state` holds
  whatever the game wants here, but this happiness function ignores it.
  When the game ships per-individual `mood`, layer it in as an extra
  penalty multiplier.
- **Condition-driven bonuses** — a `Fed` `ConditionModifier` toggled on
  when a feeding-trough entity exists within proximity. Existing engine
  `ConditionModifier` system can hook this without changing this spec.
- **Habitat *quality*** beyond presence — every Pen with a `grass` tag
  currently provides "grass" equally. Future: weighted habitat scoring
  (your savanna pen has more grass than a postage stamp).

MVP implementation can return `1.0` from `compute_placeable_happiness` and
defer this whole spec to v0.4.1 — the appeal math in
[`container_appeal.md`](container_appeal.md) is structured to multiply by
happiness, so swapping the stub for the real function is a one-line change.
