extends Node
# Spec: docs/build-plan.md §3 (autoloads — ProgressionManager), Prompt 8.
#
# Owns the unlock graph: which UnlockNodes have been acquired, and the
# generic reputation counter that gates them. Theme-agnostic — what
# "reputation" *means* (course rating, zoo stars, hospital accreditation) is
# decided by the game; the engine just tracks an int.
#
# Three unlock entry points:
#   try_unlock(id)   — full path: checks prereqs + reputation + cost,
#                      deducts cost via Ledger, marks unlocked, emits signal.
#   can_unlock(id)   — pure predicate; useful for UI button enabled-state.
#   force_unlock(id) — skips gates. For save-restore and dev/cheat tools.

var reputation: int = 0
# StringName -> true. Membership check via .has().
var unlocked: Dictionary = {}


func reset() -> void:
	reputation = 0
	unlocked.clear()


# --- Queries --------------------------------------------------------------

func is_unlocked(node_id: StringName) -> bool:
	return unlocked.has(node_id)


# Returns true only when every gate passes:
#   - the node exists in ContentDB,
#   - it's not already unlocked,
#   - all prerequisites are unlocked,
#   - reputation >= required,
#   - Ledger.balance >= cost.
func can_unlock(node_id: StringName) -> bool:
	var node: UnlockNode = ContentDB.get_unlock_node(node_id)
	if node == null:
		return false
	if is_unlocked(node_id):
		return false
	for prereq in node.prerequisites:
		if not is_unlocked(prereq):
			return false
	if reputation < node.reputation_required:
		return false
	if Ledger.get_balance() < node.cost:
		return false
	return true


# True iff `id` appears in the `unlocks` array of any currently-unlocked
# node. Downstream systems (EntityRegistry, AgentPool, …) can use this to
# gate placement/spawning on progression — opt-in, not enforced by engine.
func is_id_available(id: StringName) -> bool:
	for node_id in unlocked.keys():
		var node: UnlockNode = ContentDB.get_unlock_node(node_id)
		if node == null:
			continue
		if id in node.unlocks:
			return true
	return false


# --- Mutations ------------------------------------------------------------

# Returns true on success. Charges cost via Ledger as a single expense and
# emits unlock_acquired. No-op (returns false) if any gate fails.
func try_unlock(node_id: StringName) -> bool:
	if not can_unlock(node_id):
		return false
	var node: UnlockNode = ContentDB.get_unlock_node(node_id)
	if node.cost > 0:
		Ledger.post_expense(node.cost, "Unlock %s" % node.label, node_id)
	unlocked[node_id] = true
	EventBus.unlock_acquired.emit(node_id)
	return true


# Mark unlocked without checking gates or charging cost. Use cases:
#   - SaveService restoring a previous game state
#   - dev tools / cheat menus
#   - tutorials that grant content explicitly
func force_unlock(node_id: StringName) -> void:
	if is_unlocked(node_id):
		return
	var node: UnlockNode = ContentDB.get_unlock_node(node_id)
	if node == null:
		push_warning("ProgressionManager.force_unlock: unknown node '%s'" % node_id)
		return
	unlocked[node_id] = true
	EventBus.unlock_acquired.emit(node_id)


func set_reputation(value: int) -> void:
	if value == reputation:
		return
	reputation = value
	EventBus.reputation_changed.emit(reputation)


func add_reputation(delta: int) -> void:
	set_reputation(reputation + delta)


# Save / load (Prompt 9). Unlocked dict serialized as a String array since
# JSON keys must be strings and the value is always true.
func save_state() -> Dictionary:
	var ids: Array[String] = []
	for id in unlocked.keys():
		ids.append(String(id))
	return {
		"reputation": reputation,
		"unlocked": ids,
	}


func load_state(data: Dictionary) -> void:
	reputation = data.get("reputation", 0)
	unlocked.clear()
	for id_str in data.get("unlocked", []):
		unlocked[StringName(id_str)] = true
