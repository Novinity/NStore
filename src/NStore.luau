--[[
	NStore -- A basic Roblox datastore wrapper heavily inspired by ProfileStore
	Author: Novinity

	Features:
	- Data saving/loading
	- Code autocompletion
	- Data autosaving
	- Session locking
	- Data reconciliation
	- Per-key changed events
]]

local DataStoreService = game:GetService("DataStoreService")

local Profile = require(script.Profile)
local Signal = require(script.Signal)
local Utils = require(script.Utils)

-- Profile type for type checking
export type Profile<T> = Profile.Profile<T>

local NStore = {}
NStore.__index = NStore

-- NStore instance type for type checking
export type NStore<TData> = {
	DataStore: DataStore,
	Template: TData,
	AutoSaveInterval: number,
	AutoReplicate: {},
	
	IsClosing: boolean,

	StartSession: (self: NStore<TData>, key: string, arguments: {Cancel: (() -> boolean)?}) -> Profile<TData>?,
	GetAsync: (self: NStore<TData>, key: string) -> Profile<TData>?,
	RemoveAsync: (self: NStore<TData>, key: string) -> (),
}

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
	
	self.IsClosing = false
	
	-- Save all profiles when server is closing
	game:BindToClose(function()
		self.IsClosing = true

		local function save(profile)
			-- Save profile only if it isn't already released
			if not profile.Released then
				profile:Save(true)
			end
		end

		for _, profile in Profile.LoadedProfiles do
			task.spawn(save, profile)
		end

		-- Wait for all profiles to be saved before letting the server close
		local loaded = 0
		repeat
			task.wait()
			loaded = 0
			for _, profile in Profile.LoadedProfiles do
				loaded += 1
			end
		until loaded == 0
		print("All profiles saved.")
	end)

	print(`New NStore instance initialized: {name}`)

	return self
end

-- Create a new profile from the given key
-- key: The Datastore key to retrieve data from
-- arguments: Variables and functions used to decide on certain events
function NStore:StartSession(key: string, arguments: {
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
	local attempt = 0
	
	local suc = false -- successful
	local res -- response
	repeat
		attempt += 1
	
		local success, response = pcall(function()
			-- UpdateAsync to retrieve up-to-date data before editing
			self.DataStore:UpdateAsync(key, function(data)
				local creating = data == nil -- check if profile is being created for the first time
				-- Ensure data and MetaData is atleast an empty table
				data = data or {}
				data.MetaData = data.MetaData or {}

				local _sessionId = data.MetaData.SessionJobId
				local _sessionExpiry = data.MetaData.SessionExpiry
				-- Make sure this isn't locked by another server
				if _sessionId ~= nil and _sessionId ~= game.JobId and (_sessionExpiry or 0) >= os.time() and not arguments.Steal then
					warn(`Session for profile {key} is currently locked.`)
					return
				end
				
				-- If there is no data, apply and return the template
				if not data or not data.Data then
					local template = Utils.deepCloneTable(Profile.PROFILE_TEMPLATE)
					template.Data = Utils.deepCloneTable(self.Template) or {}

					loadedData = template
					loadedData.MetaData.SessionJobId = JobId -- lock profile
					loadedData.MetaData.SessionExpiry = os.time() + self.AutoSaveInterval -- set expiry
					loadedData.MetaData.LastUpdate = DateTime.now().UnixTimestampMillis
					loadedData.MetaData.ProfileCreateTime = loadedData.MetaData.LastUpdate

					return loadedData
				end

				data.MetaData.SessionJobId = JobId -- lock profile
				data.MetaData.SessionExpiry = os.time() + self.AutoSaveInterval -- set expiry
				data.MetaData.LastUpdate = DateTime.now().UnixTimestampMillis
				
				loadedData = data
				return data
			end)
		end)
		
		res = response
		suc = success
		
		if not success and not response then
			task.wait(2 ^ attempt)
		end
	until (suc and loadedData) or attempt >= 5 -- retry until success or max attempts reached
	if suc and loadedData then
		-- Create a profile object
		return Profile.new(key, loadedData, self)
	elseif not suc then
		warn(`Failed to start session for key {key}: {res}`)
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
	
	if success and loadedData then
		local profile = Profile.new(key, loadedData, self, true)
		return profile
	elseif not success then
		warn(`Failed to get profile {key}: {response}`)
	end
	return nil
end

-- Check if a profile is locked
-- key: The key of the profile to check
function NStore:IsLocked(key: string)
	local loadedData
	local success, response = pcall(function()
		-- UpdateAsync to retrieve up-to-date data before editing
		self.DataStore:UpdateAsync(key, function(data)
			-- If there is no data, return nothing
			if not data or not data.Data or not data.MetaData then
				return nil
			end

			loadedData = data
			return loadedData
		end)
	end)
	
	if success and loadedData then
		local _sessionId = loadedData.MetaData.SessionJobId
		local _sessionExpiry = loadedData.MetaData.SessionExpiry
		return _sessionId ~= nil and _sessionId ~= game.JobId and (_sessionExpiry or 0) >= os.time()
	end
	return false
end

-- Deletes a profile with the given key
-- key: The key of the profile to delete
-- steal: Whether to ignore a session lock on the profile
function NStore:RemoveAsync(key: string, steal: boolean?)
	local isLocked = self:IsLocked(key)
	if not isLocked then
		local success, result = pcall(function()
			return self.DataStore:RemoveAsync(key)
		end)
		if not success then
			warn(`Failed to remove profile {key}: {result}`)
		end
	else
		warn(`Session for profile {key} is currently locked.`)
		return
	end
end

return NStore
