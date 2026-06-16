extends Node
# Spec: docs/build-plan.md §3 (autoloads — ContentDB), §3.3a (design-editable
# layer), Prompt 4.
#
# Single source of compiled content. Parses design/tuning/*.md at startup,
# compiles into typed Resources, validates cross-references, and applies the
# results to live autoloads (SimClock, Ledger). Markdown is the canonical
# source — generated Resources are never persisted to .tres in this engine.
#
# Loud failures: every error carries `<path>:<line>: reason`. If any error is
# found during a load, ContentDB stays in `has_errors() == true` and does not
# apply changes to SimClock/Ledger. Tests inspect `load_errors` directly.

const TUNING_DIR := "res://design/tuning/"

var balance_config: BalanceConfig
var needs: Dictionary = {}            # StringName -> Need
var agent_types: Dictionary = {}      # StringName -> AgentType
var entity_defs: Dictionary = {}      # StringName -> EntityDef
var placeable_defs: Dictionary = {}   # StringName -> PlaceableDef (v0.4.0)
var conditions: Dictionary = {}       # StringName -> ConditionModifier
var unlock_nodes: Dictionary = {}     # StringName -> UnlockNode
var recurring_rules: Array[Dictionary] = []  # raw rule dicts for Ledger

var load_errors: Array[String] = []
var is_loaded: bool = false


func _ready() -> void:
	load_all()
	# Only push_error here, not inside load_all(), so tests can drive the
	# loader with deliberately-bad fixtures without tripping GUT's error
	# tracker. Production boots still see the loud failure on real bad data.
	if has_errors():
		for e in load_errors:
			push_error(e)


func has_errors() -> bool:
	return not load_errors.is_empty()


# Reload everything from `dir`. Used by autoload boot (default dir) and tests
# (custom dir pointing at fixtures).
func load_all(dir: String = TUNING_DIR) -> void:
	load_errors.clear()
	balance_config = BalanceConfig.new()
	needs.clear()
	agent_types.clear()
	entity_defs.clear()
	placeable_defs.clear()
	conditions.clear()
	unlock_nodes.clear()
	recurring_rules.clear()
	is_loaded = false

	# Load order matters: producers before consumers so cross-ref validation
	# has the full picture at the end.
	_load_file(dir, "balance.md", _compile_balance, false)
	_load_file(dir, "economy.md", _compile_economy, false)
	_load_file(dir, "conditions.md", _compile_conditions, true)
	_load_file(dir, "needs.md", _compile_needs, true)
	_load_file(dir, "entities.md", _compile_entities, true)
	_load_file(dir, "agents.md", _compile_agents, true)
	_load_file(dir, "placeables.md", _compile_placeables, true)
	_load_file(dir, "progression.md", _compile_progression, true)
	_load_file(dir, "navigation.md", _compile_navigation, true)

	_validate_cross_refs()

	if has_errors():
		return

	# Apply to live autoloads.
	SimClock.configure(balance_config.ticks_per_day, balance_config.days_per_period)
	Ledger.reset(balance_config.starting_cash)
	for rule in recurring_rules:
		Ledger.register_recurring(rule)
	EntityRegistry.configure(balance_config.remove_refund_fraction)
	AgentPool.configure(balance_config.base_spawn_rate)
	is_loaded = true


# --- Lookup queries --------------------------------------------------------

func get_entity_def(id: StringName) -> EntityDef:
	return entity_defs.get(id)

func get_agent_type(id: StringName) -> AgentType:
	return agent_types.get(id)

func get_need(id: StringName) -> Need:
	return needs.get(id)

func get_condition(id: StringName) -> ConditionModifier:
	return conditions.get(id)

func get_unlock_node(id: StringName) -> UnlockNode:
	return unlock_nodes.get(id)


# --- File loader plumbing --------------------------------------------------

func _load_file(dir: String, filename: String, compiler: Callable, optional: bool) -> void:
	var path := dir + filename
	if not FileAccess.file_exists(path):
		if not optional:
			load_errors.append("%s: required tuning file is missing" % path)
		return
	var parsed := MarkdownTuningParser.parse(path)
	for e in parsed["errors"]:
		load_errors.append(e)
	if parsed["errors"].is_empty():
		compiler.call(parsed)


# --- Compilers -------------------------------------------------------------

