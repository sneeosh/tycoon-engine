# Entities — Placeable definitions

<!--
Spec: docs/build-plan.md §3 (content schema — EntityDef, Effect)

Two tables:
  - `## Entities` — one row per EntityDef
  - `## Effects` — Effects attached to entities by `entity_id`

Multi-value columns:
  - `satisfies` is comma-separated Need ids
  - `appeal_profile` is `key:value,key:value` (StringName → float)
  - `conditions` on Effects is comma-separated ConditionModifier ids
-->

## Entities

| id         | display_name | build_cost | maintenance_cost | footprint_x | footprint_y | sprite_key       | satisfies | appeal_profile           |
| ---------- | ------------ | ---------- | ---------------- | ----------- | ----------- | ---------------- | --------- | ------------------------ |
| food_stand | Food Stand   | 300        | 5                | 2           | 2           | food_stand_basic | hunger    | variety:0.6,price:0.3    |
| water_post | Water Post   | 150        | 2                | 1           | 1           | water_post_basic | thirst    | variety:0.2,price:0.1    |

## Effects

| id           | entity_id  | target  | operation | magnitude | proximity | conditions |
| ------------ | ---------- | ------- | --------- | --------- | --------- | ---------- |
| food_revenue | food_stand | revenue | add       | 5.0       | 0.0       |            |
