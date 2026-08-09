--!strict
-- Services
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

-- Constants & Configurations
local DATA_STORE_KEY = "PlayerData_v1"
local PlayerDataStore = DataStoreService:GetDataStore(DATA_STORE_KEY)

-- Default data schema used for new players or fallback values
local DEFAULT_DATA = {
	Clicks = 0,
	Rebirths = 0,
	ClicksToAdd = 1,
	ClicksNeeded = 500,
	OwnedTitles = {},
	EquippedTitle = "No Title",
}

-- Memory session cache to track loaded states and prevent saving uninitialized data
local sessionData = {}

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------------------------------

-- Performs a deep copy of a table to avoid mutating the default template table
local function deepCopyTable(originalTable: { [any]: any }): { [any]: any }
	local copy = {}
	for key, value in pairs(originalTable) do
		if typeof(value) == "table" then
			copy[key] = deepCopyTable(value)
		else
			copy[key] = value
		end
	end
	return copy
end

--------------------------------------------------------------------------------
-- PLAYER DATA MANAGEMENT
--------------------------------------------------------------------------------

-- Triggered when a new player joins the server
local function onPlayerAdded(player: Player)
	local userId = tostring(player.UserId)

	----------------------------------------------------------------------------
	-- 1. INSTANTIATE IN-GAME DATA STRUCTURES
	----------------------------------------------------------------------------
	
	-- Leaderstats Folder (Visible on the player leaderboard)
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local clicks = Instance.new("IntValue")
	clicks.Name = "Clicks"
	clicks.Parent = leaderstats

	local rebirths = Instance.new("IntValue")
	rebirths.Name = "Rebirths"
	rebirths.Parent = leaderstats

	-- Hidden Internal Attributes & Values
	local multiplier = Instance.new("IntValue")
	multiplier.Name = "ClicksToAdd"
	multiplier.Parent = player

	local reqPoints = Instance.new("IntValue")
	reqPoints.Name = "ClicksNeeded"
	reqPoints.Parent = player

	local clickProgress = Instance.new("IntValue")
	clickProgress.Name = "ClickProgress"
	clickProgress.Value = 1
	clickProgress.Parent = player

	local clickProgress1 = Instance.new("IntValue")
	clickProgress1.Name = "ClickProgress1"
	clickProgress1.Value = 1
	clickProgress1.Parent = player

	local title = Instance.new("StringValue")
	title.Name = "Title"
	title.Parent = player

	----------------------------------------------------------------------------
	-- 2. FETCH SAVED DATA FROM DATASTORE
	----------------------------------------------------------------------------
	
	local success, savedData = pcall(function()
		return PlayerDataStore:GetAsync(userId)
	end)

	-- Initialize table with default fallback values
	local data = deepCopyTable(DEFAULT_DATA)

	if success then
		if savedData then
			-- Merge saved data into default template to ensure missing keys populate
			for key, value in pairs(savedData) do
				data[key] = value
			end
			print(string.format("✅ [DataStore] Data successfully loaded for %s (%s)", player.Name, userId))
		else
			print(string.format("🆕 [DataStore] No prior data found for %s (%s). Using defaults.", player.Name, userId))
		end
	else
		warn(string.format("⚠️ [DataStore] Failed to load data for %s: %s", player.Name, tostring(savedData)))
	end

	-- Cache loaded data into memory session
	sessionData[userId] = data

	----------------------------------------------------------------------------
	-- 3. ASSIGN VALUES TO INSTANCES
	----------------------------------------------------------------------------
	
	clicks.Value = data.Clicks
	rebirths.Value = data.Rebirths
	multiplier.Value = data.ClicksToAdd
	reqPoints.Value = data.ClicksNeeded
	title.Value = data.EquippedTitle
	player:SetAttribute("OwnedTitles", data.OwnedTitles)
end

-- Saves player data safely to the DataStore
local function savePlayerData(player: Player)
	local userId = tostring(player.UserId)
	
	-- Guard Clause: Ensure session data loaded properly before saving to avoid overwriting with empty defaults
	if not sessionData[userId] or not player:FindFirstChild("leaderstats") then
		warn(string.format("⚠️ [DataStore] Aborted saving for %s: Session data not initialized.", player.Name))
		return
	end

	-- Gather latest active values to construct the save dictionary
	local dataToSave = {
		Clicks = player.leaderstats.Clicks.Value,
		Rebirths = player.leaderstats.Rebirths.Value,
		ClicksToAdd = player.ClicksToAdd.Value,
		ClicksNeeded = player.ClicksNeeded.Value,
		OwnedTitles = player:GetAttribute("OwnedTitles") or {},
		EquippedTitle = player.Title.Value,
	}

	-- Update DataStore safely using UpdateAsync to avoid race conditions
	local success, err = pcall(function()
		PlayerDataStore:UpdateAsync(userId, function(oldData)
			return dataToSave
		end)
	end)

	if success then
		print(string.format("💾 [DataStore] Data successfully saved for %s (%s)", player.Name, userId))
	else
		warn(string.format("❌ [DataStore] Failed to save data for %s: %s", player.Name, tostring(err)))
	end

	-- Clear session cache after save processing completes
	sessionData[userId] = nil
end

--------------------------------------------------------------------------------
-- EVENT BINDINGS
--------------------------------------------------------------------------------

-- Connect Player Joining and Leaving Events
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(savePlayerData)

-- Handle Server Shutdowns (Prevents total data loss on game updates or crashes)
game:BindToClose(function()
	print("🛑 [DataStore] Server shutting down. Saving active player data...")
	
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(savePlayerData, player)
	end
	
	-- Allow background tasks time to complete before full server termination
	task.wait(3)
end)
