local Signal = {}
Signal.__index = Signal

-- Signal type for type checking
export type Signal = {
	Connections: {Connection},
	Connect: (self: Signal, callback: () -> ()) -> Connection,
	Wait: () -> (),
	Fire: (self: Signal, ...any) -> (),
	Once: (self: Signal, ...any) -> (),
	DisconnectAll: (self: Signal) -> (),
}

-- Connection type for type checking
export type Connection = {
	Callback: () -> (),
	Disconnect: (self: Connection) -> (),
	Once: boolean
}

-- Disconnects a connection from a signal
-- self: The signal to disconnect from
-- connection: The connection to disconnect
local function _disconnectConnection(self: Signal, connection: Connection)
	-- Find and remove if it exists on this signal
	local index = table.find(self.Connections, connection)
	if index then
		table.remove(self.Connections, index)
	end
end

-- Creates a new signal
function Signal.new(): Signal
	local self: Signal = setmetatable({
		Connections = {}
	}, Signal)
	return self
end

-- Connects a function to the signal
-- callback: The function to connect
function Signal:Connect(callback): Connection
	local connection: Connection = {
		Callback = callback,
		Once = false
	}
	connection.Disconnect = function()
		_disconnectConnection(self, connection)
	end
	
	-- Add to connections
	table.insert(self.Connections, connection)
	return connection
end

-- Connects a function to the signal, setting it to only ever fire once
-- callback: The function to connect
function Signal:Once(callback): Connection
	local connection: Connection = {
		Callback = callback,
		Once = true
	}
	connection.Disconnect = function()
		_disconnectConnection(self, connection)
	end
	
	table.insert(self.Connections, connection)
	return connection
end

-- Waits for a signal to be fired
function Signal:Wait()
	local called = false
	self:Once(function()
		called = true
	end)
	repeat task.wait() until called
end

-- Fires all connections on a signal
-- ...: Args to pass to connections
function Signal:Fire(...)
	local connCache = table.clone(self.Connections)
	-- Loop through all connections and fire their callbacks with the passed args
	for _, connection in connCache do
		task.spawn(connection.Callback, ...)
		-- If they wwere connected using :Once, disconnect them
		if connection.Once then
			connection:Disconnect()
		end
	end
end

-- Disconnects all connections from a signal
function Signal:DisconnectAll()
	for _, connection in self.Connections do
		connection:Disconnect()
	end
end

return Signal
