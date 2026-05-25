# Accounting — Income Statement & Balance Sheet (US-GAAP-style)

The engine ships the `Ledger` (cash-basis) and now `Accounting` (accrual-basis,
US-GAAP-style). Both coexist. `Ledger` remains authoritative for cash —
balances, recurring rules, transaction log — and games that don't care about
finance reporting can ignore `Accounting` entirely. `Accounting` overlays a
journal of capital expenditures, depreciation, and revenue/expense
categorization on top of the cash-basis stream, and exposes an Income
Statement (IS) and Balance Sheet (BS) at any reporting period.

This is generic engine work: every tycoon game benefits, and it's a faithful
teaching surface for real finance (capex vs opex, depreciation, retained
earnings, the accounting equation).

## Intent

1. **Coexist with the cash-basis Ledger.** Don't change Ledger semantics. A
   build still posts the full `build_cost` as a cash expense — that's correct
   for the cash story. Accounting reads the *same* transactions and reshapes
   them into accrual statements.
2. **Capex becomes an asset, not an expense.** When a placement or entity is
   acquired, Accounting registers it in the **asset register** at cost. Over
   its `useful_life_days`, that cost is recognized as **depreciation expense**
   one day at a time. The IS shows daily depreciation; the BS shows
   gross PP&E (cost) and accumulated depreciation.
3. **Game-registered categorization.** The engine knows nothing about which
   `source_id` is "ticket revenue" vs "utilities expense". Games call
   `Accounting.register_category(source_id, Category.REVENUE)` (etc.) at
   startup. Uncategorized cash-basis transactions fall into `OTHER_*`
   buckets so the books still balance.
4. **The accounting equation balances** every report. We compute it as
   `Assets − (Liabilities + Equity)` and report the delta; for v1 with no
   debt this should always be `0`.
5. **Integer money throughout.** Same units as Ledger. No floats sneaking
   in — they break round-trip exactness.

## Design calls

**Depreciation timing.** When an asset is acquired mid-day, it starts
depreciating on the *next* `day_ending`. Rationale: depreciation is a
*period-end* allocation; you don't depreciate something that hasn't been
"in service" for a full period yet. This is the simpler half-year-convention
analogue — easier to reason about, easier to test (an asset acquired on day
5 with a 10-day life starts depreciating on day 5's settlement so its last
depreciation slice lands on day 14 and the BS shows it fully depreciated by
day 14's report). Formally: on `day_ending` for day `D`, an asset acquired
on day `D` or earlier is eligible; its accumulated depreciation increases.

**Asset disposal.** When `entity_removed` / `placement_removed` fires,
`EntityRegistry` (or `RegionRegistry`) posts a refund to `Ledger` *and then*
emits the removal signal. `Accounting` subscribes to the removal signal,
finds the asset in its register, computes book value
(`cost − accumulated_depreciation`), inspects the last Ledger transaction
that carries the disposed asset's `def_id` as `source_id`, and journals a
**gain on disposal** (refund > book value, classified as `OTHER_INCOME`) or
**loss on disposal** (refund < book value, classified as `OTHER_EXPENSE`).
The cash side is *already* in Ledger — the gain/loss line only adjusts the
IS view; cash isn't double-counted. Cleaner than parsing `sell_<def_id>`
strings: no convention pressure on Ledger, all coupling lives in
`Accounting`.

## Categories

```gdscript
enum Category {
    REVENUE,              # top of IS
    COGS,                 # cost of goods/services sold; subtracts from revenue
    OPERATING_EXPENSE,    # rent, utilities, maintenance, salaries
    OTHER_INCOME,         # gains on disposal, interest income, etc.
    OTHER_EXPENSE,        # losses on disposal, one-offs
    CAPITAL_EXPENDITURE,  # build/upgrade outlays — NOT an expense; becomes an asset
}
```

Maintenance recurring rules registered by `EntityRegistry` /
`RegionRegistry` should be categorized by the game as
`OPERATING_EXPENSE`; the engine ships defaults so the maintenance rule ids
(`maint_<n>`, `place_maint_<r>_<i>`) auto-categorize as
`OPERATING_EXPENSE`. Build/upgrade `source_id`s should be categorized as
`CAPITAL_EXPENDITURE`; the engine treats unrecognized `source_id`s on
expense transactions as `OTHER_EXPENSE` and on income transactions as
`OTHER_INCOME` so the IS always balances.

## Asset register

One entry per acquired asset:

```
{
  asset_id: int,                  # accounting-side id (separate from instance ids)
  kind: StringName,               # "entity" | "placement"
  source_id: StringName,          # def id (entity_def_id or placeable_def_id)
  origin_id: Variant,             # int (entity instance_id) or [region_id, index] for placements
  cost: int,                      # original capex
  useful_life_days: int,          # 0 means immediate-expense (skip register; book as OPERATING_EXPENSE)
  acquired_day: int,              # SimClock.current_day at acquisition
  accumulated_depreciation: int,  # grows daily until == cost
  disposed_day: int,              # -1 if still held
  disposal_proceeds: int,         # 0 if still held
}
```

When `useful_life_days == 0`, no register entry is created; the cost
flows through as a `CAPITAL_EXPENDITURE` (no BS impact — see "Reconciliation"
below) and is *also* recognized as an immediate operating expense on the IS,
matching the cash-basis story. This makes the schema field backward-compatible
with the existing `EntityDef`s in the engine's example tuning that don't
specify a useful life.

## Daily depreciation

On `day_ending(day=D)`, for each held asset with `useful_life_days > 0`:

```
remaining_cost = cost - accumulated_depreciation
days_used     = D - acquired_day + 1   # acquisition day counts as the first
days_left     = useful_life_days - (days_used - 1)
if days_left <= 0:                     # already fully depreciated
    skip
daily_slice   = remaining_cost / days_left   # integer division
                                              # last slice mops up the remainder
accumulated_depreciation += daily_slice
depreciation_journal.append({day, asset_id, amount: daily_slice,
                             source_id: &"_depreciation"})
```

Carrying the remainder via `remaining_cost / days_left` guarantees the
total depreciation over the asset's life equals `cost` exactly (no
fractional drift). Depreciation is a **non-cash expense** — it is *not*
posted to `Ledger` (doing so would falsify the cash balance). Accounting
keeps its own `depreciation_journal` and uses it to feed the IS
depreciation line and the BS accumulated_depreciation column.

