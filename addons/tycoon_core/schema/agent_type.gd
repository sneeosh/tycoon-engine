extends Resource
class_name AgentType
# Spec: docs/build-plan.md §3 (content schema — AgentType), Prompt 3.
#
# Definition of a population that flows through the sim. Carries the
# extension-point script references the game implements:
#   - `behavior_script` → implements IAgentBehavior  (per-tick agent logic)
#   - `value_model_script` → implements IValueModel  (how service → money/rep)
#   - `satisfaction_model_script` → implements ISatisfactionModel
# The engine never inspects these scripts beyond calling agreed-upon methods.

@export var id: StringName = &""
@export var display_name: String = ""
@export_range(0.0, 100.0) var spawn_weight: float = 1.0
# Per-agent random trait ranges. Each value is Vector2(min, max); the engine
# samples uniformly between them at spawn. Axis names are game-defined.
@export var trait_ranges: Dictionary = {}
# Appeal preferences. Each value is Vector2(preferred, tolerance) — the
# generic appeal-match function (Prompt 7) scores how close an EntityDef's
# `appeal_profile` value is to `preferred`, falling off past `tolerance`.
@export var preferences: Dictionary = {}
@export var needs: Array[NeedSpec] = []

# When true (default), this population's satisfaction feeds the aggregate that
# drives the self-balancing spawn curve (arrival demand). Set false for a
# population whose wellbeing is NOT customer demand — e.g. a second agent
# population with its own welfare meter — so its satisfaction can't leak into
# how many new arrivals the sim spawns. Additive since v0.7.0; defaulting to
# true keeps every pre-v0.7 type behaving exactly as before.
@export var drives_spawn_balance: bool = true

# Extension-point scripts. Left null on the engine side; games assign these.
@export var behavior_script: Script
@export var value_model_script: Script
@export var satisfaction_model_script: Script
