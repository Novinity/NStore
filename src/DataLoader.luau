-- Example usage

local Players = game:GetService("Players")

local NStore = require(script.Parent.NStore)

-- Data template
local TEMPLATE = {
	Cash = 0,
	Items = {},
	Stats = {
		Deaths = 0,
	}
}

-- Create a new NStore instance
local PlayerStore = NStore.new("PlayerStore", TEMPLATE) :: NStore.NStore<typeof(TEMPLATE)>
-- Dictionary of profiles
local Profiles: {[Player]: NStore.Profile<typeof(TEMPLATE)>} = {}

-- Called when player has a character added
local function CharacterAdded(character: Model)
	-- Get the player
	local player = Players:GetPlayerFromCharacter(character)
	if player == nil then return end

	-- Get their humanoid
	local humanoid: Humanoid = character:WaitForChild("Humanoid")

	-- When they die, increment their death counter
	humanoid.Died:Connect(function()
		local profile = Profiles[player]
		if not profile then return end

		profile.Data.Stats.Deaths += 1
		print(`{player.DisplayName} has died {profile.Data.Stats.Deaths} times!`)
	end)
end

-- Called when a player joins the game
local function PlayerAdded(player: Player)
	-- Connect CharacterAdded event
	player.CharacterAdded:Connect(CharacterAdded)
	
	-- Initialize the profile for the player
	local profile = PlayerStore:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players -- Cancel profile initialization if the player isn't in the game anymore
		end,
	}) :: NStore.Profile<typeof(TEMPLATE)>

	if profile ~= nil then
		-- Add their user ID and ensure all template values are present in data
		profile:AddUserId(player.UserId)
		profile:Reconcile()

		-- When the session ends, remove their profile and kick the player
		profile.OnSessionEnd:Connect(function()
			Profiles[player] = nil
			player:Kick(`Profile session end - Please rejoin`)
		end)
		
		-- Connect a changed event to the Cash value
		profile:OnChange("Cash", function(old, new)
			print(`{player.DisplayName} has {new} cash! Was {old} cash.`)
		end)
		
		-- Connect a changed event to the Deaths value, which is in the Stats table in the profile
		profile:OnChange("Stats.Deaths", function(old, new)
			print(`{player.DisplayName} has died {new} times! Was {old} times.`)
		end)

		if player.Parent == Players then
			-- Store the profile in the dictionary
			Profiles[player] = profile
			print(`Profile loaded for {player.DisplayName}!`)

			-- test data change
			profile.Data.Cash += 100
		else
			-- If they left already, end the session
			profile:EndSession()
		end
	else
		player:Kick(`Profile load fail - Please rejoin`)
	end
end

-- Called when a player leaves the game
local function PlayerRemoving(player: Player)
	-- Get their profile and deinitialize it
	local profile = Profiles[player]
	if profile ~= nil then
		print(`Ending session for {player.Name} ({player.UserId})`)
		profile:EndSession()
		Profiles[player] = nil
	end
end

-- Make sure no players that joined before the connections were created are left out
for _, player in Players:GetPlayers() do
	task.spawn(PlayerAdded, player)
end

-- Connect events
Players.PlayerAdded:Connect(PlayerAdded)
Players.PlayerRemoving:Connect(PlayerRemoving)

-- When the server closes, call PlayerRemoving for all players
game:BindToClose(function()
	for _, player in Players:GetPlayers() do
		task.spawn(PlayerRemoving, player)
	end
	
	-- Wait until all profiles have been deinitialized before exiting the function
	local finished = false
	repeat
		local count = 0
		for _ in pairs(Profiles) do
			count += 1
		end
		if count == 0 then
			finished = true
		else
			task.wait()
		end
	until finished
end)