## Income Statement

For a period `[start_day, end_day]` (inclusive):

```
revenue            = sum(income tx where category == REVENUE)
cogs               = sum(expense tx where category == COGS)
gross_profit       = revenue - cogs
operating_expenses = {
    "<sub-category id>": sum(expense tx where category == OPERATING_EXPENSE
                             grouped by source_id),
    ...
}
depreciation       = sum(expense tx where source_id == &"_depreciation")
operating_income   = gross_profit - sum(operating_expenses.values()) - depreciation
other_income       = sum(income tx where category == OTHER_INCOME)
                   + gains_on_disposal_in_period
other_expense      = sum(expense tx where category == OTHER_EXPENSE)
                   + losses_on_disposal_in_period
other              = other_income - other_expense
net_income         = operating_income + other
```

Returned as:
```
{
  revenue: int, cogs: int, gross_profit: int,
  operating_expenses: Dictionary[StringName -> int],
  depreciation: int,
  operating_income: int,
  other_income: int, other_expense: int, other: int,
  net_income: int,
  period: {start_day: int, end_day: int},
}
```

## Balance Sheet

For a date `as_of_day = D`:

```
cash                      = Ledger.balance                 # already integer
ppe_gross                 = sum(cost for asset in register
                                where acquired_day <= D and
                                (disposed_day == -1 or disposed_day > D))
accumulated_depreciation  = sum of depreciation accrued through D
                            (per-asset; computed by replaying schedule
                            up to min(D, disposed_day-1) if disposed)
ppe_net                   = ppe_gross - accumulated_depreciation
total_assets              = cash + ppe_net
total_liabilities         = 0
starting_capital          = ContentDB.balance_config.starting_cash
retained_earnings         = (lifetime net income through D)
total_equity              = starting_capital + retained_earnings
balances                  = (total_assets == total_liabilities + total_equity)
balance_check_delta       = total_assets - (total_liabilities + total_equity)
```

The lifetime net-income identity is what makes the equation hold:

```
retained_earnings = lifetime revenue + other_income
                  - lifetime cogs - operating_expenses - depreciation
                  - other_expense
                  - capex   <-- because capex left cash but added PP&E
                  + (PP&E added by capex through day D, at cost)
                  - lifetime depreciation through D
```

The two depreciation terms cancel in the closed form, leaving:

```
retained_earnings = lifetime non-capex income
                  - lifetime non-capex expense
                  + (PP&E gross through D - PP&E disposed cost through D)
                  - cumulative accumulated_depreciation through D
                  + capex_cash_out_through_D
```

Equivalently and more cleanly: `retained_earnings = (cash - starting_capital)
+ ppe_net + disposal_adjustments`. Implementation computes it this way to
make the equation trivially hold; the IS / lifetime-IS path is the
*conceptual* derivation in the spec.

## Reporting periods

