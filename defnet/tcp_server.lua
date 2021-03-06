--- Simple, non-blocking, TCP socket server that listens for
-- clients on a specific port and for each connection
-- polls for data.
--
-- @usage
--
--	local function on_data(data, ip)
--		print("Received", data, "from", ip)
--		return "My response"
--	end
--	
--	local function on_client_connected(ip)
--		print("Client", ip, "connected")
--	end
--	
--	local function on_client_disconnected(ip)
--		print("Client", ip, "disconnected")
--	end
--	
--	function init(self)
--		self.server = tcp_server.create(8190, on_data, on_client_connected, on_client_disconnected)
--		self.server.start()
--	end
--	
--	function final(self)
--		self.server.stop()
--	end
--	
--	function update(self, dt)
--		self.server.update()
--	end
--

local socket = require "builtins.scripts.socket"
require "defnet.coxpcall"
local tcp_send_queue = require "defnet.tcp_send_queue"

local M = {}

--- Creates a new TCP socket server
-- @param port
-- @param on_data Function to call when data is received. The
-- function will be called with the following args: data, ip
-- Any value returned from this function will be sent as response.
-- @param on_client_connected Function to call when a client has
-- connected. The function will be called with the following args: ip
-- @param on_client_disconnected Function to call when a client has
-- disconnected. The function will be called with the following args: ip
-- @return Server instance
function M.create(port, on_data, on_client_connected, on_client_disconnected)
	assert(port, "You must provide a port")
	assert(on_data, "You must provide an on_data function")

	print("Creating TCP server")
	local server = {}

	local co = nil
	local server_socket = nil

	local clients = {}
	local queues = {}

	local function remove_client(connection_to_remove)
		for i,connection in pairs(clients) do
			if connection == connection_to_remove then
				table.remove(clients, i)
				if on_client_disconnected then
					on_client_disconnected(connection:getsockname())
				end
				break
			end
		end
	end

	--- Start the socket server and listen for clients
	-- Each connection is run in it's own coroutine
	-- @return success
	-- @return error_message
	function server.start()
		print("Starting TCP server on port " .. port)
		local ok, err = pcall(function()
			server_socket = assert(socket.bind("*", port))
		end)
		if not server_socket or err then
			print("Unable to start server", err)
			return false, err
		end

		co = coroutine.create(function()
			local ip, port = server_socket:getsockname()
			server_socket:settimeout(0)
			while true do
				local client, err = server_socket:accept()
				if client then
					client:settimeout(0)
					table.insert(clients, client)
					queues[client] = tcp_send_queue.create(client)
					if on_client_connected then
						on_client_connected(client:getsockname())
					end
				end
				coroutine.yield()
			end
		end)
		coroutine.resume(co)
		return true
	end

	--- Stop the socket server. The socket and all
	-- clients will be closed
	function server.stop()
		if server_socket then
			server_socket:close()
		end
		while #clients > 0 do
			local client = table.remove(clients)
			queues[client] = nil
			client:close()
		end
	end
	
	
	function server.receive(client)
		return client:receive("*l")
	end
	
	function server.send(data)
		for client,queue in pairs(queues) do
			queue.add(data)
		end
	end

	--- Update the socket server. This will resume all
	-- the spawned coroutines in order to check for new
	-- clients and data on existing clients
	function server.update()
		if not co then
			return
		end
		local status = coroutine.status(co)
		if status == "suspended" then
			coroutine.resume(co)
		elseif status == "dead" then
			co = nil
			return
		end
		
		-- read from client sockets that has data
		local read, write = socket.select(clients, nil, 0)
		if next(read) then
			for _,client in ipairs(read) do
				local data, err = server.receive(client)
				if data and on_data then
					local response = on_data(data, client:getsockname())
					if response then
						client:send(response)
					end
				end
				if err and err == "closed" then
					remove_client(client)
				end
			end
		end
		
		-- send to client sockets
		for client,queue in pairs(queues) do
			queue.send()
		end
	end

	return server
end

return M
