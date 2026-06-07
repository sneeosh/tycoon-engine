# Navigation — Agent movement on a constrained walkable network

Agents move across a player-built network of walkable grid cells toward
goals. This is the generic tycoon primitive behind zoo guests walking
paths to exhibits, theme-park guests walking to rides, hospital patients
walking corridors to departments, mall customers walking aisles to
shelves. The engine knows none of those nouns — only *cells an agent may
traverse, the cost of traversing them, and who may enter them.*

This spec defines:
- the `WalkableNetwork` graph and its structural queries,
- the default A\* `INetworkNavigator` (`find_path`, `step`,
  `reachable_from`, `nearest`, `score_goals`),
- the engagement-distance helper.

Filed by the Zoo Tycoon seam report
(`zoo-tycoon/design/engine_seam_agent_navigation.md`). Theme-agnostic per
`CLAUDE.md` §1.

## Intent

A `WalkableNetwork` is the set of grid cells an agent is allowed to stand
on, plus the 4-neighbour adjacency graph they induce. Each cell carries a
`traversal_cost` (the cost of *entering* it) and an optional set of
`tags`. Tags are **access requirements**: an agent may enter a cell only
if it carries every tag the cell declares (an untagged cell is open to
everyone). Games decide what the tags mean (`staff_only`, `paid`,
`indoor`) — the engine only does subset matching.

The network is **derived, not authored**: `NavigationRegistry` rebuilds it
reactively from the placed `EntityInstance`s whose `EntityDef.walkable`
is true, exactly the way `RegionRegistry` derives regions from zone
tiles. Adding or removing a walkable entity mutates the network and
invalidates cached routes.

## Definitions

- **Cell** — a `Vector2i` grid coordinate that is part of the network.
- **Adjacent** — two cells `a`, `b` with
  `b - a ∈ {(0,-1),(0,1),(-1,0),(1,0)}`. 4-neighbourhood by design (same
  reasoning as `region_detection.md`: diagonal movement through a corner
  gap is visually ambiguous).
- **Enterable** — `can_enter(cell, agent_tags)` is true iff `cell` is in
  the network **and** every tag on `cell` is present in `agent_tags`.
- **Path** — a sequence of cells `[c0, c1, … ck]` where consecutive cells
  are adjacent and every `ci` (for `i ≥ 1`) is enterable by the agent.
  The start `c0` need not be enterable (an agent already standing there
  may leave).
- **Path cost** — `Σ traversal_cost(ci)` for `i` in `1..k` (every cell
  *entered*; the start cell is not paid for).

## Inputs / Output

`find_path(network, from, to, agent_tags, max_expansions)`:
- **Inputs:** the network, start and goal cells, the agent's tag set,
  and an expansion budget (≤ 0 means unbounded).
- **Output:** the lowest-cost path as `Array[Vector2i]` from `from` to
  `to` inclusive, or an empty array when no path exists, the goal is not
  enterable, the start is not in the network, or the budget is exhausted
  (fail-soft).

## Algorithm — A\* search

Standard A\* over the 4-neighbour graph.

```
function find_path(net, from, to, tags, budget):
    if from == to and can_enter(from, tags): return [from]
    if not net.has_cell(from): return []
    if not can_enter(to, tags):              return []

    c_min = net.min_cost()                 # cheapest cell cost in the net
    g = { from: 0 }
    came_from = {}
    open = { from }                        # selection set
    expansions = 0

    while open not empty:
        cur = pop_best(open, g, to, c_min) # see tie-break below
        if cur == to: return reconstruct(came_from, to)
        expansions += 1
        if budget > 0 and expansions > budget: return []   # fail-soft
        for n in neighbours(cur, tags):    # ADJACENCY order, enterable only
            tentative = g[cur] + traversal_cost(n)
            if n not in g or tentative < g[n]:
                g[n] = tentative
                came_from[n] = cur
                open.add(n)
    return []                              # exhausted, no path
```

- **Heuristic:** `h(n) = manhattan(n, to) * c_min`. Admissible because any
  remaining path enters at least `manhattan(n,to)` cells, each costing at
  least `c_min`.
- **`pop_best`** selects the open cell with the lowest `f = g + h`. Ties
  are broken deterministically by: lower `f`, then lower `h`, then lower
  `x`, then lower `y`. This makes the chosen route reproducible (CLAUDE.md
  §5 determinism), which is why the worked examples below have a single
  expected path.