Helpers expose the four common windows. All use **inclusive** day ranges:
- `get_income_statement_today()` → `get_income_statement(current_day, current_day)`
- `get_income_statement_for_period()` → uses `BalanceConfig.days_per_period`
  (the engine's "week" — 7 days by default)
- `get_income_statement_for_month()` → trailing 30 days
- `get_income_statement_all_time()` → `[0, current_day]`

`get_balance_sheet_today()` / `get_balance_sheet(as_of_day)` are the BS
analogues.

## Worked Examples

Setup for all rows below. Theme-agnostic placeholders:
- Starting cash: `1000`
- Two `EntityDef`s:
  - `E_A`: build_cost=`200`, maintenance=`0`, useful_life_days=`10`
  - `E_B`: build_cost=`100`, maintenance=`0`, useful_life_days=`0`
    (no depreciation; immediate expense)
- Categories registered:
  - `E_A` → `CAPITAL_EXPENDITURE`
  - `E_B` → `OPERATING_EXPENSE`
  - `&"ticket"` → `REVENUE`
  - `&"supplies"` → `COGS`
  - `&"utilities"` → `OPERATING_EXPENSE`

Each row below mirrors as one GUT test in
`tests/autoload/test_accounting.gd`. Drift between table and code is a
build failure.

| # | scenario                                                                                                                                                                                                                                                                                       | expected (key fields)                                                                                                                                                              |
|---|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | Initial state — no actions taken. Query BS as_of_day=0.                                                                                                                                                                                                                                        | cash=1000, ppe_gross=0, ppe_net=0, total_assets=1000, total_equity=1000, balances=true, delta=0                                                                                    |
| 2 | Day 0: place one `E_A`. Query BS as_of_day=0 (same day, no `day_ending` yet).                                                                                                                                                                                                                  | cash=800, ppe_gross=200, accumulated_depreciation=0, ppe_net=200, total_assets=1000, retained_earnings=0 (capex isn't an expense), balances=true                                   |
| 3 | Day 0: post_income(50, "tickets", &"ticket"). Query IS for day 0.                                                                                                                                                                                                                              | revenue=50, cogs=0, operating_expenses={}, depreciation=0, operating_income=50, net_income=50                                                                                      |
| 4 | Day 0: post_expense(10, "utilities", &"utilities") then post_expense(25, "supplies", &"supplies"). Query IS for day 0.                                                                                                                                                                          | revenue=0, cogs=25, operating_expenses={utilities: 10}, depreciation=0, operating_income=-35, net_income=-35                                                                       |
| 5 | Day 0: place `E_A`. Advance one full day. Query BS as_of_day=1.                                                                                                                                                                                                                                | ppe_gross=200, accumulated_depreciation=20 (200/10), ppe_net=180, cash=800 (depreciation is non-cash), total_assets=980, retained_earnings=-20, total_equity=980, balances=true   |
| 6 | Day 0: place `E_A`. Advance 5 full days, then remove the entity. EntityRegistry refunds 100 (half of total invested). Query IS for days 0..5.                                                                                                                                                  | depreciation=100 (5 × 20), book value at remove = 200-100=100, refund 100 → pnl=0 (no gain or loss), other=0, net_income=-100                                                       |
| 7 | Day 0: place `E_A`. Advance 2 full days, then remove. Refund = 100. Book value = 200 - 40 = 160. Loss on disposal = 60. Query IS days 0..2.                                                                                                                                                    | other_expense includes loss=60, depreciation=40, net_income=-100                                                                                                                   |
| 8 | Day 0: place `E_A`. Place `E_B` (immediate-expense). post_income(300, "tickets", &"ticket"). post_expense(50, "supplies", &"supplies"). Advance one day. Query IS for day 0 AND verify BS equation holds as_of_day=1.                                                                          | IS: revenue=300, cogs=50, gross_profit=250, opex={E_B:100}, depreciation=20, op_income=130, net_income=130. BS as_of_day=1: cash=1000-200-100+300-50=950 (depreciation is non-cash), ppe_net=180, total_assets=1130, equity=1000+130=1130, balances=true |

## Implementation outline

- `Accounting` is an autoload, added to `project.godot` autoload list after
  `RegionRegistry` (it subscribes to `entity_placed/removed` and
  `placement_added/removed`, both produced upstream).
- Holds `assets: Array[Dictionary]`, `categories: Dictionary[StringName→int]`,
  `_next_asset_id: int`.
- Subscribes to `EventBus.day_ending` → posts daily depreciation.
- Subscribes to `EventBus.entity_placed/removed` and
  `EventBus.placement_added/removed` → maintains the register.
- Exposes `register_category`, `get_income_statement`, `get_balance_sheet`,
  plus period-convenience wrappers.
- `reset()` clears everything; tests call it in `before_each`.
- No save/load round-trip in v1 — the asset register can be rederived on
  load by replaying `entity_registry.save_state()` against `acquired_day=0`,
  which is conservative but correct for "all-time" reporting and is the
  same workaround `EntityRegistry` uses for maintenance rules. A proper
  save/load can come in v0.6.

Spec source for the implementing class:
`# Spec: design/algorithms/accounting.md`
