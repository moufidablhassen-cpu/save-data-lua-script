-- Framework: Advanced Player Data Manager

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

--------------------------------------------------------------------------------
-- LUAU TYPES & SCHEMAS
--------------------------------------------------------------------------------

export type PlayerData = {
	Clicks: number,
	Rebirths: number,
	ClicksToAdd: number,
	ClicksNeeded: number,
	ClickProgress: number,
	ClickProgress1: number,
	OwnedTitles: { string },
	EquippedTitle: string,
	Playtime: number,
	LastLogin: number,
}

--------------------------------------------------------------------------------
-- CONFIGURATION & CONSTANTS
--------------------------------------------------------------------------------

local DATA_STORE_NAME = "PlayerData_v3"
local AUTOSAVE_INTERVAL = 300
local MAX_RETRIES = 3
local RETRY_DELAY = 1.5

local DEFAULT_PROFILE: PlayerData = {
	Clicks = 0,
	Rebirths = 0,
	ClicksToAdd = 1,
	ClicksNeeded = 500,
	ClickProgress = 1,
	ClickProgress1 = 1,
	OwnedTitles = {},
	EquippedTitle = "No Title",
	Playtime = 0,
	LastLogin = 0,
}

local PlayerDataStore = DataStoreService:GetDataStore(DATA_STORE_NAME)

-- In-Memory Session Storage
local sessionCache: { [number]: PlayerData } = {}
local sessionJoinTimes: { [number]: number } = {}
local activeSaves: { [number]: boolean } = {}

--------------------------------------------------------------------------------
-- UTILITY & DATA MARSHALING
--------------------------------------------------------------------------------

--- Deep clones a profile structure efficiently
local function cloneProfile(profile: PlayerData): PlayerData
	return HttpService:JSONDecode(HttpService:JSONEncode(profile)) :: PlayerData
end

--- Reconciles retrieved data with default parameters (Schema Validation)
local function reconcile(target: { [string]: any }, template: { [string]: any })
	for key, defaultValue in pairs(template) do
		if target[key] == nil or type(target[key]) ~= type(defaultValue) then
			target[key] = defaultValue
		elseif type(defaultValue) == "table" then
			reconcile(target[key], defaultValue)
		end
	end
end

--- Dynamic exponential backoff API caller
local function callDataStoreApi<T>(apiFunc: () -> T): (boolean, T?)
	local result: T? = nil
	local err: any = nil

	for attempt = 1, MAX_RETRIES do
		local success, response = pcall(apiFunc)
		if success then
			return true, response
		end
		err = response
		task.wait(attempt * RETRY_DELAY)
	end

	warn(`[DataStore] Request failed after {MAX_RETRIES} attempts: {tostring(err)}`)
	return false, nil
end

--------------------------------------------------------------------------------
-- ATTRIBUTE SYNC & LEADERSTATS
--------------------------------------------------------------------------------

--- Binds data state directly to Roblox Attributes (Fast & Modern Replication)
local function syncStateToAttributes(player: Player, data: PlayerData)
	for key, value in pairs(data) do
		player:SetAttribute(key, value)
	end
end

--- Syncs local attributes back to the session cache prior to saving
local function syncAttributesToCache(player: Player): PlayerData?
	local data = sessionCache[player.UserId]
	if not data then return nil end

	-- Update playtime dynamically
	local joinTime = sessionJoinTimes[player.UserId] or os.time()
	local sessionDuration = os.time() - joinTime

	data.Clicks = (player:GetAttribute("Clicks") :: number?) or data.Clicks
	data.Rebirths = (player:GetAttribute("Rebirths") :: number?) or data.Rebirths
	data.ClicksToAdd = (player:GetAttribute("ClicksToAdd") :: number?) or data.ClicksToAdd
	data.ClicksNeeded = (player:GetAttribute("ClicksNeeded") :: number?) or data.ClicksNeeded
	data.ClickProgress = (player:GetAttribute("ClickProgress") :: number?) or data.ClickProgress
	data.ClickProgress1 = (player:GetAttribute("ClickProgress1") :: number?) or data.ClickProgress1
	data.EquippedTitle = (player:GetAttribute("EquippedTitle") :: string?) or data.EquippedTitle
	data.OwnedTitles = (player:GetAttribute("OwnedTitles") :: { string }?) or data.OwnedTitles
	data.Playtime = (player:GetAttribute("Playtime") :: number? or 0) + sessionDuration
	data.LastLogin = os.time()

	-- Keep session join time fresh for subsequent auto-saves
	sessionJoinTimes[player.UserId] = os.time()

	return data
