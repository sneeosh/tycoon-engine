# Changelog

All notable changes to the Tycoon Engine are recorded here. Games pinning
the engine via submodule should consult this when bumping their pin.

The engine follows semver: `MAJOR.MINOR.PATCH` where MAJOR bumps break
schema/interface compatibility, MINOR bumps add capabilities without
breaking existing games, and PATCH bumps are bug fixes.

## v0.7.0 — 2026-06-16

Spawn-balance seam. `AgentPool.compute_aggregate_satisfaction()` feeds the
self-balancing spawn curve (arrival demand). Until now it averaged over
*every* live agent, so a game adding a second agent population whose
wellbeing is its own meter — not customer happiness — would have that
population's satisfaction leak into guest arrival demand (a miserable
second-population agent suppressing new arrivals). Additive and fully
back-compatible: the new flag defaults to true, so every existing game
behaves exactly as before until it opts a population out.

### Added
- `AgentType.drives_spawn_balance: bool` (default `true`) — when false, the
  population's satisfaction is excluded from the aggregate that drives the
  spawn curve. Author it via the optional `drives_spawn_balance` column in
  the `## Agent types` table of `agents.md`; absent column → true.
- `ContentDB._compile_agents` parses the optional `drives_spawn_balance`
  column.

### Behavior changes
- `AgentPool.compute_aggregate_satisfaction()` now averages only over agents
  whose type drives spawn balance. With no qualifying agents (empty park, or
  a park holding *only* opted-out agents) it returns the neutral 0.5, exactly
  as the empty-park case did before — so arrival demand never collapses to
  zero. A type that can't be resolved is treated as driving (true), matching
  pre-v0.7 behavior.

### Tests
- 6 new GUT tests: schema default, aggregate excludes a non-driving
  population, all-non-driving park stays neutral, a miserable non-driving
  population leaves the spawn multiplier unchanged, plus loader coverage for
  the new column (parsed true/false, and absent → true). Engine suite:
  295 → 301. All green.

## v0.6.1 — 2026-06-07

Patch release. No schema or interface changes — this is the first *tagged*
cut of the navigation surface, so downstream games can pin a real semver tag
instead of a bare commit.

### Fixed
- `ContentDB._compile_entities` parsed the v0.6.0 walkable-network columns
  (`walkable`, `traversal_cost`, `network_id`, `walkable_tags`) nested inside
  the `useful_life_days` branch, so an entities table that set the walkable
  columns *without* a `useful_life_days` column silently skipped them. The
  walkable-column parsing is now un-nested and evaluated independently.

## v0.6.0 — 2026-06-07

Agent navigation on a constrained walkable network — the generic tycoon
primitive behind "agents move on a player-built network of walkable cells
toward goals, with needs decaying during travel." Filed by the Zoo Tycoon
seam report (`zoo-tycoon/design/engine_seam_agent_navigation.md`); every
tycoon game on this engine (paths, aisles, corridors, platforms) needs it,
so it lives in the engine, not a game repo. Additive — existing games are
unaffected until they opt in.

Spec: `design/algorithms/navigation.md` (9 worked examples, all mirrored as
tests).

### Added
- `WalkableNetwork` (`systems/walkable_network.gd`) — runtime graph of the
  cells an agent may stand on, each with a `traversal_cost` and optional
  access `tags`. Structural queries (`has_cell`, `traversal_cost`,
  `can_enter`, `neighbors`, `min_cost`), the engagement-distance helper
  (`within_engagement_distance` with `MANHATTAN`/`NETWORK` metrics), and a
  per-network route cache invalidated wholesale on any mutation. Derived
  runtime data (like `Region`), never authored.
- `INetworkNavigator` (`interfaces/i_network_navigator.gd`) — the pathing
  extension point: `find_path`, `step`, `reachable_from`, `nearest`,
  `score_goals`, plus the `NO_STEP` sentinel. Games override only for path
  preference, per-archetype routing, or avoidance.
