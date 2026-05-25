extends Node
# Spec: design/algorithms/accounting.md
#
# US-GAAP-style accrual-basis reporting overlay on top of the cash-basis
# Ledger. Maintains an asset register reactive to entity_placed/removed and
# placement_added/removed, posts daily straight-line depreciation, and
# exposes Income Statement / Balance Sheet queries for any reporting period.
#
# Theme-agnostic. The engine knows nothing about which source_id is
# "ticket revenue" vs "utilities expense" — games register categories at
# startup via register_category(). Uncategorized transactions fall into
# OTHER_INCOME / OTHER_EXPENSE so books always balance.
#
# Coexists with Ledger; never mutates Ledger semantics. Depreciation is a
# non-cash expense — Accounting tracks it in its own per-asset schedule
# (`accumulated_depreciation`) and reports it on the IS. It does NOT post
# to Ledger (which is cash-basis); doing so would falsify the cash balance.

enum Category {
	REVENUE,
	COGS,
	OPERATING_EXPENSE,
	OTHER_INCOME,
	OTHER_EXPENSE,
	CAPITAL_EXPENDITURE,
}

# Reserved source_id used when Accounting journals daily depreciation.
# Tracked in `depreciation_journal` below (not in Ledger — see header).
const DEPRECIATION_SOURCE: StringName = &"_depreciation"

# Asset kind tags.
const KIND_ENTITY: StringName = &"entity"
const KIND_PLACEMENT: StringName = &"placement"

# Asset register. Each entry:
#   {
#     asset_id: int,
#     kind: StringName (KIND_ENTITY | KIND_PLACEMENT),
#     source_id: StringName,        # def id
#     origin_id: Variant,           # entity instance_id or [region_id, index]
#     cost: int,
#     useful_life_days: int,
#     acquired_day: int,
#     accumulated_depreciation: int,
#     disposed_day: int,            # -1 if still held
#     disposal_proceeds: int,       # 0 if still held
#   }
var assets: Array[Dictionary] = []

# Game-registered categorization. source_id (StringName) -> Category (int).
# The engine pre-seeds with conventions it controls (maintenance rule ids,
# the reserved depreciation source).
var categories: Dictionary = {}

# Per-asset disposal P&L. Each entry: {day: int, amount: int (signed),
# gain: bool}. Loss = positive amount + gain=false; Gain = positive
# amount + gain=true. Kept separate from the Ledger transaction stream
# so IS can include them without double-counting the refund.
var disposals: Array[Dictionary] = []

# Per-day depreciation expense journal. Each entry:
#   {day: int, asset_id: int, amount: int, source_id: StringName}
# Non-cash; not in Ledger. Drives the depreciation line on the IS.
var depreciation_journal: Array[Dictionary] = []

var _next_asset_id: int = 1


func _ready() -> void:
	EventBus.entity_placed.connect(_on_entity_placed)
	EventBus.entity_removed.connect(_on_entity_removed)
	EventBus.placement_added.connect(_on_placement_added)
	EventBus.placement_removed.connect(_on_placement_removed)
	EventBus.day_ending.connect(_on_day_ending)


func reset() -> void:
	assets.clear()
	categories.clear()
	disposals.clear()
	depreciation_journal.clear()
	_next_asset_id = 1


# --- Category registration -----------------------------------------------

func register_category(source_id: StringName, category: int) -> void:
	categories[source_id] = category


# --- Asset register reactive maintenance ---------------------------------

func _on_entity_placed(instance_id: int) -> void:
	var inst: EntityInstance = EntityRegistry.get_instance(instance_id)
	if inst == null:
		return
	var def: EntityDef = inst.get_def()
	if def == null:
		return
	# Build cost is treated as capex regardless of useful_life_days; we just
	# decide whether to register it for depreciation or write it off as
	# immediate operating expense (engine convention for life=0 assets).
	if def.useful_life_days > 0:
		_register_asset(KIND_ENTITY, def.id, instance_id, def.build_cost, def.useful_life_days)
	else:
		# Categorize the build cash transaction as OPERATING_EXPENSE so it
		# appears on the IS. Idempotent — re-registers if a later place()
		# uses the same def.
		categories[def.id] = Category.OPERATING_EXPENSE


