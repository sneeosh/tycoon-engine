extends GutTest
# Tests for MarkdownTuningParser — Prompt 4.
# Spec: docs/build-plan.md §7 (Prompt 4), §3 (design-editable layer)
#
# Parser tests are file-based. Each test writes a small fixture to user://
# and asserts on the resulting Dictionary structure.

const TMP_DIR := "user://test_md_parser/"


func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))


func _write(name: String, content: String) -> String:
	var path := TMP_DIR + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f.close()
	return path


# --- Scalars ---------------------------------------------------------------

func test_parses_key_value_scalars() -> void:
	var path := _write("scalars.md", """# Title

## Globals

starting_cash = 1000
daily_settlement_enabled = true
multiplier = 0.5
""")
	var r := MarkdownTuningParser.parse(path)
	assert_eq(r["errors"].size(), 0)
	var s: Dictionary = r["sections"]["Globals"]["scalars"]
	assert_eq(s["starting_cash"]["raw"], "1000")
	assert_eq(s["daily_settlement_enabled"]["raw"], "true")
	assert_eq(s["multiplier"]["raw"], "0.5")


func test_scalars_record_source_line() -> void:
	var path := _write("scalar_lines.md", """## S

a = 1
b = 2
""")
	var r := MarkdownTuningParser.parse(path)
	var s: Dictionary = r["sections"]["S"]["scalars"]
	assert_eq(s["a"]["line"], 3)
	assert_eq(s["b"]["line"], 4)


func test_duplicate_scalar_in_section_errors() -> void:
	var path := _write("dup_scalar.md", """## S
a = 1
a = 2
""")
	var r := MarkdownTuningParser.parse(path)
	assert_eq(r["errors"].size(), 1)
	assert_string_contains(r["errors"][0], "duplicate key 'a'")


# --- Tables ----------------------------------------------------------------

func test_parses_pipe_table() -> void:
	var path := _write("table.md", """## Things

| id  | label   | cost |
| --- | ------- | ---- |
| a   | Alpha   | 100  |
| b   | Beta    | 200  |
""")
	var r := MarkdownTuningParser.parse(path)
	assert_eq(r["errors"].size(), 0)
	var tables: Array = r["sections"]["Things"]["tables"]
	assert_eq(tables.size(), 1)
	var t: Dictionary = tables[0]
	assert_eq(t["headers"], ["id", "label", "cost"])
	assert_eq(t["rows"].size(), 2)
	assert_eq(t["rows"][0]["id"], "a")
	assert_eq(t["rows"][0]["cost"], "100")
	assert_eq(t["rows"][1]["label"], "Beta")


func test_table_rows_record_source_line() -> void:
	var path := _write("table_lines.md", """## T

| id | x |
| -- | - |
| a  | 1 |
| b  | 2 |
""")
	var r := MarkdownTuningParser.parse(path)
	var t: Dictionary = r["sections"]["T"]["tables"][0]
	assert_eq(t["row_lines"][0], 5)
	assert_eq(t["row_lines"][1], 6)


func test_table_row_cell_count_mismatch_errors() -> void:
	var path := _write("ragged.md", """## T
| a | b | c |
| - | - | - |
| 1 | 2 |
""")
	var r := MarkdownTuningParser.parse(path)
	assert_eq(r["errors"].size(), 1)
	assert_string_contains(r["errors"][0], "2 cells, header has 3")


func test_two_tables_in_one_section_separated_by_blank_line() -> void:
	var path := _write("two_tables.md", """## S

| a | b |
| - | - |
| 1 | 2 |

| x | y |
| - | - |
| 9 | 8 |
""")
	var r := MarkdownTuningParser.parse(path)
	var tables: Array = r["sections"]["S"]["tables"]
	assert_eq(tables.size(), 2)
	assert_eq(tables[0]["headers"], ["a", "b"])
	assert_eq(tables[1]["headers"], ["x", "y"])


# --- Sections --------------------------------------------------------------

func test_content_before_first_section_errors() -> void:
	var path := _write("no_section.md", """a = 1
""")
	var r := MarkdownTuningParser.parse(path)
	assert_eq(r["errors"].size(), 1)
	assert_string_contains(r["errors"][0], "before any ## section header")


func test_duplicate_section_errors() -> void:
	var path := _write("dup_section.md", """## A
x = 1
## A
y = 2
""")
	var r := MarkdownTuningParser.parse(path)
	assert_eq(r["errors"].size(), 1)
	assert_string_contains(r["errors"][0], "duplicate section 'A'")


# --- Comments --------------------------------------------------------------

func test_html_comments_ignored_multiline() -> void:
	var path := _write("html_comments.md", """<!--
this is ignored
spanning multiple lines
-->
## S
a = 1
""")
	var r := MarkdownTuningParser.parse(path)
	assert_eq(r["errors"].size(), 0)
	assert_eq(r["sections"]["S"]["scalars"]["a"]["raw"], "1")


func test_top_level_hash_lines_ignored() -> void:
	var path := _write("top_hash.md", """# This is a title
# Subtitle

## S
a = 1
""")
	var r := MarkdownTuningParser.parse(path)
	assert_eq(r["errors"].size(), 0)


# --- File not found --------------------------------------------------------

func test_missing_file_records_error() -> void:
	var r := MarkdownTuningParser.parse("user://does_not_exist.md")
	assert_eq(r["errors"].size(), 1)
	assert_string_contains(r["errors"][0], "could not open")
