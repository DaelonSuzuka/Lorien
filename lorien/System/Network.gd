extends Node

# ******************************************************************************

# server signals
signal server_created

# client signals
signal connected_to_server
signal failed_to_connect
signal disconnected_from_server

# player management signals
signal peer_connected(pinfo)
signal peer_disconnected(pinfo)

# ------------------------------------------------------------------------------

# backends
enum {
	ENET,
	WEBSOCKETS
}
var backend = ENET

var server_info = {
	name = "Server",
	max_players = 10,
	region = 'US-EAST',
	port = 9096,
}

var connection_info = {
	port = 9096,
	ip = 'localhost',
}

var connected = false 
var isServer := false
var net_id := 0

var playerRegistry := {}

var player_info = {
	name = '',
	net_id = 0,
	char_color = Color(1, 1, 1),
	steam_id = 0,
	key_items = [],
}

# ------------------------------------------------------------------------------

# var prefix = '[color=green][NETWORK][/color] '
var prefix = '[NETWORK] '
func Log(string: String):
	print(prefix + string)
	# Console.write_line(prefix + string)

# ******************************************************************************

func _ready():
	get_tree().connect("connected_to_server", self, "_on_connected_to_server")
	get_tree().connect("connection_failed", self, "_on_connection_failed")
	get_tree().connect("server_disconnected", self, "_on_disconnected_from_server")

	if OS.has_feature('HTML5') or OS.has_feature('websockets'):
		backend = WEBSOCKETS

	set_physics_process(false)
	if backend == WEBSOCKETS and !OS.has_feature('HTML5'):
		set_physics_process(true)

# ******************************************************************************
# websocket client and server both need to be polled
var websocket = null
func _physics_process(delta):
	if websocket:
		websocket.poll()

# ******************************************************************************
# Server

func create_server():
	# connect signals
	get_tree().connect("network_peer_connected", self, "peer_connected_to_server")
	get_tree().connect("network_peer_disconnected", self, "peer_disconnected_from_server")

	var net = null
	var result = null

	if backend == WEBSOCKETS:
		net = WebSocketServer.new()
		result = net.listen(server_info.port, PoolStringArray(), true)
		websocket = net
	else:
		net = NetworkedMultiplayerENet.new()
		result = net.create_server(server_info.port, server_info.max_players)

	if result != OK:
		Log("Failed to create server, error code: " + str(result))
		return

	net.allow_object_decoding = true
	get_tree().set_network_peer(net)

	Log("Server created, hosting on port %s" % str(server_info.port))
	
	# update internal state
	net_id = get_tree().get_network_unique_id()
	connected = true
	isServer = true

	# set up 'player' data
	player_info.name = 'Server'
	player_info.net_id = 1
	register_player(player_info)
	emit_signal("server_created")

# server side player handling
func peer_connected_to_server(id):
	Log("Player %s connected" % str(id))

	# Send the server info to the new player
	rpc_id(id, "recieve_server_info", server_info)

func peer_disconnected_from_server(id):
	Log("Player %s disconnected (%s)" % [str(id), playerRegistry[id].name])
	
	unregister_player(id)

# ******************************************************************************
# Client

func join_server():
	if isServer:
		return

	if Args.address:
		connection_info.ip = Args.address

	# create client
	var net = null
	var result = null
	var url = null

	if backend == WEBSOCKETS:
		net = WebSocketClient.new()
		url = 'ws://' + connection_info.ip + ':' + str(connection_info.port)
		result = net.connect_to_url(url, PoolStringArray(), true)
		websocket = net
	else:
		net = NetworkedMultiplayerENet.new()
		url = connection_info.ip
		result = net.create_client(url, connection_info.port)

	if result != OK:
		Log('Failed to create client ' + str(result))
		return
		
	net.allow_object_decoding = true
	get_tree().set_network_peer(net)

	Log('Client created, attempting to connect to ' + url)

func leave_server():
	if isServer:
		return
	Log('Attempting to disconnect from server')
	rpc_id(1, 'kick_me')
	_on_disconnected_from_server()
	
# ------------------------------------------------------------------------------
# Client functions

# Client connected to server
func _on_connected_to_server():
	emit_signal("connected_to_server")
	Log("server connection successful")
	connected = true

	net_id = get_tree().get_network_unique_id()
	player_info.net_id = net_id

	# send our info to the server
	rpc_id(1, "register_player", player_info)

# Client failed to connect to server
func _on_connection_failed():
	emit_signal("failed_to_connect")
	get_tree().set_network_peer(null)

# Client disconnected from server
func _on_disconnected_from_server():
	Log("disconnected from server")
	get_tree().set_network_peer(null)
	emit_signal("disconnected_from_server")
	playerRegistry.clear()
	player_info.net_id = 0
	
	if !OS.has_feature("standalone"):
		get_tree().quit()

# Client recieves server info from server
remote func recieve_server_info(sinfo):
	if !isServer:
		server_info = sinfo

# ******************************************************************************

# Player management

# server only, RPC'd by the client
remote func register_player(pinfo):
	playerRegistry[pinfo.net_id] = pinfo
	rpc("player_registry_updated", playerRegistry)
	emit_signal('peer_connected', pinfo)

# server only, called directly on the server
func unregister_player(id):
	Log("Unregistering player with ID %s" % id)
	var pinfo = playerRegistry[id]
	playerRegistry.erase(id)
	rpc("player_registry_updated", playerRegistry)
	emit_signal("peer_disconnected", pinfo)

# client only
remote func player_registry_updated(registry):
	# check for new players
	for id in registry:
		if id in playerRegistry:
			continue
		playerRegistry[id] = registry[id]
		Log('adding player to registry: %s' % registry[id])
		emit_signal('peer_connected', registry[id])

	# check for missing players
	var removed_ids = []
	for id in playerRegistry:
		if id in registry:
			continue

		removed_ids.append(id)
		Log('removing player from registry: %s' % playerRegistry[id])
		emit_signal('peer_disconnected', playerRegistry[id])

	for id in removed_ids:
		playerRegistry.erase(id)

# ------------------------------------------------------------------------------

func set_name(new_name):
	Network.player_info.name = new_name

func set_address(address):
	Network.connection_info.ip = address
