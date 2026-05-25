extends Resource
class_name UnlockNode
# Spec: docs/build-plan.md §3 (content schema — UnlockNode), Prompt 3.
#
# One node in the progression graph. Locked until all `prerequisites` are
# unlocked AND `reputation_required` is met; unlocking consumes `cost` from
# the Ledger and grants the ids in `unlocks` (entity defs, agent types, etc).

@export var id: StringName = &""
@export var label: String = ""
@export var prerequisites: Array[StringName] = []
@export var cost: int = 0
@export var reputation_required: int = 0
# Ids of things this node unlocks. The engine treats these as opaque — the
# ProgressionManager (Prompt 8) marks them available; downstream systems
# (EntityRegistry, AgentPool, ContentDB) interpret them per their own type.
@export var unlocks: Array[StringName] = []
