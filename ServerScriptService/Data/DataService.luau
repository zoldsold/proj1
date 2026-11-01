--!nonstrict
-- DataService v1.0.0.4
-- ServerScriptService/Data/DataService (ModuleScript)
--
-- One DataStore key per player ("p_<UserId>") holding { lock = {jobId, t}, data = profile }.
-- Gameplay code only touches the in-memory profile from Get(); this module is the
-- only thing that talks to DataStoreService.
--
--   DataService.Init()                   call once from a server Script
--   DataService.Get(player)              live profile table, or nil (not loaded / leaving)
--   DataService.WaitFor(player)          yields until loaded; nil if the player left or was kicked
--   DataService.Loaded                   event (player, profile)
--   DataService.AddMoney / SpendMoney    validated money changes
--   DataService.AddXP(player, amount)    player XP + level-ups (see ProfileSchema.xpForLevel)
--   Player attributes for the HUD (render-only copies): Money, PlayerLevel, PlayerXP, PlayerXPNeeded
--   DataService.SaveSoon(player)         call after any change; coalesces into one save a few seconds later
--   DataService.SaveNow(player)          force a save now
--   DataService.GrantOnce(player, purchaseId, grantFn)
--                                        Robux receipts: grants once, saves, returns true only when safe
--                                        to answer PurchaseGranted
--
-- Profile shape and migrations live in ProfileSchema.

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Schema = require(script.Parent.ProfileSchema)
local PetConfig = require(ReplicatedStorage:WaitForChild("PetConfig"))

local STORE_NAME = "PlayerData"
local KEY_PREFIX = "p_"
local AUTOSAVE = 60 -- seconds, staggered per player by UserId
local LOCK_STALE = 180 -- a lock this old belongs to a dead server
local LOCK_TRIES, LOCK_WAIT = 6, 4 -- wait for another server to release (~20s)
local ATTEMPTS = RunService:IsStudio() and 2 or 5
local SHUTDOWN_WAIT = 25
local SAVE_SOON = 8 -- above the ~6s per-key write throttle

local MSG = {
	datastore = "Your data couldn't load. Please rejoin in a moment.",
	locked = "Your data is still saving from your last session. Please rejoin in a moment.",
	newer = "Your data was saved by a newer game version. Please rejoin.",
	corrupt = "Your data couldn't be read, and nothing was overwritten. Please contact support.",
	lost = "Your data was opened on another server. Please rejoin.",
}

local JOB_ID = game.JobId ~= "" and game.JobId or "studio"
local store = DataStoreService:GetDataStore(STORE_NAME)
local loadedEvent = Instance.new("BindableEvent")

local sessions = {} -- [Player] = { key, profile, saving, released, noSave }
local releasing = {} -- [UserId] = true while a final save is in flight
local pending = 0 -- final saves in flight, awaited by BindToClose
local started = false

local DataService = { Loaded = loadedEvent.Event }

local function retry(fn)
	local backoff = 1
	for attempt = 1, ATTEMPTS do
		local ok, a, b = pcall(fn)
		if ok then
			return true, a, b
		end
		warn(`[DataService] attempt {attempt}/{ATTEMPTS} failed: {a}`)
		if attempt < ATTEMPTS then
			task.wait(backoff)
			backoff = math.min(backoff * 2, 16)
		end
	end
	return false
end

local function lockedByOther(rec, now)
	local l = rec.lock
	return l ~= nil and l.jobId ~= JOB_ID and now - l.t < LOCK_STALE
end

-- Claims the lock and loads (or creates) the profile. Returns profile, or nil + reason.
local function load(player)
	local key = KEY_PREFIX .. player.UserId
	for attempt = 1, LOCK_TRIES do
		local denied, failReason = false, nil
		local ok, rec = retry(function()
			return store:UpdateAsync(key, function(old)
				denied, failReason = false, nil
				local now = os.time()
				if old ~= nil and type(old) ~= "table" then
					failReason = "corrupt"
					return nil
				end
				if old and lockedByOther(old, now) then
					denied = true
					return nil
				end
				local data, err = Schema.prepare(old and old.data, PetConfig, now)
				if not data then
					failReason = err
					return nil
				end
				data.meta.sessions += 1
				return { lock = { jobId = JOB_ID, t = now }, data = data }
			end)
		end)
		if not ok then
			return nil, "datastore"
		end
		if rec then
			return rec.data, key
		end
		if failReason then
			return nil, failReason
		end
		if denied and attempt < LOCK_TRIES then
			task.wait(LOCK_WAIT)
		end
	end
	return nil, "locked"
end

local function kick(player, why)
	if player.Parent then
		player:Kick(MSG[why])
	end
end

