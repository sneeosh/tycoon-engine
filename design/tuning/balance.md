# Balance — Global Tuning Knobs

<!--
Spec: docs/build-plan.md §3 (BalanceConfig)

Single source of truth for global simulation knobs. Compiled into a
BalanceConfig Resource by the tuning loader (Prompt 4). SimClock, AgentPool,
and other systems read their tunables from BalanceConfig at startup.

Until the loader lands (Prompt 4), SimClock falls back to in-code defaults that
must match the values below.
-->

## Time

ticks_per_day      = 480
days_per_period    = 7

## Spawn curve

<!-- Spec: design/algorithms/spawn-curve.md -->

spawn_curve_min_multiplier   = 0.25
spawn_curve_max_multiplier   = 3.0
spawn_curve_midpoint         = 0.5
spawn_curve_steepness        = 6.0

## Entities

remove_refund_fraction       = 0.5

## Agents

base_spawn_rate              = 1.0
