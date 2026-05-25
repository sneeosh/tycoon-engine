# Progression — Unlock tree

<!--
Spec: docs/build-plan.md §3 (content schema — UnlockNode)

`prerequisites` and `unlocks` are comma-separated id lists.
`unlocks` may point at EntityDefs or AgentTypes — the loader validates against
the union of both registries.
-->

## Unlock nodes

| id              | label          | prerequisites | cost | reputation_required | unlocks    |
| --------------- | -------------- | ------------- | ---- | ------------------- | ---------- |
| basic_food      | Basic Food     |               | 0    | 0                   | food_stand |
| premium_visitor | Premium Guests | basic_food    | 500  | 20                  | premium    |
