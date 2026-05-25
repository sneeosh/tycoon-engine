extends RefCounted
class_name IValueModel
# Spec: docs/build-plan.md §3 (extension points — IValueModel), Prompt 7.
#
# How an agent converts service into money/reputation. Games implement this:
#   - Golf: a finished round yields a green-fee + tips proportional to course quality.
#   - Restaurant: a seated party pays for entrée + dessert + tip.
#   - Hospital: a discharged patient yields revenue from insurance.
#
# Duck-typed contract — see IAgentBehavior. Engine never implements this; only
# games do. The engine's appeal-match score (EffectResolver.appeal_match) is
# typically a key input.


# Returns the monetary value an agent generates from its current interaction
# or completed service. Game callers post this to the Ledger themselves.
func compute_value(_agent: Agent) -> int:
	return 0
