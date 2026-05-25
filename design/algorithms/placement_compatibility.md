# Placement Compatibility — Can this placeable go in this region?

Run before every `RegionRegistry.add_placement(...)` and again every time
the build-menu picker filters available placeables. Returns a structured
result so UIs can grey out invalid options with a tooltip explaining why.

See [`zone_pattern.md`](zone_pattern.md) for the data model and
[`region_detection.md`](region_detection.md) for how regions are derived.

## Intent

Reject placements that would put the region in an obviously broken state:
over space budget, missing a required zone tag, or mixing incompatible
placeables. All other gameplay-quality concerns ("the placement is
*valid* but the placeable will be unhappy") are scored by the registered
`IPlaceableHappiness` implementation (see `zone_pattern.md`) and don't
block placement.

There is no separate "capacity" number — it emerges from `region.area`
and `placeable.space_required`. A region with 9 cells holds as many
3-space placeables as fit (i.e., 3).

## Inputs

- `region` — `Region` from `RegionRegistry`
- `candidate_def` — `PlaceableDef` the caller wants to add
- For each existing placement in `region.placements`, the corresponding
  `PlaceableDef` is looked up via `ContentDB.placeable_defs`

## Output

A `Dictionary` with this shape:

```
{
  "ok":     bool,
  "reason": String   # only meaningful when ok == false
}
```

Stable reason prefixes so UIs can switch on them:

- `"over space"` (followed by `: need N, have M`)
- `"missing zone tag: <tag>"`
- `"incompatible with <existing.display_name>"`

## Pseudocode

```
function can_place(region, candidate_def):
    # 1. Space
    space_used = sum(ContentDB.placeable_defs[p.placeable_def_id].space_required
                     for p in region.placements)
    space_free = region.area - space_used
    if candidate_def.space_required > space_free:
        return {ok: false, reason: "over space: need %d, have %d" %
                [candidate_def.space_required, space_free]}

    # 2. Zone tags
    for tag in candidate_def.required_zone_tags:
        if tag not in region.provided_zone_tags:
            return {ok: false, reason: "missing zone tag: %s" % tag}

    # 3. Incompatibility — symmetric. Either side declaring the other's
    #    tags as a deal-breaker blocks placement.
    for existing in region.placements:
        existing_def = ContentDB.placeable_defs[existing.placeable_def_id]
        if any(tag in candidate_def.incompatible_tags for tag in existing_def.own_tags):
            return {ok: false, reason: "incompatible with %s" % existing_def.display_name}
        if any(tag in existing_def.incompatible_tags for tag in candidate_def.own_tags):
            return {ok: false, reason: "incompatible with %s" % existing_def.display_name}

    return {ok: true, reason: ""}
```

## Worked Examples

Engine specs use abstract fixtures — the engine doesn't ship lions or
operating rooms. Per-game flavored walkthroughs (e.g. zoo's
`animal_happiness.md`) demonstrate the same algorithms with concrete
content.

```
Placeables:
  P_A: space_req 3, required_zone_tags [t1],     own [markX],         incompat [markY]
  P_B: space_req 2, required_zone_tags [t1],     own [markY],         incompat [markX]
  P_C: space_req 1, required_zone_tags [t2],     own [markZ],         incompat []
  P_D: space_req 1, required_zone_tags [t2, t3], own [markZ],         incompat []
```

Regions built up from zone tiles (see `region_detection.md`):

```
R1 (kind=alpha, area=4,  provided_zone_tags=[t1]):       4 zone-α tiles with tag t1
R2 (kind=alpha, area=9,  provided_zone_tags=[t1, t4]):   6 + 3 zone-α tiles (second set provides t4)
R3 (kind=beta,  area=8,  provided_zone_tags=[t2, t1]):   8 zone-β tiles
R4 (kind=alpha, area=12, provided_zone_tags=[t1, t3]):   12 zone-α tiles (some provide t3)
```

| # | region | existing placements          | candidate | expected ok | expected reason                  |
|---|--------|------------------------------|-----------|------------:|----------------------------------|
| 1 | R1     | []                           | P_A       | true        | (3 of 4 space used after)        |
| 2 | R1     | [P_A]                        | P_A       | false       | "over space: need 3, have 1"     |
| 3 | R1     | [P_A]                        | P_B       | false       | "incompatible with P_A"          |
| 4 | R1     | [P_B]                        | P_A       | false       | "incompatible with P_B"          |
| 5 | R1     | []                           | P_C       | false       | "missing zone tag: t2"           |
| 6 | R1     | []                           | P_D       | false       | "missing zone tag: t2"           |
| 7 | R2     | [P_A]                        | P_A       | true        | (9 area, 6 used after)           |
| 8 | R2     | [P_A, P_A]                   | P_A       | true        | (9 area, 9 used after)           |
| 9 | R2     | [P_A, P_A, P_A]              | P_A       | false       | "over space: need 3, have 0"     |
| 10| R3     | []                           | P_C       | true        | (1 of 8 space used after)        |
| 11| R3     | [P_C]×8                      | P_C       | false       | "over space: need 1, have 0"     |
| 12| R4     | []                           | P_D       | false       | "missing zone tag: t2"           |
| 13| R4     | [P_A, P_A, P_A]              | P_B       | false       | "incompatible with P_A"          |
| 14| R4     | [P_A]×3                      | P_A       | true        | (12 area, 12 used after — full)  |
| 15| R4     | [P_A]×4                      | P_A       | false       | "over space: need 3, have 0"     |

Each row above mirrors one-to-one as a GUT test in
`tests/systems/test_placement_compatibility.gd`. Drift between table and
code is a build failure.
