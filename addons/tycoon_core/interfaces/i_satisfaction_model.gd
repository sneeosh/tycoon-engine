extends RefCounted
class_name ISatisfactionModel
# Spec: docs/build-plan.md §3 (extension points — ISatisfactionModel), Prompt 6.
#
# How an agent's satisfaction is computed and updated each tick. Games
# implement this. The engine never implements one (only the trivial demo at
# `systems/demo/demo_satisfaction_model.gd`).
#
# Duck-typed contract — see IAgentBehavior for the pattern. AgentPool calls
# update_satisfaction(agent) each tick if a model is registered.

# Mutate agent.satisfaction in place. Typical implementation: blend need
# levels, recent events, condition modifiers, etc.
func update_satisfaction(_agent: Agent) -> void:
	pass
