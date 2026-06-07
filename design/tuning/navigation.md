# Navigation — Pathing defaults

<!--
Spec: design/algorithms/navigation.md

Defaults for agent movement on a WalkableNetwork. Compiled into BalanceConfig
by the tuning loader and read by NavigationRegistry / the default A*
INetworkNavigator.

Per-cell knobs (which tiles are walkable, their per-cell traversal_cost,
network_id, and access tags) are authored per-entity in entities.md, not here
— these are the engine-wide fallbacks and budgets.
-->

## Defaults

default_traversal_cost      = 1.0
default_engagement_distance = 10
max_path_expansions         = 4096