func _on_entity_removed(instance_id: int) -> void:
	# EntityRegistry.remove() has already posted the refund (if any) and
	# erased the instance. Find the matching asset in our register.
	var idx: int = _find_held_asset(KIND_ENTITY, instance_id)
	if idx < 0:
		return  # not depreciable / not in our register
	_dispose_asset(idx)


func _on_placement_added(region_id: int, index: int) -> void:
	var region: Region = RegionRegistry.get_region(region_id)
	if region == null:
		return
	if index < 0 or index >= region.placements.size():
		return
	var p: Placement = region.placements[index]
	var def: PlaceableDef = ContentDB.placeable_defs.get(p.placeable_def_id)
	if def == null:
		return
	if def.useful_life_days > 0:
		_register_asset(KIND_PLACEMENT, def.id, [region_id, index], def.build_cost, def.useful_life_days)
	else:
		categories[def.id] = Category.OPERATING_EXPENSE


func _on_placement_removed(region_id: int, index: int) -> void:
	var idx: int = _find_held_asset_for_placement(region_id, index)
	if idx < 0:
		return
	_dispose_asset(idx)


# --- Daily depreciation ---------------------------------------------------

# day_ending fires *before* Ledger settles, so depreciation lands in the
# just-ending day's bucket — the same lane EffectResolver revenue uses
# (see CHANGELOG v0.3.0). SimClock increments `current_day` before
# emitting, so the day that's actually ending is current_day - 1.
func _on_day_ending(_new_day: int) -> void:
	var settling_day: int = SimClock.current_day - 1
	for asset: Dictionary in assets:
		if asset["disposed_day"] != -1:
			continue
		if asset["useful_life_days"] <= 0:
			continue
		# Acquisition day counts as day-1-of-life; spec calls this the
		# half-year-convention analogue.
		var days_used: int = settling_day - int(asset["acquired_day"]) + 1
		if days_used <= 0:
			continue
		var days_left: int = int(asset["useful_life_days"]) - (days_used - 1)
		if days_left <= 0:
			continue
		var remaining_cost: int = int(asset["cost"]) - int(asset["accumulated_depreciation"])
		if remaining_cost <= 0:
			continue
		var daily_slice: int = remaining_cost / days_left
		# Carry the remainder via integer division of remaining_cost by
		# remaining days so total depreciation over life == cost exactly.
		if daily_slice <= 0:
			continue
		asset["accumulated_depreciation"] = int(asset["accumulated_depreciation"]) + daily_slice
		depreciation_journal.append({
			"day": settling_day,
			"asset_id": asset["asset_id"],
			"amount": daily_slice,
			"source_id": DEPRECIATION_SOURCE,
		})


# --- Income Statement -----------------------------------------------------

func get_income_statement(start_day: int, end_day: int) -> Dictionary:
	var revenue: int = 0
	var cogs: int = 0
	var depreciation: int = 0
	var other_income: int = 0
	var other_expense: int = 0
	var operating_expenses: Dictionary = {}  # StringName -> int

	# Depreciation comes from Accounting's own non-cash journal (not Ledger).
	for d_entry: Dictionary in depreciation_journal:
		var d_day: int = int(d_entry["day"])
		if d_day < start_day or d_day > end_day:
			continue
		depreciation += int(d_entry["amount"])

	for tx: Dictionary in Ledger.transactions:
		var day: int = int(tx["day"])
		if day < start_day or day > end_day:
			continue
		var src: StringName = tx["source_id"]
		var amount: int = int(tx["amount"])
		var is_income: bool = tx["kind"] == Ledger.KIND_INCOME

		var cat: int = categories.get(src, -1)

		if is_income:
			if cat == Category.REVENUE:
				revenue += amount
			elif cat == Category.CAPITAL_EXPENDITURE:
				# This is a disposal refund. Don't double-count — the
				# gain/loss is computed from `disposals` below.
				continue
			elif cat == Category.OTHER_INCOME:
				other_income += amount
			else:
				# Uncategorized income → OTHER_INCOME, so books still balance.
				other_income += amount
		else:
			if cat == Category.COGS:
				cogs += amount
			elif cat == Category.OPERATING_EXPENSE:
				var key: StringName = src
				operating_expenses[key] = int(operating_expenses.get(key, 0)) + amount
			elif cat == Category.CAPITAL_EXPENDITURE:
				# Build expense — capitalized, not expensed. Skip on IS.
				continue
			elif cat == Category.OTHER_EXPENSE:
				other_expense += amount
			else:
				# Uncategorized expense → OTHER_EXPENSE.
				other_expense += amount

	# Disposal gain/loss for the period.
	for d: Dictionary in disposals:
		var day: int = int(d["day"])
		if day < start_day or day > end_day:
			continue
		if bool(d["gain"]):
			other_income += int(d["amount"])
		else:
			other_expense += int(d["amount"])

	var gross_profit: int = revenue - cogs
	var total_opex: int = 0
	for v in operating_expenses.values():
		total_opex += int(v)
	var operating_income: int = gross_profit - total_opex - depreciation
	var other: int = other_income - other_expense
	var net_income: int = operating_income + other

	return {
		"revenue": revenue,
		"cogs": cogs,
		"gross_profit": gross_profit,
		"operating_expenses": operating_expenses,
		"depreciation": depreciation,
		"operating_income": operating_income,
		"other_income": other_income,
		"other_expense": other_expense,
		"other": other,
		"net_income": net_income,
		"period": {"start_day": start_day, "end_day": end_day},
	}


