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
	
	StartSession: (self: NStore<TData>, key: string, functions: {Cancel: (() -> boolean)?}) -> Profile<TData>?,
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
-- functions: Condition functions used to decide on certain events
function NStore:StartSession(key: string, functions: {
	Cancel: () -> ()? -- If true is returned by this function, cancel session starting
})
	-- If profile is already loaded, cancel
	if Profile.LoadedProfiles[key] then
		warn("Profile already loaded for key: " .. key)
		return
	end
	
	-- Check passed cancel condition if one is passed
	local cancelFunc = functions.Cancel
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
			
			-- Check if profile is already locked
			if data.MetaData.SessionJobId ~= nil and data.MetaData.SessionJobId ~= JobId then
				return nil
			end
			
			-- If there is no data, apply and return the template
			if not data or not data.Data then
				local template = _deepCloneTable(Profile.PROFILE_TEMPLATE)
				template.Data = template.Data or {}
				
				loadedData = template
				loadedData.MetaData.SessionJobId = JobId -- lock profile
				
				return loadedData
			end
			
			data.MetaData.SessionJobId = JobId -- lock profile
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

return NStore
