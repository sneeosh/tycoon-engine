# Region Appeal — Effective appeal_profile for a region

The existing `EffectResolver.appeal_match(agent_type, entity_def)` scores
how well an `EntityDef.appeal_profile` matches an `AgentType.preferences`.
That worked for entities with static authored appeal. Regions (zoo
exhibits, golf holes, hospital wards) compute appeal *at runtime* from
their placements — each placeable contributes to one or more axes, and
the region's appeal is the aggregation across all placements weighted by
each placeable's happiness.

This spec defines that aggregation.

See [`zone_pattern.md`](zone_pattern.md) for the data model and
[`region_detection.md`](region_detection.md) for how regions are derived.
The happiness multiplier used here comes from the registered
`IPlaceableHappiness` implementation (see `zone_pattern.md`); the engine
itself doesn't define what makes a placeable happy — golf hazards aren't
sentient, hospital beds don't get lonely. Games supply their own model.
The default engine implementation returns `1.0` for every placement, so
games that don't care about happiness get the simple "sum of contributions"
behavior automatically.

## Intent

A region's appeal should:

1. **Reflect the best of what's inside.** A region with a single lion
   still has lion-grade thrill.
2. **Reward variety with diminishing returns.** Two lions are slightly
   more appealing than one; ten lions aren't ten times more appealing.
3. **Penalize unhappy contents.** A lion at 0.5 happiness contributes
   half what a happy lion would. (This is the only place happiness enters
   appeal — placement compatibility is unaffected.)
4. **Stay bounded in `[0, 1]`** so the existing `appeal_match` formula
   keeps its semantics.

The math that satisfies all four is **saturation aggregation**:

```
appeal[axis] = 1 - PRODUCT over placements of
                   (1 - placeable.appeal_contribution[axis] × happiness)
```

Each placement closes some fraction of the remaining gap to 1.0. First
placement contributes fully; second contributes from what's left; tenth
contributes very little. The product can never exceed 1.0 → bounded
naturally. A 0-contribution or 0-happiness placeable is a no-op
(multiplies by `(1 - 0) = 1`). This is the same formula as combining
independent probabilities of "at least one succeeds" — well-understood
math, no magic constants.

## Inputs

- `region` — `Region` from `RegionRegistry`
- For each placement in `region.placements`: its `PlaceableDef` and its
  happiness (from [`placeable_happiness.md`](placeable_happiness.md))

## Output

- `appeal_profile` — `Dictionary[StringName, float]` where each value is in
  `[0, 1]`. Suitable for direct use by the existing `appeal_match` scoring
  formula in `EffectResolver`.

Regions with zero placements return an empty `{}` — `appeal_match`
already handles empty `appeal_profile`.

## Pseudocode

```
function compute_region_appeal(region):
    # axis (StringName) → running PRODUCT of (1 - effective_contrib)
    remaining: Dictionary = {}

    for i, placement in enumerate(region.placements):
        p_def = ContentDB.placeable_defs[placement.placeable_def_id]
        # Default impl returns 1.0; games override via
        # EffectResolver.register_happiness_model(impl).
        happiness = _happiness_model.compute_happiness(region, i)
        for axis, raw_contrib in p_def.appeal_contribution.items():
            effective = clamp(raw_contrib * happiness, 0.0, 1.0)
            current = remaining.get(axis, 1.0)
            remaining[axis] = current * (1.0 - effective)

    # appeal = 1 - remaining
    appeal: Dictionary = {}
    for axis, r in remaining.items():
        appeal[axis] = clamp(1.0 - r, 0.0, 1.0)
    return appeal
```

## Worked Examples

Tuning shared across specs:

```
Placeables (appeal_contribution shown):
  lion:    {thrill: 0.8, danger: 0.6}
  tiger:   {thrill: 0.7, danger: 0.7, exotic: 0.4}   (social [1, 2])
  zebra:   {beauty: 0.4}
  parrot:  {beauty: 0.5, exotic: 0.7}
  penguin: {beauty: 0.6, cute:   0.8}

Happiness rows referenced from placeable_happiness.md.
```

