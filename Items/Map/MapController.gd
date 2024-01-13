extends TileMap

var MapGenerated: bool = false

#No longer using arrays, read/write requires an indexing system which negates the performance benefit of using array index overlap as link. Reading Positions and IDs separately may be faster if staggered separately but can be added later and merged into local dictionaries.

#Last change from server, considered highest authority on accuracy
var SyncedData: Dictionary = {}
#Current map state, presumably faster than reading tilemap again
var CurrentData: Dictionary = {}
#Local modifications buffered until next sync cycle
var ChangedData: Dictionary = {}

#NOTE : Godot passes all dictionaries by reference, remember that.

const ChunkSize = 4000
const ServerChunkSendFrequency = 0.4
var CurrentServerChunkSendTime = 0

var IsServer = false

var ServerDataChanged = false


#Initialization
func _ready() -> void:
	# Without this, sending a StreamPeerBuffer over an RPC generates the error
	# "Cannot convert argument 1 from Object to Object" on the receiving end
	# and fails.
	# https://github.com/godotengine/godot/issues/82718
	multiplayer.allow_object_decoding = true

	IsServer = Globals.is_server

	if IsServer:
		GenerateMap()
		Globals.initial_map_load_finished = true
	else:
		RequestBlockState.rpc_id(1)

	Globals.WorldMap = self


func GetDepthFunction(x, WidthScale, HeightScale, CraterScale) -> float:
	return -1.0 * sin(x * WidthScale / CraterScale) / (x * WidthScale / CraterScale) * HeightScale


#Procedural world generation
func GenerateMap():
	# Desmos Formula:
	#y=\frac{-\sin\left(\frac{xd}{c}\right)}{\frac{xd}{c}}h
	#x>r
	#x<r
	# d = WidthScale
	# h = HeightScale
	# c = CraterScale
	# r = radius

	var Radius: int = 1909
	var WidthScale = 8
	var HeightScale = 1000
	var CraterScale = 2000.0

	while Radius > 0:
		var Depth = roundi(
			GetDepthFunction(
				float(Radius), float(WidthScale), float(HeightScale), float(CraterScale)
			)
		)
		for i in range(0, 20):
			CurrentData[Vector2i(Radius, -(Depth + i))] = GetRandomStoneTile()
			CurrentData[Vector2i(-Radius, -(Depth + i))] = GetRandomStoneTile()
			Depth += 1

		Radius -= 1

	#New version

	#Simple version
	'''
	var Diameter = 400
	var CurrentRadius = Diameter / 2
	var Radius = Diameter / 2

	var TopCenter = -10
	var BottomCenter = -130
	var TopEdge = 5
	var BottomEdge = -10

	while CurrentRadius >= 0:
		var RadialMultiplier = 1.0 - cos(3.14159265 / Radius * CurrentRadius / 2.0)
		var TopHeight = roundi(
			(
				float(TopCenter)
				+ (
					(float(TopEdge) - float(TopCenter))
					/ float(Radius)
					* float(CurrentRadius)
					* float(RadialMultiplier)
				)
			)
		)
		var BottomHeight = roundi(
			(
				float(BottomCenter)
				+ (
					(float(BottomEdge) - float(BottomCenter))
					/ float(Radius)
					* float(CurrentRadius)
					* float(RadialMultiplier)
				)
			)
		)

		var BottomHeightA = BottomHeight + randi_range(-2, 2)
		var BottomHeightB = BottomHeight + randi_range(-2, 2)

		for Level in range(BottomHeightA, TopHeight, 1):
			if randf() > 0.98:
				CurrentData[Vector2i(CurrentRadius, -Level)] = GetRandomOreTile()
			else:
				CurrentData[Vector2i(CurrentRadius, -Level)] = GetRandomStoneTile()

		for Level in range(BottomHeightB, TopHeight, 1):
			if randf() > 0.98:
				CurrentData[Vector2i(-CurrentRadius, -Level)] = GetRandomOreTile()
			else:
				CurrentData[Vector2i(-CurrentRadius, -Level)] = GetRandomStoneTile()

		CurrentRadius -= 1.0
	'''
	SetAllCellData(CurrentData, 0)
	SyncedData = CurrentData
	MapGenerated = true


