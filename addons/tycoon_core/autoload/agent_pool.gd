extends Node
# Spec: docs/build-plan.md §3 (autoloads — AgentPool), Prompt 6.
#
# Owns the agent population. Three responsibilities:
#   (1) Object-pool lifecycle: reuse Agent instances on respawn — never churn.
#   (2) Per-tick simulation: decay each agent's needs, fire threshold
#       crossings, dispatch to IAgentBehavior + ISatisfactionModel.
#   (3) Self-balancing spawn rate: at day_ended, read aggregate satisfaction
#       and set the next day's spawn-rate multiplier via the BalanceConfig
#       satisfaction→spawn curve.
#
# Pool semantics: when an agent despawns, its Agent object goes back to the
# free pool. On the next spawn(), if the pool isn't empty we pop an object
# and re-init it. The `agent_id` is freshly issued each spawn so dangling
# references to the old "life" don't accidentally hit the new agent.
#
# Theme-agnostic — knows nothing about any specific game. Game-specific
# behavior is injected via register_behavior / register_satisfaction_model.

const DEFAULT_BASE_SPAWN_RATE: float = 1.0  # agents/sec at multiplier 1.0

var base_spawn_rate: float = DEFAULT_BASE_SPAWN_RATE
var current_spawn_multiplier: float = 1.0

# agent_id -> Agent
var agents: Dictionary = {}
# Recycled Agent objects (alive=false).
var _free_pool: Array[Agent] = []
# agent_type_id -> Array[int]
var _by_type_id: Dictionary = {}

var _next_id: int = 1

# Game-side registrations. agent_type_id -> Object (any class with the right
# duck-typed methods — typically extends IAgentBehavior / ISatisfactionModel).
var _behaviors: Dictionary = {}
var _satisfaction_models: Dictionary = {}

# Fractional accumulator for auto-spawning. Driven from _on_tick.
var _spawn_accumulator: float = 0.0


func _ready() -> void:
	EventBus.tick.connect(_on_tick)
	EventBus.day_ended.connect(_on_day_ended)


func configure(p_base_spawn_rate: float) -> void:
	base_spawn_rate = p_base_spawn_rate


func reset() -> void:
	# Move every live agent back to the free pool — never destroy.
	for id in agents.keys():
		var a: Agent = agents[id]
		a.alive = false
		_free_pool.append(a)
	agents.clear()
	_by_type_id.clear()
	_next_id = 1
	_spawn_accumulator = 0.0
	current_spawn_multiplier = 1.0


# Game registers behavior/satisfaction model implementations at startup,
# keyed by the AgentType id they apply to.
func register_behavior(agent_type_id: StringName, behavior: Object) -> void:
	_behaviors[agent_type_id] = behavior


func register_satisfaction_model(agent_type_id: StringName, model: Object) -> void:
	_satisfaction_models[agent_type_id] = model


func unregister_behavior(agent_type_id: StringName) -> void:
	_behaviors.erase(agent_type_id)


func unregister_satisfaction_model(agent_type_id: StringName) -> void:
	_satisfaction_models.erase(agent_type_id)


# Spawn one agent of the given AgentType. Returns the new agent_id, or 0
# if the type isn't loaded.
func spawn(agent_type_id: StringName, position: Vector2 = Vector2.ZERO) -> int:
	var type: AgentType = ContentDB.get_agent_type(agent_type_id)
	if type == null:
		push_warning("AgentPool.spawn: unknown agent_type_id '%s'" % agent_type_id)
		return 0

	var agent: Agent
	if _free_pool.is_empty():
		agent = Agent.new()
	else:
		agent = _free_pool.pop_back()

	var new_id := _next_id
	_next_id += 1
	agent.reset_for_spawn(new_id, agent_type_id, position, SimClock.current_tick)

	# Sample traits from type.trait_ranges using the sim RNG (determinism).
	for axis in type.trait_ranges.keys():
		var range_vec: Vector2 = type.trait_ranges[axis]
		agent.traits[axis] = SimClock.rng.randf_range(range_vec.x, range_vec.y)

	# Initialize per-need levels from NeedSpecs.
	for ns: NeedSpec in type.needs:
		if ns.need == null:
			continue
		agent.need_levels[ns.need.id] = ns.initial_level

	agents[new_id] = agent
	if not _by_type_id.has(agent_type_id):
		_by_type_id[agent_type_id] = [] as Array[int]
	(_by_type_id[agent_type_id] as Array[int]).append(new_id)

	var behavior: Object = _behaviors.get(agent_type_id)
	if behavior != null and behavior.has_method("on_spawn"):
		behavior.on_spawn(agent)

	EventBus.agent_spawned.emit(new_id)
	return new_id


func despawn(agent_id: int) -> bool:
	if not agents.has(agent_id):
		return false
	var agent: Agent = agents[agent_id]
	var behavior: Object = _behaviors.get(agent.agent_type_id)
	if behavior != null and behavior.has_method("on_despawn"):
		behavior.on_despawn(agent)

	agent.alive = false
	var by_type: Array = _by_type_id[agent.agent_type_id]
	by_type.erase(agent_id)
	if by_type.is_empty():
		_by_type_id.erase(agent.agent_type_id)
	agents.erase(agent_id)
	_free_pool.append(agent)
	EventBus.agent_despawned.emit(agent_id)
	return true


# --- Queries --------------------------------------------------------------

func get_agent(agent_id: int) -> Agent:
	return agents.get(agent_id)


