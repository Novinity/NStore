local Signal = {}
Signal.__index = Signal

export type Signal = {
	Connections: {Connection},
	Connect: (self: Signal, callback: () -> ()) -> Connection,
	Wait: () -> (),
	Fire: (self: Signal, ...any) -> (),
	Once: (self: Signal, ...any) -> (),
	DisconnectAll: (self: Signal) -> (),
}

type Connection = {
	Callback: () -> (),
	Disconnect: (self: Connection) -> (),
	Once: boolean
}

local function _disconnectConnection(self: Signal, connection: Connection)
	local index = table.find(self.Connections, connection)
	if index then
		table.remove(self.Connections, index)
	end
end

function Signal.new(): Signal
	local self: Signal = setmetatable({
		Connections = {}
	}, Signal)
	return self
end

function Signal:Connect(callback): Connection
	local connection: Connection = {
		Callback = callback,
		Disconnect = function()
			_disconnectConnection(self)
		end,
		Once = false
	}
	table.insert(self.Connections, connection)
	return connection
end

function Signal:Once(callback): Connection
	local connection: Connection = {
		Callback = callback,
		Disconnect = function()
			_disconnectConnection(self)
		end,
		Once = true
	}
	table.insert(self.Connections, connection)
	return connection
end

function Signal:Wait()
	local called = false
	local connection = self:Once(function()
		called = true
	end)
	repeat task.wait() until called
end

function Signal:Fire(...)
	for _, connection in self.Connections do
		connection.Callback(...)
		if connection.Once then
			connection:Disconnect()
		end
	end
end

function Signal:DisconnectAll()
	for _, connection in self.Connections do
		connection:Disconnect()
	end
end

return Signal
