extends RigidBody2D

@export var spawn_position: Vector2


func _ready() -> void:
	set_physics_process(is_multiplayer_authority())
	if Globals.is_server and spawn_position:
		position = spawn_position
		Helpers.log_print(str("Setting Soup Machine position to ", spawn_position))


@rpc("any_peer", "call_local")
func grab() -> void:
	Helpers.log_print(
		str(
			"I (",
			name,
			") was grabbed by ",
			multiplayer.get_remote_sender_id(),
			" Deleting myself now"
		),
		"saddlebrown"
	)
	# Delete myself if someone grabbed me
	queue_free()
	# Once that is done, tell the player node that grabbed me to spawn a "held" version
	var player: Node = get_node_or_null(
		str("/root/Main/Players/", multiplayer.get_remote_sender_id(), "/Interaction Controller")
	)
	if player and player.has_method("spawn_player_controlled_thing"):
		player.spawn_player_controlled_thing.rpc(global_position,global_rotation,name)

var WaitingToSetLocation = false
var ForceSetPosition
var ForceSetRotation

#Unforunately Godot does not provide a system for physics/trasnform reconciliation, direct acess to the physics state, or a state update request system.
#So the only option is this cyclic state update check. Hopefully it isn't too expensive.
#The initial position can not be set either because of how the spawning system work for netwrok syncronizers.

#This is hard baked enough into Godot's methodology that I assume it is intended behavior, and consequently this will need to be broken out into it's own script
#to allow this behaviour to be easilly addded to objects, as it is critical for physics control.

func SetSpawnLocation(Position:Vector2,Rotation:float) -> void:
	ForceSetPosition = Position
	ForceSetRotation = Rotation
	WaitingToSetLocation = true

func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if WaitingToSetLocation:
		state.transform = Transform2D(ForceSetRotation,ForceSetPosition)
		WaitingToSetLocation = false