func _compile_balance(parsed: Dictionary) -> void:
	var path: String = parsed["path"]
	var time := _require_section(path, parsed, "Time")
	if time != null:
		balance_config.ticks_per_day = _scalar_int(path, time, "ticks_per_day", 1, 100000)
		balance_config.days_per_period = _scalar_int(path, time, "days_per_period", 1, 1000)
	var spawn := _require_section(path, parsed, "Spawn curve")
	if spawn != null:
		balance_config.spawn_curve_min_multiplier = _scalar_float(path, spawn, "spawn_curve_min_multiplier", 0.0, 10.0)
		balance_config.spawn_curve_max_multiplier = _scalar_float(path, spawn, "spawn_curve_max_multiplier", 0.0, 10.0)
		balance_config.spawn_curve_midpoint = _scalar_float(path, spawn, "spawn_curve_midpoint", 0.0, 1.0)
		balance_config.spawn_curve_steepness = _scalar_float(path, spawn, "spawn_curve_steepness", 0.1, 50.0)
	# `## Entities` is optional in balance.md; falls back to schema defaults.
	var entities_section: Dictionary = parsed["sections"].get("Entities", {})
	if not entities_section.is_empty():
		balance_config.remove_refund_fraction = _scalar_float(path, entities_section, "remove_refund_fraction", 0.0, 1.0)
	var agents_section: Dictionary = parsed["sections"].get("Agents", {})
	if not agents_section.is_empty():
		balance_config.base_spawn_rate = _scalar_float(path, agents_section, "base_spawn_rate", 0.0, 100.0)


func _compile_economy(parsed: Dictionary) -> void:
	var path: String = parsed["path"]
	var globals := _require_section(path, parsed, "Globals")
	if globals != null:
		balance_config.starting_cash = _scalar_int(path, globals, "starting_cash", 0, 1_000_000_000)
		balance_config.daily_settlement_enabled = _scalar_bool(path, globals, "daily_settlement_enabled")
	var recurring: Dictionary = parsed["sections"].get("Recurring expenses", {})
	if recurring.is_empty() or recurring.get("tables", []).is_empty():
		return
	var table: Dictionary = recurring["tables"][0]
	for row_idx in table["rows"].size():
		var row: Dictionary = table["rows"][row_idx]
		var line: int = table["row_lines"][row_idx]
		var id := _cell_string_name(path, row, line, "id")
		if id == &"":
			continue
		var amount := _cell_int(path, row, line, "amount", 0, 1_000_000_000)
		recurring_rules.append({
			"id": id,
			"label": row.get("label", String(id)),
			"amount": amount,
			"kind": Ledger.KIND_EXPENSE,
			"period": _cell_string_name(path, row, line, "period"),
		})


func _compile_conditions(parsed: Dictionary) -> void:
	var path: String = parsed["path"]
	var section: Dictionary = parsed["sections"].get("Conditions", {})
	if section.is_empty() or section.get("tables", []).is_empty():
		return
	var table: Dictionary = section["tables"][0]
	for row_idx in table["rows"].size():
		var row: Dictionary = table["rows"][row_idx]
		var line: int = table["row_lines"][row_idx]
		var c := ConditionModifier.new()
		c.id = _cell_string_name(path, row, line, "id")
		if c.id == &"":
			continue
		c.label = row.get("label", String(c.id))
		c.active = _cell_bool(path, row, line, "active", false)
		conditions[c.id] = c


func _compile_needs(parsed: Dictionary) -> void:
	var path: String = parsed["path"]
	var section: Dictionary = parsed["sections"].get("Needs", {})
	if section.is_empty() or section.get("tables", []).is_empty():
		return
	var table: Dictionary = section["tables"][0]
	for row_idx in table["rows"].size():
		var row: Dictionary = table["rows"][row_idx]
		var line: int = table["row_lines"][row_idx]
		var n := Need.new()
		n.id = _cell_string_name(path, row, line, "id")
		if n.id == &"":
			continue
		n.display_name = row.get("display_name", String(n.id))
		n.base_decay_per_tick = _cell_float(path, row, line, "base_decay_per_tick", 0.0, 1.0)
		needs[n.id] = n


