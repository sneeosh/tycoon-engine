extends Node
# Spec: docs/build-plan.md §3 (autoloads — EventBus)
#
# Global signal hub. Systems publish and subscribe through here to stay
# decoupled. This file is the single registry of cross-system signals — when a
# new system needs to announce something, add the signal here, not on the
# system itself.

signal tick(current_tick: int)
# `day_ending` fires *before* `day_ended` so listeners that need to post
# transactions or state changes to the just-ending day (e.g. EffectResolver
# revenue) can do so before Ledger settles. Listeners that consume the
# settled day's state (autosave, UI refresh) should continue to use
# `day_ended`.
signal day_ending(day: int)
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

# RegionRegistry (v0.4.0). See design/algorithms/zone_pattern.md +
# region_detection.md. Regions emerge from connected zone tiles; their
# lifecycle is reactive to entity_placed / entity_removed.
signal region_created(region_id: int)
signal region_destroyed(region_id: int)
signal region_changed(region_id: int)
signal placement_added(region_id: int, index: int)
signal placement_removed(region_id: int, index: int)
signal placement_stranded(region_id: int, index: int)

# NavigationRegistry (v0.6.0). See design/algorithms/navigation.md.
# WalkableNetworks are derived reactively from walkable EntityInstances;
# this fires when a network gains/loses cells. dirty_rect bounds the change
# so consumers can scope their own cache invalidation.
signal network_changed(network_id: StringName, dirty_rect: Rect2i)
