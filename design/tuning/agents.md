# Agents — Population definitions

<!--
Spec: docs/build-plan.md §3 (content schema — AgentType, NeedSpec)

Two tables: `## Agent types` defines each population; `## Need specs` attaches
Needs to those populations with per-type overrides. The loader validates that
every agent_id / need_id referenced here exists.

Behavior, value, and satisfaction model scripts are game-side extension
points — they are NOT defined in tuning. Games assign them in code via
ContentDB once content is loaded.
-->

## Agent types

| id      | display_name  | spawn_weight |
| ------- | ------------- | ------------ |
| visitor | Visitor       | 1.0          |
| premium | Premium Guest | 0.3          |

## Need specs

| agent_id | need_id | initial_level | decay_rate_multiplier | threshold |
| -------- | ------- | ------------- | --------------------- | --------- |
| visitor  | hunger  | 1.0           | 1.0                   | 0.3       |
| visitor  | thirst  | 1.0           | 1.0                   | 0.3       |
| premium  | hunger  | 1.0           | 0.7                   | 0.4       |
| premium  | thirst  | 1.0           | 0.7                   | 0.4       |

## Traits

| agent_id | trait         | min  | max  |
| -------- | ------------- | ---- | ---- |
| visitor  | walking_speed | 0.12 | 0.26 |
| premium  | walking_speed | 0.16 | 0.28 |

## Preferences

| agent_id | axis   | preferred | tolerance |
| -------- | ------ | --------- | --------- |
| premium  | thrill | 0.7       | 0.3       |
