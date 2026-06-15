local DataStoreService = game:GetService("DataStoreService")

local Profile = require(script.Profile)
local Signal = require(script.Signal)

export type Profile<T> = Profile.Profile<T>

local NStore = {}
NStore.__index = NStore

export type NStore<TData> = {
	DataStore: DataStore,
	Template: TData,
	AutoSaveInterval: number,
	
	StartSession: (self: NStore<TData>, key: string, functions: {Cancel: (() -> boolean)?}) -> Profile<TData>?,
}

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

function NStore.new(name: string, template: {}, autoSaveInterval: number?)
	local self = setmetatable({}, NStore)
	
	local DS = DataStoreService:GetDataStore(name)
	
	self.DataStore = DS
	self.Template = template
	self.AutoSaveInterval = autoSaveInterval or 300
	
	print(`New NStore instance initialized: {name}`)
	
	return self
end

function NStore:StartSession(key: string, functions: {})
	if Profile.LoadedProfiles[key] then
		warn("Profile already loaded for key: " .. key)
		return
	end
	
	print(`Starting session for {key}`)
	local cancelFunc = functions.Cancel
	if cancelFunc and cancelFunc() then
		warn("Cancelled session start by user-input function")
		return
	end
	
	local loadedData
	local JobId = game.JobId
	local success, response = pcall(function()
		self.DataStore:UpdateAsync(key, function(data)
			data = data or {}
			
			if data.SessionJobId ~= nil and data.SessionJobId ~= JobId then
				return nil
			end
			
			print("Current SessionJobId: " .. tostring(data.SessionJobId))
			
			if not data or not data.Data then
				local template = _deepCloneTable(Profile.PROFILE_TEMPLATE)
				template.Data = template.Data or {}
				
				loadedData = template
				loadedData.MetaData.SessionJobId = JobId
				
				return template
			end
			
			data.MetaData.SessionJobId = JobId
			loadedData = data
			return data
		end)
	end)
	if success and loadedData then
		print("Loading profile...")
		print(Profile)
		Profile.LoadedProfiles[key] = loadedData
		return Profile.new(key, loadedData, self)
	end
end

return NStore
