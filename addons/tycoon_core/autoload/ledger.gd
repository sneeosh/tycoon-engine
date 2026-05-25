extends Node
# Spec: docs/build-plan.md §3 (Ledger), Prompt 2.
#
# Single source of truth for money. Other systems post transactions here;
# nothing else holds a balance. Daily settlement runs on SimClock.day_ended,
# applies recurring rules, and rolls today's totals into yesterday's.
#
# Money is integer-valued — no floats. Keeps settlement and save/load exact
# (no FP drift across thousands of small transactions) and matches the
# OpenRCT2 convention. Theme-agnostic: no game-specific concepts in here.

# Default until ContentDB lands (Prompt 4). Mirrors design/tuning/economy.md.
const DEFAULT_STARTING_CASH: int = 1000

const KIND_INCOME: StringName = &"income"
const KIND_EXPENSE: StringName = &"expense"
const PERIOD_DAILY: StringName = &"daily"

var balance: int = DEFAULT_STARTING_CASH

# Append-only log of every transaction posted through Ledger. Each entry:
#   { day: int, kind: KIND_INCOME | KIND_EXPENSE, amount: int,
#     label: String, source_id: StringName }
var transactions: Array[Dictionary] = []

# Recurring rules keyed by id. Each rule:
#   { id: StringName, label: String, amount: int (>= 0),
#     kind: KIND_INCOME | KIND_EXPENSE, period: PERIOD_DAILY }
# Prompt 2 only supports daily; weekly/monthly come later.
var recurring_rules: Dictionary = {}

var _today_income: int = 0
var _today_expense: int = 0
var _yesterday_income: int = 0
var _yesterday_expense: int = 0


func _ready() -> void:
	EventBus.day_ended.connect(_on_day_ended)


# Wipes balance, log, rules, and counters back to defaults. Used by tests and
# by Prompt 4's ContentDB once tuning loads.
func reset(starting_cash: int = DEFAULT_STARTING_CASH) -> void:
	balance = starting_cash
	transactions.clear()
	recurring_rules.clear()
	_today_income = 0
	_today_expense = 0
	_yesterday_income = 0
	_yesterday_expense = 0


func post_income(amount: int, label: String, source_id: StringName = &"") -> void:
	assert(amount >= 0, "income amount must be >= 0")
	_record(KIND_INCOME, amount, label, source_id)
	balance += amount
	_today_income += amount
	EventBus.balance_changed.emit(balance)


func post_expense(amount: int, label: String, source_id: StringName = &"") -> void:
	assert(amount >= 0, "expense amount must be >= 0")
	_record(KIND_EXPENSE, amount, label, source_id)
	balance -= amount
	_today_expense += amount
	EventBus.balance_changed.emit(balance)


func register_recurring(rule: Dictionary) -> void:
	assert(rule.has("id") and rule.has("amount") and rule.has("kind"),
		"recurring rule needs id, amount, kind")
	var normalized: Dictionary = rule.duplicate()
	if not normalized.has("period"):
		normalized["period"] = PERIOD_DAILY
	if not normalized.has("label"):
		normalized["label"] = String(normalized["id"])
	recurring_rules[normalized["id"]] = normalized


func unregister_recurring(id: StringName) -> void:
	recurring_rules.erase(id)


func get_balance() -> int:
	return balance


# Totals for the day that just ended. Shape:
#   { "income": int, "expense": int, "net": int }
func get_yesterday_breakdown() -> Dictionary:
	return {
		"income": _yesterday_income,
		"expense": _yesterday_expense,
		"net": _yesterday_income - _yesterday_expense,
	}


func _record(kind: StringName, amount: int, label: String, source_id: StringName) -> void:
	transactions.append({
		"day": SimClock.current_day,
		"kind": kind,
		"amount": amount,
		"label": label,
		"source_id": source_id,
	})


# SimClock emits day_ended *after* incrementing current_day, so the day that
# just finished is `current_day - 1`. We apply recurring rules first (their
# transactions belong to the just-ended day's settlement), then roll today's
# counters into yesterday's, then announce the settlement.
func _on_day_ended(_new_day: int) -> void:
	_apply_recurring()
	_yesterday_income = _today_income
	_yesterday_expense = _today_expense
	_today_income = 0
	_today_expense = 0
	var settled_day: int = SimClock.current_day - 1
	EventBus.day_settled.emit(settled_day, _yesterday_income, _yesterday_expense)


func _apply_recurring() -> void:
	for id in recurring_rules.keys():
		var rule: Dictionary = recurring_rules[id]
		if rule["period"] != PERIOD_DAILY:
			continue
		var amount: int = rule["amount"]
		var label: String = rule["label"]
		if rule["kind"] == KIND_INCOME:
			post_income(amount, label, id)
		else:
			post_expense(amount, label, id)


# Save / load (Prompt 9). StringNames serialize as Strings; load_state
# converts back. No signal emits during load — handlers shouldn't react to
# restoration as if it were live gameplay.
func save_state() -> Dictionary:
	var ser_txs: Array = []
	for tx: Dictionary in transactions:
		ser_txs.append({
			"day": tx["day"],
			"kind": String(tx["kind"]),
			"amount": tx["amount"],
			"label": tx["label"],
			"source_id": String(tx["source_id"]),
		})
	var ser_rules: Dictionary = {}
	for id in recurring_rules.keys():
		var rule: Dictionary = recurring_rules[id]
		ser_rules[String(id)] = {
			"id": String(rule["id"]),
			"label": rule["label"],
			"amount": rule["amount"],
			"kind": String(rule["kind"]),
			"period": String(rule["period"]),
		}
	return {
		"balance": balance,
		"transactions": ser_txs,
		"recurring_rules": ser_rules,
		"today_income": _today_income,
		"today_expense": _today_expense,
		"yesterday_income": _yesterday_income,
		"yesterday_expense": _yesterday_expense,
	}


func load_state(data: Dictionary) -> void:
	balance = data.get("balance", DEFAULT_STARTING_CASH)
	transactions.clear()
	for tx in data.get("transactions", []):
		transactions.append({
			"day": tx.get("day", 0),
			"kind": StringName(tx.get("kind", "")),
			"amount": tx.get("amount", 0),
			"label": tx.get("label", ""),
			"source_id": StringName(tx.get("source_id", "")),
		})
	recurring_rules.clear()
	for id_str in data.get("recurring_rules", {}):
		var rule: Dictionary = data["recurring_rules"][id_str]
		recurring_rules[StringName(id_str)] = {
			"id": StringName(rule.get("id", id_str)),
			"label": rule.get("label", id_str),
			"amount": rule.get("amount", 0),
			"kind": StringName(rule.get("kind", "expense")),
			"period": StringName(rule.get("period", "daily")),
		}
	_today_income = data.get("today_income", 0)
	_today_expense = data.get("today_expense", 0)
	_yesterday_income = data.get("yesterday_income", 0)
	_yesterday_expense = data.get("yesterday_expense", 0)