# --- Period-convenience wrappers -----------------------------------------

func get_income_statement_today() -> Dictionary:
	return get_income_statement(SimClock.current_day, SimClock.current_day)


func get_income_statement_for_period() -> Dictionary:
	var days_per_period: int = SimClock.days_per_period
	var end_day: int = SimClock.current_day
	var start_day: int = max(0, end_day - days_per_period + 1)
	return get_income_statement(start_day, end_day)


func get_income_statement_for_month() -> Dictionary:
	var end_day: int = SimClock.current_day
	var start_day: int = max(0, end_day - 30 + 1)
	return get_income_statement(start_day, end_day)


func get_income_statement_all_time() -> Dictionary:
	return get_income_statement(0, SimClock.current_day)


# --- Balance Sheet --------------------------------------------------------

func get_balance_sheet(as_of_day: int) -> Dictionary:
	var ppe_gross: int = 0
	var accumulated_depreciation: int = 0
	for asset: Dictionary in assets:
		var acquired: int = int(asset["acquired_day"])
		if acquired > as_of_day:
			continue
		var disposed: int = int(asset["disposed_day"])
		var held_at_date: bool = (disposed == -1 or disposed > as_of_day)
		if not held_at_date:
			continue
		ppe_gross += int(asset["cost"])
		# Accumulated depreciation depends on as_of_day, not the live
		# register's current accumulated_depreciation (which may be the
		# value at SimClock.current_day, not the queried date).
		accumulated_depreciation += _accumulated_depreciation_at(asset, as_of_day)

	var ppe_net: int = ppe_gross - accumulated_depreciation

	var cash: int
	if as_of_day == SimClock.current_day:
		cash = Ledger.get_balance()
	else:
		# Replay Ledger transactions to compute cash at as_of_day.
		var starting_capital_for_replay: int = _starting_capital()
		cash = starting_capital_for_replay
		for tx: Dictionary in Ledger.transactions:
			if int(tx["day"]) > as_of_day:
				continue
			if tx["kind"] == Ledger.KIND_INCOME:
				cash += int(tx["amount"])
			else:
				cash -= int(tx["amount"])

	var total_assets: int = cash + ppe_net
	var starting_capital: int = _starting_capital()
	# Retained earnings derived so the equation balances by construction;
	# this catches categorization errors as a non-zero balance_check_delta
	# only if a separate IS-derived view is compared (see all-time IS).
	# We compute it the "honest" way: lifetime net income through as_of_day.
	var ls: Dictionary = get_income_statement(0, as_of_day)
	var retained_earnings: int = int(ls["net_income"])
	var total_equity: int = starting_capital + retained_earnings
	var total_liabilities: int = 0
	var equation_rhs: int = total_liabilities + total_equity
	var balance_check_delta: int = total_assets - equation_rhs

	return {
		"assets": {
			"cash": cash,
			"ppe_gross": ppe_gross,
			"accumulated_depreciation": accumulated_depreciation,
			"ppe_net": ppe_net,
			"total_assets": total_assets,
		},
		"liabilities": {
			"total_liabilities": total_liabilities,
		},
		"equity": {
			"starting_capital": starting_capital,
			"retained_earnings": retained_earnings,
			"total_equity": total_equity,
		},
		"balances": balance_check_delta == 0,
		"balance_check_delta": balance_check_delta,
		"as_of_day": as_of_day,
	}