- **Neighbour order** is the `ADJACENCY` constant `[(0,-1),(0,1),(-1,0),
  (1,0)]` (up, down, left, right) — only enterable neighbours are yielded.

### `step(agent, network)` — incremental movement

Per-tick stepping must not recompute a full route every tick (CLAUDE.md
§7, seam report §5). `step` plans once and then walks the cached plan:

```
function step(agent, net):
    target = agent.behavior_state["nav_target"]   # Vector2i, or absent
    if target absent: return NO_STEP
    cur = round(agent.position)
    if cur == target: return NO_STEP              # arrived — nothing to do
    route = agent.behavior_state["nav_route"]     # cached plan
    if route empty or route.back() != target or cur not in route:
        route = find_path(net, cur, target, agent.nav_tags, budget)
        agent.behavior_state["nav_route"] = route
    i = route.find(cur)
    if route.size() < 2 or i < 0 or i+1 == route.size(): return NO_STEP
    return route[i + 1]
```

`NO_STEP` is the sentinel `Vector2i(0x7FFFFFFF, 0x7FFFFFFF)` (the seam
report's `Vector2i.ZERO_INF`; Godot has no such constant). A behavior that
gets `NO_STEP` should re-plan with a fallback goal.

### `reachable_from` / `nearest`

`reachable_from(net, origin, tags)` is a breadth-first flood from `origin`
over enterable cells, returning the set of reachable cells (including
`origin` if it is in the network).

`nearest(net, origin, predicate, tags)` is the same flood, returning the
first cell (fewest hops) for which `predicate.call(cell)` is true, or
`NO_STEP` if none. Among cells at the same hop distance, the lower `(x,y)`
wins (deterministic). The predicate is a game-supplied `Callable` — the
engine never decides what a "goal" is.

### `score_goals(agent, network, candidates)`

Generic helper: given candidate goal cells (`Array[Vector2i]`), returns
`Array[Dictionary]` `[{cell, cost, reachable}]` sorted by ascending path
cost from the agent's current cell (unreachable goals sort last). Games
layer appeal/preference weighting on top — the engine only contributes
*how far* each goal is, never *how desirable.*

## Engagement distance

`within_engagement_distance(cell, target_anchors, d, metric)` answers
"is an agent standing on `cell` close enough to engage a target whose
anchor cells are `target_anchors`?" — the generic form of Zoo Tycoon's
10-tile viewing distance.

- **`MANHATTAN`** (default, matches original Zoo Tycoon): true iff
  `min over anchors of (|dx| + |dy|) ≤ d`. Cheap; ignores walls.
- **`NETWORK`**: true iff the graph distance from `cell` to some anchor is
  `≤ d`, where graph distance to an anchor is the BFS hop count to the
  anchor if it is itself a network cell, or `hops + 1` to the nearest
  network cell 4-adjacent to it otherwise. Realistic (the agent must
  actually be able to walk that close) at higher cost.

## Tuning surface

`design/tuning/navigation.md` `## Defaults`:
- `default_traversal_cost` — cost assigned to a walkable cell whose
  source `EntityDef.traversal_cost` is `≤ 0` (i.e. "unset").
- `default_engagement_distance` — `d` used by
  `NavigationRegistry.within_engagement_distance` when the caller passes
  `d < 0`.
- `max_path_expansions` — the fail-soft A\* budget used by
  `NavigationRegistry.path` / `step`.

Per-`EntityDef` knobs (`design/tuning/entities.md`, all optional): `walkable`,
`traversal_cost`, `network_id`, `walkable_tags`.

## Worked Examples

All examples use abstract cells; coordinates are `(x, y)` with `+y` down.
Each row is mirrored one-to-one by a `test_row_N_*` in
`tests/systems/test_navigation.gd`. Drift is a build failure.

Maps referenced below:

- **Corridor:** cells `(0,0),(1,0),(2,0),(3,0)`, all cost 1, no tags.
- **Ring:** the 3×3 block minus its centre — `(0,0),(1,0),(2,0),(0,1),
  (2,1),(0,2),(1,2),(2,2)`, all cost 1, no tags.
- **Loop:** cells `(0,0),(1,0),(2,0),(0,1),(1,1),(2,1)`, all cost 1.

| # | map / setup | query | expected |
|---|-------------|-------|----------|
| 1 | Corridor | `find_path (0,0)→(3,0)`, tags `[]` | `[(0,0),(1,0),(2,0),(3,0)]`, cost 3 |
| 2 | Two disjoint cells `(0,0)` and `(5,5)` | `find_path (0,0)→(5,5)` | `[]` (unreachable); also `find_path` to a non-network cell → `[]` |
| 3 | Ring | `find_path (1,0)→(1,2)`, tags `[]` | `[(1,0),(0,0),(0,1),(0,2),(1,2)]`, cost 4 (ties to the left by tie-break) |
| 4 | Loop, but `(1,0)` has cost 5 | `find_path (0,0)→(2,0)` | detours: `[(0,0),(0,1),(1,1),(2,1),(2,0)]`, cost 4 (vs 6 across the top) |
| 5 | Loop, but `(1,0)` has tag `staff_only` | `find_path (0,0)→(2,0)` | tags `[]` → `[(0,0),(0,1),(1,1),(2,1),(2,0)]` cost 4; tags `[staff_only]` → `[(0,0),(1,0),(2,0)]` cost 2 |
| 6 | — | `within_engagement_distance` | `cell (3,3)`, anchors `[(3,8)]`: `d=10`→true, `d=4`→false; anchors `[(20,20),(3,6)]`, `d=3`→true (Manhattan) |
| 7 | Ring; goal cells `{(2,0),(2,2)}` | `reachable_from`, `nearest` | `reachable_from((0,0))` = all 8 cells; `nearest((0,0), is_goal)` = `(2,0)` (2 hops, beats `(2,2)` at 4) |
| 8 | Corridor `(0,0),(1,0),(2,0)` | cache then mutate | cache route `(0,0)→(2,0)`; `remove_cell((1,0))` clears the cache and `find_path` now returns `[]`; re-add `(1,0)` and the route is found again |
| 9 | Corridor `(0,0),(1,0),(2,0)`; agent `nav_target=(2,0)` | `step` | at `(0,0)`→`(1,0)`; at `(1,0)`→`(2,0)`; at `(2,0)`→`NO_STEP` (arrived) |

## Performance

Phase-1 web budget (seam report §5): 60 fps with 100+ agents on a
~200-cell network. The default navigator holds this by:

- **Route caching** — `WalkableNetwork` memoises each `(from, to, tags)`
  result; a mutation calls `clear_cache()` (and `NavigationRegistry`
  emits `network_changed(network_id, dirty_rect)` so game consumers can
  drop their own caches). MVP clears the whole cache on any mutation;
  dirty-rect-scoped invalidation is a future optimisation.
- **Incremental stepping** — `step` plans once and pops one cell per
  tick from the stored route; it re-plans only when the route is stale.
- **Fail-soft budget** — `max_path_expansions` caps the search so a
  pathological query can't stall a tick.

`tests/systems/test_navigation_perf.gd` asserts that planning + stepping
100 agents over a 200-cell network completes well inside a 16 ms frame
budget on CI hardware.

## What this spec deliberately does NOT model (yet)

- **Tag-weighted traversal cost / avoidance weights.** The seam report §4
  floated "default traversal costs by cell tag" and "avoidance weights."
  We deliberately keep cell tags to a *single* role — access gating — and
  keep cost a separate authored numeric (`EntityDef.traversal_cost`).
  Overloading one tag namespace to mean both "who may enter" and "how
  expensive" is the kind of muddy abstraction `CLAUDE.md` §10 warns
  against, and the report itself defers avoidance (open question 4). When
  a concrete game needs differentiated per-tag cost, that is a follow-up
  seam where we can decide whether cost-tags and access-tags want separate
  namespaces.
- **Crowd-density / queue avoidance** (seam report open question 4) — a
  separate future seam.
- **Multiple metrics beyond Manhattan/Network** for engagement.
- **Dirty-rect-scoped cache invalidation** — clearing all on mutation is
  the MVP; the `dirty_rect` is already published for consumers.
- **Flow fields** — the seam report's fallback if per-agent A\* proves too
  expensive at scale. Not needed at the Phase-1 budget; revisit on profile
  data.
