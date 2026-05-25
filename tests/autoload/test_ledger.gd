extends GutTest
# Tests for Ledger — Prompt 2.
# Spec: docs/build-plan.md §7 (Prompt 2)


func before_each() -> void:
	Ledger.reset()
	SimClock.current_tick = 0
	SimClock.current_day = 0
	SimClock.current_period = 0
	SimClock.ticks_per_day = 5
	SimClock.days_per_period = 2


# --- Transactions ---------------------------------------------------------

func test_starts_at_default_cash() -> void:
	assert_eq(Ledger.get_balance(), 1000)


func test_post_income_increases_balance_and_logs() -> void:
	Ledger.post_income(150, "ticket sale", &"gate")
	assert_eq(Ledger.get_balance(), 1150)
	assert_eq(Ledger.transactions.size(), 1)
	var tx: Dictionary = Ledger.transactions[0]
	assert_eq(tx["kind"], Ledger.KIND_INCOME)
	assert_eq(tx["amount"], 150)
	assert_eq(tx["label"], "ticket sale")
	assert_eq(tx["source_id"], &"gate")


func test_post_expense_decreases_balance_and_logs() -> void:
	Ledger.post_expense(80, "supplies", &"warehouse")
	assert_eq(Ledger.get_balance(), 920)
	assert_eq(Ledger.transactions.size(), 1)
	var tx: Dictionary = Ledger.transactions[0]
	assert_eq(tx["kind"], Ledger.KIND_EXPENSE)
	assert_eq(tx["amount"], 80)


func test_multiple_transactions_accumulate() -> void:
	Ledger.post_income(100, "a")
	Ledger.post_income(50, "b")
	Ledger.post_expense(30, "c")
	assert_eq(Ledger.get_balance(), 1000 + 100 + 50 - 30)
	assert_eq(Ledger.transactions.size(), 3)


func test_transactions_stamp_current_day() -> void:
	SimClock.current_day = 4
	Ledger.post_income(10, "x")
	assert_eq((Ledger.transactions[0] as Dictionary)["day"], 4)


func test_balance_changed_signal_fires() -> void:
	var balances: Array[int] = []
	var capture := func(b: int) -> void: balances.append(b)
	EventBus.balance_changed.connect(capture)
	Ledger.post_income(25, "a")
	Ledger.post_expense(10, "b")
	assert_eq(balances, [1025, 1015] as Array[int])
	EventBus.balance_changed.disconnect(capture)


# --- Recurring rules + daily settlement -----------------------------------

func test_register_recurring_normalizes_defaults() -> void:
	Ledger.register_recurring({
		"id": &"utilities",
		"amount": 50,
		"kind": Ledger.KIND_EXPENSE,
	})
	var rule: Dictionary = Ledger.recurring_rules[&"utilities"]
	assert_eq(rule["period"], Ledger.PERIOD_DAILY, "period defaults to daily")
	assert_eq(rule["label"], "utilities", "label defaults to id string")


func test_recurring_expense_applies_on_day_end() -> void:
	Ledger.register_recurring({
		"id": &"utilities",
		"label": "Utilities",
		"amount": 50,
		"kind": Ledger.KIND_EXPENSE,
	})
	# Drive a full day via SimClock so the EventBus.day_ended wiring exercises.
	for i in range(5):
		SimClock.advance_tick()
	assert_eq(Ledger.get_balance(), 950)


func test_recurring_income_applies_on_day_end() -> void:
	Ledger.register_recurring({
		"id": &"sponsor",
		"label": "Daily sponsor",
		"amount": 200,
		"kind": Ledger.KIND_INCOME,
	})
	for i in range(5):
		SimClock.advance_tick()
	assert_eq(Ledger.get_balance(), 1200)


func test_multiple_recurring_rules_all_apply() -> void:
	Ledger.register_recurring({"id": &"utilities", "amount": 50, "kind": Ledger.KIND_EXPENSE})
	Ledger.register_recurring({"id": &"insurance", "amount": 20, "kind": Ledger.KIND_EXPENSE})
	Ledger.register_recurring({"id": &"grant", "amount": 30, "kind": Ledger.KIND_INCOME})
	for i in range(5):
		SimClock.advance_tick()
	assert_eq(Ledger.get_balance(), 1000 - 50 - 20 + 30)


func test_unregister_recurring_stops_applying() -> void:
	Ledger.register_recurring({"id": &"utilities", "amount": 50, "kind": Ledger.KIND_EXPENSE})
	for i in range(5):
		SimClock.advance_tick()
	assert_eq(Ledger.get_balance(), 950, "first day applied utilities")
	Ledger.unregister_recurring(&"utilities")
	for i in range(5):
		SimClock.advance_tick()
	assert_eq(Ledger.get_balance(), 950, "second day no longer applies utilities")


# --- Yesterday breakdown queries ------------------------------------------

func test_yesterday_breakdown_starts_zero() -> void:
	var b: Dictionary = Ledger.get_yesterday_breakdown()
	assert_eq(b["income"], 0)
	assert_eq(b["expense"], 0)
	assert_eq(b["net"], 0)


func test_yesterday_breakdown_captures_just_ended_day() -> void:
	Ledger.post_income(300, "tickets")
	Ledger.post_expense(120, "supplies")
	# Force day end.
	for i in range(5):
		SimClock.advance_tick()
	var b: Dictionary = Ledger.get_yesterday_breakdown()
	assert_eq(b["income"], 300)
	assert_eq(b["expense"], 120)
	assert_eq(b["net"], 180)


func test_yesterday_breakdown_resets_today_after_settlement() -> void:
	Ledger.post_income(100, "a")
	for i in range(5):
		SimClock.advance_tick()
	# After settlement, today's counters are zero again. Post a new tx and
	# confirm a second settlement reflects only the new tx.
	Ledger.post_income(20, "b")
	for i in range(5):
		SimClock.advance_tick()
	var b: Dictionary = Ledger.get_yesterday_breakdown()
	assert_eq(b["income"], 20, "yesterday is only the most recently ended day")
	assert_eq(b["expense"], 0)


func test_recurring_rolls_into_yesterday_breakdown() -> void:
	Ledger.register_recurring({"id": &"utilities", "amount": 50, "kind": Ledger.KIND_EXPENSE})
	for i in range(5):
		SimClock.advance_tick()
	var b: Dictionary = Ledger.get_yesterday_breakdown()
	assert_eq(b["expense"], 50, "recurring counts toward the just-ended day")


# --- day_settled signal ---------------------------------------------------

func test_day_settled_signal_emits_with_settled_day_and_totals() -> void:
	var captured: Array[Dictionary] = []
	var capture := func(day: int, income: int, expense: int) -> void:
		captured.append({"day": day, "income": income, "expense": expense})
	EventBus.day_settled.connect(capture)
	Ledger.post_income(40, "a")
	Ledger.post_expense(15, "b")
	for i in range(5):
		SimClock.advance_tick()
	assert_eq(captured.size(), 1)
	var s: Dictionary = captured[0]
	# SimClock now sits at day 1; the day that settled is day 0.
	assert_eq(s["day"], 0, "day_settled arg is the just-ended day")
	assert_eq(s["income"], 40)
	assert_eq(s["expense"], 15)
	EventBus.day_settled.disconnect(capture)
