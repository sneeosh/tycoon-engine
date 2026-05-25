# Conditions — Global state modifiers

<!--
Spec: docs/build-plan.md §3 (content schema — ConditionModifier)

ConditionModifiers represent global state like weather, season, market cycle.
When active, an Effect that lists this condition's id under `conditions` is
gated on it.

Effects attached to a ConditionModifier (global effects when active) are
defined inline here in a future iteration; for now this file just declares
the conditions themselves so other tables can reference them.
-->

## Conditions

| id       | label    | active |
| -------- | -------- | ------ |
| daylight | Daylight | true   |
| rain     | Rain     | false  |