func _compile_entities(parsed: Dictionary) -> void:
	var path: String = parsed["path"]

	# Entities first.
	var entities_section: Dictionary = parsed["sections"].get("Entities", {})
	if not entities_section.is_empty() and not entities_section.get("tables", []).is_empty():
		var table: Dictionary = entities_section["tables"][0]
		for row_idx in table["rows"].size():
			var row: Dictionary = table["rows"][row_idx]
			var line: int = table["row_lines"][row_idx]
			var ed := EntityDef.new()
			ed.id = _cell_string_name(path, row, line, "id")
			if ed.id == &"":
				continue
			ed.display_name = row.get("display_name", String(ed.id))
			ed.build_cost = _cell_int(path, row, line, "build_cost", 0, 1_000_000_000)
			ed.maintenance_cost = _cell_int(path, row, line, "maintenance_cost", 0, 1_000_000_000)
			ed.footprint = Vector2i(
				_cell_int(path, row, line, "footprint_x", 1, 100),
				_cell_int(path, row, line, "footprint_y", 1, 100))
			ed.sprite_key = _cell_string_name(path, row, line, "sprite_key")
			ed.satisfies = _cell_array_string_names(row, "satisfies")
			ed.appeal_profile = _cell_dict_string_name_float(path, row, line, "appeal_profile")
			# v0.4.0 zone fields (optional — pre-v0.4 tuning files omit them).
			if row.has("zone_kind"):
				ed.zone_kind = _cell_string_name(path, row, line, "zone_kind")
			if row.has("zone_tags"):
				ed.zone_tags = _cell_array_string_names(row, "zone_tags")
			# v0.5.0 accounting field — optional, defaults to 0
			# (no depreciation, immediate expense).
			if row.has("useful_life_days"):
				ed.useful_life_days = _cell_int(path, row, line, "useful_life_days", 0, 1_000_000)
			# v0.6.0 walkable-network fields (optional — see
			# design/algorithms/navigation.md). Absent columns leave the
			# schema defaults (walkable=false, cost 1.0, default network).
			if row.has("walkable"):
				ed.walkable = _cell_bool(path, row, line, "walkable", false)
			if row.has("traversal_cost"):
				ed.traversal_cost = _cell_float(path, row, line, "traversal_cost", 0.0, 1e9)
			if row.has("network_id"):
				var net_id := _cell_string_name(path, row, line, "network_id")
				if net_id != &"":
					ed.network_id = net_id
			if row.has("walkable_tags"):
				ed.walkable_tags = _cell_array_string_names(row, "walkable_tags")
			entity_defs[ed.id] = ed

	# Effects, applied to their owning entity by entity_id.
	var effects_section: Dictionary = parsed["sections"].get("Effects", {})
	if not effects_section.is_empty() and not effects_section.get("tables", []).is_empty():
		var table: Dictionary = effects_section["tables"][0]
		for row_idx in table["rows"].size():
			var row: Dictionary = table["rows"][row_idx]
			var line: int = table["row_lines"][row_idx]
			var entity_id := _cell_string_name(path, row, line, "entity_id")
			var owner: EntityDef = entity_defs.get(entity_id)
			if owner == null:
				load_errors.append("%s:%d: effect references unknown entity_id '%s'" % [path, line, entity_id])
				continue
			var e := Effect.new()
			e.id = _cell_string_name(path, row, line, "id")
			e.target = _cell_string_name(path, row, line, "target")
			e.operation = _cell_string_name(path, row, line, "operation")
			e.magnitude = _cell_float(path, row, line, "magnitude", -1e9, 1e9)
			e.proximity = _cell_float(path, row, line, "proximity", 0.0, 1000.0)
			e.conditions = _cell_array_string_names(row, "conditions")
			owner.effects.append(e)