- `AStarNetworkNavigator` (`systems/astar_network_navigator.gd`) — the
  shipped default: deterministic A\* over the 4-neighbour graph (admissible
  Manhattan×min-cost heuristic, fixed tie-break), a fail-soft
  `max_path_expansions` budget, and incremental per-tick `step`ping that
  walks a cached route instead of re-planning every tick.
- `NavigationRegistry` autoload — owns the WalkableNetworks (plural; one per
  `network_id` so indoor/outdoor or staff/public stay separate) and the
  bound navigator. Rebuilds networks reactively from placed walkable
  `EntityInstance`s on `entity_placed`/`entity_removed` (the same model as
  `RegionRegistry`), emits `network_changed(network_id, dirty_rect)`, and
  exposes convenience `path`/`reachable_from`/`nearest`/
  `within_engagement_distance` plus `rebuild_all()` (for post-load
  reconstruction) and `set_navigator()`.
- `EventBus.network_changed(network_id, dirty_rect)` signal.
- `IAgentBehavior.decide_next_step(agent)` — parallel hook to
  `decide_next_target`; default delegates to the bound navigator via
  `NavigationRegistry`, so a behavior that doesn't path is untouched.
- `EntityDef` fields (all optional, default off): `walkable: bool`,
  `traversal_cost: float`, `network_id: StringName`,
  `walkable_tags: Array[StringName]`. `ContentDB._compile_entities` parses
  the matching optional columns.
- `BalanceConfig` navigation knobs + `design/tuning/navigation.md`
  (`## Defaults`): `nav_default_traversal_cost`,
  `nav_default_engagement_distance`, `nav_max_path_expansions`. New
  `ContentDB._compile_navigation` compiler.

### Tests
- 30 new GUT tests. `tests/systems/test_navigation.gd` mirrors the 9 spec
  worked examples (simple/blocked/around-obstacle/cost-aware/tag-restricted
  routes, engagement distance, reachable/nearest, cache invalidation,
  incremental stepping) plus fail-soft budget, same-cell, NETWORK-metric,
  and `score_goals`. `tests/autoload/test_navigation_registry.gd` covers the
  reactive build, `network_changed`, plural networks, tuning-default cost,
  the convenience queries, `rebuild_all`, and the `decide_next_step`
  default. `tests/systems/test_navigation_perf.gd` asserts 100 agents on a
  200-cell network hold the 60 fps frame budget (warm stepping
  ~0.14 ms/frame on CI). Engine suite: 265 → 295. All green.

### Design notes
- **Plural networks** (seam open question 1) and **Manhattan engagement by
  default** (open question 2), per the report's stated defaults.
- **Deliberate scope decision:** cell `tags` carry a *single* role — access
  gating (subset rule) — and traversal cost stays a separate authored
  numeric. The seam report §4 floated "traversal cost by tag" and
  "avoidance weights"; overloading one tag namespace to mean both "who may
  enter" and "how expensive" is the muddy abstraction CLAUDE.md §10 warns
  against, and the report itself defers avoidance (open question 4). Both
  are noted in the spec as a follow-up seam for when a concrete game needs
  differentiated per-tag cost.
- Cache invalidation clears the whole route cache on any mutation (MVP);
  the `dirty_rect` is already published so consumers can scope their own.
  Flow-field fallback (report §5) is unneeded at the Phase-1 budget.

## v0.5.0 — 2026-05-25

US-GAAP-style Accounting overlay. The cash-basis `Ledger` continues as the
authority for cash; a new `Accounting` autoload reads from it (and a small
non-cash journal of its own) to produce a real Income Statement and Balance
Sheet at any reporting period. Every tycoon game built on the engine
benefits, and it's a faithful surface for teaching capex vs opex,
straight-line depreciation, retained earnings, and the accounting equation.

