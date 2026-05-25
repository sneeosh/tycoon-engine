extends IAgentBehavior
class_name DemoAgentBehavior
# DEMO — not a real game behavior. Lives in the engine so the AgentPool
# wiring (need decay → threshold → seek entity → reach → refill) can be
# exercised end-to-end without a game project. CLAUDE.md §1 forbids
# theme-specific logic in the engine; this is intentionally generic — it
# refills whichever need crossed threshold by picking the nearest entity
# whose `satisfies` covers it.

const SPEED_PER_TICK: float = 0.1  # tiles per tick
const REACH_DISTANCE: float = 0.5


func on_spawn(_agent: Agent) -> void:
	pass


func on_need_threshold_crossed(agent: Agent, need_id: StringName) -> void:
	# Find nearest entity whose satisfies includes need_id.
	var best_id: int = 0
	var best_dist_sq: float = INF
	for entity_id in EntityRegistry.instances.keys():
		var inst: EntityInstance = EntityRegistry.get_instance(entity_id)
		var def := inst.get_def()
		if def == null:
			continue
		if not (need_id in def.satisfies):
			continue
		var center := Vector2(inst.position) + Vector2(def.footprint) * 0.5
		var d := center.distance_squared_to(agent.position)
		if d < best_dist_sq:
			best_dist_sq = d
			best_id = entity_id
	if best_id != 0:
		agent.target_entity_id = best_id
		agent.seeking_need = need_id


func on_tick(agent: Agent) -> void:
	if agent.target_entity_id == 0:
		return
	var inst: EntityInstance = EntityRegistry.get_instance(agent.target_entity_id)
	if inst == null:
		# Target was removed mid-trip.
		agent.target_entity_id = 0
		agent.seeking_need = &""
		return
	var def := inst.get_def()
	var target_pos := Vector2(inst.position) + Vector2(def.footprint) * 0.5
	var to_target := target_pos - agent.position
	var dist := to_target.length()
	if dist <= REACH_DISTANCE:
		# Arrived — refill the need.
		if agent.seeking_need != &"":
			agent.need_levels[agent.seeking_need] = 1.0
		agent.target_entity_id = 0
		agent.seeking_need = &""
		return
	# Step toward target.
	agent.position += to_target.normalized() * SPEED_PER_TICK


func on_despawn(_agent: Agent) -> void:
	pass
