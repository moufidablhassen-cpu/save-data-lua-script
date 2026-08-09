--!strict
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local DATA_KEY = "PlayerData_v1"
local AUTOSAVE_INTERVAL = 300
local PlayerStore = DataStoreService:GetDataStore(DATA_KEY)

local DEFAULT_DATA = {
	Clicks = 0,
	Rebirths = 0,
	ClicksToAdd = 1,
	ClicksNeeded = 500,
	ClickProgress = 1,
	ClickProgress1 = 1,
	OwnedTitles = {},
	EquippedTitle = "No Title",
}

-- Session tracking
local sessionData = {}
local activeSaves = {}

-- Quick helper to clone the template
local function cloneTable(target)
	local copy = {}
	for k, v in pairs(target) do
		copy[k] = if type(v) == "table" then cloneTable(v) else v
	end
	return copy
end

-- Merges saved data with defaults so new stats don't break existing profiles
local function loadProfile(raw)
	local profile = cloneTable(DEFAULT_DATA)
	if type(raw) ~= "table" then
		return profile
	end

	for key, defaultVal in pairs(DEFAULT_DATA) do
		if raw[key] ~= nil and type(raw[key]) == type(defaultVal) then
			profile[key] = raw[key]
		end
	end
	return profile
end

-- Retries failed DataStore requests
local function safeRequest(action)
	for attempt = 1, 3 do
		local success, result = pcall(action)
		if success then
			return true, result
		end
		
		if attempt < 3 then
			task.wait(attempt * 1.5)
		else
			return false, result
		end
	end
	return false, nil
end

-- Sets up folders and values on the player
local function setupPlayer(player: Player)
	local leaderstats = player:FindFirstChild("leaderstats") or Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	local clicks = leaderstats:FindFirstChild("Clicks") or Instance.new("IntValue")
	clicks.Name = "Clicks"
	clicks.Parent = leaderstats

	local rebirths = leaderstats:FindFirstChild("Rebirths") or Instance.new("IntValue")
	rebirths.Name = "Rebirths"
	rebirths.Parent = leaderstats

	local clicksToAdd = player:FindFirstChild("ClicksToAdd") or Instance.new("IntValue")
	clicksToAdd.Name = "ClicksToAdd"
	clicksToAdd.Parent = player

	local clicksNeeded = player:FindFirstChild("ClicksNeeded") or Instance.new("IntValue")
	clicksNeeded.Name = "ClicksNeeded"
	clicksNeeded.Parent = player

	local clickProgress = player:FindFirstChild("ClickProgress") or Instance.new("IntValue")
	clickProgress.Name = "ClickProgress"
	clickProgress.Parent = player

	local clickProgress1 = player:FindFirstChild("ClickProgress1") or Instance.new("IntValue")
	clickProgress1.Name = "ClickProgress1"
	clickProgress1.Parent = player

	local title = player:FindFirstChild("Title") or Instance.new("StringValue")
	title.Name = "Title"
	title.Parent = player

	return {
		Clicks = clicks :: IntValue,
		Rebirths = rebirths :: IntValue,
		ClicksToAdd = clicksToAdd :: IntValue,
		ClicksNeeded = clicksNeeded :: IntValue,
		ClickProgress = clickProgress :: IntValue,
		ClickProgress1 = clickProgress1 :: IntValue,
		Title = title :: StringValue,
	}
end

-- Collects active values to prepare for saving
local function getSavePayload(player: Player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then return nil end

	local clicks = leaderstats:FindFirstChild("Clicks") :: IntValue?
	local rebirths = leaderstats:FindFirstChild("Rebirths") :: IntValue?
	local clicksToAdd = player:FindFirstChild("ClicksToAdd") :: IntValue?
	local clicksNeeded = player:FindFirstChild("ClicksNeeded") :: IntValue?
	local clickProgress = player:FindFirstChild("ClickProgress") :: IntValue?
	local clickProgress1 = player:FindFirstChild("ClickProgress1") :: IntValue?
	local title = player:FindFirstChild("Title") :: StringValue?

	if not (clicks and rebirths and clicksToAdd and clicksNeeded and clickProgress and clickProgress1 and title) then
		return nil
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
	}
end

local function onPlayerAdded(player: Player)
	local userId = tostring(player.UserId)
	local values = setupPlayer(player)

	local ok, rawData = safeRequest(function()
		return PlayerStore:GetAsync(userId)
	end)

	if not player:IsDescendantOf(Players) then return end

	local data = loadProfile(rawData)
	sessionData[userId] = data

	if not ok then
		warn("[DataStore] Failed to fetch data for " .. player.Name .. ", loaded defaults.")
	end

	-- Assign values to instances
	values.Clicks.Value = data.Clicks
	values.Rebirths.Value = data.Rebirths
	values.ClicksToAdd.Value = data.ClicksToAdd
	values.ClicksNeeded.Value = data.ClicksNeeded
	values.ClickProgress.Value = data.ClickProgress
	values.ClickProgress1.Value = data.ClickProgress1
	values.Title.Value = data.EquippedTitle
	player:SetAttribute("OwnedTitles", data.OwnedTitles)
end

local function savePlayerData(player: Player)
	local userId = tostring(player.UserId)

	if not sessionData[userId] or activeSaves[userId] then
		return false
	end

	local payload = getSavePayload(player)
	if not payload then return false end

	activeSaves[userId] = true

	local ok, err = safeRequest(function()
		PlayerStore:UpdateAsync(userId, function()
			return payload
		end)
	end)

	activeSaves[userId] = nil

	if ok then
		sessionData[userId] = payload
		return true
	else
		warn("[DataStore] Failed to save " .. player.Name .. ": " .. tostring(err))
		return false
	end
end

local function onPlayerRemoving(player: Player)
	local userId = tostring(player.UserId)
	savePlayerData(player)
	sessionData[userId] = nil
	activeSaves[userId] = nil
end

-- Background autosave thread
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(savePlayerData, player)
		end
	end
end)

-- Connections
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- Save data on server shutdown
game:BindToClose(function()
	local players = Players:GetPlayers()
	local pending = #players

	if pending == 0 then return end

	for _, player in ipairs(players) do
		task.spawn(function()
			savePlayerData(player)
			pending -= 1
		end)
	end

	local start = os.clock()
	while pending > 0 and (os.clock() - start) < 20 do
		task.wait(0.2)
	end
end)
