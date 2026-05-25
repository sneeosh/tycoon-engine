extends Resource
class_name Need
# Spec: docs/build-plan.md §3 (content schema — Need), Prompt 3.
#
# A generic need an agent can have (hunger, thirst, restroom, restlessness…).
# Borrowed from the RCT peep model. Agents decay this each tick; once it
# crosses a threshold, the agent's behavior seeks an entity whose `satisfies`
# list covers this Need's id.

@export var id: StringName = &""
@export var display_name: String = ""
# How much the need decays per tick (units: level per tick). Higher = faster
# decay. Agents start full (level=1.0); a value of 0.01 means the agent goes
# empty after 100 ticks.
@export_range(0.0, 1.0, 0.0001) var base_decay_per_tick: float = 0.01
# Maps need level (0=empty, 1=full) to a per-tick satisfaction penalty while
# the need is unmet. Null = no penalty curve attached yet; tuning loader will
# point this at one.
@export var penalty_curve: Curve
