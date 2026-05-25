# Tycoon Engine — Design & Build Plan

A reusable, theme-agnostic tycoon simulation engine in **Godot 4**, web-first, with golf as its first plugged-in game. This doc is meant to ride along into Claude Code as a reference and prompt source.

---

## 1. Design philosophy

A tycoon game, stripped of theme, is always the same six systems:

1. **Economic loop** — money in, money out, profit reinvested.
2. **Time progression** — ticks, days, fiscal periods.
3. **Buildable entities** — things the player places and upgrades.
4. **Agents** — the simulated population that flows through entities and converts them into value.
5. **Progression gates** — unlocks, tech trees, reputation tiers.
6. **Balance layer** — the tunable numbers, kept in data, not code.

None of those six knows what golf is. The entire discipline of a reusable engine is this:

> **The engine defines generic systems and interfaces. A game provides content (data Resources) plus a few small adapter scripts that implement game-specific behavior through defined extension points. Golf logic must never leak into engine code.**

If golf-specific concepts (holes, greens fees, par) appear anywhere in the engine, you don't have an engine — you have a golf game with extra steps.

---

## 2. What the OpenGolf repo already proves

The existing golf project independently discovered most of the right patterns. That's not waste — it's the empirical map of where the engine/game seam falls. Mapping existing pieces to their generic form:

| OpenGolf (golf-fused)                | Generic engine form                  |
|--------------------------------------|--------------------------------------|
| `EventBus` autoload                  | `EventBus` (keep the pattern as-is)  |
| `GameManager` god-object             | Split into `SimClock` + `Ledger` + `ProgressionManager` |
| `DayNightSystem` + speed controls    | `SimClock` (tick/time authority)     |
| Budget tracking, daily settlement    | `Ledger` (economic source of truth)  |
| `BuildingRegistry`                   | `EntityRegistry`                     |
| `GolferManager`                      | `AgentPool`                          |
| `buildings.json`                     | `EntityDef` Resources                |
| `golfer_traits.json`                 | `AgentType` Resources                |
| Pro Shop proximity revenue           | `Effect` (composable modifier)       |
| `CourseRatingSystem`                 | `IQualityRating` (game-implemented)  |
| Reputation + clubhouse tiers         | `ProgressionManager`                 |
| `WeatherSystem` / `WindSystem`       | `ConditionModifier`                  |
| `SaveManager`                        | `SaveService`                        |
| Ball physics, pathfinding, shots     | **Stays in the golf module** — golf's implementation of `IAgentBehavior` |

The last row is the whole point: ball physics and shot modifiers are *not* engine concerns. They're golf's private implementation of a generic interface.

---

## 3. Architecture

### Repo strategy *(decided)*
**One engine repo, one repo per game.** The engine lives in its own standalone Git repository (a Godot project shipping the addon `addons/tycoon_core/`). Each game — golf, zoo, future titles — is its own separate repository that pulls the engine in as a **git submodule** at `addons/tycoon_core/`, pinned to a tagged engine release. Benefits: each game pins a known-good engine version and upgrades deliberately (bump the submodule when ready); the engine stays independently testable and versioned; a fix in the engine propagates to games on their schedule, not by surprise. Tag engine releases (`v0.1.0`, …) so game repos always point at a tag, never a moving branch.

### Engine autoloads (singletons)
1. **`SimClock`** — the time authority. Advances ticks, emits `tick`, `day_ended`, `period_ended`. Owns pause / play / fast-forward speed state. Everything time-based subscribes here.
2. **`Ledger`** — economic single source of truth. Cash on hand, registers of recurring income/expense, a transaction log, and daily settlement. Nothing else tracks money; everything *reports* to the Ledger.
3. **`EventBus`** — global signal hub for decoupling (keep your existing pattern).
4. **`EntityRegistry`** — tracks all placed entities, their state and upgrades; supports spatial/type queries (needed for proximity effects).
5. **`AgentPool`** — spawns, pools, and despawns agents; owns agent lifecycle. **Pooling is mandatory** (web performance + you flagged it as missing in golf).
6. **`ContentDB`** — loads and serves all content Resources at startup; the data access layer.
7. **`ProgressionManager`** — unlocks, prerequisites, reputation tiers, gating.
8. **`SaveService`** — serializes engine state plus any game-registered extra state.