func _compile_agents(parsed: Dictionary) -> void:
	var path: String = parsed["path"]
	var section: Dictionary = parsed["sections"].get("Agent types", {})
	if not section.is_empty() and not section.get("tables", []).is_empty():
		var table: Dictionary = section["tables"][0]
		for row_idx in table["rows"].size():
			var row: Dictionary = table["rows"][row_idx]
			var line: int = table["row_lines"][row_idx]
			var at := AgentType.new()
			at.id = _cell_string_name(path, row, line, "id")
			if at.id == &"":
				continue
			at.display_name = row.get("display_name", String(at.id))
			at.spawn_weight = _cell_float(path, row, line, "spawn_weight", 0.0, 100.0)
			# v0.7.0 spawn-balance flag — optional column, defaults to true so
			# absent columns and pre-v0.7 tuning behave exactly as before.
			if row.has("drives_spawn_balance"):
				at.drives_spawn_balance = _cell_bool(path, row, line, "drives_spawn_balance", true)
			agent_types[at.id] = at

	# Need specs — attach Needs to AgentTypes with overrides.
	var specs_section: Dictionary = parsed["sections"].get("Need specs", {})
	if not specs_section.is_empty() and not specs_section.get("tables", []).is_empty():
		var table: Dictionary = specs_section["tables"][0]
		for row_idx in table["rows"].size():
			var row: Dictionary = table["rows"][row_idx]
			var line: int = table["row_lines"][row_idx]
			var agent_id := _cell_string_name(path, row, line, "agent_id")
			var need_id := _cell_string_name(path, row, line, "need_id")
			var agent: AgentType = agent_types.get(agent_id)
			var need: Need = needs.get(need_id)
			if agent == null:
				load_errors.append("%s:%d: need spec references unknown agent_id '%s'" % [path, line, agent_id])
				continue
			if need == null:
				load_errors.append("%s:%d: need spec references unknown need_id '%s'" % [path, line, need_id])
				continue
			var ns := NeedSpec.new()
			ns.need = need
			ns.initial_level = _cell_float(path, row, line, "initial_level", 0.0, 1.0)
			ns.decay_rate_multiplier = _cell_float(path, row, line, "decay_rate_multiplier", 0.0, 10.0)
			ns.threshold = _cell_float(path, row, line, "threshold", 0.0, 1.0)
			agent.needs.append(ns)

	# Traits — optional per-agent sampling ranges. Each row contributes one
	# axis. AgentPool.spawn() samples uniformly from [min, max] using the
	# sim RNG at spawn time and writes the result to agent.traits[axis].
	var traits_section: Dictionary = parsed["sections"].get("Traits", {})
	if not traits_section.is_empty() and not traits_section.get("tables", []).is_empty():
		var table: Dictionary = traits_section["tables"][0]
		for row_idx in table["rows"].size():
			var row: Dictionary = table["rows"][row_idx]
			var line: int = table["row_lines"][row_idx]
			var agent_id := _cell_string_name(path, row, line, "agent_id")
			var trait_id := _cell_string_name(path, row, line, "trait")
			var min_v := _cell_float(path, row, line, "min", -1e9, 1e9)
			var max_v := _cell_float(path, row, line, "max", -1e9, 1e9)
			var agent: AgentType = agent_types.get(agent_id)
			if agent == null:
				load_errors.append("%s:%d: trait '%s' references unknown agent_id '%s'" %
					[path, line, trait_id, agent_id])
				continue
			if min_v > max_v:
				load_errors.append("%s:%d: trait '%s' min (%f) > max (%f)" %
					[path, line, trait_id, min_v, max_v])
				continue
			agent.trait_ranges[trait_id] = Vector2(min_v, max_v)

	# Preferences — optional appeal-match weights. Each row contributes one
	# axis. EffectResolver.appeal_match(agent_type, entity_def) scores how
	# well an entity's appeal_profile[axis] matches `preferred`, falling
	# off past `tolerance`. Type-level (shared across all agents of this
	# type); per-agent variation comes from traits.
	var prefs_section: Dictionary = parsed["sections"].get("Preferences", {})
	if not prefs_section.is_empty() and not prefs_section.get("tables", []).is_empty():
		var table: Dictionary = prefs_section["tables"][0]
		for row_idx in table["rows"].size():
			var row: Dictionary = table["rows"][row_idx]
			var line: int = table["row_lines"][row_idx]
			var agent_id := _cell_string_name(path, row, line, "agent_id")
			var axis_id := _cell_string_name(path, row, line, "axis")
			var preferred := _cell_float(path, row, line, "preferred", -1e9, 1e9)
			var tolerance := _cell_float(path, row, line, "tolerance", 0.0, 1e9)
			var agent: AgentType = agent_types.get(agent_id)
			if agent == null:
				load_errors.append("%s:%d: preference '%s' references unknown agent_id '%s'" %
					[path, line, axis_id, agent_id])
				continue
			agent.preferences[axis_id] = Vector2(preferred, tolerance)


