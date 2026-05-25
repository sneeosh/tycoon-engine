extends GutTest
# Tests for Accounting — v0.5.0.
# Spec: design/algorithms/accounting.md
#
# Each worked-examples row in the spec is mirrored one-to-one here so drift
# between code and spec is a build failure. Tests inject EntityDefs into
# ContentDB directly (matches test_entity_registry.gd's pattern) so balance
# numbers stay independent of the shipped example tuning.

const E_A := &"test_acct_E_A"
const E_B := &"test_acct_E_B"


func before_each() -> void:
	# Per-test clean state.
	SaveService.autosave_enabled = false
	Accounting.reset()
	EntityRegistry.reset()
	EntityRegistry.configure(0.5)
	# Disable agent spawning so advance_tick() in our day-rollover helpers
	# doesn't churn AgentPool and leak agents into the free pool that other
	# test files rely on being empty.
	AgentPool.reset()
	AgentPool.configure(0.0)
	Ledger.reset(1000)
	SimClock.current_tick = 0
	SimClock.current_day = 0
	SimClock.current_period = 0
	SimClock.ticks_per_day = 5
	SimClock.days_per_period = 7

	# Define test entities. E_A is depreciable (10-day life, cost 200);
	# E_B is immediate-expense (no useful_life), cost 100.
	var a := EntityDef.new()
	a.id = E_A
	a.display_name = "E_A"
	a.build_cost = 200
	a.useful_life_days = 10
	a.footprint = Vector2i(1, 1)
	ContentDB.entity_defs[E_A] = a

	var b := EntityDef.new()
	b.id = E_B
	b.display_name = "E_B"
	b.build_cost = 100
	b.useful_life_days = 0
	b.footprint = Vector2i(1, 1)
	ContentDB.entity_defs[E_B] = b

	# Register categories per spec.
	Accounting.register_category(&"ticket", Accounting.Category.REVENUE)
	Accounting.register_category(&"supplies", Accounting.Category.COGS)
	Accounting.register_category(&"utilities", Accounting.Category.OPERATING_EXPENSE)


func after_each() -> void:
	ContentDB.entity_defs.erase(E_A)
	ContentDB.entity_defs.erase(E_B)


# ---------------------------------------------------------------------------
# Worked example #1 — initial state
# ---------------------------------------------------------------------------

func test_row1_initial_state_balance_sheet() -> void:
	var bs: Dictionary = Accounting.get_balance_sheet(0)
	assert_eq(bs["assets"]["cash"], 1000)
	assert_eq(bs["assets"]["ppe_gross"], 0)
	assert_eq(bs["assets"]["accumulated_depreciation"], 0)
	assert_eq(bs["assets"]["ppe_net"], 0)
	assert_eq(bs["assets"]["total_assets"], 1000)
	assert_eq(bs["equity"]["starting_capital"], 1000)
	assert_eq(bs["equity"]["retained_earnings"], 0)
	assert_eq(bs["equity"]["total_equity"], 1000)
	assert_eq(bs["liabilities"]["total_liabilities"], 0)
	assert_true(bs["balances"])
	assert_eq(bs["balance_check_delta"], 0)


# ---------------------------------------------------------------------------
# Worked example #2 — capex is an asset, not an expense
# ---------------------------------------------------------------------------

func test_row2_capex_creates_asset_does_not_reduce_equity() -> void:
	var id: int = EntityRegistry.place(E_A, Vector2i(0, 0))
	assert_gt(id, 0)
	var bs: Dictionary = Accounting.get_balance_sheet(0)
	assert_eq(bs["assets"]["cash"], 800)
	assert_eq(bs["assets"]["ppe_gross"], 200)
	assert_eq(bs["assets"]["accumulated_depreciation"], 0)
	assert_eq(bs["assets"]["ppe_net"], 200)
	assert_eq(bs["assets"]["total_assets"], 1000)
	assert_eq(bs["equity"]["retained_earnings"], 0,
		"capex is not an expense — retained earnings unchanged")
	assert_true(bs["balances"])


# ---------------------------------------------------------------------------
# Worked example #3 — revenue flows through to net income
# ---------------------------------------------------------------------------

func test_row3_revenue_on_income_statement() -> void:
	Ledger.post_income(50, "tickets", &"ticket")
	var is_stmt: Dictionary = Accounting.get_income_statement(0, 0)
	assert_eq(is_stmt["revenue"], 50)
	assert_eq(is_stmt["cogs"], 0)
	assert_eq(is_stmt["depreciation"], 0)
	assert_eq((is_stmt["operating_expenses"] as Dictionary).size(), 0)
	assert_eq(is_stmt["operating_income"], 50)
	assert_eq(is_stmt["net_income"], 50)


# ---------------------------------------------------------------------------
# Worked example #4 — operating expense vs cogs categorization
# ---------------------------------------------------------------------------

