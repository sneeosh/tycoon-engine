# Economy — Starting Funds and Recurring Costs

<!--
Spec: docs/build-plan.md §3 (Ledger autoload)

This file is the SINGLE SOURCE OF TRUTH for the values below. The tuning loader
(Prompt 4) parses it at import time and compiles a typed Resource. Never edit
the generated .tres by hand; never hardcode these numbers in .gd files. The
loader fails loudly with file/line context on malformed syntax or out-of-range
values.

Format rules:
- `key = value` lines for scalar globals (one per line, whitespace around `=` ok)
- markdown pipe-tables for collections (header row + separator row + data rows)
- lines starting with `#` outside a code block, and HTML comments, are ignored
- ids are snake_case StringNames
-->

## Globals

starting_cash             = 1000
daily_settlement_enabled  = true

## Recurring expenses

| id             | label       | amount | period |
| -------------- | ----------- | ------ | ------ |
| utilities_base | Utilities   | 50     | daily  |
| insurance      | Insurance   | 20     | daily  |