func _compile_placeables(parsed: Dictionary) -> void:
	# v0.4.0 — see design/algorithms/zone_pattern.md.
	# Optional file. Single "## Placeables" section, one PlaceableDef per row.
	var path: String = parsed["path"]
	var section: Dictionary = parsed["sections"].get("Placeables", {})
	if section.is_empty() or section.get("tables", []).is_empty():
		return
	var table: Dictionary = section["tables"][0]
	for row_idx in table["rows"].size():
		var row: Dictionary = table["rows"][row_idx]
		var line: int = table["row_lines"][row_idx]
		var pd := PlaceableDef.new()
		pd.id = _cell_string_name(path, row, line, "id")
		if pd.id == &"":
			continue
		pd.display_name = row.get("display_name", String(pd.id))
		pd.sprite_key = _cell_string_name(path, row, line, "sprite_key")
		pd.build_cost = _cell_int(path, row, line, "build_cost", 0, 1_000_000_000)
		pd.maintenance_cost = _cell_int(path, row, line, "maintenance_cost", 0, 1_000_000_000)
		pd.space_required = _cell_int(path, row, line, "space_required", 0, 1_000_000)
		pd.space_ideal = _cell_int(path, row, line, "space_ideal", 0, 1_000_000)
		pd.required_zone_tags = _cell_array_string_names(row, "required_zone_tags")
		pd.own_tags = _cell_array_string_names(row, "own_tags")
		pd.incompatible_tags = _cell_array_string_names(row, "incompatible_tags")
		pd.appeal_contribution = _cell_dict_string_name_float(path, row, line, "appeal_contribution")
		if row.has("social_min"):
			pd.social_min = _cell_int(path, row, line, "social_min", 0, 1_000_000)
		if row.has("social_max"):
			pd.social_max = _cell_int(path, row, line, "social_max", 0, 1_000_000)
		if row.has("needs_provided_tags"):
			pd.needs_provided_tags = _cell_array_string_names(row, "needs_provided_tags")
		# v0.5.0 accounting field — optional, defaults to 0
		# (no depreciation, immediate expense).
		if row.has("useful_life_days"):
			pd.useful_life_days = _cell_int(path, row, line, "useful_life_days", 0, 1_000_000)
		placeable_defs[pd.id] = pd


func _compile_progression(parsed: Dictionary) -> void:
	var path: String = parsed["path"]
	var section: Dictionary = parsed["sections"].get("Unlock nodes", {})
	if section.is_empty() or section.get("tables", []).is_empty():
		return
	var table: Dictionary = section["tables"][0]
	for row_idx in table["rows"].size():
		var row: Dictionary = table["rows"][row_idx]
		var line: int = table["row_lines"][row_idx]
		var un := UnlockNode.new()
		un.id = _cell_string_name(path, row, line, "id")
		if un.id == &"":
			continue
		un.label = row.get("label", String(un.id))
		un.prerequisites = _cell_array_string_names(row, "prerequisites")
		un.cost = _cell_int(path, row, line, "cost", 0, 1_000_000_000)
		un.reputation_required = _cell_int(path, row, line, "reputation_required", 0, 1_000_000)
		un.unlocks = _cell_array_string_names(row, "unlocks")
		unlock_nodes[un.id] = un


func _compile_navigation(parsed: Dictionary) -> void:
	# v0.6.0 — see design/algorithms/navigation.md. Optional file; a single
	# `## Defaults` section feeds NavigationRegistry / the default A* navigator.
	var path: String = parsed["path"]
	var defaults := _require_section(path, parsed, "Defaults")
	if defaults != null:
		balance_config.nav_default_traversal_cost = _scalar_float(path, defaults, "default_traversal_cost", 0.0, 1e9)
		balance_config.nav_default_engagement_distance = _scalar_int(path, defaults, "default_engagement_distance", 0, 1_000_000)
		balance_config.nav_max_path_expansions = _scalar_int(path, defaults, "max_path_expansions", 0, 100_000_000)


# --- Cross-ref validation --------------------------------------------------