end

--- Minimal leaderstats hookup for standard core UI display
local function setupLeaderstats(player: Player, data: PlayerData)
	local leaderstats = player:FindFirstChild("leaderstats") or Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local clicks = leaderstats:FindFirstChild("Clicks") or Instance.new("IntValue")
	clicks.Name = "Clicks"
	clicks.Value = data.Clicks
	clicks.Parent = leaderstats

	local rebirths = leaderstats:FindFirstChild("Rebirths") or Instance.new("IntValue")
	rebirths.Name = "Rebirths"
	rebirths.Value = data.Rebirths
	rebirths.Parent = leaderstats

	-- Bind Attribute updates to Leaderstats automatically
	player:GetAttributeChangedSignal("Clicks"):Connect(function()
		clicks.Value = (player:GetAttribute("Clicks") :: number) or 0
	end)

	player:GetAttributeChangedSignal("Rebirths"):Connect(function()
		rebirths.Value = (player:GetAttribute("Rebirths") :: number) or 0
	end)
end

--------------------------------------------------------------------------------
-- CORE CONTROLLER
--------------------------------------------------------------------------------

local function loadPlayer(player: Player)
	local userIdKey = `Player_{player.UserId}`
	sessionJoinTimes[player.UserId] = os.time()

	local success, rawData = callDataStoreApi(function()
		return PlayerDataStore:GetAsync(userIdKey)
	end)

	if not player:IsDescendantOf(Players) then return end

	local profile = cloneProfile(DEFAULT_PROFILE)
	if success and type(rawData) == "table" then
		reconcile(rawData, profile)
		profile = rawData :: PlayerData
	end

	sessionCache[player.UserId] = profile

	-- Bind attributes and HUD
	syncStateToAttributes(player, profile)
	setupLeaderstats(player, profile)
end

local function savePlayer(player: Player): boolean
	local userId = player.UserId
	if activeSaves[userId] or not sessionCache[userId] then return false end

	activeSaves[userId] = true
	local currentData = syncAttributesToCache(player)

	if not currentData then
		activeSaves[userId] = nil
		return false
	end

	local userIdKey = `Player_{userId}`
	local success = callDataStoreApi(function()
		return PlayerDataStore:UpdateAsync(userIdKey, function(oldData)
			return currentData
		end)
	end)

	activeSaves[userId] = nil
	return success
end

--------------------------------------------------------------------------------
-- LIFECYCLE HOOKS
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(loadPlayer)

Players.PlayerRemoving:Connect(function(player)
	savePlayer(player)
	sessionCache[player.UserId] = nil
	sessionJoinTimes[player.UserId] = nil
end)

-- Handle existing players in case of late load
for _, player in Players:GetPlayers() do
	task.spawn(loadPlayer, player)
end

-- Auto-Save Thread
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in Players:GetPlayers() do
			task.spawn(savePlayer, player)
		end
	end
end)

-- Server Shutdown Guard
game:BindToClose(function()
	if RunService:IsStudio() then return end

	local playersToSave = Players:GetPlayers()
	local savesRemaining = #playersToSave

	for _, player in playersToSave do
		task.spawn(function()
			savePlayer(player)
			savesRemaining -= 1
		end)
	end

	local timeout = os.clock() + 15
	while savesRemaining > 0 and os.clock() < timeout do
		task.wait(0.1)
	end
end)
