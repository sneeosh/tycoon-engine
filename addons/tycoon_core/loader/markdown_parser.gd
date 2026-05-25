extends RefCounted
class_name MarkdownTuningParser
# Spec: docs/build-plan.md §3 ("The design-editable layer"), Prompt 4.
#
# Parses one design/tuning/*.md file into a generic, schema-agnostic structure.
# Format (strict — see CLAUDE.md §3a):
#   - Top-level `# ` lines and HTML comments are ignored.
#   - `## Section Name` opens a section. All content lives inside a section.
#   - `key = value` lines are scalar assignments within the current section.
#   - Markdown pipe tables become row collections within the current section.
#   - Blank lines end the current table (so multiple tables per section work).
#
# Errors carry `<path>:<line>: <reason>` strings — never silent.
# Schema-specific compilation lives in ContentDB; the parser is dumb on purpose.

# Returns a Dictionary:
#   {
#     "path": String,
#     "errors": Array[String],
#     "sections": {
#       section_name: {
#         "line": int,                              # source line of `## header`
#         "scalars": { key: {"raw": String, "line": int} },
#         "tables": [ { "headers": Array[String],
#                       "rows": Array[Dictionary], # header → raw cell value
#                       "row_lines": Array[int] } ]
#       }
#     }
#   }
static func parse(path: String) -> Dictionary:
	var result := {
		"path": path,
		"errors": [] as Array[String],
		"sections": {},
	}

	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		result["errors"].append("%s: could not open file (error %d)" % [path, FileAccess.get_open_error()])
		return result

	var current_section_name: String = ""
	var pending_table: Dictionary = {}  # empty = no table in progress
	var in_html_comment := false
	var line_num := 0

	while not f.eof_reached():
		line_num += 1
		var raw_line := f.get_line()
		var stripped := raw_line.strip_edges()

		# HTML comment handling — supports multi-line and inline.
		if in_html_comment:
			if "-->" in stripped:
				in_html_comment = false
			continue
		if stripped.begins_with("<!--"):
			if not ("-->" in stripped.substr(4)):
				in_html_comment = true
			continue

		# Top-level `# ` (single hash = file title or commentary) → ignored.
		if stripped.begins_with("# "):
			pending_table = {}
			continue

		# Blank line ends a pending table.
		if stripped.is_empty():
			pending_table = {}
			continue

		# `## ` opens a new section.
		if stripped.begins_with("## "):
			current_section_name = stripped.substr(3).strip_edges()
			if current_section_name.is_empty():
				result["errors"].append("%s:%d: empty section name" % [path, line_num])
				continue
			if result["sections"].has(current_section_name):
				result["errors"].append("%s:%d: duplicate section '%s'" % [path, line_num, current_section_name])
				continue
			result["sections"][current_section_name] = {
				"line": line_num,
				"scalars": {},
				"tables": [] as Array,
			}
			pending_table = {}
			continue

		if current_section_name.is_empty():
			result["errors"].append("%s:%d: content before any ## section header: %s" % [path, line_num, stripped])
			continue

		var section: Dictionary = result["sections"][current_section_name]

		# Pipe table row.
		if stripped.begins_with("|"):
			var cells := _split_table_row(stripped)
			if pending_table.is_empty():
				# First | line in this run = header row.
				pending_table = {
					"headers": cells,
					"rows": [] as Array[Dictionary],
					"row_lines": [] as Array[int],
				}
				section["tables"].append(pending_table)
				continue
			# Separator row like |---|---|---|.
			if _is_separator_row(cells):
				continue
			var headers: Array = pending_table["headers"]
			if cells.size() != headers.size():
				result["errors"].append("%s:%d: table row has %d cells, header has %d" %
					[path, line_num, cells.size(), headers.size()])
				continue
			var row := {}
			for i in cells.size():
				row[headers[i]] = cells[i]
			pending_table["rows"].append(row)
			pending_table["row_lines"].append(line_num)
			continue

		# `key = value` scalar.
		if "=" in stripped:
			var eq_idx := stripped.find("=")
			var key := stripped.substr(0, eq_idx).strip_edges()
			var val := stripped.substr(eq_idx + 1).strip_edges()
			if key.is_empty():
				result["errors"].append("%s:%d: scalar with empty key" % [path, line_num])
				continue
			if section["scalars"].has(key):
				result["errors"].append("%s:%d: duplicate key '%s' in section '%s'" %
					[path, line_num, key, current_section_name])
				continue
			section["scalars"][key] = {"raw": val, "line": line_num}
			pending_table = {}
			continue

		result["errors"].append("%s:%d: couldn't parse line (not key=value, not table row): %s" %
			[path, line_num, stripped])

	return result


static func _split_table_row(line: String) -> Array[String]:
	var inner := line.strip_edges()
	if inner.begins_with("|"):
		inner = inner.substr(1)
	if inner.ends_with("|"):
		inner = inner.substr(0, inner.length() - 1)
	var parts: Array[String] = []
	for p in inner.split("|"):
		parts.append(p.strip_edges())
	return parts


static func _is_separator_row(cells: Array[String]) -> bool:
	for c in cells:
		var t := c.strip_edges().replace(":", "").replace("-", "")
		if not t.is_empty():
			return false
	return true
