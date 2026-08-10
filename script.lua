--!strict
-- Services required for player management and data persistenceand server state checks
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

-- Configuration Constants
local DATA_STORE_KEY = "PlayerData_v2" -- Change this string when resetting or migrating data schemas
local AUTOSAVE_INTERVAL = 300           -- Save frequency for online players 
local MAX_RETRIES = 3                   -- Maximum retry attempts for failed DataStore API calls
local RETRY_DELAY = 1.5                 -- Base delay multiplier between retry attempts
local SHUTDOWN_TIMEOUT = 20             -- Maximum duration 

-- Initialize the player data store
local PlayerDataStore = DataStoreService:GetDataStore(DATA_STORE_KEY)

-- Default profile template used for new players or fallback when fields are missing
local DEFAULT_PROFILE = {
	Clicks = 0,
	Rebirths = 0,
	ClicksToAdd = 1,
	ClicksNeeded = 500,
	ClickProgress = 1,
	ClickProgress1 = 1,
	OwnedTitles = {},
	EquippedTitle = "No Title",
	FolderData = {},
	Playtime = 0,
	LastLogin = 0,
}

-- Session Tracking Tables
local sessionRegistry = {} -- Stores loaded profiles in memory indexed by UserId string
local saveQueue = {}       -- Prevents concurrent save operations for the same player
local joinTimestamps = {}  -- Tracks server join times to accurately calculate session playtime

--------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
--------------------------------------------------------------------------------

--- Recursively copies a table and all its nested sub-tables to prevent pass-by-reference issues
local function deepCopyTable(sourceTable: { [any]: any }): { [any]: any }
	local copy = {}
	for key, value in pairs(sourceTable) do
		if type(value) == "table" then
			copy[key] = deepCopyTable(value)
		else
			copy[key] = value
		end
	end
	return copy
end

--- Validates data against an expected default type to prevent corrupted or injected data types
local function sanitizeValue(value: any, defaultValue: any): any
	if value == nil then
		return defaultValue
	end
	if type(value) ~= type(defaultValue) then
		warn("[DataStore Warning] Type mismatch detected during load. Expected: " .. type(defaultValue) .. ", Got: " .. type(value))
		return defaultValue
	end
	return value
end

--- Fills missing keys from retrieved data using the DEFAULT_PROFILE and validates data types
local function mergeWithDefaults(retrievedData: any): { [string]: any }
	local profile = deepCopyTable(DEFAULT_PROFILE)
	if type(retrievedData) ~= "table" then
		return profile
	end

	for key, defaultValue in pairs(DEFAULT_PROFILE) do
		profile[key] = sanitizeValue(retrievedData[key], defaultValue)
	end
	return profile
end

--- Wraps dynamic DataStore API requests with an exponential backoff retry loop
local function executeDataStoreRequest(requestFunction: () -> any): (boolean, any)
	local lastError = nil
	for attempt = 1, MAX_RETRIES do
		local success, result = pcall(requestFunction)
		if success then
			return true, result
		end
		
		lastError = result
		if attempt < MAX_RETRIES then
			task.wait(attempt * RETRY_DELAY)
		end
	end
	return false, lastError
end

--------------------------------------------------------------------------------
-- INSTANCE MANIPULATION & SETUP
--------------------------------------------------------------------------------

--- Ensures the player has a valid "leaderstats" folder required for Roblox leaderboards
local function createLeaderstatsFolder(player: Player): Folder
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats or not leaderstats:IsA("Folder") then
		if leaderstats then leaderstats:Destroy() end
		leaderstats = Instance.new("Folder")
		leaderstats.Name = "leaderstats"
		leaderstats.Parent = player
	end
	return leaderstats :: Folder
end

--- Creates or reuses a ValueBase object 
local function createPrimitiveValue(valueType: string, valueName: string, parentInstance: Instance, initialValue: any): ValueBase
	local existingValue = parentInstance:FindFirstChild(valueName)
	if existingValue and not existingValue:IsA(valueType) then
		existingValue:Destroy()
		existingValue = nil
	end

	if not existingValue then
		local newObj = Instance.new(valueType)
		newObj.Name = valueName
		newObj.Parent = parentInstance
		existingValue = newObj
	end

	(existingValue :: any).Value = initialValue
	return existingValue :: ValueBase
