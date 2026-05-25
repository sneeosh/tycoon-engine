# Container Appeal — Effective appeal_profile for a container

The existing `EffectResolver.appeal_match(agent_type, entity_def)` scores
how well an `EntityDef.appeal_profile` matches an `AgentType.preferences`.
Pre-container, an entity's appeal_profile was authored statically in
`entities.md` and never changed. With the container pattern, an entity that
*is* a container computes its appeal_profile at runtime from its
placements — each placeable contributes to one or more axes, and a
container's appeal is the aggregation across all placements.

This spec defines that aggregation.

See [`container_pattern.md`](container_pattern.md) for the schema and
[`placeable_happiness.md`](placeable_happiness.md) for the happiness
multiplier this depends on.

## Intent

A container's appeal should:

1. **Reflect the best of what's inside.** A pen with a single lion still
   has lion-grade thrill.
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

- `container_def` — `EntityDef` with container fields set
- `placements` — `Array[Placement]` in this container instance
- For each placement: its `PlaceableDef` and its happiness (from
  [`placeable_happiness.md`](placeable_happiness.md))

## Output

- `appeal_profile` — `Dictionary[StringName, float]` where each value is in
  `[0, 1]`. Suitable for direct use by the existing `appeal_match` scoring
  formula in `EffectResolver`.

Containers with zero placements return an empty `{}` — `appeal_match`
already handles empty `appeal_profile` (returns the existing fallback
behavior).

## Pseudocode

```
function compute_container_appeal(container_def, placements):
    # axis (StringName) → running PRODUCT of (1 - effective_contrib)
    remaining: Dictionary = {}

    for i, placement in enumerate(placements):
        p_def = ContentDB.placeable_defs[placement.placeable_def_id]
        happiness = placeable_happiness(container_def, placements, i)
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

Tuning shared with the other specs:

```
Placeables (appeal_contribution shown):
  lion:    {thrill: 0.8, danger: 0.6}
  tiger:   {thrill: 0.7, danger: 0.7, exotic: 0.4}  (own [predator, big]; social [1, 2])
  zebra:   {beauty: 0.4}
  parrot:  {beauty: 0.5, exotic: 0.7}
  penguin: {beauty: 0.6, cute:   0.8}

Happiness comes from placeable_happiness.md row references below; rows
referencing tiger / mixed compositions compute happiness inline (the
happiness spec's table only covers single-species cases — these are the
multi-species worked examples).
```

| # | container | placements                 | happiness per placement      | appeal_profile (out)                                                  |
|---|-----------|----------------------------|------------------------------|-----------------------------------------------------------------------|
| 1 | small_pen | []                         | —                            | {} (empty)                                                            |
| 2 | small_pen | [lion]                     | [0.90] (row 1 from happiness)| {thrill: 1-(1-0.72) = 0.72, danger: 1-(1-0.54) = 0.54}                |
| 3 | small_pen | [lion, lion]               | [1.00, 1.00]                 | {thrill: 1-(0.2)(0.2) = 0.96, danger: 1-(0.4)(0.4) = 0.84}            |
| 4 | large_pen | [lion]×4                   | [1.00]×4                     | {thrill: 1-(0.2)^4 = 0.9984, danger: 1-(0.4)^4 = 0.9744}              |
| 5 | large_pen | [lion]×5                   | [0.85]×5                     | effective = 0.8×0.85 = 0.68; thrill: 1-(0.32)^5 ≈ 0.9966; danger eff = 0.51, 1-(0.49)^5 ≈ 0.9718 |
| 6 | large_pen | [lion, tiger]              | [0.90, 0.90] *               | thrill: 1-(1-0.72)(1-0.63) = 0.8964; danger: 1-(1-0.54)(1-0.63) = 0.8298; exotic: 1-(1-0.36) = 0.36 |
| 7 | aviary    | [parrot]×5                 | [1.00]×5 (row 7)             | beauty: 1-(0.5)^5 ≈ 0.969; exotic: 1-(0.3)^5 ≈ 0.998                  |
| 8 | aviary    | [parrot]                   | [0.80] (row 5)               | effective beauty = 0.40, exotic = 0.56; appeal: {beauty: 0.40, exotic: 0.56} |
| 9 | aquarium  | [penguin]×4                | [0.90]×4 (row 11)            | beauty eff = 0.54, cute eff = 0.72; beauty: 1-(0.46)^4 ≈ 0.955; cute: 1-(0.28)^4 ≈ 0.994 |
| 10| small_pen | [zebra]                    | [n/a — solo zebra, social_min 3 → happiness = 1-(3-0)*0.1 = 0.70] | beauty eff = 0.28; {beauty: 0.28} |

\* Row 6: a lion and a tiger share a Large Pen. Each is the only member of
its own species → each scores `social_min - 0 = 1` "lonely" penalty
→ happiness 0.9 each. Effective contributions are reduced accordingly
(thrill: lion `0.8×0.9 = 0.72`, tiger `0.7×0.9 = 0.63`). The aggregation
math then combines them via saturation. The `exotic` axis only has the
tiger contributing — adding a second tiger would lift their happiness
(companions in range) AND push exotic toward saturation.

Each row above mirrors one-to-one as a GUT test in
`tests/systems/test_container_appeal.gd`. Drift between table and code
is a build failure.

## Integration with the existing appeal_match

The existing `EffectResolver.appeal_match(agent_type, entity_def)` runs
unchanged for non-container entities. For containers, a new helper:

```gdscript
func appeal_match_container(agent_type: AgentType, instance: EntityInstance) -> float:
    var profile := compute_container_appeal(
        instance.get_def(), instance.placements)
    return _appeal_match_against_profile(agent_type, profile)
```

`_appeal_match_against_profile` is the existing math, factored out so both
the static-`appeal_profile` and dynamic-container paths share it.

Game-side `IValueModel` / `ISatisfactionModel` implementations that
currently call `EffectResolver.appeal_match(agent_type, entity_def)` should
switch to a polymorphic helper that picks `appeal_match_container` when
the entity is a container. This is a one-line change in each game (the
engine ships the helper).

## MVP simplification

For the first cut (v0.4.0), `placeable_happiness` returns `1.0` always (see
that spec's MVP note). The aggregation math here works unchanged — every
placement's effective contribution = its raw contribution. Rows 2, 5, 8,
9, 10 above would all shift up to "happiness 1.0" variants.

When `placeable_happiness` ships for real (v0.4.1), the same test rows
land — no change to this spec's implementation.