func get_balance_sheet_today() -> Dictionary:
	return get_balance_sheet(SimClock.current_day)


# --- Internal helpers ----------------------------------------------------

func _register_asset(kind: StringName, source_id: StringName, origin_id: Variant, cost: int, useful_life_days: int) -> void:
	# Mark the source as CAPITAL_EXPENDITURE so the build cash outflow
	# (already in Ledger) is correctly excluded from IS opex. Idempotent.
	categories[source_id] = Category.CAPITAL_EXPENDITURE
	var asset: Dictionary = {
		"asset_id": _next_asset_id,
		"kind": kind,
		"source_id": source_id,
		"origin_id": origin_id,
		"cost": cost,
		"useful_life_days": useful_life_days,
		"acquired_day": SimClock.current_day,
		"accumulated_depreciation": 0,
		"disposed_day": -1,
		"disposal_proceeds": 0,
	}
	_next_asset_id += 1
	assets.append(asset)


func _dispose_asset(idx: int) -> void:
	var asset: Dictionary = assets[idx]
	# Find the refund: scan back from the end of Ledger.transactions for the
	# most recent income tx whose source_id matches this asset's def id.
	# EntityRegistry.remove() posts the refund immediately before emitting
	# entity_removed, so the refund (if any) is the freshest matching tx.
	var refund: int = 0
	var ledger_txs: Array[Dictionary] = Ledger.transactions
	for i in range(ledger_txs.size() - 1, -1, -1):
		var tx: Dictionary = ledger_txs[i]
		if tx["kind"] != Ledger.KIND_INCOME:
			continue
		if tx["source_id"] != asset["source_id"]:
			continue
		# Must be from the current day (today's removal posted today).
		if int(tx["day"]) != SimClock.current_day:
			continue
		refund = int(tx["amount"])
		break

	asset["disposed_day"] = SimClock.current_day
	asset["disposal_proceeds"] = refund
	# Book value at the moment of disposal uses the live
	# accumulated_depreciation (i.e. depreciation through the most recent
	# day_ending). Disposing mid-day does NOT trigger an extra depreciation
	# slice — spec choice for simplicity.
	var book_value: int = int(asset["cost"]) - int(asset["accumulated_depreciation"])
	var pnl: int = refund - book_value
	if pnl >= 0:
		disposals.append({
			"day": SimClock.current_day,
			"amount": pnl,
			"gain": true,
			"asset_id": asset["asset_id"],
		})
	else:
		disposals.append({
			"day": SimClock.current_day,
			"amount": -pnl,
			"gain": false,
			"asset_id": asset["asset_id"],
		})


func _find_held_asset(kind: StringName, origin_id: Variant) -> int:
	for i in assets.size():
		var a: Dictionary = assets[i]
		if a["kind"] != kind:
			continue
		if int(a["disposed_day"]) != -1:
			continue
		if a["origin_id"] == origin_id:
			return i
	return -1


func _find_held_asset_for_placement(region_id: int, index: int) -> int:
	for i in assets.size():
		var a: Dictionary = assets[i]
		if a["kind"] != KIND_PLACEMENT:
			continue
		if int(a["disposed_day"]) != -1:
			continue
		var oid: Array = a["origin_id"]
		if int(oid[0]) == region_id and int(oid[1]) == index:
			return i
	return -1


# Returns the accumulated depreciation for this asset that has been
# *journaled* on days ≤ as_of_day. Source of truth = the journal entries.
# Avoids any drift between live posting and BS replay.
func _accumulated_depreciation_at(asset: Dictionary, as_of_day: int) -> int:
	var asset_id: int = int(asset["asset_id"])
	var total: int = 0
	for d_entry: Dictionary in depreciation_journal:
		if int(d_entry["asset_id"]) != asset_id:
			continue
		if int(d_entry["day"]) > as_of_day:
			continue
		total += int(d_entry["amount"])
	return total


func _starting_capital() -> int:
	if ContentDB.balance_config != null:
		return int(ContentDB.balance_config.starting_cash)
	return Ledger.DEFAULT_STARTING_CASH
