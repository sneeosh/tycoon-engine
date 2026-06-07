extends RefCounted
class_name INetworkNavigator
# Spec: design/algorithms/navigation.md
#
# Pathing for one agent population over a WalkableNetwork. The engine ships
# a default A* implementation (`systems/astar_network_navigator.gd`) that
# most games will never need to override — NavigationRegistry uses it by
# default. Games override only when they want path *preference* (prefer wide
# corridors but cut through narrow ones), per-archetype routing, or layered
# avoidance, without forking the engine pathfinder.
#
# Duck-typed like the other extension points: callers use `has_method`, so a
# game's navigator can extend this base or any class exposing these methods.
# This base is a no-op contract; the methods return empty / sentinel values.

# Sentinel returned by step()/nearest() to mean "no cell" — the seam
# report's `Vector2i.ZERO_INF` (Godot has no such constant). Vector2i max.
const NO_STEP := Vector2i(0x7FFFFFFF, 0x7FFFFFFF)


# Lowest-cost path from `from` to `to` inclusive, or [] when none exists,
# the goal is not enterable, the start is off-network, or the expansion
# budget (<= 0 = unbounded) is exhausted.
func find_path(_network: WalkableNetwork, _from: Vector2i, _to: Vector2i,
		_agent_tags: Array[StringName] = [], _max_expansions: int = -1) -> Array[Vector2i]:
	return [] as Array[Vector2i]


# Next cell an agent should move to toward behavior_state["nav_target"],
# popping one cell per tick from a cached route. NO_STEP when arrived or no
# route exists.
func step(_agent: Agent, _network: WalkableNetwork) -> Vector2i:
	return NO_STEP


# Set of cells (Dictionary Vector2i -> true) reachable from `origin`.
func reachable_from(_network: WalkableNetwork, _origin: Vector2i,
		_agent_tags: Array[StringName] = []) -> Dictionary:
	return {}


# Nearest (fewest hops) cell from `origin` for which predicate.call(cell)
# is true, or NO_STEP if none. predicate: func(cell: Vector2i) -> bool.
func nearest(_network: WalkableNetwork, _origin: Vector2i, _predicate: Callable,
		_agent_tags: Array[StringName] = []) -> Vector2i:
	return NO_STEP


# Score candidate goal cells by path cost from the agent's current cell.
# Returns Array[Dictionary] [{cell, cost, reachable}] sorted by ascending
# cost (unreachable last). Games layer appeal/preference on top.
func score_goals(_agent: Agent, _network: WalkableNetwork,
		_candidates: Array[Vector2i]) -> Array[Dictionary]:
	return [] as Array[Dictionary]
