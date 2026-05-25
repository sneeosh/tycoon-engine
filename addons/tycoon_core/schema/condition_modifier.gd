extends Resource
class_name ConditionModifier
# Spec: docs/build-plan.md §3 (content schema — ConditionModifier), Prompt 3.
#
# Global state that modulates the sim. Generalizes Weather/Wind/Season/
# market-cycle. When `active`, its `effects` apply globally; Effects elsewhere
# can list this modifier's id under `conditions` to gate their own activation.

@export var id: StringName = &""
@export var label: String = ""
@export var active: bool = false
@export var effects: Array[Effect] = []
