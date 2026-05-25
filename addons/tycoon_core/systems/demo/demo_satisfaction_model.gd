extends ISatisfactionModel
class_name DemoSatisfactionModel
# DEMO — satisfaction = mean of current need levels. Trivial but enough to
# drive the satisfaction→spawn feedback loop end-to-end for engine tests.
# Real games will weight needs, factor in waits, weather, condition
# modifiers, etc.


func update_satisfaction(agent: Agent) -> void:
	if agent.need_levels.is_empty():
		agent.satisfaction = 0.5
		return
	var sum: float = 0.0
	for level in agent.need_levels.values():
		sum += level
	agent.satisfaction = sum / agent.need_levels.size()