Spec: `design/algorithms/accounting.md` (8 worked examples, all mirrored as
tests).

### Added
- `EntityDef.useful_life_days: int` (default 0) — when `> 0`, the asset is
  capitalized as PP&E and depreciated straight-line over N days; when `0`,
  the build cost is recognized as an immediate operating expense (matches
  the cash story, fully backward-compatible with pre-v0.5 tuning files).
- `PlaceableDef.useful_life_days: int` — same semantics for placeables.
- `ContentDB._compile_entities` / `_compile_placeables` parse the new
  optional `useful_life_days` column; absent column defaults to 0.
- `Accounting` autoload — listens to `entity_placed/removed` and
  `placement_added/removed` to maintain an asset register; subscribes to
  `day_ending` to post daily straight-line depreciation (non-cash; tracked
  in `depreciation_journal`, never posted to Ledger). Exposes:
  - `register_category(source_id, Category)` — game-side categorization
    for the IS (`REVENUE`, `COGS`, `OPERATING_EXPENSE`, `OTHER_INCOME`,
    `OTHER_EXPENSE`, `CAPITAL_EXPENDITURE`); uncategorized falls into
    `OTHER_*` so books still balance.
  - `get_income_statement(start_day, end_day)` and convenience wrappers
    `_today` / `_for_period` / `_for_month` / `_all_time`.
  - `get_balance_sheet(as_of_day)` and `_today` — returns assets (cash,
    PP&E gross, accumulated depreciation, PP&E net), liabilities (0 for
    v1), equity (starting capital + retained earnings), plus a
    `balances` bool and `balance_check_delta` for verifying the
    accounting equation.
  - Disposal P&L: on `entity_removed`/`placement_removed`, computes book
    value, compares to the just-posted Ledger refund, and journals a
    gain (`OTHER_INCOME`) or loss (`OTHER_EXPENSE`). The refund cash is
    *not* double-counted on the IS — its source is marked
    `CAPITAL_EXPENDITURE` and excluded from `OTHER_INCOME` aggregation.

### Tests
- 17 new GUT tests in `tests/autoload/test_accounting.gd`: 8 mirror the
  spec's worked examples; 9 cover schema wiring, gain on disposal, full-
  life depreciation summing exactly to cost, uncategorized fallback, and
  the period-convenience wrappers. Engine suite: 248 → 265. All green.

### Design notes
- Depreciation timing: an asset acquired on day D begins depreciating on
  day D's settlement (the half-year-convention analogue, simpler than
  mid-period proration).
- Asset disposal: `Accounting` reads the just-posted refund from the tail
  of `Ledger.transactions` (matched by `source_id`), rather than parsing
  `sell_<def_id>` conventions. No coupling pressure on Ledger; all the
  disposal logic stays inside Accounting.
- Depreciation is a **non-cash expense** — Accounting does not post to
  Ledger, so the cash balance reported on the BS remains the Ledger's
  truth.

## v0.4.0 — 2026-05-25

Container/contents pattern. Players build regions by placing zone-kind
tiles on the grid; regions emerge from connected components; placeables
go INSIDE regions. The generic "zoo exhibit / hospital ward / golf hole"
shape every tycoon eventually wants.

Specs (all in `design/algorithms/`):
- `zone_pattern.md` — overview, schema, extension points, lifecycle
- `region_detection.md` — connected-components algorithm (add/remove/merge/split)
- `placement_compatibility.md` — incompat → zone tags → space check order
- `region_appeal.md` — saturation aggregation modulated by happiness model

### Added
- `EntityDef.zone_kind: StringName` + `EntityDef.zone_tags: Array[StringName]`
  — when `zone_kind` is non-empty, the entity is a zone tile and
  participates in region detection.
- `PlaceableDef` Resource — the thing that goes INSIDE a region. Has
  build/maintenance cost, space accounting, zone-tag requirements,
  own/incompatible tags for compatibility, appeal_contribution, plus
  engine-passive metadata (`social_min/max`, `needs_provided_tags`) that
  game-side `IPlaceableHappiness` impls consume.
