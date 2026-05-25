extends Resource
class_name UpgradeTier
# Spec: docs/build-plan.md §3 (content schema — UpgradeTier), Prompt 3.
#
# One step along an EntityDef's `upgrade_chain`. Upgrading consumes `cost`
# from the Ledger, swaps the sprite, and appends `added_effects` to the
# entity's active Effect list.

@export var label: String = ""
@export var cost: int = 0
@export var new_sprite_key: StringName = &""
@export var added_effects: Array[Effect] = []