#Gets a random valid stone tile ID from the atlas
func GetRandomStoneTile():
	return Vector2i(randi_range(0, 9), 0)


func GetRandomOreTile():
	return Vector2i(randi_range(0, 9), 1)


var CurrentCycleTime: float = 0.0
const SendFrequency = 0.1


func _process(delta: float) -> void:
	CurrentCycleTime += delta
	if CurrentCycleTime > SendFrequency:
		if !IsServer:
			PushChangedData()
		else:
			ServerSendBufferedChanges()
		CurrentCycleTime = 0.0

	if IsServer and MapGenerated:
		CurrentServerChunkSendTime += delta
		if CurrentServerChunkSendTime > ServerChunkSendFrequency:
			CurrentServerChunkSendTime = 0.0
			var Count = len(PlayersToSendInitialState) - 1
			if Count > -1:
				ChunkAndProcessInitialStateData()

			if len(StoredPlayerInventoryDrops):
				for Key in StoredPlayerInventoryDrops.keys():
					Globals.Players[Key].AddInventoryData.rpc(StoredPlayerInventoryDrops[Key])
				StoredPlayerInventoryDrops.clear()

	if IsServer and ServerDataChanged:
		ServerDataChanged = false
		SetAllCellData(SyncedData, 0)


#Check for any buffered change data on the server (data received from clients and waiting to be sent), then chunk it and send it out to clients
func ServerSendBufferedChanges():
	if len(ServerBufferedChanges.keys()) > 0:
		var Count = ChunkSize
		var ChunkedData = {}
		while Count > 0 and len(ServerBufferedChanges.keys()) > 0:
			ChunkedData[ServerBufferedChanges.keys()[0]] = ServerBufferedChanges[
				ServerBufferedChanges.keys()[0]
			]
			ServerBufferedChanges.erase(ServerBufferedChanges.keys()[0])
			Count -= 1
		ServerSendChangedData.rpc(ChunkedData)


#Set the tile map to the given values at given cells. Clears the tile map before doing so. Meant for complete map refreshes, not for incremental changes
func SetAllCellData(Data: Dictionary, Layer: int) -> void:
	clear_layer(Layer)
	for Key: Vector2i in Data.keys():
		set_cell(Layer, Key, 0, Data[Key])


#Get the positions of every cell in the tile map
func GetCellPositions(Layer: int) -> Array[Vector2i]:
	var Positions: Array[Vector2i] = get_used_cells(Layer)
	return Positions


#Get the tile IDs of every cell in the tile map
func GetCellIDs(Layer):
	var IDs: Array[Vector2i]
	var Positions: Array[Vector2i] = get_used_cells(Layer)

	for Position in Positions:
		IDs.append(get_cell_atlas_coords(Layer, Position))
	return IDs


var PlayersToSendInitialState: Array[int] = []
var InitialStatesRemainingPos = []
var InitialStatesRemainingIDs = []

#Requests a world state sync from the server, this is an initial request only sent when a client first joins
@rpc("any_peer", "call_remote", "reliable")
func RequestBlockState() -> void:
	if IsServer:
		PlayersToSendInitialState.append(multiplayer.get_remote_sender_id())

		var Values = []
		for Key in SyncedData.keys():
			Values.append(SyncedData[Key])

		InitialStatesRemainingPos.append(SyncedData.keys())
		InitialStatesRemainingIDs.append(Values)


#Processes chunked initial states for each client that has requested a world state sync
#Currently sends out chunks to every client in parallel, but should probably send out data to one client at a time to avoid many simultaneous RPCs if multiple clients join at the same time
func ChunkAndProcessInitialStateData():
	var player_index: int = len(PlayersToSendInitialState) - 1
	if player_index >= 0:
		while player_index >= 0:
			#SendTestPeerBuffer(PlayersToSendInitialState[player_index])
			Helpers.log_print(str("Tile Count: ", len(InitialStatesRemainingPos[player_index])))
			var SliceCount = clamp(len(InitialStatesRemainingPos[player_index]), 0, ChunkSize)
			var SlicePositions = InitialStatesRemainingPos[player_index].slice(0, SliceCount)
			var SliceIDs = InitialStatesRemainingIDs[player_index].slice(0, SliceCount)
			InitialStatesRemainingPos[player_index - 1] = (
				InitialStatesRemainingPos[player_index - 1].slice(SliceCount)
			)
			InitialStatesRemainingIDs[player_index - 1] = (
				InitialStatesRemainingIDs[player_index - 1].slice(SliceCount)
			)

			ServerCompressAndSendBlockStates(
				PlayersToSendInitialState[player_index],
				SlicePositions,
				SliceIDs,
				len(InitialStatesRemainingPos[player_index]) == 0,
			)

			if len(InitialStatesRemainingPos[player_index]) == 0:
				InitialStatesRemainingPos.remove_at(player_index)
				InitialStatesRemainingIDs.remove_at(player_index)
				PlayersToSendInitialState.remove_at(player_index)
			player_index -= 1