func test_row4_operating_expense_and_cogs_categorization() -> void:
	Ledger.post_expense(10, "utilities", &"utilities")
	Ledger.post_expense(25, "supplies", &"supplies")
	var is_stmt: Dictionary = Accounting.get_income_statement(0, 0)
	assert_eq(is_stmt["revenue"], 0)
	assert_eq(is_stmt["cogs"], 25)
	assert_eq(is_stmt["depreciation"], 0)
	assert_eq((is_stmt["operating_expenses"] as Dictionary).get(&"utilities", 0), 10)
	assert_eq(is_stmt["operating_income"], -35)
	assert_eq(is_stmt["net_income"], -35)


# ---------------------------------------------------------------------------
# Worked example #5 — one day of straight-line depreciation
# ---------------------------------------------------------------------------

func test_row5_one_day_of_depreciation() -> void:
	var id: int = EntityRegistry.place(E_A, Vector2i(0, 0))
	assert_gt(id, 0)
	_advance_one_day()
	var bs: Dictionary = Accounting.get_balance_sheet(1)
	assert_eq(bs["assets"]["ppe_gross"], 200)
	assert_eq(bs["assets"]["accumulated_depreciation"], 20)
	assert_eq(bs["assets"]["ppe_net"], 180)
	assert_eq(bs["assets"]["cash"], 800, "depreciation is non-cash")
	assert_eq(bs["assets"]["total_assets"], 980)
	assert_eq(bs["equity"]["retained_earnings"], -20)
	assert_eq(bs["equity"]["total_equity"], 980)
	assert_true(bs["balances"])


# ---------------------------------------------------------------------------
# Worked example #6 — clean disposal (refund == book value)
# ---------------------------------------------------------------------------

func test_row6_disposal_break_even_no_gain_or_loss() -> void:
	var id: int = EntityRegistry.place(E_A, Vector2i(0, 0))
	assert_gt(id, 0)
	for i in 5:
		_advance_one_day()
	# 5 day_endings → depreciation slices for days 0..4, each = 20, total 100.
	assert_true(EntityRegistry.remove(id))
	# Refund = floor(200 * 0.5) = 100. Book value = 200 - 100 = 100. pnl = 0.
	var is_stmt: Dictionary = Accounting.get_income_statement(0, 5)
	assert_eq(is_stmt["depreciation"], 100)
	assert_eq(is_stmt["revenue"], 0)
	assert_eq(is_stmt["other_income"], 0, "break-even disposal posts no gain")
	assert_eq(is_stmt["other_expense"], 0, "break-even disposal posts no loss")
	assert_eq(is_stmt["net_income"], -100)


# ---------------------------------------------------------------------------
# Worked example #7 — disposal at a loss
# ---------------------------------------------------------------------------

func test_row7_disposal_at_a_loss() -> void:
	var id: int = EntityRegistry.place(E_A, Vector2i(0, 0))
	assert_gt(id, 0)
	for i in 2:
		_advance_one_day()
	# 2 day_endings → depreciation 40. Book value = 160.
	assert_true(EntityRegistry.remove(id))
	# Refund = 100. Loss = 160 - 100 = 60.
	var is_stmt: Dictionary = Accounting.get_income_statement(0, 2)
	assert_eq(is_stmt["depreciation"], 40)
	assert_eq(is_stmt["other_expense"], 60, "loss on disposal")
	assert_eq(is_stmt["other_income"], 0)
	assert_eq(is_stmt["net_income"], -100, "-40 depreciation -60 loss")


# ---------------------------------------------------------------------------
# Worked example #8 — combined: capex, opex, revenue, cogs, depreciation, BS balances
# ---------------------------------------------------------------------------

func test_row8_combined_period_and_balance_sheet_equation() -> void:
	var id_a: int = EntityRegistry.place(E_A, Vector2i(0, 0))
	assert_gt(id_a, 0)
	var id_b: int = EntityRegistry.place(E_B, Vector2i(2, 2))
	assert_gt(id_b, 0)
	Ledger.post_income(300, "tickets", &"ticket")
	Ledger.post_expense(50, "supplies", &"supplies")
	_advance_one_day()

	var is_stmt: Dictionary = Accounting.get_income_statement(0, 0)
	assert_eq(is_stmt["revenue"], 300)
	assert_eq(is_stmt["cogs"], 50)
	assert_eq(is_stmt["gross_profit"], 250)
	assert_eq((is_stmt["operating_expenses"] as Dictionary).get(E_B, 0), 100,
		"E_B is immediate-expense, lands in operating_expenses keyed by its def id")
	assert_eq(is_stmt["depreciation"], 20)
	assert_eq(is_stmt["operating_income"], 130)
	assert_eq(is_stmt["net_income"], 130)

	var bs: Dictionary = Accounting.get_balance_sheet(1)
	assert_eq(bs["assets"]["cash"], 950, "1000-200-100+300-50; depreciation is non-cash")
	assert_eq(bs["assets"]["ppe_gross"], 200, "only E_A is depreciable; E_B not registered")
	assert_eq(bs["assets"]["accumulated_depreciation"], 20)
	assert_eq(bs["assets"]["ppe_net"], 180)
	assert_eq(bs["assets"]["total_assets"], 1130)
	assert_eq(bs["equity"]["total_equity"], 1130)
	assert_true(bs["balances"], "BS equation: assets = liabilities + equity")
	assert_eq(bs["balance_check_delta"], 0)