- `Placement` Resource — runtime state for one placeable in one region.
  Engine reads `state["primary_cell"]` (override) and
  `state["attitude"]` (multiplier on happiness, default 1.0); never
  writes either.
- `Region` runtime class — derived state; `region.area` is the cells count.
- `IPlaceableHappiness` interface — engine ships a no-op default
  (returns 1.0). Games register their own via
  `EffectResolver.register_happiness_model(impl)`.
- `RegionRegistry` autoload — reactive to `entity_placed`/`entity_removed`,
  maintains the regions dictionary, exposes `can_add_placement`,
  `add_placement`, `remove_placement`, `region_at_cell`, `region_for_tile`,
  `all_regions`. Mirrors `region_*` and `placement_*` signals from
  EventBus for caller convenience.
- `EffectResolver.compute_region_appeal(region)` + `appeal_match_region(...)`
  — saturation aggregation per `region_appeal.md`.
- `ContentDB` parses optional `## Placeables` section in `placeables.md`
  and optional `zone_kind` / `zone_tags` columns on `entities.md`.
  Cross-ref validation: every `required_zone_tags` must be providable
  by some zone tile.
- Per-placement maintenance auto-registered as a recurring expense on
  `add_placement` and unregistered on `remove_placement` — same pattern
  as `EntityDef.maintenance_cost` since v0.3.0.

### Tests
- 36 new GUT tests: 11 region_detection, 15 placement_compatibility, 10
  region_appeal. Engine suite: 212 → 248. All green.

### Internal
- `EffectResolver.appeal_match` refactored to delegate to
  `_appeal_match_against_profile(agent_type, profile)`, so both the
  static-EntityDef and dynamic-Region appeal paths share the scoring math.

## v0.3.1 — 2026-05-24

Patch release surfaced by zoo's first attempt at trait-driven agents:
the schema fields existed and AgentPool sampled them at spawn, but
ContentDB had no parser for them, so games couldn't actually populate
them from `design/tuning/*.md` without writing setup code.

### Added
- `ContentDB._compile_agents` parses two new optional sections in
  `agents.md`:
  - `## Traits` — per-axis sampling ranges. Columns: `agent_id`,
    `trait`, `min`, `max`. Each row contributes one trait; AgentPool
    samples uniformly from [min, max] at spawn and writes to
    `agent.traits[trait]`. Inverted ranges (min > max) and unknown
    `agent_id`s are flagged as load_errors with file:line.
  - `## Preferences` — type-level appeal-match parameters. Columns:
    `agent_id`, `axis`, `preferred`, `tolerance`. Consumed by
    `EffectResolver.appeal_match(agent_type, entity_def)`. Type-level
    (not per-agent); use traits for per-agent variation.
- 4 new tests covering happy-path + error reporting; engine suite:
  208 → 212.

### Internal
- Engine's example `design/tuning/agents.md` now demonstrates both
  sections so games have a working reference. The shipped values are
  example-only — games override per their own tuning.

## v0.3.0 — 2026-05-24

CTO/QA review pass: ships the P0/P1/P2/P3 items identified in the v0.2.0
post-mortem. No schema breaks; existing games continue to load, but
behavior changes (see "Behavior changes") may shift balance numbers a
hair — re-run any tuning that assumed the old timings.

### Added
- `EventBus.day_ending` signal — fires *before* `day_ended` so
  pre-settlement listeners (revenue effects) can post to the just-ending
  day. Use `day_ending` for "post transactions for today"; keep
  `day_ended` for "react to settled day" (autosave, UI refresh,
  spawn-curve resets).
- `AgentPool.count_targeting(inst_id: int) -> int` — cheap query for
  "how many agents are heading to this entity right now", enabling
  anti-swarm behaviors without a custom reverse index.
