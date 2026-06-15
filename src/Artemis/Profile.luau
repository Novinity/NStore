local Signal = require(script.Parent.Signal)

local Profile = {}
Profile.__index = Profile

Profile.LoadedProfiles = {}

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

export type Profile<TData> = {
	Key: string,
	DataStore: any,
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

local function _runAutoSaveLoop(profile, interval: number)
	while profile ~= nil and not profile.SessionEnded do
		task.wait(interval)
		profile:Save()
	end
end

local function _tablesEqual(a, b)
	if a == b then
		return true
	end
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return false
	end

	for key, value in pairs(a) do
		if not _tablesEqual(value, b[key]) then
			return false
		end
	end

	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end

	return true
end

local function _runChangedCheck(profile, interval: number)
	local cache = _deepCloneTable(profile.Data)
	
	while profile ~= nil and not profile.SessionEnded do
		task.wait(interval)
		if not _tablesEqual(profile.Data, cache) then
			profile.Changed:Fire(profile.Data)
			cache = _deepCloneTable(profile.Data)
		end
	end
end

local function _reconcileTable(target, template)
	for key, templateValue in pairs(template) do
		if target[key] == nil then
			target[key] = templateValue
		elseif typeof(target[key]) == "table" and typeof(templateValue) == "table" then
			_reconcileTable(target[key], templateValue)
		end
	end
	return target
end

function Profile.new(key: string, data: {}, instance)
	data = data or {}
	data.MetaData = data.MetaData or {}
	
	local OnSessionEnd: Signal.Signal = Signal.new()
	local Changed: Signal.Signal = Signal.new()
	
	local self = setmetatable({
		Key = key,
		DataStore = instance,
		Data = data.Data or {},
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

	self.MetaData.SessionLoadCount += 1

	local success, result = pcall(function()
		return self.DataStore.DataStore:UpdateAsync(self.Key, function(data)
			local creating = data == nil
			
			data = data or {}
			data.MetaData = data.MetaData or {}
			
			if data.MetaData.SessionJobId ~= nil and data.MetaData.SessionJobId ~= game.JobId then
				warn("Session is currently locked.")
				return
			end

			data.MetaData.SessionJobId = game.JobId
			self.MetaData.LastUpdate = DateTime.now().UnixTimestampMillis
			self.MetaData.LastUpdate += 1
			if creating then
				self.MetaData.ProfileCreateTime = self.MetaData.LastUpdate
			end

			return data
		end)
	end)
	if not success or not result then
		warn("Failed to load profile")
		return nil
	end

	if key then
		Profile.LoadedProfiles[key] = self
		task.spawn(_runAutoSaveLoop, self, instance.AutoSaveInterval)
		task.spawn(_runChangedCheck, self, 1)
	end

	return self
end

function Profile:AddUserId(userId: number)
	local idx = table.find(self.UserIds, userId)
	if idx then return end
	print(`Adding user id {userId}`)
	table.insert(self.UserIds, userId)
end

function Profile:RemoveUserId(userId: number)
	local idx = table.find(self.UserIds, userId)
	if not idx then return end
	print(`Removing user id {userId}`)
	table.remove(self.UserIds, idx)
end

function Profile:Reconcile()
	print("Reconciling...")
	local reconciled = _reconcileTable(self.Data, self.DataStore.Template)
	self.Data = reconciled
end

function Profile:EndSession()
	if self.SessionEnded then
		return
	end
	print("Ending session")
	
	self.SessionEnded = true
	self.OnSessionEnd:Fire()
	self:Save(true)
	Profile.LoadedProfiles[self.Key] = nil
end

function Profile:Save(unlock: boolean?)
	local success, response = pcall(function()
		return self.DataStore.DataStore:UpdateAsync(self.Key, function(data)
			data = data or {}
			data.MetaData = data.MetaData or {}
			
			if data.MetaData.SessionJobId ~= nil and data.MetaData.SessionJobId ~= game.JobId then
				warn("Session is currently locked.")
				return
			end

			self.MetaData.LastUpdate = DateTime.now().UnixTimestampMillis

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
		warn(response)
		return false
	end
	return true
end

return Profile