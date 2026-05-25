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

1. **Reflect the best of what's inside.** A region with a single
   placeable still has that placeable's full appeal on the axes it
   contributes to.
2. **Reward variety with diminishing returns.** Two identical placeables
   are more appealing than one; ten aren't ten times more appealing.
3. **Penalize unhappy contents.** A placeable at 0.5 happiness contributes
   half what a happy one would. (This is the only place happiness enters
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

Engine examples use abstract placeholders. Happiness values are stipulated
per row (a real test would invoke the registered `IPlaceableHappiness`
implementation; for unit-testing the aggregation math we feed in
constants).

```
Placeables (appeal_contribution shown):
  P_A: {axis1: 0.8, axis2: 0.6}
  P_B: {axis1: 0.7, axis2: 0.7, axis3: 0.4}
  P_C: {axis2: 0.4}
  P_D: {axis2: 0.5, axis3: 0.7}
  P_E: {axis2: 0.6, axis4: 0.8}
```

Regions (built up from zone tiles per `region_detection.md`):
- R_4:  area 4
- R_9:  area 9
- R_16: area 16

| # | region | placements         | stipulated happiness          | appeal_profile (out)                                                              |
|---|--------|--------------------|-------------------------------|-----------------------------------------------------------------------------------|
| 1 | R_4    | []                 | —                             | `{}` (empty)                                                                      |
| 2 | R_4    | [P_A]              | [0.90]                        | axis1: 1-(1-0.72)=0.72; axis2: 1-(1-0.54)=0.54                                    |
| 3 | R_9    | [P_A, P_A]         | [1.00, 1.00]                  | axis1: 1-(0.2)(0.2)=0.96; axis2: 1-(0.4)(0.4)=0.84                                |
| 4 | R_16   | [P_A]×4            | [1.00]×4                      | axis1: 1-(0.2)^4=0.9984; axis2: 1-(0.4)^4=0.9744                                  |
| 5 | R_16   | [P_A]×5            | [0.85]×5                      | eff axis1=0.68; 1-(0.32)^5≈0.9966. eff axis2=0.51; 1-(0.49)^5≈0.9718              |
| 6 | R_9    | [P_A, P_B]         | [0.90, 0.90]                  | axis1: P_A eff 0.72, P_B eff 0.63 → 1-(0.28)(0.37)=0.8964. axis2: 0.54, 0.63 → 1-(0.46)(0.37)=0.8298. axis3: P_B only 0.36 → 0.36 |
| 7 | R_9    | [P_D]×5            | [1.00]×5                      | axis2: 1-(0.5)^5≈0.969; axis3: 1-(0.3)^5≈0.998                                    |
| 8 | R_9    | [P_D]              | [0.80]                        | eff axis2=0.40, axis3=0.56 → `{axis2: 0.40, axis3: 0.56}`                         |
| 9 | R_16   | [P_E]×4            | [0.90]×4                      | eff axis2=0.54, axis4=0.72; axis2: 1-(0.46)^4≈0.955; axis4: 1-(0.28)^4≈0.994      |
| 10| R_4    | [P_C]              | [0.70]                        | eff axis2=0.28; `{axis2: 0.28}`                                                   |

Row 6 in plain English: P_A and P_B each scored 0.90 happiness. Each
contributes a reduced share to its appeal axes. The aggregation closes
the gap to 1 by saturation — two contributors yield ~0.9 on axis1,
~0.83 on axis2, plus P_B's solo 0.36 on axis3.

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
