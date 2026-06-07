extends Resource
class_name BalanceConfig
# Spec: docs/build-plan.md §3 (content schema — BalanceConfig), Prompt 3.
#
# All global tunable knobs in one Resource. Hand-edited in design/tuning/*.md;
# the loader (Prompt 4) compiles those into a generated .tres at import time.

# Time — mirrors design/tuning/balance.md `## Time`
@export var ticks_per_day: int = 480
@export var days_per_period: int = 7

# Spawn curve — Spec: design/algorithms/spawn-curve.md, mirrors
# design/tuning/balance.md `## Spawn curve`. AgentPool (Prompt 6) reads these.
@export_range(0.0, 10.0) var spawn_curve_min_multiplier: float = 0.25
@export_range(0.0, 10.0) var spawn_curve_max_multiplier: float = 3.0
@export_range(0.0, 1.0) var spawn_curve_midpoint: float = 0.5
@export_range(0.1, 50.0) var spawn_curve_steepness: float = 6.0

# Economy — mirrors design/tuning/economy.md `## Globals`. Ledger (Prompt 2)
# reads `starting_cash` via Ledger.reset() once ContentDB is online.
@export var starting_cash: int = 1000
@export var daily_settlement_enabled: bool = true

# EntityRegistry (Prompt 5) — fraction of total invested (build_cost +
# upgrade costs) refunded when an entity is removed. Mirrors
# design/tuning/balance.md `## Entities`.
@export_range(0.0, 1.0) var remove_refund_fraction: float = 0.5

# AgentPool (Prompt 6) — base spawn rate in agents per second when the
# satisfaction→spawn curve multiplier equals 1.0. Mirrors
# design/tuning/balance.md `## Agents`.
@export_range(0.0, 100.0) var base_spawn_rate: float = 1.0

# Navigation (v0.6.0) — Spec: design/algorithms/navigation.md, mirrors
# design/tuning/navigation.md `## Defaults`. Read by NavigationRegistry /
# the default A* navigator.
# Cost assigned to a walkable cell whose EntityDef.traversal_cost is <= 0.
@export var nav_default_traversal_cost: float = 1.0
# `d` used by within_engagement_distance when the caller passes d < 0.
@export var nav_default_engagement_distance: int = 10
# Fail-soft A* expansion budget (<= 0 = unbounded).
@export var nav_max_path_expansions: int = 4096
