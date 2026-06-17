--[[
	NStore -- A basic Roblox datastore wrapper heavily inspired by ProfileStore
	Author: Novinity

	Features:
	- Data saving/loading
	- Code autocompletion
	- Data autosaving
	- Session locking
	- Data reconciliation
]]

local DataStoreService = game:GetService("DataStoreService")

local Profile = require(script.Profile)
local Signal = require(script.Signal)

-- Profile type for type checking
export type Profile<T> = Profile.Profile<T>

local NStore = {}
NStore.__index = NStore

-- NStore instance type for type checking
export type NStore<TData> = {
	DataStore: DataStore,
	Template: TData,
	AutoSaveInterval: number,

	StartSessionAsync: (self: NStore<TData>, key: string, functions: {Cancel: (() -> boolean)?}) -> Profile<TData>?,
	GetAsync: (self: NStore<TData>, key: string) -> Profile<TData>?,
	RemoveAsync: (self: NStore<TData>, key: string) -> (),
}

-- Clones a table and all its subtables
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

-- Creates a new NStore instance
-- name: Datastore name
-- template: Data template to be copied and referenced
-- autoSaveInterval: How often data should be saved automatically
function NStore.new(name: string, template: {}, autoSaveInterval: number?)
	local self = setmetatable({}, NStore)

	-- Get the datastore with the passed name
	local DS = DataStoreService:GetDataStore(name)

	-- Populate self
	self.DataStore = DS
	self.Template = template
	self.AutoSaveInterval = autoSaveInterval or 300

	print(`New NStore instance initialized: {name}`)

	return self
end

-- Create a new profile from the given key
-- key: The Datastore key to retrieve data from
-- arguments: Variables and functions used to decide on certain events
function NStore:StartSessionAsync(key: string, arguments: {
		Steal: boolean?, -- If true, this will override an existing session lock
		Cancel: () -> ()? -- If true is returned by this function, cancel session starting
	})
	-- If profile is already loaded, cancel
	if Profile.LoadedProfiles[key] then
		warn("Profile already loaded for key: " .. key)
		return
	end

	-- Check passed cancel condition if one is passed
	local cancelFunc = arguments.Cancel
	if cancelFunc and cancelFunc() then
		return
	end

	local loadedData
	local JobId = game.JobId -- server id
	local success, response = pcall(function()
		-- UpdateAsync to retrieve up-to-date data before editing
		self.DataStore:UpdateAsync(key, function(data)
			-- Ensure data and MetaData is atleast an empty table
			data = data or {}
			data.MetaData = data.MetaData or {}

			local _sessionId = data.MetaData.SessionJobId
			local _sessionExpiry = data.MetaData.SessionExpiry
			-- Make sure this isn't locked by another server
			if _sessionId ~= nil and _sessionId ~= game.JobId and (_sessionExpiry or 0) >= os.time() then
				warn(`Session for profile {self.Key} is currently locked.`)
				return
			end

			-- If there is no data, apply and return the template
			if not data or not data.Data then
				local template = _deepCloneTable(Profile.PROFILE_TEMPLATE)
				template.Data = self.Template or {}

				loadedData = template
				loadedData.MetaData.SessionJobId = JobId -- lock profile
				loadedData.MetaData.SessionExpiry = os.time() + self.AutoSaveInterval -- set expiry
				print(loadedData)

				return loadedData
			end

			data.MetaData.SessionJobId = JobId -- lock profile
			data.MetaData.SessionExpiry = os.time() + self.AutoSaveInterval -- set expiry
			loadedData = data
			return data
		end)
	end)
	if success and loadedData then
		-- Add to loaded profiles and create a profile object
		Profile.LoadedProfiles[key] = loadedData
		return Profile.new(key, loadedData, self)
	elseif not success then
		warn(`Failed to start session for key {key}: {response}`)
	end
	return nil
end

-- Reads a profile without starting a session
-- key: The key of the profile to get
function NStore:GetAsync(key: string)
	local loadedData
	local success, response = pcall(function()
		-- UpdateAsync to retrieve up-to-date data before editing
		self.DataStore:UpdateAsync(key, function(data)
			-- If there is no data, return nothing
			if not data or not data.Data then
				return nil
			end

			loadedData = data
			return loadedData
		end)
	end)
	
	if success then
		local profile = Profile.new(key, loadedData, self, true)
		return loadedData
	end
	warn(`Failed to get profile {key}: {response}`)
end

-- Deletes a profile with the given key
-- key: The key of the profile to delete
-- steal: Whether to ignore a session lock on the profile
function NStore:RemoveAsync(key: string, steal: boolean?)
	local profile = self:GetAsync(key)
	if profile then
		if profile.MetaData then
			local _sessionId = profile.MetaData.SessionJobId
			local _sessionExpiry = profile.MetaData.SessionExpiry
			-- Make sure this isn't locked by another server
			if _sessionId ~= nil and _sessionId ~= game.JobId and (_sessionExpiry or 0) >= os.time() then
				warn(`Session for profile {key} is currently locked.`)
				return
			end
		end
		local success, result = pcall(function()
			return self.DataStore:RemoveAsync(key)
		end)
		if not success then
			warn(`Failed to remove profile {key}: {result}`)
		end
	end
end

return NStore
