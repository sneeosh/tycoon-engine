extends RefCounted
class_name IAgentBehavior
# Spec: docs/build-plan.md §3 (extension points — IAgentBehavior), Prompt 6.
#
# Per-tick agent logic. Games implement this — golf's IAgentBehavior owns
# ball/shot/pathfinding; a zoo's owns wander/observe/leave; a hospital's
# owns triage/wait/treat. The engine never implements one (only the trivial
# demo at `systems/demo/demo_agent_behavior.gd` for tests).
#
# GDScript has no interfaces, so this is a no-op base. Games can either:
#   (a) extend this and override the methods, or
#   (b) duck-type with any class that exposes the same method names.
# AgentPool calls each method via `has_method` so missing overrides are safe.

# Called once when an agent spawns or is reused from the pool.
func on_spawn(_agent: Agent) -> void:
	pass

# Called every SimClock tick for every live agent.
func on_tick(_agent: Agent) -> void:
	pass

# Called when one of the agent's Needs falls from >= threshold to < threshold.
# Typical behavior here: query EntityRegistry for entities whose `satisfies`
# covers `need_id`, pick one, set agent.target_entity_id / seeking_need.
func on_need_threshold_crossed(_agent: Agent, _need_id: StringName) -> void:
	pass

# Called when an agent is despawned (either by the game or by the engine).
func on_despawn(_agent: Agent) -> void:
	pass


# Spec: design/algorithms/navigation.md. Pick the next cell an agent should
# move to this tick. The default delegates to the bound INetworkNavigator
# via NavigationRegistry, walking the network named by
# `agent.behavior_state["nav_network_id"]` (default &"default") toward
# `agent.behavior_state["nav_target"]`. Returns INetworkNavigator.NO_STEP
# when there is no network or no route.
#
# Games that don't use networks (free-roam validation, debug harnesses)
# simply never call this — the existing IAgentBehavior contract is intact.
# Games that do path can override for per-archetype routing, or rely on the
# default and just set nav_target on the agent.
func decide_next_step(agent: Agent) -> Vector2i:
	var net_id: StringName = agent.behavior_state.get("nav_network_id", NavigationRegistry.DEFAULT_NETWORK)
	var network: WalkableNetwork = NavigationRegistry.get_network(net_id)
	if network == null:
		return INetworkNavigator.NO_STEP
	return NavigationRegistry.navigator.step(agent, network)
