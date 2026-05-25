# Placement Compatibility — Can this placeable go in this container?

Run before every `EntityRegistry.add_placement(...)` and again every time
the build-menu picker filters available placeables. Returns a structured
result so UIs can grey out invalid options with a tooltip explaining why.

See [`container_pattern.md`](container_pattern.md) for the schema this
operates on.

## Intent

Reject placements that would put the container in an obviously broken state:
over capacity, over its space budget, missing a required habitat, or mixing
incompatible species. All other gameplay-quality concerns (a placement is
"valid" but the placeable will be unhappy) are scored separately by
[`placeable_happiness.md`](placeable_happiness.md) — they don't block
placement.

## Inputs

- `container_def` — `EntityDef` with container fields set
- `placements` — `Array[Placement]` currently in this container instance
- `candidate_def` — `PlaceableDef` the caller wants to add
- For each existing placement, the corresponding `PlaceableDef` is looked
  up via `ContentDB.placeable_defs[placement.placeable_def_id]`

## Output

A `Dictionary` with this shape:

```
{
  "ok":     bool,
  "reason": String   # only meaningful when ok == false
}
```

Stable reason prefixes so UIs can switch on them:

- `"over capacity"`
- `"over space"` (followed by `: need N, have M`)
- `"missing habitat: <tag>"`
- `"incompatible with <existing.display_name>"`

## Pseudocode

```
function can_place(container_def, placements, candidate_def):
    # 1. Capacity
    if len(placements) + 1 > container_def.container_capacity:
        return {ok: false, reason: "over capacity"}

    # 2. Space
    space_used = sum(ContentDB.placeable_defs[p.placeable_def_id].space_required
                     for p in placements)
    if space_used + candidate_def.space_required > container_def.container_space_total:
        return {ok: false, reason: "over space: need %d, have %d" %
                [candidate_def.space_required,
                 container_def.container_space_total - space_used]}

    # 3. Habitat
    for tag in candidate_def.required_habitats:
        if tag not in container_def.container_provided_habitats:
            return {ok: false, reason: "missing habitat: %s" % tag}

    # 4. Incompatibility — symmetric. Either side declaring the other's
    #    tags as a deal-breaker blocks placement.
    for existing in placements:
        existing_def = ContentDB.placeable_defs[existing.placeable_def_id]
        if any(tag in candidate_def.incompatible_tags for tag in existing_def.own_tags):
            return {ok: false, reason: "incompatible with %s" % existing_def.display_name}
        if any(tag in existing_def.incompatible_tags for tag in candidate_def.own_tags):
            return {ok: false, reason: "incompatible with %s" % existing_def.display_name}

    return {ok: true, reason: ""}
```

## Worked Examples

Tuning for all examples (zoo flavor):

```
Containers:
  small_pen: capacity 2, space_total 9, habitats [grass]
  large_pen: capacity 5, space_total 16, habitats [grass, rocks]
  aviary:    capacity 8, space_total 9,  habitats [tall_cage, grass]
  aquarium:  capacity 4, space_total 12, habitats [water]

Placeables:
  lion:    space_req 3, habitats [grass], own [predator, big],   incompat [prey]
  zebra:   space_req 2, habitats [grass], own [prey, herd],      incompat [predator]
  parrot:  space_req 1, habitats [tall_cage], own [bird, colorful], incompat []
  penguin: space_req 1, habitats [water, grass], own [bird, social], incompat []
```

| # | container | existing      | candidate | expected ok | expected reason                |
|---|-----------|---------------|-----------|------------:|--------------------------------|
| 1 | small_pen | []            | lion      | true        | (empty reason)                 |
| 2 | small_pen | [lion]        | lion      | true        | (2/2 capacity, 6/9 space)      |
| 3 | small_pen | [lion, lion]  | lion      | false       | "over capacity"                |
| 4 | small_pen | [lion, lion]  | zebra     | false       | "over capacity"                |
| 5 | small_pen | [lion]        | zebra     | false       | "incompatible with Lion"       |
| 6 | small_pen | [zebra]       | lion      | false       | "incompatible with Zebra"      |
| 7 | small_pen | []            | parrot    | false       | "missing habitat: tall_cage"   |
| 8 | small_pen | []            | penguin   | false       | "missing habitat: water"       |
| 9 | aquarium  | []            | penguin   | false       | "missing habitat: grass"       |
| 10| aviary    | []            | parrot    | true        | (1/8 capacity, 1/9 space)      |
| 11| aviary    | [parrot]×8    | parrot    | false       | "over capacity"                |
| 12| large_pen | [lion×5]                          | lion  | false | "over capacity"             |
| 13| large_pen | [lion×4]                          | lion  | true  | (5/5 capacity, 15/16 space) |
| 14| aviary    | [parrot×8]                        | parrot| false | "over capacity"             |
| 15| large_pen | [lion×4] (12/16 space)            | zebra | false | "incompatible with Lion" *  |
| 16| large_pen | []                                | zebra | true  |                             |

\* Row 15: zebra would fit by capacity (5/5) and space (14/16) but lion's
`incompat [prey]` matches zebra's `own [prey]`, so the compatibility check
rejects it before space is even relevant. Incompatibility is symmetric;
either side's `incompatible_tags` matching the other's `own_tags` blocks.

(Capacity is checked before space, space before habitat, habitat before
incompatibility. The order isn't load-bearing for correctness — only one
rejection wins — but it determines which message the player sees first.)

Each row above must mirror one-to-one as a GUT test in
`tests/systems/test_placement_compatibility.gd`. Drift between table and
code is a build failure.