func ServerCompressAndSendBlockStates(player_id, Positions, IDs, Finished):
	var StreamData: StreamPeerBuffer = StreamPeerBuffer.new()

	var Count: int = len(Positions) - 1
	StreamData.put_u16(Count)

	while Count >= 0:
		StreamData.put_16(Positions[Count].x)
		StreamData.put_16(Positions[Count].y)

		StreamData.put_16(IDs[Count].x)
		StreamData.put_16(IDs[Count].y)
		Count -= 1

	SendBlockState.rpc_id(
		player_id, StreamData.data_array.size(), StreamData.data_array.compress(), Finished
	)


#Send chunks of the world dat block to clients, used for initial world sync
@rpc("authority", "call_remote", "unreliable")
func SendBlockState(DataSize: int, CompressedData: PackedByteArray, Finished: bool) -> void:
	if !Globals.initial_map_load_finished:
		# Decompress data from stream buffer
		var Positions = []
		var IDs = []

		var Data: StreamPeerBuffer = StreamPeerBuffer.new()
		Helpers.log_print(
			str(
				"Received CompressedData Size: ",
				CompressedData.size(),
				" Originally: ",
				DataSize,
				" Chunk Size: ",
				ChunkSize
			)
		)
		Data.data_array = CompressedData.decompress(DataSize)

		var Length = Data.get_u16() - 1
		while Length >= 0:
			Positions.append(Vector2i(Data.get_16(), Data.get_16()))
			IDs.append(Vector2i(Data.get_16(), Data.get_16()))
			Length -= 1

		# Convert arrays back into dictionary
		var Count = len(Positions) - 1
		while Count >= 0:
			SyncedData[Positions[Count]] = IDs[Count]
			CurrentData[Positions[Count]] = IDs[Count]
			Count -= 1

		if Finished:
			if len(BufferedChangesReceivedFromServer) > 0:
				for BufferedChange in BufferedChangesReceivedFromServer:
					for Key: Vector2i in BufferedChange.keys():
						SyncedData[Key] = BufferedChange[Key]
						CurrentData[Key] = BufferedChange[Key]
			BufferedChangesReceivedFromServer.clear()

		SetAllCellData(CurrentData, 0)

		Globals.initial_map_load_finished = Finished
		if Globals.initial_map_load_finished:
			Helpers.log_print("Finished loading map.")


#Architecture plan:

#Players modify local data
#Push data to server, store buffered status
#Server receives push and overwrites local data
#Server pushes modifications to all clients
#Receiving client accepts changes
#Failed local state revision drops placed cells, drop items are not spawned until state change is confirmed

#Design Issues:
#Empty cells considered empty data, requires updating entire tile map for empty refresh (expensive?)
#Solution is to store remove tile changes as separate system


#Modify a cell from the client, checks for finished world load and buffers changes for server accordingly
func ModifyCell(Position: Vector2i, ID: Vector2i):
	if !Globals.initial_map_load_finished:
		#Not allowed to modify map until first state received
		#Because current map is not trustworthy, not cleared on start so player doesn't fall through world immediately.
		return
	if Position in ChangedData.keys():
		ChangedData[Position] = [ChangedData[Position][0], ID]
	elif SyncedData.has(Position):
		ChangedData[Position] = [SyncedData[Position], ID]
	else:
		ChangedData[Position] = [Vector2i(-1, -1), ID]

	SetCellData(Position, ID)


