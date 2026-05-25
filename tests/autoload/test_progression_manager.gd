extends GutTest
# Tests for ProgressionManager — Prompt 8.
# Spec: docs/build-plan.md §7 (Prompt 8)

const NODE_BASIC := &"test_basic"
const NODE_PREMIUM := &"test_premium"
const NODE_DEEP := &"test_deep"


func before_each() -> void:
	ProgressionManager.reset()
	Ledger.reset(1000)

	# Basic — free, no prereqs, unlocks an entity id.
	var basic := UnlockNode.new()
	basic.id = NODE_BASIC
	basic.label = "Basic"
	basic.cost = 0
	basic.unlocks = [&"basic_thing"] as Array[StringName]
	ContentDB.unlock_nodes[NODE_BASIC] = basic

	# Premium — requires basic + reputation 20 + 500 cash.
	var premium := UnlockNode.new()
	premium.id = NODE_PREMIUM
	premium.label = "Premium"
	premium.cost = 500
	premium.prerequisites = [NODE_BASIC] as Array[StringName]
	premium.reputation_required = 20
	premium.unlocks = [&"premium_thing"] as Array[StringName]
	ContentDB.unlock_nodes[NODE_PREMIUM] = premium

	# Deep — requires premium.
	var deep := UnlockNode.new()
	deep.id = NODE_DEEP
	deep.label = "Deep"
	deep.cost = 100
	deep.prerequisites = [NODE_PREMIUM] as Array[StringName]
	ContentDB.unlock_nodes[NODE_DEEP] = deep


func after_each() -> void:
	ContentDB.unlock_nodes.erase(NODE_BASIC)
	ContentDB.unlock_nodes.erase(NODE_PREMIUM)
	ContentDB.unlock_nodes.erase(NODE_DEEP)


# --- Initial state --------------------------------------------------------

func test_starts_empty() -> void:
	assert_eq(ProgressionManager.reputation, 0)
	assert_false(ProgressionManager.is_unlocked(NODE_BASIC))


# --- try_unlock happy path -----------------------------------------------

func test_try_unlock_succeeds_for_free_no_prereq_node() -> void:
	assert_true(ProgressionManager.try_unlock(NODE_BASIC))
	assert_true(ProgressionManager.is_unlocked(NODE_BASIC))


func test_try_unlock_deducts_cost_from_ledger() -> void:
	ProgressionManager.try_unlock(NODE_BASIC)
	ProgressionManager.set_reputation(20)
	var pre := Ledger.get_balance()
	assert_true(ProgressionManager.try_unlock(NODE_PREMIUM))
	assert_eq(Ledger.get_balance(), pre - 500)


func test_try_unlock_emits_unlock_acquired_signal() -> void:
	var captured: Array[StringName] = []
	var capture := func(id: StringName) -> void: captured.append(id)
	EventBus.unlock_acquired.connect(capture)
	ProgressionManager.try_unlock(NODE_BASIC)
	assert_eq(captured, [NODE_BASIC] as Array[StringName])
	EventBus.unlock_acquired.disconnect(capture)


func test_chained_unlocks_in_order() -> void:
	assert_true(ProgressionManager.try_unlock(NODE_BASIC))
	ProgressionManager.set_reputation(20)
	assert_true(ProgressionManager.try_unlock(NODE_PREMIUM))
	assert_true(ProgressionManager.try_unlock(NODE_DEEP))


# --- try_unlock gate failures --------------------------------------------

func test_try_unlock_fails_when_prereq_missing() -> void:
	ProgressionManager.set_reputation(50)  # rep is fine
	assert_false(ProgressionManager.try_unlock(NODE_PREMIUM),
		"premium needs basic first")
	assert_false(ProgressionManager.is_unlocked(NODE_PREMIUM))


func test_try_unlock_fails_when_reputation_too_low() -> void:
	ProgressionManager.try_unlock(NODE_BASIC)
	# reputation is 0, premium requires 20
	assert_false(ProgressionManager.try_unlock(NODE_PREMIUM))


func test_try_unlock_fails_when_balance_too_low() -> void:
	ProgressionManager.try_unlock(NODE_BASIC)
	ProgressionManager.set_reputation(20)
	Ledger.reset(100)  # < 500 cost
	assert_false(ProgressionManager.try_unlock(NODE_PREMIUM))