func _validate_cross_refs() -> void:
	for ed: EntityDef in entity_defs.values():
		for need_id in ed.satisfies:
			if not needs.has(need_id):
				load_errors.append("entity '%s' satisfies unknown need '%s'" % [ed.id, need_id])
		for eff: Effect in ed.effects:
			for cond_id in eff.conditions:
				if not conditions.has(cond_id):
					load_errors.append("entity '%s' effect '%s' references unknown condition '%s'" % [ed.id, eff.id, cond_id])
	for un: UnlockNode in unlock_nodes.values():
		for prereq in un.prerequisites:
			if not unlock_nodes.has(prereq):
				load_errors.append("unlock node '%s' has unknown prerequisite '%s'" % [un.id, prereq])
		# `unlocks` is intentionally polymorphic — could point at entities,
		# agent types, or future kinds. Validate against the union.
		for unlocked_id in un.unlocks:
			if not (entity_defs.has(unlocked_id) or agent_types.has(unlocked_id)):
				load_errors.append("unlock node '%s' unlocks unknown id '%s' (not an entity or agent type)" % [un.id, unlocked_id])
	_detect_unlock_cycles()

	# v0.4.0 — every placeable's required_zone_tags must be providable by
	# at least one zone-kind EntityDef. Otherwise the placeable can never
	# be placed in any region.
	var all_provided: Dictionary = {}
	for ed: EntityDef in entity_defs.values():
		if ed.zone_kind == &"":
			continue
		for tag in ed.zone_tags:
			all_provided[tag] = true
	for pd: PlaceableDef in placeable_defs.values():
		for tag in pd.required_zone_tags:
			if not all_provided.has(tag):
				load_errors.append("placeable '%s' requires zone tag '%s' which no zone tile provides" % [pd.id, tag])


# DFS over the unlock graph; flags any back-edge as a cycle. Without this,
# `try_unlock` on a cyclic node spins forever waiting for prereqs that can
# never be met.
func _detect_unlock_cycles() -> void:
	const WHITE := 0   # unvisited
	const GRAY := 1    # on the current DFS stack
	const BLACK := 2   # fully explored
	var state: Dictionary = {}
	for id in unlock_nodes.keys():
		state[id] = WHITE
	for id in unlock_nodes.keys():
		if state[id] == WHITE:
			_cycle_dfs(id, state, [])


func _cycle_dfs(node_id: StringName, state: Dictionary, path: Array) -> void:
	state[node_id] = 1  # GRAY
	path.append(node_id)
	var node: UnlockNode = unlock_nodes[node_id]
	for prereq in node.prerequisites:
		if not unlock_nodes.has(prereq):
			continue  # cross-ref validation already reported this
		if state[prereq] == 1:  # GRAY → back edge
			var start := path.find(prereq)
			var cycle: Array = path.slice(start)
			cycle.append(prereq)
			var rendered := " -> ".join(cycle.map(func(x): return String(x)))
			load_errors.append("unlock cycle detected: %s" % rendered)
		elif state[prereq] == 0:  # WHITE
			_cycle_dfs(prereq, state, path)
	path.pop_back()
	state[node_id] = 2  # BLACK


# --- Section / scalar / cell helpers --------------------------------------

func _require_section(path: String, parsed: Dictionary, name: String) -> Variant:
	if not parsed["sections"].has(name):
		load_errors.append("%s: missing required section '## %s'" % [path, name])
		return null
	return parsed["sections"][name]


func _scalar_int(path: String, section: Dictionary, key: String, min_val: int, max_val: int) -> int:
	var entry: Dictionary = section["scalars"].get(key, {})
	if entry.is_empty():
		load_errors.append("%s:%d: missing required key '%s'" % [path, section["line"], key])
		return 0
	var raw: String = entry["raw"]
	if not raw.is_valid_int():
		load_errors.append("%s:%d: '%s' is not an integer: '%s'" % [path, entry["line"], key, raw])
		return 0
	var val := raw.to_int()
	if val < min_val or val > max_val:
		load_errors.append("%s:%d: '%s' out of range [%d, %d]: %d" % [path, entry["line"], key, min_val, max_val, val])
	return val


