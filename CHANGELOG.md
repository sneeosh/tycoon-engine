# Changelog

All notable changes to the Tycoon Engine are recorded here. Games pinning
the engine via submodule should consult this when bumping their pin.

The engine follows semver: `MAJOR.MINOR.PATCH` where MAJOR bumps break
schema/interface compatibility, MINOR bumps add capabilities without
breaking existing games, and PATCH bumps are bug fixes.

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
