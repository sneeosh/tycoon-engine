extends Resource
class_name Effect
# Spec: docs/build-plan.md §3 (content schema — Effect), Prompt 3.
#
# A composable modifier. Generalizes "Pro Shop gives +$15 per nearby golfer"
# and "ICU ward raises patient recovery rate" into one machinery: target field,
# magnitude, proximity, optional conditions.

const TARGET_REVENUE: StringName = &"revenue"
const TARGET_SATISFACTION: StringName = &"satisfaction"
const TARGET_SPAWN_RATE: StringName = &"spawn_rate"
const TARGET_QUALITY: StringName = &"quality"
const TARGET_NEED_DECAY: StringName = &"need_decay"

const OP_ADD: StringName = &"add"
const OP_MULTIPLY: StringName = &"multiply"

@export var id: StringName = &""
# Which sim quantity this Effect touches. One of the TARGET_* constants, or a
# game-defined extension (the engine reads `target` as data, not enum).
@export var target: StringName = TARGET_REVENUE
# How to combine with the base value. ADD = additive; MULTIPLY = scalar.
@export var operation: StringName = OP_ADD
# Signed magnitude. Positive = bonus, negative = penalty.
@export var magnitude: float = 0.0
# Effective radius in tiles. 0 = global (no proximity check).
@export_range(0.0, 1000.0) var proximity: float = 0.0
# Ids of ConditionModifiers that must be active for this Effect to apply. All
# must be active (AND). Empty = always applies.
@export var conditions: Array[StringName] = []
