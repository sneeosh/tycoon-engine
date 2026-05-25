# Region Detection — Connected components of zone tiles

A `Region` is an emergent gameplay unit (zoo exhibit, golf hole, hospital
ward) derived from a connected set of zone-kind tiles on the grid.
When the player places or removes a tile with a non-empty
`EntityDef.zone_kind`, `RegionRegistry` recomputes which regions
exist and which tiles belong to which.

This spec defines that detection.

See [`zone_pattern.md`](zone_pattern.md) for the data model.

## Intent

Reactively maintain a partition of all currently-placed zone tiles
into regions, where two tiles share a region iff they're connected
through a path of edge-adjacent same-kind zone tiles. Recomputation
runs on add and on remove. Add is cheap (the new tile joins at most one
region, or merges several); remove can split a region into multiple
connected components and is the harder case.

## Definitions

- **Tile** — an `EntityInstance` whose `EntityDef.zone_kind` is non-empty.
- **Adjacent** — two cells `a`, `b` such that `b - a ∈ {(0,-1),(0,1),(-1,0),(1,0)}`.
  4-neighborhood by design — diagonal connections create visually
  ambiguous regions ("are those two grass tiles in the same exhibit if
  they only touch at a corner?") and are surprising to players.
- **Same-kind adjacent tiles** — two adjacent tiles `a`, `b` whose
  `EntityDef.zone_kind` are equal.

A **region** is a maximal set of tiles, every pair of which is connected
by a path of same-kind adjacent tiles.

## Inputs

- Whole set of currently-placed zone tiles (from `EntityRegistry`)
- The tile that was just added or removed (the event trigger)

## Output

- An updated `RegionRegistry.regions` dictionary
- Signals emitted on `EventBus`: `region_created`, `region_destroyed`,
  `region_changed`, `placement_stranded`

## Algorithm — incremental updates

### On `entity_placed(instance_id)`

```
function on_tile_placed(t):
    if not is_enclosure_tile(t):
        return

    neighbours = same_kind_adjacent_tiles(t)
    neighbour_region_ids = unique(_tile_membership[n.instance_id] for n in neighbours)

    if len(neighbour_region_ids) == 0:
        # New isolated region.
        r = Region.new()
        r.region_id = _next_region_id++
        r.kind = t.get_def().zone_kind
        r.member_instance_ids = [t.instance_id]
        r.cells = cells_of(t)
        r.provided_zone_tags = list(t.get_def().zone_tags)
        r.area = r.cells.size()
        regions[r.region_id] = r
        _tile_membership[t.instance_id] = r.region_id
        emit region_created(r.region_id)
        return

    if len(neighbour_region_ids) == 1:
        # Extend the existing region.
        rid = neighbour_region_ids[0]
        r = regions[rid]
        r.member_instance_ids.append(t.instance_id)
        r.cells += cells_of(t)
        r.provided_zone_tags = union(r.provided_zone_tags,
                                    t.get_def().zone_tags)
        r.area = r.cells.size()
        _tile_membership[t.instance_id] = rid
        emit region_changed(rid)
        return

    # Multiple neighbour regions → merge them all into the first.
    primary_id = neighbour_region_ids[0]
    primary = regions[primary_id]
    for other_id in neighbour_region_ids[1:]:
        other = regions[other_id]
        primary.member_instance_ids += other.member_instance_ids
        primary.cells += other.cells
        primary.provided_zone_tags = union(primary.provided_zone_tags,
                                          other.provided_zone_tags)
        primary.placements += other.placements   # contents migrate
        for tid in other.member_instance_ids:
            _tile_membership[tid] = primary_id
        regions.erase(other_id)
        emit region_destroyed(other_id)
    primary.member_instance_ids.append(t.instance_id)
    primary.cells += cells_of(t)
    primary.area = primary.cells.size()
    _tile_membership[t.instance_id] = primary_id
    emit region_changed(primary_id)
```

### On `entity_removed(instance_id)`

```
function on_tile_removed(t):
    if not _tile_membership.has(t.instance_id):
        return  # wasn't an zone tile

    rid = _tile_membership[t.instance_id]
    r = regions[rid]
    _tile_membership.erase(t.instance_id)
    r.member_instance_ids.erase(t.instance_id)

    if r.member_instance_ids.is_empty():
        regions.erase(rid)
        for p in r.placements:
            emit placement_stranded(rid, idx_of(p))   # region's gone
        emit region_destroyed(rid)
        return

    # Recompute connected components among the remaining members.
    # If still one component, just shrink in place.
    components = flood_fill_components(r.member_instance_ids)

    if len(components) == 1:
        r.cells = recompute_cells(components[0])
        r.provided_zone_tags = recompute_habitats(components[0])
        r.area = r.cells.size()
        _check_strandings(r)
        emit region_changed(rid)
        return

    # Split: keep the largest component as r (preserves region_id, keeps
    # most placements anchored), create new regions for the others.
    components.sort_by(len, descending=true)
    kept = components[0]
    r.member_instance_ids = kept
    r.cells = recompute_cells(kept)
    r.provided_zone_tags = recompute_habitats(kept)
    r.area = r.cells.size()

    # Reassign placements based on which split component they belong to.
    # A placement belongs to the component whose cells set contains its
    # primary cell (defined as the first cell it was placed on; tracked
    # in Placement.state["primary_cell"], stamped at add time).
    new_regions = []
    for other_component in components[1:]:
        new_r = Region.new()
        new_r.region_id = _next_region_id++
        new_r.kind = r.kind
        new_r.member_instance_ids = other_component
        new_r.cells = recompute_cells(other_component)
        new_r.provided_zone_tags = recompute_habitats(other_component)
        new_r.area = new_r.cells.size()
        for tid in other_component:
            _tile_membership[tid] = new_r.region_id
        regions[new_r.region_id] = new_r
        new_regions.append(new_r)
        emit region_created(new_r.region_id)

    _redistribute_placements(r, new_regions)
    _check_strandings(r)
    for nr in new_regions:
        _check_strandings(nr)
    emit region_changed(rid)
```

`flood_fill_components(tiles)` is standard BFS — pick any tile, walk its
same-kind adjacents transitively, collect into a component, repeat for
uncovered tiles. O(N + E) where N=tile count, E=adjacency edges. At
typical zoo scale (~hundreds of tiles), single-millisecond cost; engine
will refuse to optimize until proven necessary.

`_check_strandings(r)` walks `r.placements` and emits `placement_stranded`
for any whose `space_required` exceeds `r.area` or whose `required_zone_tags`
aren't all present in `r.provided_zone_tags`.

## Worked Examples

Engine examples use abstract zone-tile types; theme-flavored walkthroughs
live in each game's repo.

A 4×4 grid. Cells written as `(x,y)`. Zone tile types:
- `α` = zone_kind `alpha`, zone_tags `[t1]`
- `α'` = zone_kind `alpha`, zone_tags `[t1, t2]` (a variant — same kind, extra tag)
- `β` = zone_kind `beta`,  zone_tags `[t3, t1]`

Placeable fixtures used in rows 9–11:
- `Q` = `space_required=1`, `required_zone_tags=[t1]`
- `Q3` = `space_required=3`, `required_zone_tags=[t1]`
- `Q2` = `space_required=1`, `required_zone_tags=[t2]` (needs the α' variant)

| # | initial state                                                          | event                          | expected outcome                                                                 |
|---|------------------------------------------------------------------------|--------------------------------|----------------------------------------------------------------------------------|
| 1 | empty                                                                  | place α at (1,1)               | Region #1: kind `alpha`, area 1, zone_tags [t1], cells [(1,1)]                   |
| 2 | Region #1 with α at (1,1)                                              | place α at (1,2)               | Region #1 extends: area 2, cells [(1,1),(1,2)]                                   |
| 3 | Region #1: α at (1,1),(1,2)                                            | place α at (3,3)               | Region #2 created at (3,3); #1 unchanged                                         |
| 4 | Region #1: α at (1,1),(1,2); Region #2: α at (3,3)                     | place α at (2,3)               | Region #2 extends to [(3,3),(2,3)]; still no #1 ↔ #2 merge                       |
| 5 | Region #1: α at (1,1),(1,2); Region #2: α at (2,3),(3,3)               | place α at (1,3)               | Merge: #1 absorbs #2 → area 5, cells [(1,1),(1,2),(1,3),(2,3),(3,3)]; #2 destroyed |
| 6 | Region #1: α at (1,1),(1,2)                                            | place α' at (1,3)              | Same kind `alpha` → #1 extends to area 3, zone_tags [t1, t2]                     |
| 7 | Region #1: α at (1,1),(1,2)                                            | place β at (1,3)               | Different kind `beta` → new Region #2: kind `beta`, area 1; #1 unchanged         |
| 8 | Region #1: α at (1,1),(1,2),(1,3),(1,4) (vertical line)                | remove α at (1,2)              | Split: #1 keeps (1,3),(1,4) (the larger; tie-breaker: lowest cell index), #3 created for (1,1) |
| 9 | Region #1: α at (1,1),(1,2),(1,3),(1,4); placement `Q` at (1,3)        | remove α at (1,2)              | Split as in #8; `Q`'s primary_cell=(1,3) stays in #1 (the kept component)        |
| 10| Region #1: α' at (1,1) only; placement `Q2` at (1,1) (needs t2)        | remove α' at (1,1)             | region_destroyed(#1); placement_stranded fires before destroy                    |
| 11| Region #1: α at (1,1),(1,2),(1,3); placement `Q3` (space_required=3)   | remove α at (1,2)              | Split: components [(1,1)] and [(1,3)] — both area 1. `Q3`'s space_required 3 > area 1 → placement_stranded emitted, `Q3` stays in its primary cell's component |

Each row above mirrors one-to-one as a GUT test in
`tests/systems/test_region_detection.gd`. Drift between table and code
is a build failure.

## Performance notes

For a game with a few hundred zone tiles and a handful of regions, even
the full O(N+E) flood fill is sub-millisecond. The engine ships the naive
incremental algorithm and revisits only if profile data shows it matters.
Optimizations available if needed:

- **Union-Find with path compression** for the add path — O(α(N))
  amortized.
- **Cached component IDs** for the remove path so flood-fill only walks
  the now-fragmented region, not the whole tile set.
- **Spatial hash** on `_tile_membership` keyed by cell so
  `region_at_cell` is O(1).

Defer all of these until needed.

## What this spec deliberately does NOT model (yet)

- **Kind-compatibility tables** — currently the rule is "exact same kind."
  Future: an authored `enclosure_compatibility.md` could declare e.g.
  `pen` ↔ `rocky_pen` compatible but `pen` ↔ `aviary` not. MVP keeps the
  one-kind-per-region rule.
- **Diagonal adjacency** — 4-neighborhood only.
- **Tile orientation** — fence/wall pieces that have a "front" side
  don't exist yet; an zone tile is fully isotropic.
- **Gates / openings** — there's no concept of a "visitor entry point"
  on a region yet. Visitors interact with regions as black boxes (a region
  has appeal; visitors near it gain satisfaction). When pathing-aware
  visitors land, a Gate placement (special placeable kind?) will mark the
  cell visitors enter through.
- **Multi-cell zone tiles** — supported by the algorithm (cells of a
  tile = `footprint × position`), but not exercised in worked examples.