# ---------------------------------------------------------------------------
# Extra coverage — schema / wiring
# ---------------------------------------------------------------------------

func test_zero_useful_life_does_not_register_asset() -> void:
	var id: int = EntityRegistry.place(E_B, Vector2i(0, 0))
	assert_gt(id, 0)
	assert_eq(Accounting.assets.size(), 0,
		"useful_life_days=0 → no asset register entry")


func test_positive_useful_life_registers_asset() -> void:
	var id: int = EntityRegistry.place(E_A, Vector2i(0, 0))
	assert_gt(id, 0)
	assert_eq(Accounting.assets.size(), 1)
	var asset: Dictionary = Accounting.assets[0]
	assert_eq(asset["cost"], 200)
	assert_eq(asset["useful_life_days"], 10)
	assert_eq(asset["acquired_day"], 0)
	assert_eq(int(asset["disposed_day"]), -1)


func test_depreciation_does_not_post_to_ledger() -> void:
	# Verifies the non-cash design call. Cash balance before and after
	# day_ending depreciation must be identical.
	var id: int = EntityRegistry.place(E_A, Vector2i(0, 0))
	assert_gt(id, 0)
	var cash_before: int = Ledger.get_balance()
	_advance_one_day()
	var cash_after: int = Ledger.get_balance()
	assert_eq(cash_after, cash_before, "depreciation is non-cash")
	assert_eq(Accounting.depreciation_journal.size(), 1)


func test_full_life_depreciation_sums_exactly_to_cost() -> void:
	# Carries the remainder via remaining/days_left so total dep == cost.
	var id: int = EntityRegistry.place(E_A, Vector2i(0, 0))
	assert_gt(id, 0)
	for i in 10:
		_advance_one_day()
	var total_dep: int = 0
	for entry: Dictionary in Accounting.depreciation_journal:
		total_dep += int(entry["amount"])
	assert_eq(total_dep, 200, "lifetime depreciation equals original cost exactly")
	# Further day_endings post no more depreciation.
	_advance_one_day()
	var total_dep_after: int = 0
	for entry: Dictionary in Accounting.depreciation_journal:
		total_dep_after += int(entry["amount"])
	assert_eq(total_dep_after, 200, "no over-depreciation past useful life")


func test_uncategorized_expense_falls_into_other_expense() -> void:
	Ledger.post_expense(33, "mystery", &"mystery_source")
	var is_stmt: Dictionary = Accounting.get_income_statement(0, 0)
	assert_eq(is_stmt["other_expense"], 33,
		"uncategorized → OTHER_EXPENSE so books still balance")


func test_uncategorized_income_falls_into_other_income() -> void:
	Ledger.post_income(77, "windfall", &"mystery_income")
	var is_stmt: Dictionary = Accounting.get_income_statement(0, 0)
	assert_eq(is_stmt["other_income"], 77)


func test_gain_on_disposal() -> void:
	# Refund > book value → gain (OTHER_INCOME).
	# Configure refund_fraction to 1.0 so the refund is the full cost; then
	# disposal_proceeds (200) > book_value (160 after 2 days) → gain 40.
	EntityRegistry.configure(1.0)
	var id: int = EntityRegistry.place(E_A, Vector2i(0, 0))
	assert_gt(id, 0)
	for i in 2:
		_advance_one_day()
	assert_true(EntityRegistry.remove(id))
	var is_stmt: Dictionary = Accounting.get_income_statement(0, 2)
	assert_eq(is_stmt["other_income"], 40, "gain on disposal = refund 200 - book 160")
	assert_eq(is_stmt["other_expense"], 0)


func test_period_convenience_wrappers() -> void:
	# IS-today returns same numbers as get_income_statement(current_day, current_day).
	Ledger.post_income(42, "tickets", &"ticket")
	var today: Dictionary = Accounting.get_income_statement_today()
	assert_eq(today["revenue"], 42)
	var explicit: Dictionary = Accounting.get_income_statement(SimClock.current_day, SimClock.current_day)
	assert_eq(today["revenue"], explicit["revenue"])


func test_all_time_income_statement_spans_zero_to_current_day() -> void:
	Ledger.post_income(10, "tickets", &"ticket")
	_advance_one_day()
	Ledger.post_income(20, "tickets", &"ticket")
	_advance_one_day()
	var lifetime: Dictionary = Accounting.get_income_statement_all_time()
	assert_eq(lifetime["revenue"], 30)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _advance_one_day() -> void:
	for i in SimClock.ticks_per_day:
		SimClock.advance_tick()