func test_try_unlock_failed_attempt_does_not_charge_ledger() -> void:
	ProgressionManager.set_reputation(50)
	var pre := Ledger.get_balance()
	assert_false(ProgressionManager.try_unlock(NODE_PREMIUM))  # no prereq
	assert_eq(Ledger.get_balance(), pre)


func test_try_unlock_already_unlocked_returns_false() -> void:
	ProgressionManager.try_unlock(NODE_BASIC)
	assert_false(ProgressionManager.try_unlock(NODE_BASIC))


func test_try_unlock_unknown_node_returns_false() -> void:
	assert_false(ProgressionManager.try_unlock(&"never_existed"))


# --- can_unlock predicate -------------------------------------------------

func test_can_unlock_true_when_all_gates_pass() -> void:
	ProgressionManager.try_unlock(NODE_BASIC)
	ProgressionManager.set_reputation(20)
	assert_true(ProgressionManager.can_unlock(NODE_PREMIUM))


func test_can_unlock_false_for_unknown_node() -> void:
	assert_false(ProgressionManager.can_unlock(&"never_existed"))


func test_can_unlock_false_when_already_unlocked() -> void:
	ProgressionManager.try_unlock(NODE_BASIC)
	assert_false(ProgressionManager.can_unlock(NODE_BASIC))


# --- force_unlock ---------------------------------------------------------

func test_force_unlock_skips_all_gates() -> void:
	# Nothing unlocked, no reputation, full balance
	var pre := Ledger.get_balance()
	ProgressionManager.force_unlock(NODE_PREMIUM)
	assert_true(ProgressionManager.is_unlocked(NODE_PREMIUM))
	assert_eq(Ledger.get_balance(), pre, "force_unlock never charges")


func test_force_unlock_emits_signal() -> void:
	var captured: Array[StringName] = []
	var capture := func(id: StringName) -> void: captured.append(id)
	EventBus.unlock_acquired.connect(capture)
	ProgressionManager.force_unlock(NODE_BASIC)
	assert_eq(captured, [NODE_BASIC] as Array[StringName])
	EventBus.unlock_acquired.disconnect(capture)


func test_force_unlock_idempotent_for_already_unlocked() -> void:
	ProgressionManager.try_unlock(NODE_BASIC)
	var captured: Array[StringName] = []
	var capture := func(id: StringName) -> void: captured.append(id)
	EventBus.unlock_acquired.connect(capture)
	ProgressionManager.force_unlock(NODE_BASIC)
	assert_eq(captured, [] as Array[StringName],
		"re-forcing an already-unlocked node is a no-op")
	EventBus.unlock_acquired.disconnect(capture)


# --- Reputation -----------------------------------------------------------

func test_set_reputation_emits_signal() -> void:
	var captured: Array[int] = []
	var capture := func(v: int) -> void: captured.append(v)
	EventBus.reputation_changed.connect(capture)
	ProgressionManager.set_reputation(42)
	assert_eq(captured, [42] as Array[int])
	EventBus.reputation_changed.disconnect(capture)


func test_set_reputation_to_same_value_does_not_emit() -> void:
	ProgressionManager.set_reputation(42)
	var captured: Array[int] = []
	var capture := func(v: int) -> void: captured.append(v)
	EventBus.reputation_changed.connect(capture)
	ProgressionManager.set_reputation(42)
	assert_eq(captured, [] as Array[int])
	EventBus.reputation_changed.disconnect(capture)


func test_add_reputation_accumulates() -> void:
	ProgressionManager.set_reputation(10)
	ProgressionManager.add_reputation(15)
	assert_eq(ProgressionManager.reputation, 25)


# --- is_id_available ------------------------------------------------------

func test_is_id_available_true_for_unlocked_content() -> void:
	ProgressionManager.try_unlock(NODE_BASIC)
	assert_true(ProgressionManager.is_id_available(&"basic_thing"))


func test_is_id_available_false_when_node_locked() -> void:
	# NODE_BASIC unlocks basic_thing — but we haven't unlocked NODE_BASIC.
	assert_false(ProgressionManager.is_id_available(&"basic_thing"))


func test_is_id_available_false_for_unknown_id() -> void:
	ProgressionManager.try_unlock(NODE_BASIC)
	assert_false(ProgressionManager.is_id_available(&"never_existed"))
