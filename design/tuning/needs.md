# Needs — Agent need catalog

<!--
Spec: docs/build-plan.md §3 (content schema — Need)

Defines the Needs available in this game. AgentTypes attach to these via
`agents.md ## Need specs` rows. EntityDefs cover them via `satisfies` columns.
The loader builds Need Resources from this table; ContentDB.get_need(id) serves
them by id.
-->

## Needs

| id     | display_name | base_decay_per_tick |
| ------ | ------------ | ------------------- |
| hunger | Hunger       | 0.005               |
| thirst | Thirst       | 0.008               |
