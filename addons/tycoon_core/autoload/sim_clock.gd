extends Node
# Spec: docs/build-plan.md §3 (autoloads), Prompt 1 (SimClock)
#
# Time authority for the simulation. Advances discrete ticks, rolls them into
# days and periods, and announces each via EventBus. Owns play/pause/speed
# state. Theme-agnostic — knows nothing about any specific game.

# Defaults pending the Prompt 4 tuning loader. Canonical values live in
# `design/tuning/balance.md`. Once ContentDB lands, it calls `configure()` to
# override these. The fallbacks must match the markdown values.
const DEFAULT_TICKS_PER_DAY: int = 480
const DEFAULT_DAYS_PER_PERIOD: int = 7
const TICKS_PER_SECOND: float = 20.0  # base rate at speed 1.0

@export var ticks_per_day: int = DEFAULT_TICKS_PER_DAY
@export var days_per_period: int = DEFAULT_DAYS_PER_PERIOD

var current_tick: int = 0
var current_day: int = 0
var current_period: int = 0

# 0.0 = paused; positive = play-speed multiplier (1.0 = normal, 2.0/4.0 = ff).
var speed: float = 1.0

# Accumulator in *tick units* (not seconds). This avoids the floating-point
# drift that comes from repeatedly subtracting a non-binary-exact interval
# like 0.05: subtracting 1.0 from an integer-valued float is exact.
var _accumulator: float = 0.0

# Single seeded RNG for the sim — see CLAUDE.md §5. Every system that needs
# randomness pulls from here, never from the global RNG (`randf()` etc).
# Replays and save/load reproduce exactly when the seed and call order match.
const DEFAULT_SEED: int = 1234567
var rng: RandomNumberGenerator


func _ready() -> void:
	rng = RandomNumberGenerator.new()
	rng.seed = DEFAULT_SEED


func set_seed(s: int) -> void:
	rng.seed = s


func _process(delta: float) -> void:
	if speed <= 0.0:
		return
	_accumulator += delta * speed * TICKS_PER_SECOND
	while _accumulator >= 1.0:
		_accumulator -= 1.0
		advance_tick()


# Tests drive this directly so they never depend on real wall-clock timing.
func advance_tick() -> void:
	current_tick += 1
	EventBus.tick.emit(current_tick)
	if current_tick % ticks_per_day == 0:
		current_day += 1
		EventBus.day_ended.emit(current_day)
		if current_day % days_per_period == 0:
			current_period += 1
			EventBus.period_ended.emit(current_period)


func pause() -> void:
	speed = 0.0


func play() -> void:
	speed = 1.0


func set_speed(multiplier: float) -> void:
	speed = max(multiplier, 0.0)


func is_paused() -> bool:
	return speed <= 0.0


# Called by ContentDB once BalanceConfig is loaded (Prompt 4).
func configure(p_ticks_per_day: int, p_days_per_period: int) -> void:
	ticks_per_day = p_ticks_per_day
	days_per_period = p_days_per_period


# Save / load (Prompt 9). Seed is preserved; the PCG state isn't round-trip
# safe through JSON in Godot 4's public API (state setter doesn't fully
# recover an arbitrary internal position), so load resets to seed and
# post-load draws form a fresh deterministic stream from there.
func save_state() -> Dictionary:
	return {
		"current_tick": current_tick,
		"current_day": current_day,
		"current_period": current_period,
		"ticks_per_day": ticks_per_day,
		"days_per_period": days_per_period,
		"speed": speed,
		"rng_seed": int(rng.seed),
	}


func load_state(data: Dictionary) -> void:
	current_tick = data.get("current_tick", 0)
	current_day = data.get("current_day", 0)
	current_period = data.get("current_period", 0)
	ticks_per_day = data.get("ticks_per_day", DEFAULT_TICKS_PER_DAY)
	days_per_period = data.get("days_per_period", DEFAULT_DAYS_PER_PERIOD)
	speed = data.get("speed", 1.0)
	rng.seed = data.get("rng_seed", DEFAULT_SEED)
	_accumulator = 0.0