- `Ledger.register_recurring()` now returns `bool` and validates the
  rule (non-empty id, non-negative amount, known kind, known period).
  Bad rules log a push_warning with file:line and refuse to register
  instead of silently corrupting balances.
- `ContentDB._validate_cross_refs` runs a DFS over the unlock graph
  and flags cycles as load errors (file:line). Previously a cyclic
  prerequisite chain made `try_unlock` spin forever.
- `SaveService.register_migration(from_version, callable)` and
  matching `unregister_migration` — register one-step migrations that
  chain to upgrade old saves on load. Without a registered migration,
  older payloads fail loudly with a "missing migration step" message
  instead of "version unsupported".
- 17 new tests covering all of the above; engine suite: 191 → 208.

### Behavior changes
- `EntityDef.maintenance_cost` is now actually consumed. On placement
  the engine registers a per-instance daily recurring expense
  (`maint_<instance_id>`); on removal it unregisters. Previously the
  field was loaded from tuning but silently ignored. Existing games
  with `maintenance_cost > 0` in their entities tuning will start
  paying that overhead daily — adjust starting cash or tuning numbers
  if balance is now negative.
- `EffectResolver` revenue effects fire on `day_ending` (not
  `day_ended`) so income lands in the day it was earned for. The
  yesterday-breakdown HUD now correctly reflects today's revenue.
  Spawn-rate effects still fire on `day_ended` (after AgentPool resets
  the curve, so the multiplier composes instead of being overwritten).
- `AgentPool._spawn_from_weighted_types()` iterates agent types in
  sorted-id order so two runs with the same RNG seed pick the same
  type sequence. Previously Dictionary iteration order leaked
  implementation-defined ordering into the simulation.

### Performance
- `EffectResolver` now caches a flat `(instance, effect)` list,
  rebuilt only on `entity_placed` / `entity_removed` /
  `entity_upgraded`. Per-tick `compute_*_for(agent)` calls iterate
  the cache directly instead of re-traversing every entity's effect
  chain — O(effects) instead of O(entities × effects per entity).

### Internal
- CHANGELOG semver rules clarified at top of file.

## v0.2.0 — 2026-05-24

### Added
- `addons/tycoon_core/harness/` — optional headless driver for unattended
  iteration (CI, AI-driven development, scripted scenarios).
  - `ScriptedSession` replays a JSON action list against the engine
    autoloads (place, remove, spawn, warmup, set_speed, screenshot,
    save/load, force_unlock, several `assert_*` checks). Games extend it
    with custom actions via `register_action(name, callable)`.
  - `Screenshotter` is the one-shot convenience: `TYCOON_SHOT=path.png[:ticks]`
    fast-forwards and snaps a PNG of the host's viewport. Useful for
    visually verifying a single moment without writing a JSON script.
  - Both helpers are theme-agnostic and additive — existing games can
    ignore them entirely.
- `CHANGELOG.md` (this file).

### Internal
- 11 new GUT tests in `tests/harness/` covering action dispatch, custom
  registration, and malformed-input handling (engine suite: 180 → 191).

## v0.1.0 — 2026-05-23

Initial public release.

### Included
- Autoloads: `SimClock`, `Ledger`, `EventBus`, `EntityRegistry`,
  `AgentPool`, `ContentDB`, `EffectResolver`, `ProgressionManager`,
  `SaveService`.
- Content schema: `EntityDef`, `UpgradeTier`, `AgentType`, `Need`,
  `NeedSpec`, `Effect`, `UnlockNode`, `ConditionModifier`, `BalanceConfig`.
- Extension interfaces: `IAgentBehavior`, `IValueModel`,
  `ISatisfactionModel`, `IQualityRating`.
- Markdown tuning loader (`design/tuning/*.md` → typed Resources).
- 180 GUT tests; deterministic single-RNG simulation; save/load
  round-trip including game-registered state providers.
