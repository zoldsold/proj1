-- v1.0.0.0.1
--[[
	PetTamingService (ModuleScript -> ServerScriptService)

	Server-authoritative taming session. One session per player:
	  Request -> validate, roll, lock player -> TameBegin (client plays ceremony)
	    success: client names the pet -> TameNickname -> player ends it -> TameFinish
	    failure: server cues damage at FailHitAt, finishes at FailEndAt, concusses
	Clients only render. Every exit goes through finish() (unlock, release, cleanup).

	Wire-up: PetManager calls Init(deps), Request, Nickname, Finish, CleanupPlayer.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService       = game:GetService("TextService")
local TamingModules = ReplicatedStorage:WaitForChild("PetTamingModules")

local Config    = require(TamingModules:WaitForChild("PetTaming_Config"))
local PetConfig = require(ReplicatedStorage:WaitForChild("PetConfig"))

local TC  = Config.Taming
local rng = Random.new()

local Service  = {}
local deps
local sessions = {} -- [Player] = session
local nextId   = 0

local function num(v, default)
	v = tonumber(v)
	if v == nil or v ~= v then return default end
	return v
end

local function reject(player, reason)
	if player.Parent then deps.remote:FireClient(player, "TameRejected", reason) end
end

local function isConcussed(player)
	local untilTime = player:GetAttribute("TameConcussedUntil")
	return typeof(untilTime) == "number" and workspace:GetServerTimeNow() < untilTime
end

local function chanceFor(wild, playerLevel)
	local wildLevel = num(wild:GetAttribute("Level"), 1)
	local released  = wild:GetAttribute("Released") == true
	if released then
		wildLevel = math.max(wildLevel, num(wild:GetAttribute("PreviousOwnerLevel"), 0))
	end
	local penalty = released and TC.PenaltyPerLevelReleased or TC.PenaltyPerLevel
	return math.clamp(TC.BaseChance - (wildLevel - playerLevel) * penalty, TC.MinChance, TC.MaxChance)
end

local function sanitize(text)
	if typeof(text) ~= "string" then return "" end
	text = text:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if not utf8.len(text) then return "" end
	local max = Config.Nickname.MaxLength
	if utf8.len(text) > max then
		text = text:sub(1, utf8.offset(text, max + 1) - 1)
	end
	return text
end

-------------------------------------------------------------------- lock

local function lock(player, s, wildPos)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local hum  = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not hum then return end

	s.Root, s.Hum = root, hum
	s.Walk, s.Jump, s.JumpHeight = hum.WalkSpeed, hum.JumpPower, hum.JumpHeight

	root.AssemblyLinearVelocity = Vector3.zero
	local flat = Vector3.new(wildPos.X, root.Position.Y, wildPos.Z)
	if (flat - root.Position).Magnitude > 0.1 then
		root.CFrame = CFrame.lookAt(root.Position, flat) -- face the pet
	end
	hum.WalkSpeed, hum.JumpPower, hum.JumpHeight = 0, 0, 0
	root.Anchored = true
end

local function unlock(s)
	if s.Hum and s.Hum.Parent then
		s.Hum.WalkSpeed  = s.Walk or 16
		s.Hum.JumpPower  = s.Jump or 50
		s.Hum.JumpHeight = s.JumpHeight or 7.2
	end
	if s.Root and s.Root.Parent then s.Root.Anchored = false end
end

-------------------------------------------------------------------- finish

local function finish(player, s, reason)
	if s.Done then return end
	s.Done = true
	if sessions[player] == s then sessions[player] = nil end
	if s.DiedConn then s.DiedConn:Disconnect() end
	unlock(s)

	local profile = deps.profiles[player]
	local wild    = s.Wild
	if profile then profile.busy = false end
	if not player.Parent then return end

	local remote = deps.remote
	if reason ~= "complete" then remote:FireClient(player, "TameAbort", s.Id) end

	if s.Outcome == "success" then
		if wild and wild.Parent then wild:Destroy() end
		-- Result BEFORE Equip: client clears its cinematic lock first, then the
		-- Summon effect from Equip can set its own.
		remote:FireClient(player, "TameResult", "success")
		if profile and deps.profiles[player] == profile then
			deps.Equip(player, s.PetId)
			task.delay(0.8, function()
				if deps.profiles[player] == profile then deps.SpawnWild(player) end
			end)
		end
	else
		if wild and wild.Parent then wild:SetAttribute("Claimed", false) end
		local dazed = 0
		if reason == "complete" then
			dazed = TC.ConcussionSeconds
			player:SetAttribute("TameConcussedUntil", workspace:GetServerTimeNow() + dazed)
		end
		remote:FireClient(player, "TameResult", "failure", dazed)
	end
end

local function applyFailHit(player, s)
	if s.Done or sessions[player] ~= s then return end
	local hum = s.Hum
	if hum and hum.Parent and hum.Health > 1 then
		hum:TakeDamage(math.min(TC.FailDamage, hum.Health - 1)) -- never lethal
	end
end

-------------------------------------------------------------------- public API

function Service.Init(d)
	deps = d
end

function Service.Request(player, wild)
	if sessions[player] then return end
	local profile = deps.profiles[player]
	if not profile or profile.busy then return reject(player, "busy") end

	if typeof(wild) ~= "Instance" or not wild:IsA("Model") then return reject(player, "invalid") end
	if not wild.Parent or not wild:IsDescendantOf(workspace) then return reject(player, "invalid") end
	if wild:GetAttribute("IsWild") ~= true or wild:GetAttribute("Claimed") then return reject(player, "invalid") end

	local owner = wild:GetAttribute("WildOwnerUserId")
	if owner ~= nil and owner ~= player.UserId then return reject(player, "invalid") end

	local speciesId = wild:GetAttribute("SpeciesId")
	if speciesId == nil or not PetConfig.Species or not PetConfig.Species[speciesId] then
		return reject(player, "invalid")
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local hum  = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then return end

	local okPos, wildPos = pcall(function() return wild:GetPivot().Position end)
	if not okPos or (wildPos - root.Position).Magnitude > deps.TameRange then
		return reject(player, "invalid")
	end

	if isConcussed(player) then return reject(player, "dazed") end
	if TC.RequireGrounded and hum.FloorMaterial == Enum.Material.Air then return reject(player, "airborne") end
	if #profile.order >= num(PetConfig.MaxSlots, 10) then return reject(player, "full") end

	-- Claim first: blocks a second request (or player) during the ceremony.
	wild:SetAttribute("Claimed", true)

	local level   = num(player:GetAttribute("Level"), 1)
	local success = rng:NextNumber() < chanceFor(wild, level)

	local petId
	if success then
		petId = deps.GivePet(player, speciesId, {
			Stage          = num(wild:GetAttribute("Stage"), 1),
			Level          = num(wild:GetAttribute("Level"), 1),
			SizeMultiplier = num(wild:GetAttribute("SizeMultiplier"), 1),
		})
		if not petId then
			wild:SetAttribute("Claimed", false)
			return reject(player, "full")
		end
	end

	nextId += 1
	local s = { Id = nextId, Wild = wild, Outcome = success and "success" or "failure", PetId = petId, Named = false }
	sessions[player] = s
	profile.busy = true
	lock(player, s, wildPos)
	if s.Hum then
		s.DiedConn = s.Hum.Died:Connect(function() finish(player, s, "abort") end)
	end

	deps.remote:FireClient(player, "TameBegin", {
		Id = s.Id, WildModel = wild, Outcome = s.Outcome, PetId = petId, PlayerLevel = level,
	})

	if success then
		task.delay(TC.SessionTimeout, function() finish(player, s, "timeout") end)
	else
		task.delay(Config.FailHitAt() + Config.ServerCueLag, function() applyFailHit(player, s) end)
		task.delay(Config.FailEndAt() + Config.ServerCueLag, function() finish(player, s, "complete") end)
	end
end

function Service.Nickname(player, text)
	local s = sessions[player]
	if not s or s.Outcome ~= "success" or s.Named or s.Naming then return end
	s.Naming = true

	task.spawn(function()
		local clean = sanitize(text)
		if utf8.len(clean) == nil or utf8.len(clean) < Config.Nickname.MinLength then
			s.Naming = false
			return
		end

		-- User text shown to other players MUST be filtered.
		local ok, filtered = pcall(function()
			local result = TextService:FilterStringAsync(clean, player.UserId, Enum.TextFilterContext.PublicChat)
			return result:GetNonChatStringForBroadcastAsync()
		end)
		if not ok or typeof(filtered) ~= "string" or filtered == "" then
			warn("[PetTamingService] nickname filter failed:", filtered)
			filtered = "Companion"
		end
		if s.Done or sessions[player] ~= s then return end

		local profile = deps.profiles[player]
		local data = profile and profile.pets[s.PetId]
		if data then data.Nickname = filtered end
		s.Named = true
		deps.Sync(player)
		deps.remote:FireClient(player, "TameNickname", s.Id, filtered)
	end)
end

function Service.Finish(player)
	local s = sessions[player]
	if s and s.Outcome == "success" then finish(player, s, "complete") end
end

function Service.CleanupPlayer(player)
	local s = sessions[player]
	if not s then return end
	s.Done = true
	sessions[player] = nil
	if s.DiedConn then s.DiedConn:Disconnect() end
end

return Service