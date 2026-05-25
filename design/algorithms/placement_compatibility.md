# Placement Compatibility — Can this placeable go in this region?

Run before every `RegionRegistry.add_placement(...)` and again every time
the build-menu picker filters available placeables. Returns a structured
result so UIs can grey out invalid options with a tooltip explaining why.

See [`enclosure_pattern.md`](enclosure_pattern.md) for the data model and
[`region_detection.md`](region_detection.md) for how regions are derived.

## Intent

Reject placements that would put the region in an obviously broken state:
over space budget, missing a required habitat, or mixing incompatible
species. All other gameplay-quality concerns ("the placement is *valid*
but the placeable will be unhappy") are scored by
[`placeable_happiness.md`](placeable_happiness.md) and don't block
placement.

The "container capacity" concept from the v1 draft is gone — capacity
emerges from `region.area` and `placeable.space_required`. A region with
9 cells holds as many lions as fit at 3 cells each (i.e., 3), no separate
capacity number.

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
- `"missing habitat: <tag>"`
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

    # 2. Habitat
    for tag in candidate_def.required_habitats:
        if tag not in region.provided_habitats:
            return {ok: false, reason: "missing habitat: %s" % tag}

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

Tuning shared across the four specs:

```
Placeables:
  lion:    space_req 3, habitats [grass],        own [predator, big],   incompat [prey]
  zebra:   space_req 2, habitats [grass],        own [prey, herd],      incompat [predator]
  parrot:  space_req 1, habitats [tall_cage],    own [bird, colorful],  incompat []
  penguin: space_req 1, habitats [water, grass], own [bird, social],    incompat []
```

Regions built up from enclosure tiles (see `region_detection.md`):

```
R1 (kind=pen,    area=4, habitats=[grass]):         four grass_pen tiles
R2 (kind=pen,    area=9, habitats=[grass, rocks]):  six grass_pen + three rocky_pen
R3 (kind=aviary, area=8, habitats=[tall_cage, grass]): eight aviary_pen tiles
R4 (kind=pen,    area=12, habitats=[grass, water]): eight grass_pen + four water_pen
```

| # | region | existing placements          | candidate | expected ok | expected reason                |
|---|--------|------------------------------|-----------|------------:|--------------------------------|
| 1 | R1     | []                           | lion      | true        | (3 of 4 space used after)      |
| 2 | R1     | [lion]                       | lion      | false       | "over space: need 3, have 1"   |
| 3 | R1     | [lion]                       | zebra     | false       | "incompatible with Lion"       |
| 4 | R1     | [zebra]                      | lion      | false       | "incompatible with Zebra"      |
| 5 | R1     | []                           | parrot    | false       | "missing habitat: tall_cage"   |
| 6 | R1     | []                           | penguin   | false       | "missing habitat: water"       |
| 7 | R2     | [lion]                       | lion      | true        | (9 area, 6 used after)         |
| 8 | R2     | [lion, lion]                 | lion      | true        | (9 area, 9 used after)         |
| 9 | R2     | [lion, lion, lion]           | lion      | false       | "over space: need 3, have 0"   |
| 10| R3     | []                           | parrot    | true        | (1 of 8 space used after)      |
| 11| R3     | [parrot]×8                   | parrot    | false       | "over space: need 1, have 0"   |
| 12| R4     | []                           | penguin   | true        |                                |
| 13| R4     | [penguin, lion, lion, lion]  | zebra     | false       | "incompatible with Lion"       |
| 14| R4     | [lion]×3                     | lion      | true        | (12 area, 12 used after — exactly full) |
| 15| R4     | [lion]×4                     | lion      | false       | "over space: need 3, have 0"   |

Each row above mirrors one-to-one as a GUT test in
`tests/systems/test_placement_compatibility.gd`. Drift between table and
code is a build failure.
