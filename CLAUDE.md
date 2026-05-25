# CLAUDE.md — Tycoon Engine

Operating rules for any AI coding agent (and human) working in this repository.
Read this fully before making changes. These rules apply to **every** commit.

> Design rationale lives in `docs/build-plan.md`. This file is the *contract*; the
> build plan is the *why*. When they conflict, follow this file and flag it.

---

## 0. What this repository is

This is the **standalone, theme-agnostic Tycoon Engine** — a Godot 4 project that
ships as the addon `addons/tycoon_core/`. It knows nothing about any specific game.

- **Games do not live here.** Golf, Zoo, and future titles are each their *own*
  repository that includes this engine as a **git submodule** at
  `addons/tycoon_core/`, pinned to a tagged release.
- This repo contains the engine, its tests, and **example/test content only** —
  never a real game's content or assets.

---

## 1. The Prime Directive — zero theme logic

**The engine must contain NO theme-specific logic.** No golf, no zoo, no animals,
no holes, no greens fees, no exhibits — nothing tied to a particular game.

If you ever find yourself:
- naming something after a specific domain (`Golfer`, `Exhibit`, `greens_fee`),
- writing an `if game == "golf"` style branch,
- or adding a field that only one game would ever use,

**STOP.** That logic belongs in a game repo via an extension point, not here.
When a needed capability seems to require theme knowledge, the correct move is to
generalize it into a data-driven Resource or an interface the game implements —
or to pause and report the tension rather than leak the abstraction.

**Allowed in the engine:** generic concepts — entities, agents, needs, effects,
money, ticks, satisfaction, progression, conditions.
**Forbidden in the engine:** anything that names or assumes a specific industry.

This directive outranks convenience, speed, and cleverness. Reusability is the
entire point of this codebase.

---

## 2. Repository structure

```
addons/tycoon_core/
  autoload/        # singletons (SimClock, Ledger, EventBus, EntityRegistry,
                   #   AgentPool, ContentDB, ProgressionManager, SaveService)
  schema/          # typed content Resources (EntityDef, AgentType, Need,
                   #   NeedSpec, Effect, UpgradeTier, UnlockNode,
                   #   ConditionModifier, BalanceConfig)
  interfaces/      # extension points (IAgentBehavior, IValueModel,
                   #   ISatisfactionModel, IQualityRating)
  systems/         # effect resolution, appeal matching, spawn loop, etc.
  loader/          # markdown tuning loader
  harness/         # optional headless dev driver (ScriptedSession,
                   #   Screenshotter) — drive a game end-to-end via JSON
                   #   for CI / AI / unattended iteration. Theme-agnostic.
design/
  tuning/          # CANONICAL parameter files (plaintext markdown)
  algorithms/      # algorithm specs with worked examples
tests/             # GUT tests, mirror the structure above
docs/              # build-plan.md and other design docs
```

Engine code lives under `addons/tycoon_core/` so a game repo can include exactly
that folder as a submodule. Tests, design docs, and example content stay at root.

---

## 3. The design-editable layer (HARD RULES)

A game designer must be able to change how the game plays **without opening code
or the Godot editor.** Two mechanisms, two non-negotiable rules:

### 3a. Parameters live in `design/tuning/*.md` — and nowhere else
- All tunable numbers (costs, decay rates, weights, curves, thresholds, the
  satisfaction→spawn curve) live in `design/tuning/*.md` as the **single source
  of truth.**
- A loader compiles these into typed `.tres` Resources at import time. The `.tres`
  files are **generated artifacts** — never hand-edited, never committed as the
  source of truth.
- **Numbers are NEVER hardcoded** in `.gd` files. If you need a constant that a
  designer might ever want to change, it goes in a tuning file.
- Tuning files use a **strict, parseable format**: fixed-column markdown tables or
  `key = value` lines. No free-form prose the loader can't parse.
- The loader **fails loudly** — with file name, line number, and reason — on
  malformed syntax, unknown ids, or out-of-range values. Silent fallback to
  defaults is forbidden; a typo must break the build, not corrupt balance.

### 3b. Algorithms are specified in `design/algorithms/*.md` and enforced by tests
- Every non-trivial algorithm (satisfaction, spawn response, appeal matching,
  effect resolution, quality rating, …) has a spec file with: a plain-English
  description, pseudocode, and a **"Worked Examples"** section giving concrete
  inputs → expected outputs.
- The implementing code carries a header comment citing its spec:
  `# Spec: design/algorithms/satisfaction.md`
