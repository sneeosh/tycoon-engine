extends INetworkNavigator
class_name AStarNetworkNavigator
# Spec: design/algorithms/navigation.md
#
# The engine's default INetworkNavigator: A* over a WalkableNetwork's
# 4-neighbour graph, with deterministic tie-breaking (CLAUDE.md §5), a
# fail-soft expansion budget, and incremental per-tick stepping that walks
# a cached route instead of re-planning every tick (CLAUDE.md §7).
#
# Theme-agnostic — knows only cells, costs, and access tags.


func find_path(network: WalkableNetwork, from: Vector2i, to: Vector2i,
		agent_tags: Array[StringName] = [], max_expansions: int = -1) -> Array[Vector2i]:
	var empty: Array[Vector2i] = []
	if from == to:
		return ([from] as Array[Vector2i]) if network.can_enter(from, agent_tags) else empty
	if not network.has_cell(from):
		return empty
	if not network.can_enter(to, agent_tags):
		return empty

	var c_min: float = network.min_cost()
	var g: Dictionary = {from: 0.0}
	var came_from: Dictionary = {}
	# Open set as a plain dict-of-membership; pop_best does a linear scan.
	# Adequate at tycoon scales (small networks); revisit with a real heap
	# only if profiling demands it.
	var open: Dictionary = {from: true}
	var expansions: int = 0

	while not open.is_empty():
		var cur: Vector2i = _pop_best(open, g, to, c_min)
		if cur == to:
			return _reconstruct(came_from, to)
		expansions += 1
		if max_expansions > 0 and expansions > max_expansions:
			return empty
		var cur_g: float = g[cur]
		for n in network.neighbors(cur, agent_tags):
			var tentative: float = cur_g + network.traversal_cost(n)
			if not g.has(n) or tentative < g[n]:
				g[n] = tentative
				came_from[n] = cur
				open[n] = true
	return empty


# Lowest f = g + h, ties by (h, x, y). Removes and returns the winner.
func _pop_best(open: Dictionary, g: Dictionary, to: Vector2i, c_min: float) -> Vector2i:
	var best: Vector2i = NO_STEP
	var best_f: float = INF
	var best_h: float = INF
	for cell in open.keys():
		var h: float = (absi(cell.x - to.x) + absi(cell.y - to.y)) * c_min
		var f: float = g[cell] + h
		if f < best_f \
				or (f == best_f and h < best_h) \
				or (f == best_f and h == best_h and cell.x < best.x) \
				or (f == best_f and h == best_h and cell.x == best.x and cell.y < best.y):
			best = cell
			best_f = f
			best_h = h
	open.erase(best)
	return best


func _reconstruct(came_from: Dictionary, to: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [to]
	var cur: Vector2i = to
	while came_from.has(cur):
		cur = came_from[cur]
		path.append(cur)
	path.reverse()
	return path


func step(agent: Agent, network: WalkableNetwork) -> Vector2i:
	if not agent.behavior_state.has("nav_target"):
		return NO_STEP
	var target: Vector2i = agent.behavior_state["nav_target"]
	var tags: Array[StringName] = agent.behavior_state.get("nav_tags", [] as Array[StringName])
	var cur := Vector2i(agent.position.round())
	if cur == target:
		return NO_STEP  # arrived — no further step needed

	var route: Array[Vector2i] = agent.behavior_state.get("nav_route", [] as Array[Vector2i])
	var idx: int = route.find(cur)
	var stale: bool = route.is_empty() or route[route.size() - 1] != target or idx < 0
	if stale:
		route = find_path(network, cur, target, tags, _budget())
		agent.behavior_state["nav_route"] = route
		idx = route.find(cur)

	if route.size() < 2 or idx < 0 or idx + 1 >= route.size():
		return NO_STEP
	return route[idx + 1]


func reachable_from(network: WalkableNetwork, origin: Vector2i,
		agent_tags: Array[StringName] = []) -> Dictionary:
	var seen: Dictionary = {}
	if not network.has_cell(origin):
		return seen
	seen[origin] = true
	var queue: Array[Vector2i] = [origin]
	var head: int = 0
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		for n in network.neighbors(cur, agent_tags):
			if not seen.has(n):
				seen[n] = true
				queue.append(n)
	return seen


func nearest(network: WalkableNetwork, origin: Vector2i, predicate: Callable,
		agent_tags: Array[StringName] = []) -> Vector2i:
	if not network.has_cell(origin):
		return NO_STEP
	# BFS by hop count; among equal-hop cells the lower (x,y) is visited
	# first because we sort each frontier deterministically.
	var seen: Dictionary = {origin: true}
	var frontier: Array[Vector2i] = [origin]
	while not frontier.is_empty():
		frontier.sort_custom(_cell_less)
		for cell in frontier:
			if predicate.call(cell):
				return cell
		var next_frontier: Array[Vector2i] = []
		for cur in frontier:
			for n in network.neighbors(cur, agent_tags):
				if not seen.has(n):
					seen[n] = true
					next_frontier.append(n)
		frontier = next_frontier
	return NO_STEP


func score_goals(agent: Agent, network: WalkableNetwork,
		candidates: Array[Vector2i]) -> Array[Dictionary]:
	var tags: Array[StringName] = agent.behavior_state.get("nav_tags", [] as Array[StringName])
	var cur := Vector2i(agent.position.round())
	var out: Array[Dictionary] = []
	for goal in candidates:
		var route := find_path(network, cur, goal, tags, _budget())
		var reachable := not route.is_empty()
		var cost := 0.0
		if reachable:
			for i in range(1, route.size()):
				cost += network.traversal_cost(route[i])
		out.append({"cell": goal, "cost": cost, "reachable": reachable})
	out.sort_custom(func(a, b):
		if a["reachable"] != b["reachable"]:
			return a["reachable"]  # reachable goals first
		return a["cost"] < b["cost"])
	return out


static func _cell_less(a: Vector2i, b: Vector2i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	return a.y < b.y


# Fail-soft A* budget from tuning (navigation.md ## Defaults). -1 (unbounded)
# when ContentDB hasn't loaded a BalanceConfig yet.
func _budget() -> int:
	var bc: BalanceConfig = ContentDB.balance_config
	return bc.nav_max_path_expansions if bc != null else -1