-- Writes the profile (and refreshes the lock, or clears it when `release`).
local function flush(player, s, release)
	while s.saving do
		task.wait()
	end
	if s.noSave then
		return true
	end
	s.saving = true
	local lost = false
	local ok = retry(function()
		return store:UpdateAsync(s.key, function(old)
			lost = false
			local now = os.time()
			if old and lockedByOther(old, now) then
				lost = true -- another server owns this player now: never overwrite it
				return nil
			end
			Schema.clampMoney(s.profile) -- bad money must not make every save fail
			s.profile.meta.lastSave = now
			return { lock = (not release) and { jobId = JOB_ID, t = now } or nil, data = s.profile }
		end)
	end)
	s.saving = false
	if lost then
		s.noSave = true
		kick(player, "lost")
		return false
	end
	if not ok then
		warn(`[DataService] save failed for {player.UserId}; will retry next cycle`)
	end
	return ok
end

local function release(player)
	local s = sessions[player]
	if not s or s.released then
		return
	end
	s.released = true -- stops autosave and makes Get() return nil
	releasing[player.UserId] = true
	pending += 1
	flush(player, s, true)
	pending -= 1
	releasing[player.UserId] = nil
	sessions[player] = nil
end

-- Copies HUD values onto the player. Attribute names avoid "Level", which the pet/taming code reads.
local function publish(player, p)
	player:SetAttribute("Money", p.money)
	player:SetAttribute("PlayerXP", p.progress.xp)
	player:SetAttribute("PlayerLevel", p.progress.level)
	player:SetAttribute("PlayerXPNeeded", Schema.xpForLevel(p.progress.level))
end

local function onAdded(player)
	-- a fast rejoin to this same server must not read data before the old final save lands
	while releasing[player.UserId] do
		task.wait(0.1)
	end

	local profile, key = load(player)
	local noSave = false
	if not profile then
		if RunService:IsStudio() and key == "datastore" then
			warn("[DataService] Studio API access unavailable: using a throwaway profile, nothing will be saved.")
			profile, key, noSave = Schema.default(os.time()), "", true
		else
			kick(player, key)
			return
		end
	end

	local s = { key = key, profile = profile, saving = false, released = false, noSave = noSave }
	sessions[player] = s
	if not player.Parent then -- left while loading: hand the lock back
		release(player)
		return
	end

	publish(player, profile)

	task.spawn(function()
		task.wait(player.UserId % AUTOSAVE)
		while sessions[player] == s and not s.released do
			if DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync) >= 3 then
				flush(player, s, false)
			end
			task.wait(AUTOSAVE)
		end
	end)

	loadedEvent:Fire(player, profile)
end

function DataService.Init()
	if started then
		return
	end
	started = true

	Players.PlayerAdded:Connect(onAdded)
	Players.PlayerRemoving:Connect(release)
	for _, player in Players:GetPlayers() do
		task.spawn(onAdded, player)
	end

	game:BindToClose(function()
		for player in pairs(table.clone(sessions)) do
			task.spawn(release, player)
		end
		if RunService:IsStudio() then
			return
		end
		local t = os.clock()
		while pending > 0 and os.clock() - t < SHUTDOWN_WAIT do
			task.wait()
		end
	end)
end

function DataService.Get(player)
	local s = sessions[player]
	return s and not s.released and s.profile or nil
end

function DataService.WaitFor(player)
	while player.Parent and not DataService.Get(player) do
		task.wait(0.1)
	end
	return DataService.Get(player)
end

function DataService.SaveNow(player)
	local s = sessions[player]
	return s ~= nil and not s.released and flush(player, s, false)
end

function DataService.SaveSoon(player)
	local s = sessions[player]
	if not s or s.released or s.soon then
		return
	end
	s.soon = true
	task.delay(SAVE_SOON, function()
		s.soon = false
		if not s.released then
			flush(player, s, false)
		end
	end)
end

function DataService.AddMoney(player, amount)
	local p = DataService.Get(player)
	if not p or type(amount) ~= "number" or amount ~= amount or amount < 0 then
		return false
	end
	p.money = math.min(p.money + math.floor(amount), Schema.MAX_MONEY)
	publish(player, p)
	DataService.SaveSoon(player)
	return true
end

function DataService.SpendMoney(player, amount)
	local p = DataService.Get(player)
	if not p or type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount ~= math.floor(amount) then
		return false
	end
	if p.money < amount then
		return false
	end
	p.money -= amount
	publish(player, p)
	DataService.SaveSoon(player)
	return true
end

function DataService.AddXP(player, amount)
	local p = DataService.Get(player)
	if not p or type(amount) ~= "number" or amount ~= amount or amount < 1 then
		return false
	end
	Schema.addXP(p.progress, amount)
	publish(player, p)
	DataService.SaveSoon(player)
	return true
end

-- Roblox re-sends a receipt until it gets PurchaseGranted, so the grant must happen once and be
-- saved before answering. Returns false (retry later) if the data isn't loaded or the save failed.
function DataService.GrantOnce(player, purchaseId, grantFn)
	local p = DataService.Get(player)
	if not p or type(purchaseId) ~= "string" then
		return false
	end
	if not table.find(p.receipts, purchaseId) then
		grantFn(p)
		table.insert(p.receipts, purchaseId)
		if #p.receipts > Schema.MAX_RECEIPTS then
			table.remove(p.receipts, 1)
		end
	end
	return DataService.SaveNow(player)
end

return DataService