Regions:
- R_small: area=4 (grass)
- R_med:   area=9 (grass + rocks)
- R_big:   area=16 (grass + rocks)
- R_aviary:area=9 (tall_cage + grass)
- R_aqua:  area=12 (water + grass)

| # | region   | placements                     | happiness per placement       | appeal_profile (out)                                                  |
|---|----------|--------------------------------|-------------------------------|-----------------------------------------------------------------------|
| 1 | R_small  | []                             | —                             | {} (empty)                                                            |
| 2 | R_small  | [lion]                         | [0.90] (happiness row 1)      | {thrill: 1-(1-0.72) = 0.72, danger: 1-(1-0.54) = 0.54}                |
| 3 | R_med    | [lion, lion]                   | [1.00, 1.00] (happiness row 2)| {thrill: 1-(0.2)(0.2) = 0.96, danger: 1-(0.4)(0.4) = 0.84}            |
| 4 | R_big    | [lion]×4                       | [1.00]×4 (happiness row 3)    | {thrill: 1-(0.2)^4 = 0.9984, danger: 1-(0.4)^4 = 0.9744}              |
| 5 | R_big    | [lion]×5                       | [0.85]×5 (happiness row 4)    | effective thrill = 0.8×0.85 = 0.68; 1-(0.32)^5 ≈ 0.9966. eff danger = 0.51; 1-(0.49)^5 ≈ 0.9718 |
| 6 | R_med    | [lion, tiger]                  | [0.90, 0.90] (happiness row 12 + symmetric for tiger) | thrill: lion eff 0.72, tiger eff 0.63; 1-(1-0.72)(1-0.63) = 0.8964. danger: lion 0.54, tiger 0.63; 1-(0.46)(0.37) = 0.8298. exotic: tiger only 0.36; 1-(1-0.36) = 0.36 |
| 7 | R_aviary | [parrot]×5                     | [1.00]×5 (happiness row 7)    | beauty: 1-(0.5)^5 ≈ 0.969; exotic: 1-(0.3)^5 ≈ 0.998                  |
| 8 | R_aviary | [parrot]                       | [0.80] (happiness row 5)      | effective beauty = 0.40, exotic = 0.56; appeal: {beauty: 0.40, exotic: 0.56} |
| 9 | R_aqua   | [penguin]×4                    | [0.90]×4 (happiness row 11)   | beauty eff = 0.54, cute eff = 0.72; beauty: 1-(0.46)^4 ≈ 0.955; cute: 1-(0.28)^4 ≈ 0.994 |
| 10| R_small  | [zebra]                        | [0.70] (happiness: solo zebra, social_min 3 → 1-(3-0)*0.1 = 0.70) | beauty eff = 0.28; {beauty: 0.28} |

Reading row 6 in plain English: a lone lion and a lone tiger share a
9-cell region. Neither has a same-species companion → both score 0.9
happiness (`-1×0.1` social penalty). Each contributes a reduced share to
its appeal axes. The aggregation closes the gap to 1 by saturation — two
contributors yields ~0.9 thrill, ~0.83 danger, plus the tiger's solo
0.36 exotic.

Each row above mirrors one-to-one as a GUT test in
`tests/systems/test_region_appeal.gd`. Drift between table and code
is a build failure.

## Integration with `appeal_match`

The existing `EffectResolver.appeal_match(agent_type, entity_def)` keeps
working unchanged for non-region entities (food stand, restroom, ATM,
etc.). For regions, a new helper:

```gdscript
func appeal_match_region(agent_type: AgentType, region: Region) -> float:
    var profile := compute_region_appeal(region)
    return _appeal_match_against_profile(agent_type, profile)
```

`_appeal_match_against_profile` is the existing math, factored out so both
the static-`appeal_profile` and dynamic-region paths share it.

Game-side `IValueModel` / `ISatisfactionModel` implementations that
currently call `EffectResolver.appeal_match(agent_type, entity_def)` and
want to factor in regions near the agent should also call
`appeal_match_region(agent_type, region)` for each region in proximity.
Engine ships both helpers; the game decides how to combine them (sum,
max, weighted by distance, etc.).
