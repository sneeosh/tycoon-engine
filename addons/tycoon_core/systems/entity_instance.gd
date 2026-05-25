extends RefCounted
class_name EntityInstance
# Spec: docs/build-plan.md §3 (EntityRegistry), Prompt 5.
#
# Runtime state for one placed entity. The EntityDef is the *type* (authored
# content); EntityInstance is the *instance* (what the player actually built).
# Theme-agnostic — a placed exhibit, a placed hole, and a placed ICU bed are
# all EntityInstances of different EntityDefs.
#
# Not a Resource: this is mutable runtime state created by the engine, not
# content authored in tuning files. SaveService (Prompt 9) serializes the
# registry's instances en masse rather than per-Resource.

var instance_id: int = 0
var entity_def_id: StringName = &""
var position: Vector2i = Vector2i.ZERO
# 0 = base; tier N means upgrade_chain[0..N-1] have been applied cumulatively.
var upgrade_tier: int = 0
# Game-side free-form runtime state. Engine doesn't inspect it.
var state: Dictionary = {}


func get_def() -> EntityDef:
	return ContentDB.get_entity_def(entity_def_id)


# All effects currently active on this instance: base + every applied tier's
# added_effects (cumulative).
func get_active_effects() -> Array[Effect]:
	var out: Array[Effect] = []
	var def := get_def()
	if def == null:
		return out
	out.append_array(def.effects)
	var applied := mini(upgrade_tier, def.upgrade_chain.size())
	for i in applied:
		out.append_array((def.upgrade_chain[i] as UpgradeTier).added_effects)
	return out


func get_current_sprite_key() -> StringName:
	var def := get_def()
	if def == null:
		return &""
	if upgrade_tier > 0 and upgrade_tier <= def.upgrade_chain.size():
		return (def.upgrade_chain[upgrade_tier - 1] as UpgradeTier).new_sprite_key
	return def.sprite_key


# build_cost + sum of all applied upgrade-tier costs. Used by EntityRegistry
# to compute removal refunds.
func get_total_invested() -> int:
	var def := get_def()
	if def == null:
		return 0
	var total := def.build_cost
	var applied := mini(upgrade_tier, def.upgrade_chain.size())
	for i in applied:
		total += (def.upgrade_chain[i] as UpgradeTier).cost
	return total
