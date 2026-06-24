extends Node
# Detects dedicated-server exports and relaunches with server.gd as the main script.
# server.gd extends SceneTree and must run as the SceneTree script, which requires
# the --script flag.  The dedicated-server export bakes OS.has_feature("dedicated_server")
# into the binary; we use that to trigger the relaunch without any CLI arguments.
func _ready() -> void:
	if not OS.has_feature("dedicated_server"):
		return
	OS.execute(OS.get_executable_path(), ["--script", "res://server.gd"])
	get_tree().quit()
