extends RefCounted
class_name Agent
# Spec: docs/build-plan.md §3 (AgentPool, IAgentBehavior), Prompt 6.
#
# Runtime state for one agent. AgentType is the *type* (authored content);
# Agent is the *instance* (currently alive in the world). When despawned, the
# Agent object goes back to AgentPool's free pool and is re-initialized on
# the next spawn — pooling is mandatory (CLAUDE.md §7, build plan §3).
#
# `agent_id` is fresh on every spawn even when the underlying object is
# reused. Old code holding `agent_id = 5` after that agent died will get a
# null lookup, not a confused new agent.

var agent_id: int = 0
var agent_type_id: StringName = &""
var position: Vector2 = Vector2.ZERO
var alive: bool = false
var spawn_tick: int = 0

# Per-need current level (0.0 = empty, 1.0 = full).
# StringName (need_id) -> float
var need_levels: Dictionary = {}

# Aggregate happiness, computed each tick by ISatisfactionModel.
var satisfaction: float = 0.5

# Game-side traits sampled from AgentType.trait_ranges at spawn.
# StringName (axis) -> float
var traits: Dictionary = {}

# Behavior may stash whatever runtime state it needs here.
var behavior_state: Dictionary = {}

# Current goal — set by IAgentBehavior, used by IAgentBehavior. Engine doesn't
# inspect these; they're here so reset() can clear them on pool reuse.
var seeking_need: StringName = &""
var target_entity_id: int = 0


func get_type() -> AgentType:
	return ContentDB.get_agent_type(agent_type_id)


# Re-initialize for pool reuse. Called by AgentPool on spawn.
func reset_for_spawn(new_agent_id: int, new_type_id: StringName, new_position: Vector2, current_tick: int) -> void:
	agent_id = new_agent_id
	agent_type_id = new_type_id
	position = new_position
	alive = true
	spawn_tick = current_tick
	satisfaction = 0.5
	seeking_need = &""
	target_entity_id = 0
	need_levels.clear()
	traits.clear()
	behavior_state.clear()
