local Signal = require(script.Parent.Signal)

local Profile = {}
Profile.__index = Profile

Profile.LoadedProfiles = {} -- List of all profiles that are currently loaded and have active sessions

-- Profile object template
Profile.PROFILE_TEMPLATE = {
	Data = {},
	MetaData = {
		LastUpdate = DateTime.now().UnixTimestampMillis,
		ProfileCreateTime = DateTime.now().UnixTimestampMillis,
		SessionLoadCount = 0,
		SessionJobId = nil
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
	},
	UserIds: {number},

	Changed: any,
	OnSessionEnd: any,
	SessionEnded: boolean?,

	AddUserId: (self: Profile<TData>, userId: number) -> (),
	RemoveUserId: (self: Profile<TData>, userId: number) -> (),
	Reconcile: (self: Profile<TData>) -> (),
	EndSession: (self: Profile<TData>) -> (),
	Save: (self: Profile<TData>, unlock: boolean?) -> boolean,
	OnChange: (self: Profile<TData>, key: string, callback: (any, any) -> (), once: boolean?) -> Signal.Connection
}

-- Clones a table and all its subtables
-- tbl: The table to clone
local function _deepCloneTable(tbl)
	local clone = {}
	for key, value in pairs(tbl) do
		if typeof(value) == "table" then
			clone[key] = _deepCloneTable(value)
		else
			clone[key] = value
		end
	end
	return clone
end

-- Auto save a profile at a given interval
-- profile: The profile to save
-- interval: The amount of time between each autosave
local function _runAutoSaveLoop(profile, interval: number)
	while profile ~= nil and not profile.SessionEnded do
		task.wait(interval)
		profile:Save()
	end
end

-- Check if two tables have all the same values
-- a, b: Tables to compare
local function _tablesEqual(a, b)
	-- If the same table was passed twice
	if a == b then
		return true
	end
	-- If either is not a table
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return false
	end

	-- Loop through and check if every value is equal to each other
	for key, value in pairs(a) do
		if not _tablesEqual(value, b[key]) then
			return false
		end
	end

	-- Make sure no values are missing
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end

	return true
end

-- Detect when changes are made to a profile's data
-- profile: The profile to check for changes on
-- interval: The amount of time between each check
-- TODO: optimize this...perchance...
local function _runChangedCheck(profile, interval: number)
	local cache = _deepCloneTable(profile.Data) -- Stores the last known value
	
	-- Go through the table and call each key's changed signal if it has one
	local function callChangedPerValue(tbl, c, directory: string)
		for key, value in pairs(tbl) do
			if typeof(value) == "table" then
				callChangedPerValue(value, c[key], directory and `{directory}.{key}` or key)
			elseif c[key] ~= value then
				-- Get and call signal
				local signal: Signal.Signal? = directory and profile.KeySignals[`{directory}.{key}`] or profile.KeySignals[key]
				if signal then
					signal:Fire(c[key], value)
				end
			end
		end
	end

	while profile ~= nil and not profile.SessionEnded do
		task.wait(interval)
		-- Check current value against cache
		if not _tablesEqual(profile.Data, cache) then
			-- If they are not equal, fire changed signals and update cache
			profile.Changed:Fire(cache, profile.Data)
			callChangedPerValue(profile.Data, cache)
			
			cache = _deepCloneTable(profile.Data)
		end
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
	local OnSessionEnd: Signal.Signal = Signal.new()
	-- Called when profile data is changed
	-- Calls with old and new values
	local Changed: Signal.Signal = Signal.new()

	local self = setmetatable({
		Key = key,
		DataStore = instance,
		KeySignals = {},
		
		Data = data.Data or Profile.PROFILE_TEMPLATE,
		MetaData = {
			LastUpdate = data.MetaData.LastUpdate or DateTime.now().UnixTimestampMillis,
			ProfileCreateTime = data.MetaData.ProfileCreateTime or DateTime.now().UnixTimestampMillis,
			SessionLoadCount = data.MetaData.SessionLoadCount or 0,
			SessionJobId = data.MetaData.SessionJobId or game.JobId
		},
		UserIds = data.UserIds or {},

		Changed = Changed,
		OnSessionEnd = OnSessionEnd
	}, Profile)

	if not mock then
		self.MetaData.SessionLoadCount += 1
		local success, result = pcall(function()
			return self.DataStore.DataStore:UpdateAsync(self.Key, function(data)
				-- Check if this is the first creation of this data
				local creating = data == nil

				-- Nil-safety
				data = data or {}
				data.MetaData = data.MetaData or {}

				-- Ensure profile is not already locked
				if data.MetaData.SessionJobId ~= nil and data.MetaData.SessionJobId ~= game.JobId then
					warn(`Session for profile {key} is currently locked.`)
					return
				end

				-- Lock profile and update metadata
				data.MetaData.SessionJobId = game.JobId
				self.MetaData.LastUpdate = DateTime.now().UnixTimestampMillis
				-- If creating, also add the ProfileCreateTime
				if creating then
					self.MetaData.ProfileCreateTime = self.MetaData.LastUpdate
				end

				return data
			end)
		end)
		if not success or not result then
			warn(`Failed to load profile {key}: {result}`)
			return nil
		end
		
		if key then
			-- Add to LoadedProfile and start running loops
			Profile.LoadedProfiles[key] = self
			task.spawn(_runAutoSaveLoop, self, instance.AutoSaveInterval)
			task.spawn(_runChangedCheck, self, 0.5)
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
	local reconciled = _reconcileTable(self.Data, self.DataStore.Template)
	self.Data = reconciled
end

-- Ends a profile's session (saving and unlocking it)
function Profile:EndSession()
	-- If it's already ended, don't continue
	if self.SessionEnded then
		return
	end

	-- Call session ended signal, save, and unload
	self.SessionEnded = true
	self.OnSessionEnd:Fire()
	self:Save(true)
	Profile.LoadedProfiles[self.Key] = nil
end

-- Saves a profile's data
-- unlock: Whether to unlock the session
function Profile:Save(unlock: boolean?)
	local success, response = pcall(function()
		return self.DataStore.DataStore:UpdateAsync(self.Key, function(data)
			-- Nil-safety
			data = data or {}
			data.MetaData = data.MetaData or {}

			-- Make sure this isn't locked by another server
			if data.MetaData.SessionJobId ~= nil and data.MetaData.SessionJobId ~= game.JobId then
				warn("Session is currently locked.")
				return
			end

			-- Update LastUpdate
			self.MetaData.LastUpdate = DateTime.now().UnixTimestampMillis

			-- Set all the data and unlock if necessary
			data.Data = self.Data
			data.MetaData = self.MetaData
			data.UserIds = self.UserIds
			if unlock then
				data.MetaData.SessionJobId = nil
			end

			return data
		end)
	end)
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
	print(key)
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

return Profile