func get_agents_by_type(agent_type_id: StringName) -> Array[int]:
	var out: Array[int] = []
	if _by_type_id.has(agent_type_id):
		out.append_array(_by_type_id[agent_type_id])
	return out


func alive_count() -> int:
	return agents.size()


func pool_size() -> int:
	return _free_pool.size()


# Spec: design/algorithms/spawn-curve.md. Mirrored 1:1 by tests in
# tests/systems/test_spawn_curve.gd — drift breaks the build.
func spawn_curve(satisfaction: float) -> float:
	var s := clampf(satisfaction, 0.0, 1.0)
	var bc: BalanceConfig = ContentDB.balance_config
	if bc == null:
		bc = BalanceConfig.new()
	var x := (s - bc.spawn_curve_midpoint) * bc.spawn_curve_steepness
	var sigmoid := 1.0 / (1.0 + exp(-x))
	return bc.spawn_curve_min_multiplier + (bc.spawn_curve_max_multiplier - bc.spawn_curve_min_multiplier) * sigmoid


# Mean satisfaction across live agents, or 0.5 when no agents (so the spawn
# rate doesn't collapse to zero on an empty park).
func compute_aggregate_satisfaction() -> float:
	if agents.is_empty():
		return 0.5
	var total: float = 0.0
	for a: Agent in agents.values():
		total += a.satisfaction
	return total / agents.size()


# --- Per-tick simulation --------------------------------------------------

func _on_tick(_t: int) -> void:
	for a: Agent in agents.values():
		_decay_needs(a)
		_update_satisfaction(a)
		# Layer EffectResolver-driven satisfaction modifier on top of the
		# baseline computed by the game's ISatisfactionModel.
		a.satisfaction = clampf(
			a.satisfaction + EffectResolver.compute_satisfaction_modifier_for(a),
			0.0, 1.0)
		_tick_behavior(a)

	# Auto-spawn loop driven by the current multiplier. base_spawn_rate is
	# agents per second; convert to per-tick using SimClock's tick rate.
	var per_tick := (base_spawn_rate * current_spawn_multiplier) / SimClock.TICKS_PER_SECOND
	_spawn_accumulator += per_tick
	while _spawn_accumulator >= 1.0:
		_spawn_accumulator -= 1.0
		_spawn_from_weighted_types()


func _on_day_ended(_d: int) -> void:
	var avg := compute_aggregate_satisfaction()
	current_spawn_multiplier = spawn_curve(avg)
	EventBus.aggregate_satisfaction_changed.emit(avg, current_spawn_multiplier)


func _decay_needs(agent: Agent) -> void:
	var type: AgentType = agent.get_type()
	if type == null:
		return
	for ns: NeedSpec in type.needs:
		if ns.need == null:
			continue
		var need_id: StringName = ns.need.id
		var prev: float = agent.need_levels.get(need_id, 1.0)
		var decay: float = ns.need.base_decay_per_tick * ns.decay_rate_multiplier
		# EffectResolver may add positive (faster) or negative (slower)
		# decay modifiers based on what entities the agent is near.
		decay += EffectResolver.compute_need_decay_modifier_for(agent, need_id)
		var new_level: float = maxf(0.0, prev - decay)
		agent.need_levels[need_id] = new_level
		# Threshold crossing fires only on the tick of the transition, not
		# every tick while below.
		if prev >= ns.threshold and new_level < ns.threshold:
			EventBus.agent_need_threshold_crossed.emit(agent.agent_id, need_id)
			var behavior: Object = _behaviors.get(agent.agent_type_id)
			if behavior != null and behavior.has_method("on_need_threshold_crossed"):
				behavior.on_need_threshold_crossed(agent, need_id)


func _update_satisfaction(agent: Agent) -> void:
	var model: Object = _satisfaction_models.get(agent.agent_type_id)
	if model != null and model.has_method("update_satisfaction"):
		model.update_satisfaction(agent)


func _tick_behavior(agent: Agent) -> void:
	var behavior: Object = _behaviors.get(agent.agent_type_id)
	if behavior != null and behavior.has_method("on_tick"):
		behavior.on_tick(agent)


func _spawn_from_weighted_types() -> void:
	# Iterate in sorted-id order so two runs with the same seed pick the
	# same type sequence — Dictionary iteration order is implementation-
	# defined in Godot and was breaking session-to-session reproducibility.
	# (Distribution was always weighted-correct; only the ordering differed.)
	var type_ids: Array = ContentDB.agent_types.keys()
	if type_ids.is_empty():
		return
	type_ids.sort_custom(func(a, b): return String(a) < String(b))
	var total_weight: float = 0.0
	for id in type_ids:
		total_weight += (ContentDB.agent_types[id] as AgentType).spawn_weight
	if total_weight <= 0.0:
		return
	var pick := SimClock.rng.randf() * total_weight
	var accum: float = 0.0
	for id in type_ids:
		var t: AgentType = ContentDB.agent_types[id]
		accum += t.spawn_weight
		if pick <= accum:
			spawn(t.id, Vector2.ZERO)
			return


# Returns the number of currently-alive agents whose target_entity_id matches
# `inst_id`. Behaviors use this to avoid swarming a single popular entity —
# e.g. pick the second-nearest food stand if the nearest is already crowded.
# O(alive agents). Cheap at typical scales; if you call this from a hot
# per-tick loop with thousands of agents, maintain your own reverse index.
func count_targeting(inst_id: int) -> int:
	var c: int = 0
	for id in agents.keys():
		var a: Agent = agents[id]
		if a.alive and a.target_entity_id == inst_id:
			c += 1
	return c
