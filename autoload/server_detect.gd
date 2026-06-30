extends Node
# Detects dedicated-server exports and relaunches with server.gd as the main script.
# server.gd extends SceneTree and must run as the SceneTree script, which requires
# the --script flag.  The dedicated-server export bakes OS.has_feature("dedicated_server")
# into the binary; we use that to trigger the relaunch without any CLI arguments.
func _ready() -> void:
	if not OS.has_feature("dedicated_server"):
		return
	# A dedicated server has no display and no HMD, so force --headless and
	# --xr-mode off on the relaunch. Without them the child opens a window and
	# stalls on OpenXR init (xrCreateInstance fails with no runtime), so it never
	# binds the listener. This matches the CI smoke's `--headless --script server.gd`.
	OS.execute(OS.get_executable_path(), ["--headless", "--xr-mode", "off", "--script", "res://server.gd"])
	get_tree().quit()
