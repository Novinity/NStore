local Signal = require(script.Parent.Signal)
local Utils = require(script.Parent.Utils)

local Profile = {}
Profile.__index = Profile

Profile.LoadedProfiles = {} -- List of all profiles that are currently loaded and have active sessions

-- Profile object template
Profile.PROFILE_TEMPLATE = {
	Data = {},
	MetaData = {
		LastUpdate = 0,
		ProfileCreateTime = 0,
		SessionLoadCount = 0,
		SessionJobId = nil,
		SessionExpiry = nil,
	},
	UserIds = {}
}

-- Profile type for type checking
export type Profile<TData> = {
	Key: string,
	DataStore: any,
	KeySignals: {[string]: Signal.Signal},

	Data: TData,
	MetaData: {
		LastUpdate: number,
		ProfileCreateTime: number,
		SessionLoadCount: number,
		SessionJobId: string?,
		SessionExpiry: number?,
	},
	UserIds: {number},
	
	Released: boolean?,

	Changed: Signal.Signal,
	OnRelease: Signal.Signal,
	OnSave: Signal.Signal,
	OnAfterSave: Signal.Signal,
	OnLastSave: Signal.Signal,

	AddUserId: (self: Profile<TData>, userId: number) -> (),
	RemoveUserId: (self: Profile<TData>, userId: number) -> (),
	Reconcile: (self: Profile<TData>) -> (),
	Release: (self: Profile<TData>) -> (),
	Save: (self: Profile<TData>, unlock: boolean?) -> boolean,
	OnChange: (self: Profile<TData>, key: string, callback: (any, any) -> (), once: boolean?) -> Signal.Connection,
	DisconnectAllKeyListeners: (self: Profile<TData>, key: string) -> ()
}

-- Auto save a profile at a given interval
-- profile: The profile to save
-- interval: The amount of time between each autosave
local function _runAutoSaveLoop(profile, interval: number)
	while profile ~= nil and not profile.Released do
		task.wait(interval)
		if profile.Released then
			break
		end
		profile:Save()
	end
end

-- Ensures no values from template are missing in target
-- target: The table to add values to
-- template: The table to reference for value
local function _reconcileTable(target, template)
	-- Loop through everything in template
	for key, templateValue in pairs(template) do
		-- If it doesn't exist, add it
		if target[key] == nil then
			target[key] = templateValue
		-- If it's a table, ensure they are reconciled too
		elseif typeof(target[key]) == "table" and typeof(templateValue) == "table" then
			_reconcileTable(target[key], templateValue)
		end
	end
	return target
end

-- Creates a proxy/interceptor for the given table to allow changes to be detected
-- target: The table to create a proxy for
-- path: The path to the table to pass to changed event
-- onChange: Function to call when a change is detected
local function _proxyTable(target, path, onChange)
	path = path or "" -- path to current location in table
	local childProxies = {} -- proxy cache
	
	return setmetatable({}, {
		-- getter
		__index = function(_, key)
			local value = target[key]
			-- Proxy nested tables
			if typeof(value) == "table" then
				-- Check cache for existing proxy, create if one doesnt exist
				if not childProxies[key] then
					local prxy = _proxyTable(value, path .. key .. ".", function(subKey, old, new, path)
						if onChange then
							onChange(subKey, old, new, path)
						end
					end)
					childProxies[key] = prxy
					return prxy
				end
				return childProxies[key]
			end
			return value
		end,
		-- setter
		__newindex = function(_, key, value)
			-- Check if a change was actually made
			local old = target[key]
			if old == value then return end
			
			-- Update value in proxy table
			target[key] = value
			-- Invalidate existing proxy cache for this key
			childProxies[key] = nil
			
			-- Call changed
			if onChange then
				onChange(key, old, value, path)
			end
		end,
		-- length
		__len = function()
			return #target
		end,
		-- iteration
		__iter = function(self)
			local key = nil
			return function()
				key = next(target, key)
				if not key then return nil end
				return key, self[key]
			end, self
		end,
		-- print
		__tostring = function()
			return `\{\n{Utils.tableToString(target)}\n\}`
		end,
	}), target
end

local function _dataChangeCallback(self, subKey, old, new, path)
	-- Fire the profile change and key change events
	self.Changed:Fire(old, new)

	local p = path .. subKey
	local signal: Signal.Signal? = self.KeySignals[p]
	if signal then
		signal:Fire(old, new)
	end
end