- **Each worked example is mirrored one-to-one as a GUT test.** If code drifts
  from the documented formula, a test must go red. The spec is authoritative for
  intent; the test is the contract that keeps them in sync.
- Changing an algorithm means updating the spec (incl. its worked examples) and
  the tests in the same commit. Spec and code never diverge silently.

---

## 4. Architecture (summary — see build-plan.md for detail)

**Autoload singletons:** `SimClock` (time authority), `Ledger` (money source of
truth), `EventBus` (global signal hub), `EntityRegistry` (placed entities +
spatial/type queries), `AgentPool` (pooled agent lifecycle + needs + spawn loop),
`ContentDB` (loads/serves content), `ProgressionManager` (unlocks/reputation),
`SaveService` (serialization).

**Content Resources (data):** `EntityDef`, `UpgradeTier`, `AgentType`, `Need`,
`NeedSpec`, `Effect`, `UnlockNode`, `ConditionModifier`, `BalanceConfig`.

**Extension points (games implement):** `IAgentBehavior`, `IValueModel`,
`ISatisfactionModel`, `IQualityRating`. The engine calls these through a startup
registration step; it never implements them itself (only trivial demos for tests).

**Core tick flow:** `SimClock` ticks → `AgentPool` decays needs / drives behavior
→ agents interact with entities → satisfaction + value update → `Ledger` records.
On `day_ended`: settle, recompute rating, adjust spawn rate from aggregate
satisfaction, check unlocks, autosave.

---

## 5. Coding conventions (Godot 4 / GDScript)

- **Static typing everywhere:** typed vars, params, and return types. No untyped
  `var` where a type is known.
- **`class_name`** for all Resources and reusable classes.
- **Naming:** `snake_case` for files/variables/functions, `PascalCase` for
  `class_name` and node types, `SCREAMING_SNAKE_CASE` for constants.
- **Ids and keys** use `StringName` (`&"hunger"`), not plain strings.
- **Resources for data, Nodes for behavior.** Don't put simulation logic in data
  Resources.
- **Cross-system communication goes through `EventBus`** signals. Avoid systems
  reaching into each other directly. Local signals within a node are fine.
- **Determinism:** the simulation must be reproducible given a seed. All
  randomness comes from a single seeded RNG owned by the sim — never `randi()`
  on the global RNG, never wall-clock time. This keeps save/load exact and tests
  reliable.
- **No leftover debug output.** Use `push_warning` / `push_error` for real
  conditions; remove `print()` before committing.
- **Prefer composition** (injected interface implementations) over inheritance for
  anything a game customizes.

---

## 6. Testing (GUT)

- Every system, schema, and loader ships with GUT tests in the same commit.
- Worked examples from `design/algorithms/*.md` are mirrored as tests (see 3b).
- Tests must run **headlessly** in CI (GitHub Actions). A red test blocks merge.
- Test the seam: where practical, assert that the engine produces correct results
  using *example* content only, with no theme-specific code paths.
- Save/load tests must prove exact round-trip fidelity, including
  game-registered extra state.

---

## 7. Web performance (this engine targets web first)

- **Object pooling is mandatory** in `AgentPool` — reuse instances, never churn.
- Preload content Resources; avoid per-frame allocations in the tick loop.
- Keep the engine core lean; watch node counts and draw calls for scenes with
  many entities/agents.
- **Asset generation is build-time only.** Never generate or fetch assets at
  runtime.

---

## 8. References & licensing (study, never fork)

We may study OpenRCT2 (GPLv3) and OpenTTD (GPLv2) for patterns, math, and design
decisions. **Do not copy their code** — this engine is permissively licensed and
copying copyleft source would infect it. Patterns and formulas are fine to learn
from; source code is not to be reproduced. The same caution applies to any
third-party repo: check its license before borrowing anything.

---

## 9. Versioning

- Tag engine releases (`v0.1.0`, `v0.2.0`, …). Game repos always pin a tag, never
  a moving branch.
- Breaking changes to schemas or interfaces bump the version and are noted in a
  CHANGELOG so games can upgrade deliberately.

---

## 10. How to work here

- **Small, focused commits**, each ending with green tests.
- Follow the build order in `docs/build-plan.md` unless told otherwise.
- When a task seems to need theme-specific logic, **stop and report it** rather
  than leaking it into the engine — that tension is signal, and resolving it
  correctly (generalize vs. push to a game repo) is the most important work here.
- If you're unsure whether something belongs in the engine, ask: *"Would a zoo,
  a hospital, and a railroad all need this?"* If not, it's not engine code.
