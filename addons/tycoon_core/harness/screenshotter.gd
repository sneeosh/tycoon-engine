extends RefCounted
class_name Screenshotter
# One-shot screenshot helper for quick visual iteration. For multi-step
# scenarios use [[ScriptedSession]] instead.
#
# Activation: set `TYCOON_SHOT=/abs/path.png[:warmup_ticks]` (env) or pass
# `++ --tycoon-shot=/abs/path.png[:warmup_ticks]` on the command line.
# `warmup_ticks` defaults to 30 — long enough for the spawn loop and any
# stage-setup logic to settle. From the game's main scene `_ready()`, after
# whatever world-staging you want captured:
#
#     if await Screenshotter.maybe_capture(self):
#         return
#
# Bails out (returns false, no side-effects) when neither the env var nor
# the cmd-line arg is set, so leaving the call in shipping code is safe.

const ARG_PREFIX := "--tycoon-shot="
const ENV_VAR := "TYCOON_SHOT"


static func get_spec() -> Dictionary:
	var raw := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(ARG_PREFIX):
			raw = arg.substr(ARG_PREFIX.length())
			break
	if raw.is_empty():
		raw = OS.get_environment(ENV_VAR)
	if raw.is_empty():
		return {}
	var parts := raw.split(":")
	var warmup: int = 30
	if parts.size() > 1 and parts[1].is_valid_int():
		warmup = parts[1].to_int()
	return {"path": parts[0], "warmup": warmup}


# Fast-forward `warmup` ticks, snap the host's viewport to a PNG, quit. Returns
# true if it took over (caller should `return` from `_ready` to skip the rest
# of normal startup).
static func maybe_capture(host: Node) -> bool:
	var spec := get_spec()
	if spec.is_empty():
		return false
	var path: String = spec["path"]
	var warmup: int = spec["warmup"]
	# Force a brisk pace so the warmup completes in a few real-time seconds
	# regardless of the game's current speed setting.
	SimClock.set_speed(maxf(SimClock.speed, 8.0))
	for _i in warmup:
		await EventBus.tick
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	var img := host.get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	if err != OK:
		push_error("[shot] save_png failed: %s -> %s" % [error_string(err), path])
		host.get_tree().quit(1)
		return true
	print("[shot] saved %s" % path)
	host.get_tree().quit(0)
	return true