-- Creates a new profile
-- key: The datastore key to use
-- data: The data to load onto the profile
-- instance: The NStore instance this is applied to
-- mock: Whether the profile should not be saved
function Profile.new(key: string, data: {}, instance, mock: boolean?)
	-- Nil-safety
	data = data or {}
	data.MetaData = data.MetaData or {}

	-- Called when session ends
	local OnRelease: Signal.Signal = Signal.new()
	-- Called when profile data is changed
	-- Calls with old and new values
	local Changed: Signal.Signal = Signal.new()
	-- Called right before the profile saves
	local OnSave: Signal.Signal = Signal.new()
	-- Called right after the profile saves
	-- Passes success status with it
	local OnAfterSave: Signal.Signal = Signal.new()
	-- Called when the profile is saving for the final time
	-- Passes the reason for ending
	-- "Manual": :Release was called by user code
	-- "Shutdown": :Release was called because the server is shutting down
	local OnLastSave: Signal.Signal = Signal.new()

	local self = setmetatable({
		Key = key,
		DataStore = instance,
		KeySignals = {},
		
		--Data = {},
		MetaData = {
			LastUpdate = data.MetaData.LastUpdate or DateTime.now().UnixTimestampMillis,
			ProfileCreateTime = data.MetaData.ProfileCreateTime or DateTime.now().UnixTimestampMillis,
			SessionLoadCount = data.MetaData.SessionLoadCount or 0,
			SessionJobId = data.MetaData.SessionJobId or game.JobId,
			SessionExpiry = data.MetaData.SessionExpiry or os.time() + instance.AutoSaveInterval,
		},
		UserIds = data.UserIds or {},

		Changed = Changed,
		OnRelease = OnRelease,
		OnSave = OnSave,
		OnAfterSave = OnAfterSave,
		OnLastSave = OnLastSave
	}, Profile)
	
	-- Create a proxy for the data
	-- Raw data keeps a copy of the data without any proxy for saving
	local rawData = data.Data
	local proxy, raw = _proxyTable(rawData, nil, function(subKey, old, new, path)
		_dataChangeCallback(self, subKey, old, new, path)
	end)
	
	self.Data = proxy
	self._rawData = raw

	if not mock then
		self.MetaData.SessionLoadCount += 1
		
		if key then
			-- Add to LoadedProfile and start running loops
			Profile.LoadedProfiles[key] = self
			task.spawn(_runAutoSaveLoop, self, instance.AutoSaveInterval)
			--task.spawn(_runChangedCheck, self, 0.5)
		end
	end

	return self
end

-- Adds a user id to the list of userIds in a profile
-- userId: The user id to add
function Profile:AddUserId(userId: number)
	-- Make sure it's not already in the list
	local idx = table.find(self.UserIds, userId)
	if idx then return end

	table.insert(self.UserIds, userId)
	
end

-- Removes a user id to the list of userIds in a profile
-- userId: The user id to remove
function Profile:RemoveUserId(userId: number)
	-- Make sure it's actually in the list
	local idx = table.find(self.UserIds, userId)
	if not idx then return end

	table.remove(self.UserIds, idx)
end

-- Ensures no values from the template are missing from the data
function Profile:Reconcile()
	local reconciled = _reconcileTable(self._rawData, self.DataStore.Template)
	local proxy, raw = _proxyTable(reconciled, nil, function(subKey, old, new, path)
		_dataChangeCallback(self, subKey, old, new, path)
	end)
	self.Data = proxy
	self._rawData = raw
end

-- Ends a profile's session (saving and unlocking it)
function Profile:Release()
	-- If it's already ended, don't continue
	if self.Released then
		return
	end

	-- Call session ended signal, save, and unload
	self.Released = true
	self.OnRelease:Fire()
	
	if self.DataStore.IsClosing then
		self.OnLastSave:Fire("Shutdown")
	else
		self.OnLastSave:Fire("Manual")
	end
	
	self:Save(true)
	Profile.LoadedProfiles[self.Key] = nil
	
	-- Clean up connections
	for _, signal: Signal.Signal in self.KeySignals do
		signal:DisconnectAll()
	end
	self.OnRelease:DisconnectAll()
	self.OnSave:DisconnectAll()
	self.OnAfterSave:DisconnectAll()
	self.OnLastSave:DisconnectAll()
	self.Changed:DisconnectAll()
end

-- Saves a profile's data
-- unlock: Whether to unlock the session
function Profile:Save(unlock: boolean?, dontFire: boolean?)
	if not dontFire then
		self.OnSave:Fire()
	end
	local success, response = pcall(function()
		return self.DataStore.DataStore:UpdateAsync(self.Key, function(data)
			-- Nil-safety
			data = data or {}
			data.MetaData = data.MetaData or {}

			local _sessionId = data.MetaData.SessionJobId
			local _sessionExpiry = data.MetaData.SessionExpiry
			-- Make sure this isn't locked by another server
			if _sessionId ~= nil and _sessionId ~= game.JobId and (_sessionExpiry or 0) >= os.time() then
				warn(`Session for profile {self.Key} is currently locked.`)
				return
			end

			-- Update LastUpdate
			self.MetaData.LastUpdate = DateTime.now().UnixTimestampMillis

			-- Set all the data and unlock if necessary
			data.Data = Utils.deepCloneTable(self._rawData)
			data.MetaData = self.MetaData
			data.UserIds = self.UserIds
			if unlock then
				data.MetaData.SessionJobId = nil
				data.MetaData.SessionExpiry = nil
			else
				data.MetaData.SessionExpiry = os.time() + self.DataStore.AutoSaveInterval
			end

			return data
		end)
	end)
	
	if not dontFire then
		self.OnAfterSave:Fire(success and response and true or false)
	end
	
	if not success or not response then
		warn(`Failed to save profile {self.Key}: {response}`)
		return false
	end
	return true
end

-- Connect a callback to a change signal on a specific key
-- key: The key to track
-- callback: The function to call when the key changes (old, new)
-- once: Whether to only use this connection once
function Profile:OnChange(key: string, callback, once: boolean?): Signal.Connection
	-- Retrieve or create signal
	local signal = self.KeySignals[key] or Signal.new()
	-- If signal did not exist, cache it
	if not self.KeySignals[key] then
		self.KeySignals[key] = signal
	end
	
	-- Connect to signal
	if once then
		return signal:Once(callback)
	else
		return signal:Connect(callback)
	end
end

-- Disconnects all changed signals for the given key
-- key: The key to disconnect from
function Profile:DisconnectAllKeyListeners(key: string)
	local signal = self.KeySignals[key]
	if signal then
		signal:DisconnectAll()
	end
end

return Profile