#Place air at a position : TEST TEMP
func MineCellAtPosition(Position: Vector2):
	ModifyCell(local_to_map(to_local(Position)), Vector2i(-1, -1))


#Place a standard piece of stone at a position : TEST TEMP
func PlaceCellAtPosition(Position: Vector2):
	ModifyCell(local_to_map(to_local(Position)), GetRandomStoneTile())


#Set the current data of a cell to a given value
func SetCellData(Position: Vector2i, ID: Vector2i) -> void:
	CurrentData[Position] = ID
	set_cell(0, Position, 0, ID)


#Push change data stored on the client to the server, if there is any
#Still need to add chunking to this process right here
func PushChangedData() -> void:
	if len(ChangedData.keys()) > 0:
		RPCSendChangedData.rpc(ChangedData)
		ChangedData.clear()


#Changes the server has received and accepted, and is waiting to send back to all clients later
var ServerBufferedChanges: Dictionary = {}

#Sends changes from the client to the server to be processed
@rpc("any_peer", "call_remote", "reliable")
func RPCSendChangedData(Data: Dictionary) -> void:
	if IsServer:
		var Player = multiplayer.get_remote_sender_id()
		for Key: Vector2i in Data.keys():
			if not SyncedData.has(Key) or SyncedData[Key] == Data[Key][0]:
				ServerBufferedChanges[Key] = Data[Key][1]
				SyncedData[Key] = Data[Key][1]

				if Data[Key][0].y > -1:
					if Player not in StoredPlayerInventoryDrops.keys():
						StoredPlayerInventoryDrops[Player] = {}
					if Data[Key][0].y in StoredPlayerInventoryDrops[Player].keys():
						StoredPlayerInventoryDrops[Player][Data[Key][0].y] += 1
					else:
						StoredPlayerInventoryDrops[Player][Data[Key][0].y] = 1

		ServerDataChanged = true


var StoredPlayerInventoryDrops = {}

var BufferedChangesReceivedFromServer: Array[Dictionary] = []

#Sends changes from the server to clients
@rpc("authority", "call_remote", "reliable")
func ServerSendChangedData(Data: Dictionary) -> void:
	if !Globals.initial_map_load_finished:
		#Store changes and process after the maps has been fully loaded
		BufferedChangesReceivedFromServer.append(Data)
		return
	if IsServer:
		return
	for Key: Vector2i in Data.keys():
		SyncedData[Key] = Data[Key]
		CurrentData[Key] = Data[Key]
		UpdateCellFromCurrent(Key)


#Updates a cells tile from current data
func UpdateCellFromCurrent(Position):
	set_cell(0, Position, 0, CurrentData[Position])


#Test RPC's
func SendTestPeerBuffer(player_id: int) -> void:
	var StreamData: StreamPeerBuffer = StreamPeerBuffer.new()
	StreamData.put_8(127)
	StreamData.put_8(126)
	StreamData.put_8(125)
	StreamData.put_8(-123)
	Helpers.log_print(
		str("Sending test data of length ", StreamData.data_array.size(), " to ", player_id)
	)
	StreamData.seek(0)
	Helpers.log_print(str(StreamData.get_8()))
	Helpers.log_print(str(StreamData.get_8()))
	Helpers.log_print(str(StreamData.get_8()))
	Helpers.log_print(str(StreamData.get_8()))

	# That's right, the cursor i sin the StreamPeerBuffer and will be where you left it on the receiving end!
	StreamData.seek(0)

	RPCSendTestPeerBuffer.rpc_id(
		player_id, StreamData.data_array.size(), StreamData.data_array.compress()
	)


@rpc("any_peer", "call_remote", "reliable")
func RPCSendTestPeerBuffer(DataSize: int, CompressedData: PackedByteArray) -> void:
	var Data: StreamPeerBuffer = StreamPeerBuffer.new()
	Data.data_array = CompressedData.decompress(DataSize)
	Helpers.log_print(str("Received test data:"))
	#Helpers.log_print(str("Received test data of length ", StreamPeerBuffer.data_array.size()))
	#Data.seek(0)  # Probably not needed, since we just received this?
	Helpers.log_print(str(Data.get_8()))
	Helpers.log_print(str(Data.get_8()))
	Helpers.log_print(str(Data.get_8()))
	Helpers.log_print(str(Data.get_8()))
