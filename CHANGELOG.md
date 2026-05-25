# Changelog

All notable changes to the Tycoon Engine are recorded here. Games pinning
the engine via submodule should consult this when bumping their pin.

The engine follows semver: `MAJOR.MINOR.PATCH` where MAJOR bumps break
schema/interface compatibility, MINOR bumps add capabilities without
breaking existing games, and PATCH bumps are bug fixes.

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