### Content schema (typed Godot Resources)
These are the data types a game authors. All `class_name`d, inspector-editable, no manual parsing.

- **`EntityDef`** — id, display name, build cost, footprint, maintenance cost, `upgrade_chain: Array[UpgradeTier]`, `effects: Array[Effect]`, `satisfies: Array[StringName]` (which Needs this entity can satisfy, e.g. `&"hunger"`), `appeal_profile: Dictionary` (named axes → values; generalizes RCT's excitement/intensity/nausea), sprite key.
- **`AgentType`** — id, spawn weight, trait ranges, `needs: Array[NeedSpec]`, `preferences: Dictionary` (named appeal axes → preferred value + tolerance), satisfaction model ref, value behavior ref.
- **`Need`** / **`NeedSpec`** — *(borrowed from the RCT peep model)* a `Need` defines an id, display name, base decay rate, and the satisfaction-penalty curve as the need goes unmet; a `NeedSpec` attaches a `Need` to an `AgentType` with per-type decay/threshold overrides. An agent seeks an entity whose `satisfies` list covers a need that has crossed its threshold.
- **`Effect`** — the key abstraction. What it touches (revenue / satisfaction / spawn-rate / quality), magnitude, range/proximity, conditions. This single type makes "Pro Shop gives +$15 per nearby golfer" the *same machinery* as "ICU ward raises patient recovery rate."
- **`UpgradeTier`** — cost, new effects, new sprite key.
- **`UnlockNode`** — id, prerequisites, cost, what it unlocks.
- **`ConditionModifier`** — global state that modulates the sim (weather, wind, season, market cycle). Generalizes Weather/Wind.
- **`BalanceConfig`** — one Resource holding global tunable numbers, including the **satisfaction→spawn curve** (see below). The designer-facing tuning surface.

### Extension points (how a game customizes without forking the engine)
The engine can't know how golf scores a round or how a restaurant seats a table. It exposes interfaces the game implements as small GDScript classes, registered at startup:

- **`IAgentBehavior`** — per-tick agent logic (golf: play hole; restaurant: order→eat→leave).
- **`IValueModel`** — how an agent converts service into money/reputation.
- **`ISatisfactionModel`** — how satisfaction is computed and updated.
- **`IQualityRating`** — how the establishment's quality/star rating is computed (generalizes `CourseRatingSystem`).

### Signal flow — one tick
```
SimClock emits `tick`
  → AgentPool decays each agent's Needs; if a Need crosses threshold,
    the agent's IAgentBehavior seeks an entity whose `satisfies` covers it
    → agents interact with entities (EntityRegistry queries)
      → ISatisfactionModel updates happiness (needs met ↑, unmet/waits ↓)
      → IValueModel produces value events on EventBus
        → Ledger records transactions
On SimClock `day_ended`:
  → Ledger settles daily income/costs
  → IQualityRating recomputes establishment rating
  → AgentPool reads aggregate satisfaction → sets tomorrow's spawn rate
    via the BalanceConfig satisfaction→spawn curve
  → ProgressionManager checks unlocks
  → SaveService autosaves
```
Generic, golf-free, and exactly the loop the golf repo already runs informally.

### The satisfaction→spawn feedback loop *(borrowed from RCT)*
The economic loop is self-balancing: aggregate agent satisfaction modulates how many new agents arrive. Happy customers → more arrivals → more revenue; unhappy customers → fewer arrivals → pressure to improve. This single feedback rule is what makes a tycoon game *feel* alive, and it lives generically in `AgentPool` + `BalanceConfig`, not in any game. (It also fills the "golfer needs" gap the golf repo listed as unimplemented.)

### Appeal matching *(generalized from RCT's excitement/intensity/nausea)*
Each entity exposes an `appeal_profile` (named axes); each `AgentType` has `preferences` over those axes. A generic match function scores how well an agent likes an entity, feeding `IValueModel` and `ISatisfactionModel`. Golf might use axes like `difficulty`/`scenery`; a theme park would use `thrill`/`nausea`. Same machinery, different axis names — defined purely in data.

---

## 4. Golf as the proof case

When you plug golf in later, the mapping is:

- **Hole** → `EntityDef` (assembled from tee/green/flag placement).
- **Golfer** → `AgentType` + a golf `IAgentBehavior` that owns the shot/ball/pathfinding code (lives in the golf module, not the engine).
- **Green fee** → a `Ledger` income rule.
- **Pro Shop proximity revenue** → an `Effect`.
- **Course rating** → golf's `IQualityRating` implementation.
- **Weather / wind** → `ConditionModifier` instances.
- **Tournaments** → a golf-specific event built on `SimClock` + `ProgressionManager`.

If all of that maps cleanly and ball physics never touches engine code, the seam is correct.

### The design-editable layer (plaintext tuning + algorithm specs)
The designer must be able to change how the game plays without opening code or the Godot editor. Everything designer-facing lives in a `design/` directory of plaintext markdown, split by purpose:

```
design/
  tuning/          # PARAMETERS — canonical, machine-read
    economy.md         # starting cash, fee rules, settlement
    agents.md          # agent types, need decay rates, preferences
    entities.md        # entity costs, footprints, effects, satisfies/appeal
    progression.md     # unlock tree: prerequisites, costs
    balance.md         # global knobs incl. satisfaction→spawn curve
  algorithms/      # LOGIC SPECS — authoritative intent + worked examples
    satisfaction.md
    spawn.md
    appeal-match.md
    effect-resolution.md
    quality-rating.md
```

Two rules keep this from rotting into stale documentation:

1. **Tuning files are read, not copied.** A loader parses `design/tuning/*.md` into the runtime Resources at import time, so the markdown *is* the source of truth — there's no second copy of the numbers in code. The files use a strict parseable convention (fixed-column tables or `key = value` lines), and the loader fails loudly with a clear error on a malformed file or out-of-range value, exactly like ContentDB's broken-reference detection. A designer never edits a `.tres` or a `.gd` to change balance.

2. **Algorithm specs are enforced by tests.** Each `algorithms/*.md` describes one algorithm in plain English plus pseudocode, and ends with a **Worked Examples** section (concrete inputs → expected outputs). Those examples are mirrored one-to-one as GUT test cases, and the implementing code carries a header comment citing its spec path (`# Spec: design/algorithms/satisfaction.md`). If code drifts from the documented formula, a test goes red. The spec is authoritative for intent; the test is the contract.

The honest cost: this needs a small markdown loader and the discipline of writing worked examples. The payoff is a designer who tunes and even re-specs the game in plaintext, and specs an AI coding agent can read directly — which is exactly your workflow.

---

## 5. Key decisions (recommendations — override as you like)

- **Data format: plaintext markdown is the designer-owned source of truth; Resources are the compiled runtime form.** Designers edit numbers in `design/tuning/*.md`; a loader compiles those into typed `.tres` Resources at import time. There is exactly one hand-authored copy (the markdown) — the `.tres` are generated, never edited by hand. This keeps tuning accessible in any text editor and clean in git diffs, while the engine still runs on fast typed Resources. (See "The design-editable layer" in section 3.) *(This supersedes the earlier .tres-canonical idea and also moves away from the golf project's JSON-at-runtime approach.)*
- **Validate with a throwaway non-golf game first.** Before plugging in golf, build a deliberately trivial second domain (e.g. a lemonade-stand / food-cart tycoon) on the engine. A second domain is the only real test that the abstraction holds — golf alone can't prove reusability.
- **Web performance is a design constraint, not a later fix:** mandatory object pooling in `AgentPool`, preloaded Resources, a lean engine core, and **build-time** asset generation (never runtime). Godot 4 web export is far lighter than Unity WebGL but still rewards discipline on draw calls and node counts for 18+ entity scenes.
- **Keep your existing infra:** GUT tests, GitHub Actions CI, and Cloudflare Wrangler web deploy all carry over. The engine should ship with GUT scaffolding from commit one.

---

## 6. External architecture & MCPs

- **Pixel Lab MCP** — wire into Claude Code from day one. Server `https://api.pixellab.ai/mcp` (HTTP transport, Bearer token from your account; requires your active paid subscription). Gives Claude Code `create_character` (4/8 directional), `animate_character`, and `create_tileset` directly in the editor; a Python SDK (`pip install pixellab`) exists for batch pipelines.
- **Subscription assumption: middle tier (~$24/mo, max ~400×400px, priority queue, limited concurrency).** *(Decided — dial up to the $50 tier later if concurrency or resolution bites.)* Practical consequences for the manifest: keep individual sprite targets comfortably under 400×400 (tycoon sprites — characters, tiles, building icons — are typically 16–128px, so this is rarely a constraint); for anything larger, compose from tiles rather than one big image. Because concurrency is limited at this tier, treat batch generation as roughly sequential — don't design the pipeline to assume many parallel jobs.
- **Asset manifest** — a Godot Resource mapping logical keys (`entity.zoo_lion_exhibit.sprite`) to files. The engine *never* hardcodes a path; it asks the manifest. Generating a new game's art becomes: run the manifest's entries through Pixel Lab → drop into the game's content folder → engine picks them up unchanged. Store target dimensions in the manifest so generation requests stay within tier limits automatically.
- **Generation mode: build-time, committed assets.** Best for web payload control. Runtime generation is off the table for web.
- **GitHub MCP (optional)** — useful for issue/PR-driven workflow in Claude Code, but not required.

---

## 7. Claude Code prompt sequence

Run these roughly in order. Each is self-contained, ends with tests, and assumes a `CLAUDE.md` describing the engine philosophy lives at repo root.

### Prompt 0 — Bootstrap
```
Scaffold a standalone Godot 4 project that will become a reusable, theme-agnostic
tycoon engine shipped as an addon at addons/tycoon_core/. Create the folder
structure for engine autoloads, content Resource schemas, and extension-point
interfaces, plus a top-level design/ directory with tuning/ and algorithms/
subfolders. Set up GUT for unit testing and a placeholder GitHub Actions workflow
that runs the tests headlessly. Write a CLAUDE.md at repo root stating these
standing rules that ALL later work must follow:
  1. The engine must contain ZERO theme-specific logic (no golf, no specific
     industry); games provide content Resources plus adapter scripts implementing
     defined interfaces.
  2. Designer-facing PARAMETERS live only in design/tuning/*.md as the single
     source of truth, in a strict parseable format (fixed-column tables or
     `key = value` lines). They are compiled into runtime Resources by a loader;
     numbers are NEVER hardcoded in .gd or hand-edited in .tres. The loader must
     fail loudly with a clear message on malformed or out-of-range values.
  3. Every non-trivial algorithm has a spec in design/algorithms/<name>.md with
     plain-English logic, pseudocode, and a "Worked Examples" section. The
     implementing code cites its spec path in a header comment, and each worked
     example is mirrored as a GUT test so code/spec drift fails the build.
Do not implement systems yet — just the skeleton, the test harness, the design/
folders with one example tuning file and one example algorithm spec demonstrating
the conventions, and the CLAUDE.md.
```

### Prompt 1 — SimClock
```
Implement the SimClock autoload: the engine's time authority. It advances the
simulation in discrete ticks and emits `tick`, `day_ended`, and `period_ended`
signals via the EventBus. It owns speed state (paused / playing / fast-forward)
and a configurable ticks-per-day. No game-specific concepts. Write GUT tests
covering tick advancement, day rollover, speed changes, and pause behavior.
```

### Prompt 2 — Ledger
```
Implement the Ledger autoload as the single source of truth for money. Support:
cash balance, a register of recurring income sources and recurring expenses, a
transaction log, and a daily settlement triggered on SimClock's `day_ended`.
Other systems must report transactions to the Ledger rather than tracking money
themselves. Expose query methods for current balance and yesterday's income/
expense breakdown. Write GUT tests for transactions, recurring settlement, and
the breakdown queries.
```

### Prompt 3 — Content schema Resources
```
Create the typed content Resource classes (class_name) the engine consumes:
EntityDef, UpgradeTier, AgentType, Need, NeedSpec, Effect, UnlockNode,
ConditionModifier, and BalanceConfig — per the schema in the build plan. Effect
must be a composable modifier (target field, magnitude, range/proximity,
conditions) general enough to express both proximity revenue bonuses and stat
modifiers. EntityDef must include `satisfies` (which Needs it covers) and an
`appeal_profile` dictionary; AgentType must include `needs` (Array[NeedSpec]) and
a `preferences` dictionary over appeal axes. BalanceConfig must include a
configurable satisfaction→spawn curve. Add export hints so all are
inspector-editable. Include one example .tres of each for tests. No loading logic
yet — just the schemas.
```

### Prompt 4 — ContentDB + markdown tuning loader
```
Implement the ContentDB autoload plus the design/tuning markdown loader. The
loader parses design/tuning/*.md (strict format: fixed-column tables or
`key = value` lines) and compiles them into the typed content Resources at import
time — the markdown is the single source of truth; generated .tres are never
hand-edited. ContentDB then serves Resources by id and validates references
between them (e.g. an UnlockNode pointing at a missing EntityDef errors clearly).
The loader must fail loudly with file/line context on malformed syntax, unknown
ids, or out-of-range values. Provide an example tuning file per category. Write
GUT tests for: parsing each tuning format, compilation into correct Resources,
id lookup, broken-reference detection, and clear failure on malformed input.
```

### Prompt 5 — EntityRegistry
```
Implement the EntityRegistry autoload: tracks all placed entity instances, their
current upgrade tier and state. Support queries by type and by spatial proximity
(needed for Effect resolution). Provide place/remove/upgrade operations that
report costs to the Ledger. Write GUT tests for placement, upgrade, removal with
refund, and proximity queries.
```

### Prompt 6 — AgentPool + IAgentBehavior + needs loop
```
Implement the AgentPool autoload with mandatory object pooling (reuse instances,
never churn). Define the IAgentBehavior interface (per-tick agent logic) and the
ISatisfactionModel interface. Agents are driven by an AgentType plus injected
behavior/satisfaction implementations. Each tick, decay each agent's Needs per its
NeedSpecs; when a Need crosses threshold, the behavior should seek an entity whose
`satisfies` covers it (query EntityRegistry). On day_ended, compute aggregate
satisfaction and set the next day's spawn rate via the BalanceConfig
satisfaction→spawn curve (the self-balancing feedback loop). Include a trivial demo
behavior + satisfaction model, clearly marked as demo, not engine. Write GUT tests
for spawn, pool reuse, despawn, need decay/threshold seeking, and the
satisfaction→spawn adjustment.
```

### Prompt 7 — Effect resolution + appeal matching
```
Implement the system that resolves Effects each relevant tick/day: for each active
entity, apply its Effects to the right targets (revenue via Ledger, satisfaction/
spawn-rate/quality via the appropriate systems), honoring range/proximity and
conditions. Also implement the generic appeal-match function: score how well an
AgentType's `preferences` fit an EntityDef's `appeal_profile`, and expose that
score to IValueModel and ISatisfactionModel. This is the bridge between placed
entities and simulation outcomes. Write GUT tests proving (a) a proximity revenue
Effect produces correct Ledger income given nearby agents, and (b) appeal match
scoring behaves correctly for aligned vs mismatched preferences.
```

### Prompt 8 — ProgressionManager
```
Implement the ProgressionManager autoload: loads UnlockNodes, tracks which are
unlocked, checks prerequisites and costs, and emits unlock events on the EventBus.
Support a generic reputation/tier value that gates unlocks. No game-specific tiers
hardcoded. Write GUT tests for prerequisite gating, cost deduction via Ledger, and
unlock events.
```

### Prompt 9 — SaveService
```
Implement the SaveService autoload: serialize and restore full engine state
(Ledger, EntityRegistry, SimClock, ProgressionManager) plus a registration hook so
a game can add its own extra state to the save payload. Support named slots and
autosave on day_ended. Write GUT tests for round-trip save/load fidelity including
game-registered extra state.
```

### Prompt 10 — Validation game: minimal Zoo Tycoon
```
In a SEPARATE new git repository (not the engine repo), create a deliberately
minimal Zoo Tycoon that consumes the engine as a git submodule at
addons/tycoon_core/ pinned to the latest engine tag. Keep it a PLUMBING TEST,
not a full game: a few EntityDefs (2-3 animal exhibits + 1 food stand + 1
restroom), one visitor AgentType, and small adapter scripts implementing
IAgentBehavior, IValueModel, ISatisfactionModel, and IQualityRating. Keep agent
needs TRIVIAL for this pass (e.g. a single "hunger" need with a gentle curve) so
you're testing the engine's plumbing, not balance tuning. All numbers live in
design/tuning/*.md per the standing rules. Goal: prove the engine runs an
end-to-end economic loop (visitors arrive → buy tickets/food → satisfaction drives
spawn → daily settlement) with ZERO changes to the engine submodule. Document any
place you were tempted to edit the engine — those are seam leaks to fix in the
engine repo, then re-pin.
```
*Note: this stripped zoo exists only to validate the engine. A full Zoo Tycoon —
two agent populations (visitors + animals), animal welfare as its own system,
exhibit suitability, breeding — becomes a proper game build later, in this same
repo, once the engine is proven.*

### Later — Golf integration (after the engine feels good)
```
In a SEPARATE repository (the existing OpenGolf project, restructured to consume
the engine as a submodule at addons/tycoon_core/ pinned to a tag), plug the golf
systems into the engine as a thin game module: golf holes as EntityDefs, golfers
as an AgentType with the existing shot/ball/pathfinding logic moved into a golf
IAgentBehavior, green fees as Ledger rules, the course rating as an IQualityRating
implementation, weather/wind as ConditionModifiers, tournaments as a
progression-driven event. All tunable numbers move into design/tuning/*.md. Ball
physics and pathfinding must live entirely in the golf module — if any of it needs
to touch engine code, stop and report the seam violation.
```

---

## 8. References & borrowed patterns (study, don't fork)

**Licensing rule, non-negotiable:** the heavyweight references are copyleft. Read them for patterns, math, and design decisions — never copy code into this engine, which we're keeping permissive. Patterns aren't copyrightable; source is.

| Source | License | What to learn from it | Copy code? |
|--------|---------|----------------------|------------|
| **OpenRCT2** (RollerCoaster Tycoon 2, C/C++) | GPLv3 | Guest/peep AI, needs simulation, ride excitement/intensity/nausea ratings, park reputation, finance, scenario objectives. The gold standard for this genre. | **No** |
| **OpenTTD** (Transport Tycoon, C++) | GPLv2 | Supply/demand economy, cargo routing — relevant if a future game in the series is logistics-flavored. | **No** |
| **freettd** (Transport Tycoon in Godot) | check repo | Same-engine reference: how others structure autoloads/scenes/data in GDScript. Small/unverified. | Only if license allows |
| **hwtycoon** (Hardware Tycoon in Godot 4) | check repo | Same-engine GDScript structure reference. Small/unverified. | Only if license allows |
| **Game Programming Patterns** (Nystrom, free online) | reference text | The theory behind our autoloads — see mapping below. | N/A (concepts) |

**Game Programming Patterns → our systems:**
- *Game Loop* + *Update Method* → `SimClock` / per-tick dispatch
- *Event Queue* → `EventBus`
- *Object Pool* → `AgentPool` (confirms the mandatory pooling)
- *Component* → entity composition via `Effect`s
- *Type Object* + data-driven design → `EntityDef` / `AgentType` Resources

**What we borrowed from the RCT model (already folded into the schema above):** per-agent needs with decay and thresholds, facility-seeking when a need crosses threshold, happiness that decays over time and responds to met/unmet needs, the satisfaction→spawn feedback loop, and the appeal-profile/preference match generalized from excitement/intensity/nausea.

---

## 9. Resolved decisions
- **Repo strategy:** one standalone **engine repo**; **one repo per game** (golf, zoo, …), each consuming the engine as a git submodule pinned to a tagged release. *(See section 3.)*
- **Data format:** plaintext **markdown tuning files are canonical**, compiled into typed `.tres` Resources at import; `.tres` are generated, never hand-edited. Algorithm logic lives in `design/algorithms/*.md` with worked-examples-as-tests. *(Supersedes the earlier JSON option; see sections 3 & 5.)*
- **Validation domain:** a **minimal Zoo Tycoon** (Prompt 10), kept to a plumbing test with trivial needs; full Zoo Tycoon becomes a real game afterward.
- **Pixel Lab tier:** middle (~$24/mo, ~400×400px), dial up later if needed; manifest stores per-asset target sizes and the pipeline assumes limited concurrency. *(See section 6.)*

## 10. Suggested build order recap
0 Bootstrap → 1 SimClock → 2 Ledger → 3 Schema → 4 ContentDB + markdown loader → 5 EntityRegistry → 6 AgentPool + needs → 7 Effects + appeal → 8 Progression → 9 SaveService → 10 Minimal Zoo validation → *(then)* Golf integration → *(then)* full Zoo as a real game.