end

--- Builds in-game instances, attributes, and dynamic folder trees based on loaded profile data
local function initializePlayerInstances(player: Player, profileData: { [string]: any })
	-- 1. Setup leaderstats values 
	local leaderstats = createLeaderstatsFolder(player)
	createPrimitiveValue("IntValue", "Clicks", leaderstats, profileData.Clicks)
	createPrimitiveValue("IntValue", "Rebirths", leaderstats, profileData.Rebirths)

	-- 2. Setup player-level primitive values
	createPrimitiveValue("IntValue", "ClicksToAdd", player, profileData.ClicksToAdd)
	createPrimitiveValue("IntValue", "ClicksNeeded", player, profileData.ClicksNeeded)
	createPrimitiveValue("IntValue", "ClickProgress", player, profileData.ClickProgress)
	createPrimitiveValue("IntValue", "ClickProgress1", player, profileData.ClickProgress1)
	createPrimitiveValue("StringValue", "Title", player, profileData.EquippedTitle)

	-- 3. Set custom attributes
	player:SetAttribute("OwnedTitles", profileData.OwnedTitles)
	player:SetAttribute("Playtime", profileData.Playtime)

	-- 4. Reconstruct dynamic template folders attached under this script
	local folderData = profileData.FolderData or {}
	for _, templateFolder in ipairs(script:GetChildren()) do
		if templateFolder:IsA("Folder") then
			-- Re-clone clean template into player
			local existingPlayerFolder = player:FindFirstChild(templateFolder.Name)
			if existingPlayerFolder then existingPlayerFolder:Destroy() end

			local clonedFolder = templateFolder:Clone()
			clonedFolder.Parent = player

			-- Populate values inside cloned folder using composite key mapping 
			for _, statObject in ipairs(clonedFolder:GetChildren()) do
				if statObject:IsA("ValueBase") then
					local lookupKey = statObject.Name .. "_" .. templateFolder.Name
					if folderData[lookupKey] ~= nil then
						(statObject :: any).Value = folderData[lookupKey]
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- SAVE & LOAD CORE LOGIC
--------------------------------------------------------------------------------

--- Gathers current in-game values from the player and builds a serializable dictionary
local function buildSavePayload(player: Player): { [string]: any }?
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then return nil end

	-- Find primary value objects
	local clicks = leaderstats:FindFirstChild("Clicks") :: IntValue?
	local rebirths = leaderstats:FindFirstChild("Rebirths") :: IntValue?
	local clicksToAdd = player:FindFirstChild("ClicksToAdd") :: IntValue?
	local clicksNeeded = player:FindFirstChild("ClicksNeeded") :: IntValue?
	local clickProgress = player:FindFirstChild("ClickProgress") :: IntValue?
	local clickProgress1 = player:FindFirstChild("ClickProgress1") :: IntValue?
	local title = player:FindFirstChild("Title") :: StringValue?

	-- Ensure essential instances exist before saving to avoid overwriting with incomplete data
	if not (clicks and rebirths and clicksToAdd and clicksNeeded and clickProgress and clickProgress1 and title) then
		warn("[DataStore] Failed to construct payload for " .. player.Name .. " - missing required stats.")
		return nil
	end

	-- Record dynamic folder stats
	local dynamicFolderData = {}
	for _, templateFolder in ipairs(script:GetChildren()) do
		if templateFolder:IsA("Folder") then
			local activeFolder = player:FindFirstChild(templateFolder.Name)
			if activeFolder then
				for _, statObject in ipairs(activeFolder:GetChildren()) do
					if statObject:IsA("ValueBase") then
						local compositeKey = statObject.Name .. "_" .. templateFolder.Name
						dynamicFolderData[compositeKey] = (statObject :: any).Value
					end
				end
			end
		end
	end

	-- Calculate total playtime based on elapsed session duration
	local previousPlaytime = player:GetAttribute("Playtime") or 0
	local currentSessionTime = 0
	local joinTime = joinTimestamps[player.UserId]
	if joinTime then
		currentSessionTime = math.floor(os.time() - joinTime)
	end

	return {
		Clicks = clicks.Value,
		Rebirths = rebirths.Value,
		ClicksToAdd = clicksToAdd.Value,
		ClicksNeeded = clicksNeeded.Value,
		ClickProgress = clickProgress.Value,
		ClickProgress1 = clickProgress1.Value,
		OwnedTitles = player:GetAttribute("OwnedTitles") or {},
		EquippedTitle = title.Value,
		FolderData = dynamicFolderData,
		Playtime = previousPlaytime + currentSessionTime,
		LastLogin = os.time(),
	}
