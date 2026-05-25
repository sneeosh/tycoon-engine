extends Node
# Spec: docs/build-plan.md §3 (autoloads — EventBus)
#
# Global signal hub. Systems publish and subscribe through here to stay
# decoupled. This file is the single registry of cross-system signals — when a
# new system needs to announce something, add the signal here, not on the
# system itself.

signal tick(current_tick: int)
signal day_ended(day: int)
signal period_ended(period: int)

# Ledger (Prompt 2)
signal balance_changed(new_balance: int)
signal day_settled(day: int, income: int, expense: int)

# EntityRegistry (Prompt 5)
signal entity_placed(instance_id: int)
signal entity_removed(instance_id: int)
signal entity_upgraded(instance_id: int, new_tier: int)

# AgentPool (Prompt 6)
signal agent_spawned(agent_id: int)
signal agent_despawned(agent_id: int)
signal agent_need_threshold_crossed(agent_id: int, need_id: StringName)
signal aggregate_satisfaction_changed(satisfaction: float, spawn_multiplier: float)

# ProgressionManager (Prompt 8)
signal unlock_acquired(node_id: StringName)
signal reputation_changed(new_value: int)

# SaveService (Prompt 9)
signal save_completed(slot: String)
signal load_completed(slot: String)
signal load_failed(slot: String, reason: String)