func _scalar_float(path: String, section: Dictionary, key: String, min_val: float, max_val: float) -> float:
	var entry: Dictionary = section["scalars"].get(key, {})
	if entry.is_empty():
		load_errors.append("%s:%d: missing required key '%s'" % [path, section["line"], key])
		return 0.0
	var raw: String = entry["raw"]
	if not raw.is_valid_float():
		load_errors.append("%s:%d: '%s' is not a number: '%s'" % [path, entry["line"], key, raw])
		return 0.0
	var val := raw.to_float()
	if val < min_val or val > max_val:
		load_errors.append("%s:%d: '%s' out of range [%f, %f]: %f" % [path, entry["line"], key, min_val, max_val, val])
	return val


func _scalar_bool(path: String, section: Dictionary, key: String) -> bool:
	var entry: Dictionary = section["scalars"].get(key, {})
	if entry.is_empty():
		load_errors.append("%s:%d: missing required key '%s'" % [path, section["line"], key])
		return false
	var raw: String = String(entry["raw"]).to_lower()
	if raw == "true":
		return true
	if raw == "false":
		return false
	load_errors.append("%s:%d: '%s' is not true/false: '%s'" % [path, entry["line"], key, entry["raw"]])
	return false


func _cell_int(path: String, row: Dictionary, line: int, col: String, min_val: int, max_val: int) -> int:
	var raw: String = String(row.get(col, "")).strip_edges()
	if raw.is_empty():
		load_errors.append("%s:%d: missing column '%s'" % [path, line, col])
		return 0
	if not raw.is_valid_int():
		load_errors.append("%s:%d: column '%s' is not an integer: '%s'" % [path, line, col, raw])
		return 0
	var val := raw.to_int()
	if val < min_val or val > max_val:
		load_errors.append("%s:%d: column '%s' out of range [%d, %d]: %d" % [path, line, col, min_val, max_val, val])
	return val


func _cell_float(path: String, row: Dictionary, line: int, col: String, min_val: float, max_val: float) -> float:
	var raw: String = String(row.get(col, "")).strip_edges()
	if raw.is_empty():
		load_errors.append("%s:%d: missing column '%s'" % [path, line, col])
		return 0.0
	if not raw.is_valid_float():
		load_errors.append("%s:%d: column '%s' is not a number: '%s'" % [path, line, col, raw])
		return 0.0
	var val := raw.to_float()
	if val < min_val or val > max_val:
		load_errors.append("%s:%d: column '%s' out of range [%f, %f]: %f" % [path, line, col, min_val, max_val, val])
	return val


func _cell_bool(path: String, row: Dictionary, line: int, col: String, default_val: bool) -> bool:
	var raw: String = String(row.get(col, "")).strip_edges().to_lower()
	if raw.is_empty():
		return default_val
	if raw == "true":
		return true
	if raw == "false":
		return false
	load_errors.append("%s:%d: column '%s' is not true/false: '%s'" % [path, line, col, raw])
	return default_val


func _cell_string_name(path: String, row: Dictionary, line: int, col: String) -> StringName:
	var raw: String = String(row.get(col, "")).strip_edges()
	if raw.is_empty():
		# Don't append an error here for optional columns; callers check empty.
		# Required-column checks happen on the int/float helpers.
		return &""
	return StringName(raw)


func _cell_array_string_names(row: Dictionary, col: String) -> Array[StringName]:
	var out: Array[StringName] = []
	var raw: String = String(row.get(col, "")).strip_edges()
	if raw.is_empty():
		return out
	for token in raw.split(","):
		var t := token.strip_edges()
		if not t.is_empty():
			out.append(StringName(t))
	return out


func _cell_dict_string_name_float(path: String, row: Dictionary, line: int, col: String) -> Dictionary:
	# Format: "k:v,k:v" — empty cell = empty dict.
	var out := {}
	var raw: String = String(row.get(col, "")).strip_edges()
	if raw.is_empty():
		return out
	for pair in raw.split(","):
		var p := pair.strip_edges()
		if p.is_empty():
			continue
		var colon := p.find(":")
		if colon < 0:
			load_errors.append("%s:%d: column '%s' expected 'key:value' pairs: '%s'" % [path, line, col, p])
			continue
		var key := p.substr(0, colon).strip_edges()
		var val_raw := p.substr(colon + 1).strip_edges()
		if not val_raw.is_valid_float():
			load_errors.append("%s:%d: column '%s' value not a number for key '%s': '%s'" % [path, line, col, key, val_raw])
			continue
		out[StringName(key)] = val_raw.to_float()
	return out