end

--- Handles the player join flow: fetches data from DataStore and creates instances
local function onPlayerAdded(player: Player)
	local userIdString = tostring(player.UserId)
	joinTimestamps[player.UserId] = os.time()

	-- Retrieve saved data from DataStore
	local success, rawResponse = executeDataStoreRequest(function()
		return PlayerDataStore:GetAsync(userIdString)
	end)

	-- Edge Case Safeguard: Check if the player left while their data was loading
	if not player:IsDescendantOf(Players) then
		return
	end

	-- Merge response with defaults and cache in session memory
	local profile = mergeWithDefaults(rawResponse)
	sessionRegistry[userIdString] = profile

	if not success then
		warn("[DataStore] Could not retrieve data for " .. player.Name .. ". Fallback defaults initialized.")
	end

	-- Build in-game value objects and folders
	initializePlayerInstances(player, profile)
end

--- Saves active player state to DataStore using update safety checks
local function savePlayerData(player: Player): boolean
	local userIdString = tostring(player.UserId)

	-- Guard 1 Don't save if data was never loaded into the session registry
	if not sessionRegistry[userIdString] then
		return false
	end

	-- Guard 2 Don't save if an existing save request is already in-flight
	if saveQueue[userIdString] then
		return false
	end

	-- Guard 3 Construct payload and verify validity
	local payload = buildSavePayload(player)
	if not payload then
		return false
	end

	saveQueue[userIdString] = true

	-- Write data to DataStore via UpdateAsync to prevent race conditions
	local success, err = executeDataStoreRequest(function()
		PlayerDataStore:UpdateAsync(userIdString, function(oldData)
			return payload
		end)
	end)

	saveQueue[userIdString] = nil

	if success then
		sessionRegistry[userIdString] = payload
		return true
	else
		warn("[DataStore Error] Critical save failure for " .. player.Name .. ": " .. tostring(err))
		return false
	end
end

--- Clean up session memory and trigger save on player leave
local function onPlayerRemoving(player: Player)
	local userIdString = tostring(player.UserId)
	savePlayerData(player)
	
	-- Clean memory caches
	sessionRegistry[userIdString] = nil
	saveQueue[userIdString] = nil
	joinTimestamps[player.UserId] = nil
end

--- Periodic background auto-save loop for online players
local function runAutoSaveLoop()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(function()
				savePlayerData(player)
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- INITIALIZATION & EVENT LISTENERS
--------------------------------------------------------------------------------

-- Start autosave loop in a background thread
task.spawn(runAutoSaveLoop)

-- Player connections
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players who connected before the script fully loaded
for _, activePlayer in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		onPlayerAdded(activePlayer)
	end)
end

--- Game Shutdown Handler (Handles server closure and Studio stops)
game:BindToClose(function()
	-- Skip long shutdown waits when testing in Studio
	if RunService:IsStudio() then
		task.wait(1)
		return
	end

	local onlinePlayers = Players:GetPlayers()
	local pendingSaves = #onlinePlayers

	if pendingSaves == 0 then
		return
	end

	-- Trigger thread-safe save calls for all remaining players simultaneously
	for _, playerToSave in ipairs(onlinePlayers) do
		task.spawn(function()
			savePlayerData(playerToSave)
			pendingSaves -= 1
		end)
	end

	-- Keep server alive until all saves finish or timeout hits
	local startTime = os.clock()
	while pendingSaves > 0 and (os.clock() - startTime) < SHUTDOWN_TIMEOUT do
		task.wait(0.2)
	end
end)
