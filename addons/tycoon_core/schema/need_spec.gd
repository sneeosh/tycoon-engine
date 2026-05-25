extends Resource
class_name NeedSpec
# Spec: docs/build-plan.md §3 (content schema — NeedSpec), Prompt 3.
#
# Attaches a Need to an AgentType with per-type overrides. Two AgentTypes can
# share a single `Need` resource but tune their own decay rates and thresholds.

@export var need: Need
# Level at spawn (0=empty, 1=full).
@export_range(0.0, 1.0) var initial_level: float = 1.0
# Multiplied with `Need.base_decay_per_tick` to get this AgentType's decay.
@export_range(0.0, 10.0) var decay_rate_multiplier: float = 1.0
# Once level falls below this, the agent's behavior starts seeking a satisfier.
@export_range(0.0, 1.0) var threshold: float = 0.3
