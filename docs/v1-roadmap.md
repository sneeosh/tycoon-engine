# Road to v1.0 — surface audit & additive API proposal

> **Status: proposal, not built.** This document audits the current engine
> surface against the two downstream features hard-gated on engine `v1.0` —
> a **research/husbandry tree** and a **scenario editor** — and proposes the
> *minimal additive* API needed to support them without future breaking
> changes. Anything that would force a breaking change is called out in the
> [Breaking-change watchlist](#breaking-change-watchlist) so it can be
> batched and landed deliberately before the 1.0 freeze.
>
> Nothing here ships until each item gets its own spec + worked examples +
> GUT coverage, per `CLAUDE.md` §3/§6. The point of writing it now is to
> lock the *shape* of the 1.0 surface while breaks are still cheap.

## Why this matters

After `v1.0` the published surface is a stability contract: the interfaces,
EventBus signals, autoload methods, schema fields, and tuning columns that
the Zoo Tycoon game (and future games) bind to. Adding to that surface is
safe forever; **renaming or reshaping it is a major bump**. So the goal is to
front-load any unavoidable reshaping now, and design the new capabilities as
pure additions.

The stable consumer contract today (do not reshape without a major bump):
`IAgentBehavior` / `IValueModel` / `ISatisfactionModel` / `IQualityRating` /
`IPlaceableHappiness` / `INetworkNavigator`; the `EventBus` signals;
`SaveService.register_game_state_provider` / `register_migration`;
`ProgressionManager`; `SimClock`; `RegionRegistry` / `Region` / `Placement`
(`Placement.state` is game-owned — engine reads only `attitude`);
`ContentDB`; `Ledger`; `AgentPool`; `EntityRegistry`.

---

## Part A — Current progression surface (what exists today)

**`UnlockNode`** (`schema/unlock_node.gd`):
`id`, `label`, `prerequisites: Array[StringName]`, `cost: int`,
`reputation_required: int`, `unlocks: Array[StringName]`.

**`ProgressionManager`** (`autoload/progression_manager.gd`):
- `reputation: int` — a single generic gating counter.
- `unlocked: Dictionary` — acquired node ids.
- `try_unlock(id)` — gates on prereqs + `reputation_required` + Ledger
  balance ≥ `cost`, charges `cost` as a Ledger **expense**, marks unlocked,
  emits `unlock_acquired`.
- `can_unlock(id)`, `force_unlock(id)`, `is_id_available(id)`,
  `set_reputation` / `add_reputation` (emit `reputation_changed`),
  `save_state` / `load_state`.

**`ContentDB` / loader** (`progression.md` → `## Unlock nodes`):
parses the table; `_validate_cross_refs` checks prerequisites resolve,
`unlocks` ids resolve to an entity **or** agent type, and `_detect_unlock_cycles`
rejects cyclic prerequisite graphs.

### What already supports the v1.0 features

- **The unlock graph is already a DAG, not a linear chain.** `prerequisites`
  is a list and cycles are rejected, so a *tree* (or arbitrary DAG) of
  research nodes is authorable **today** with zero engine change. The phrase
  "replacing the linear unlock chain" is a content decision, not an engine
  gap — the engine never assumed linearity.
- **`ContentDB.load_all(dir)` already accepts an arbitrary directory** (the
  test suite drives it that way). Loading a scenario's tuning bundle from a
  non-default folder is already possible.
- **Save migrations already exist** (`register_migration`), so growing the
  save payload for new progression/scenario state is a solved, non-breaking
  problem.

---

## Part B — Feature 1: research / husbandry tree

**Game intent:** spend *earned points* on tech / husbandry / amenity nodes.

### Gaps

1. **No spendable progression currency.** Unlock cost is *money* (`cost` →
   Ledger expense) and `reputation_required` is a *threshold*, not a spent
   resource. A research economy needs a counter you **earn over time and
   spend** on nodes — and likely **more than one** (research vs. husbandry
   vs. amenity points) so trees can be gated independently.
2. **No node categorization.** `UnlockNode` can't say it belongs to the
   "tech" vs. "husbandry" vs. "amenities" branch, which the UI and the
   point-pool routing will want.

### Proposed additive API

**Generalize gating into named meters — without removing `reputation`.**
Add a generic named-counter facility to `ProgressionManager`:

```
# ProgressionManager (additive)
var meters: Dictionary = {}                      # StringName -> int
func get_meter(id: StringName) -> int
func add_meter(id: StringName, delta: int) -> void      # emits meter_changed
func set_meter(id: StringName, value: int) -> void
func spend_meter(id: StringName, amount: int) -> bool   # false if insufficient
# EventBus (additive)
signal meter_changed(meter_id: StringName, value: int)
```

`reputation` stays as-is (its own field, method, and signal) for back-compat;
internally it MAY be re-expressed as `meters[&"reputation"]` **only if** the
existing `reputation` / `set_reputation` / `reputation_changed` surface keeps
delegating unchanged. (See the watchlist — this is the one spot where getting
it wrong becomes a break.)

**`UnlockNode` additive fields** (all optional, default-empty = today's
behavior):

```
@export var category: StringName = &""              # "tech" | "husbandry" | ...
@export var meter_costs: Dictionary = {}            # StringName -> int, spent on unlock
@export var meter_requirements: Dictionary = {}     # StringName -> int, threshold gate
```

`try_unlock` extends additively: after the existing money/reputation gates,
also require every `meter_requirements` met and every `meter_costs` affordable,
then `spend_meter` each atomically (all-or-nothing). Nodes with empty dicts
behave exactly as today. `cost` (money) and `reputation_required` are
untouched, so existing tuning is unaffected.

**Loader (`progression.md`)** — parse optional columns: `category`, and
`meter_costs` / `meter_requirements` as `key:value,key:value` cells (the same
multi-value convention already used for `appeal_profile`). Cross-ref: a node
referencing a meter id no other node/source ever grants is a *warning*, not
an error (a game may grant meters purely in code).

> **Theme check:** points, meters, and categories are generic
> ("research", "husbandry", "amenities" are author-supplied StringNames; the
> engine ships none of them). A zoo, a hospital, and a railroad can all use a
> named-meter economy. ✅

---

## Part C — Feature 2: scenario editor

**Game intent:** author/edit scenarios — starting conditions, which content
is enabled, and objectives / win conditions — then play or share them.

### Gaps

1. **No scenario bundle.** Starting cash lives in `economy.md`, clock config
   in `balance.md`, content across the other tuning files. There's no single
   authorable "scenario" object describing *initial state* (starting cash,
   clock, pre-unlocked nodes, initial `ConditionModifier` states, time limit)
   as a unit the editor reads and writes.
2. **No objective / win-condition concept** anywhere in the engine. This is
   the only genuinely new primitive.
3. **Runtime content authoring is unguarded.** `ContentDB` exposes mutable
   dictionaries but no *validate-after-mutation* entry point; an editor that
   adds/edits defs at runtime needs to re-run cross-ref validation and learn
   whether the result is loadable.

### Proposed additive API

**`ScenarioDef` resource** (new schema type; authored in a new optional
`design/tuning/scenarios.md`, or supplied at runtime by the editor):

```
class_name ScenarioDef
@export var id: StringName
@export var display_name: String
@export var starting_cash: int = -1          # -1 = inherit economy.md
@export var ticks_per_day: int = -1          # -1 = inherit balance.md
@export var day_limit: int = 0               # 0 = open-ended
@export var preunlocked: Array[StringName] = []
@export var initial_conditions: Dictionary = {}   # condition_id -> bool active
@export var objectives: Array[ObjectiveDef] = []
```

**`ObjectiveDef` resource + a thin evaluation interface.** Keep the engine
theme-agnostic by expressing an objective as a generic comparison over engine
quantities, evaluated by a game-supplied interface for anything richer:

```
class_name ObjectiveDef
@export var id: StringName
@export var metric: StringName     # &"cash" | &"reputation" | &"meter:<id>"
                                   #   | &"entities_of:<def_id>" | &"day"
@export var comparator: StringName # &">=" | &"<=" | &"=="
@export var target: float
@export var by_day: int = 0        # 0 = no deadline

# IScenarioObjective (extension point) — games register custom metrics the
# generic evaluator can't express. Engine ships a default that handles the
# built-in metrics above.
```

**`ScenarioRunner` autoload (or thin service)** — applies a `ScenarioDef` to
the engine at start (set cash via `Ledger.reset`, configure `SimClock`,
`force_unlock` the preunlocked set, set condition states), evaluates
objectives on `day_ended`, and emits:

```
# EventBus (additive)
signal objective_completed(objective_id: StringName)
signal scenario_succeeded(scenario_id: StringName)
signal scenario_failed(scenario_id: StringName)   # e.g. day_limit hit
```

**`ContentDB` additive API for the editor:**

```
func validate() -> bool            # re-run _validate_cross_refs, refresh load_errors
func load_from(dir: String) -> void  # alias making the existing load_all(dir) intent explicit
```

(The mutate-then-`validate()` loop lets an editor apply an edit and surface
errors with the same file/line discipline the loader already uses.)

> **Theme check:** scenarios, objectives, and metrics are generic. The only
> caution is keeping the built-in metric vocabulary engine-level (cash, day,
> reputation, meters, entity counts); anything game-specific routes through
> `IScenarioObjective`, never into engine code. ✅

---

## Breaking-change watchlist

These are the items to **decide and land before the 1.0 freeze**, because
getting them wrong later is a major bump:

1. **Meter model vs. `reputation`.** Shipping the named-meter economy is the
   highest-leverage decision. It can be *fully additive* if `reputation`
   keeps its standalone field/method/signal (optionally delegating to
   `meters[&"reputation"]` under the hood). The break only happens if a
   future version tries to *remove* `reputation` in favor of meters — so the
   decision to land now is "meters are additive, reputation is permanent."
   Lock this before 1.0.
2. **`UnlockNode.cost` semantics.** `cost` is money (Ledger). Do **not**
   overload it for research points — add `meter_costs` instead. Renaming
   `cost` → `money_cost` for symmetry would be a break; if we want that
   symmetry, do it **before** 1.0 or never.
3. **Save payload growth.** Meters + scenario progress + objective state grow
   the `SaveService` payload. This is handled by `register_migration` (not a
   contract break), but the `SAVE_VERSION` bump + migration must ship *with*
   the feature, never after.
4. **`unlocks` cross-ref union.** If amenity/husbandry nodes need to grant ids
   that are neither `EntityDef` nor `AgentType` (e.g. a `PlaceableDef` or a
   pure capability flag), widen the `_validate_cross_refs` union additively
   when those id-kinds land — but settle the *set* of grantable kinds before
   1.0 so the validator doesn't churn.
5. **Objective metric vocabulary.** The built-in `metric` keywords are part
   of the contract once games author against them. Fix the initial vocabulary
   (`cash`, `day`, `reputation`, `meter:<id>`, `entities_of:<id>`) before 1.0;
   extend only via `IScenarioObjective` afterward.

Everything else in Parts B and C is purely additive and can land in minor
releases on the way to 1.0.

## Suggested sequencing

- **v0.8.0 — progression meters.** Named meters + `meter_changed`,
  `UnlockNode.category` / `meter_costs` / `meter_requirements`, loader columns,
  save migration. Unblocks the research/husbandry tree.
- **v0.9.0 — scenario surface.** `ScenarioDef` / `ObjectiveDef`,
  `IScenarioObjective`, `ScenarioRunner`, scenario EventBus signals,
  `ContentDB.validate()`. Unblocks the scenario editor.
- **v1.0.0 — freeze.** Resolve the watchlist, write the CHANGELOG migration
  notes, tag the stable surface. No new primitives in the freeze release.
