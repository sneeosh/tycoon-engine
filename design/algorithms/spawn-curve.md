# Spawn Curve — Satisfaction → Spawn-Rate Multiplier

The self-balancing feedback loop borrowed from RCT. At end of day, aggregate
agent satisfaction maps to a multiplier on tomorrow's base spawn rate. Happy
customers bring more customers; unhappy ones thin the crowd. Bounded above
(no runaway growth) and below (no instant death spiral).

## Intent

A sigmoid centered at a configurable satisfaction midpoint, asymptoting to
`min_mult` as satisfaction → 0 and `max_mult` as satisfaction → 1. The
steepness controls how sharply the curve turns around the midpoint.

## Inputs

- `s` — aggregate satisfaction, normalized to `[0.0, 1.0]`
- Tuning (from `design/tuning/balance.md`):
  - `min_mult` — floor (e.g. `0.25`)
  - `max_mult` — ceiling (e.g. `3.0`)
  - `midpoint` — satisfaction at which output is `(min_mult + max_mult) / 2`
  - `steepness` — sigmoid steepness; larger = sharper transition

## Output

- `m` — multiplier applied to base spawn rate for the next day

## Pseudocode

```
function spawn_multiplier(s, min_mult, max_mult, midpoint, steepness):
    s = clamp(s, 0.0, 1.0)
    x = (s - midpoint) * steepness
    sigmoid = 1.0 / (1.0 + exp(-x))
    return min_mult + (max_mult - min_mult) * sigmoid
```

## Worked Examples

Tuning for all examples: `min_mult = 0.25`, `max_mult = 3.0`,
`midpoint = 0.5`, `steepness = 6.0`. Expected outputs rounded to 3 decimals.

| # | satisfaction | expected multiplier | notes                                |
|---|-------------:|--------------------:|--------------------------------------|
| 1 | 0.00         | 0.380               | floor side — well below midpoint     |
| 2 | 0.25         | 0.752               | one-quarter satisfaction             |
| 3 | 0.50         | 1.625               | midpoint = mean of (min + max) / 2   |
| 4 | 0.75         | 2.498               | three-quarter satisfaction           |
| 5 | 1.00         | 2.870               | ceiling side — well above midpoint   |

Each row above must be mirrored one-to-one as a GUT test in
`tests/systems/test_spawn_curve.gd` when this algorithm is implemented
(Prompt 6). Drift between this table and the code is a build failure.
