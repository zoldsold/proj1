-- v1.0.0.0.8
--[[
	PetManager (ModuleScript -> ServerScriptService)

	Server responsibilities:
	- Build and parent pet models into workspace.Pets
	- Write SpeciesId/Stage/PetId/Nickname attributes so client knows what it's following
	- AlignPosition/AlignOrientation are created client-side (PetClient)
	- Bob anchor is entirely client-side (PetClient handles it)
	- Spawn wild stray pets in workspace (IsWild models) for taming
	- Ownership and inventory
	- Release system: return owned pet to wild, preserving level/stage/size

	CHANGES in v1.0.0.0.8:
	- Pets, order, equipped and nextId persist via DataService: the runtime profile
	  forwards those fields to the saved profile, so every in-place edit is saved
	  (debounced SaveSoon after each change, plus autosave / leave / shutdown).

	CHANGES in v1.0.0.0.7:
	- Taming moved to PetTamingService (session, roll, anchor, damage, nickname).
	  PetManager only routes RequestTame / TameNickname / TameFinish to it.
	- Pets carry a server-filtered Nickname (snapshot + model attribute).
	- BUGFIX: getGroundPosition was defined AFTER ReleasePet used it (nil call
	  when releasing a pet). It now lives in the utility section.
	- MagicCircleService is no longer required here (ceremony renders client-side).

	NOTE:
	Pet parts are Anchored. SetNetworkOwner is intentionally not called.
]]

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local RunService          = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

-------------------------------------------------------------------- safe require

local function waitForInstance(parent, name, timeout)
	local inst = parent:WaitForChild(name, timeout)
	if not inst then
		error(string.format("[PetManager] Missing required instance: %s.%s", parent:GetFullName(), name))
	end
	return inst
end

local PetConfig = require(waitForInstance(ReplicatedStorage,   "PetConfig",         10))
local Builder   = require(waitForInstance(ReplicatedStorage,   "PetModelBuilder",   10))
local Taming    = require(waitForInstance(ServerScriptService, "PetTaming_Service",  10))
local DataService = require(waitForInstance(waitForInstance(ServerScriptService, "Data", 10), "DataService", 10))
DataService.Init() -- idempotent

-------------------------------------------------------------------- module

local PetManager = {}

local initialized = false

local remote
local petsFolder

local profiles   = {}
local lastAction = {}
local lastAttack = {}

local rng = Random.new()

local ACQUISITION = {
	LevelMin        = 1,
	LevelMax        = 5,
	SizeMin         = 0.85,
	SizeMax         = 1.2,
	SpawnRadiusMin  = 8,
	SpawnRadiusMax  = 18,
	WildCount       = 3,
	WildRadiusMin   = 18,
	WildRadiusMax   = 35,
	WildTameRange   = 30,
}

-- Attack cooldown.
local ATTACK_COOLDOWN = 1.0
local DEVOUR_DAMAGE   = 25

-- MoveSpeed attribute throttle.
local MOVE_SPEED_INTERVAL = 0.1
local moveSpeedTimer      = 0

-------------------------------------------------------------------- utility

local function validNumber(value, fallback)
	local n = tonumber(value)
	if n == nil or n ~= n then return fallback end
	return n
end

local function randomInteger(min, max, fallback)
	min = tonumber(min); max = tonumber(max)
	if min == nil or max == nil or min ~= min or max ~= max then return fallback or 1 end
	min = math.floor(min); max = math.floor(max)
	if min == max then return min end
	if min > max  then return fallback or min end
	return rng:NextInteger(min, max)
end

local function randomNumber(min, max, fallback)
	min = tonumber(min); max = tonumber(max)
	if min == nil or max == nil or min ~= min or max ~= max then return fallback or 0 end
	if min == max then return min end
	if min > max  then return fallback or min end
	return rng:NextNumber(min, max)
end

local function getTiming(key, default)
	local timing = PetConfig and PetConfig.Timing
	local value  = timing and timing[key]
	value = validNumber(value, default)
	if value == nil or value < 0 then return default end
	return value
end

local function getGroundPosition(position, excludeList)
	local params = RaycastParams.new()
	params.FilterType                 = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = excludeList or {}
	local result = workspace:Raycast(
		position + Vector3.new(0, 50, 0),
		Vector3.new(0, -200, 0),
		params
	)
	return result and (result.Position + Vector3.new(0, 1.5, 0)) or position
end

-------------------------------------------------------------------- data

-- Runtime profile = transient flags + persisted fields forwarded to the DataService
-- profile. Add new persisted fields to PERSISTED (and to ProfileSchema).
local PERSISTED = { pets = true, order = true, equipped = true, nextId = true }

local function bindProfile(stored)
	return setmetatable({ busy = false, wildSpawning = false }, {
		__index    = function(_, k) if PERSISTED[k] then return stored[k] end end,
		__newindex = function(t, k, v)
			if PERSISTED[k] then stored[k] = v else rawset(t, k, v) end
		end,
	})
end

local function snapshot(profile)
	local pets = {}
	for _, id in ipairs(profile.order) do
		local d = profile.pets[id]
		if d then
			table.insert(pets, {
				Id             = d.Id,
				Species        = d.Species,
				Stage          = d.Stage,
				XP             = d.XP,
				Level          = d.Level or 1,
				SizeMultiplier = d.SizeMultiplier or 1,
				Nickname       = d.Nickname,
			})
		end
	end
	return {
		Equipped = profile.equipped,
		Pets     = pets,
	}
end

local function sync(player)
	local profile = profiles[player]
	if profile and remote then
		remote:FireClient(player, "Sync", snapshot(profile))
	end
end

-- Every state change goes through commit: tell the client and schedule a save.
local function commit(player)
	DataService.SaveSoon(player)
	sync(player)
end

function PetManager.GetPetModel(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return nil end
	if not petsFolder or not petsFolder.Parent then return nil end
	return petsFolder:FindFirstChild(tostring(player.UserId))
end

-------------------------------------------------------------------- despawn/spawn

local function despawn(player)
	local model = PetManager.GetPetModel(player)
	if model then model:Destroy() end
end

local function spawnPet(player, summon, atCFrame)
	local profile = profiles[player]
	if not profile or not profile.equipped then return false end
	if not petsFolder or not petsFolder.Parent then return false end

	local data      = profile.pets[profile.equipped]
	local character = player.Character
	local root      = character and character:FindFirstChild("HumanoidRootPart")
	if not data or not root then return false end

	local stageCfg = PetConfig.GetStage(data.Species, data.Stage)
	if not stageCfg then
		warn("[PetManager] Invalid stage for spawn:", data.Species, data.Stage)
		return false
	end

	local okBuild, model = pcall(Builder.Build, data.Species, data.Stage, false)
	if not okBuild or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn("[PetManager] Builder.Build failed:", data.Species, data.Stage)
		return false
	end

	local body = model.PrimaryPart
	if not body then
		warn("[PetManager] Built pet has no PrimaryPart:", data.Species, data.Stage)
		model:Destroy()
		return false
	end

	if profiles[player] ~= profile or not player.Parent then
		model:Destroy()
		return false
	end

	if atCFrame and typeof(atCFrame) ~= "CFrame" then atCFrame = nil end

	despawn(player)

	model.Name = tostring(player.UserId)
	model:SetAttribute("SpeciesId",      data.Species)
	model:SetAttribute("Stage",          data.Stage)
	model:SetAttribute("PetId",          data.Id)
	model:SetAttribute("Level",          data.Level or 1)
	model:SetAttribute("SizeMultiplier", data.SizeMultiplier or 1)
	model:SetAttribute("Nickname",       data.Nickname)

	if summon then model:SetAttribute("Spawning", true) end

	local sizeMult = validNumber(data.SizeMultiplier, 1)
	if sizeMult ~= 1 then
		pcall(function() model:ScaleTo(sizeMult) end)
	end

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored   = true
			d.CanCollide = false
			d.CanQuery   = false
			d.CanTouch   = false
			d.Massless   = true
		end
	end

	if not body:FindFirstChild("PetAttach") then
		local attach  = Instance.new("Attachment")
		attach.Name   = "PetAttach"
		attach.Parent = body
	end

	local spawnCF = atCFrame
	if not spawnCF then
		local followOffset = stageCfg.FollowOffset
		if typeof(followOffset) ~= "Vector3" then
			followOffset = Vector3.new(0, 3, 4)
		end
		local angle    = randomNumber(0, math.pi * 2, 0)
		local distance = randomNumber(ACQUISITION.SpawnRadiusMin, ACQUISITION.SpawnRadiusMax, 10)
		local offset   = Vector3.new(math.cos(angle) * distance, 3, math.sin(angle) * distance)
		spawnCF = root.CFrame * CFrame.new(followOffset + offset)
	end

	model:PivotTo(spawnCF)
	model.Parent = petsFolder

	if summon then
		local summonTime = getTiming("Summon", 3)
		task.delay(math.max(0, summonTime), function()
			if model.Parent then model:SetAttribute("Spawning", nil) end
		end)
		if remote then remote:FireAllClients("FX", "Summon", player.UserId) end
	end

	if remote then remote:FireClient(player, "PetSpawned", tostring(player.UserId)) end

	return true
end

-------------------------------------------------------------------- MoveSpeed throttle

RunService.Heartbeat:Connect(function(dt)
	moveSpeedTimer += dt
	if moveSpeedTimer < MOVE_SPEED_INTERVAL then return end
	moveSpeedTimer = 0
	if not petsFolder or not petsFolder.Parent then return end

	for player, profile in pairs(profiles) do
		if profile.equipped then
			local character = player.Character
			local root      = character and character:FindFirstChild("HumanoidRootPart")
			local model     = petsFolder:FindFirstChild(tostring(player.UserId))
			if root and model then
				local vel       = root.AssemblyLinearVelocity
				local speed     = Vector3.new(vel.X, 0, vel.Z).Magnitude
				local lastSpeed = validNumber(model:GetAttribute("MoveSpeed"), nil)
				if lastSpeed == nil or math.abs(lastSpeed - speed) > 0.05 then
					model:SetAttribute("MoveSpeed", speed)
				end
			end
		end
	end
end)

-------------------------------------------------------------------- public actions

function PetManager.GivePet(player, speciesId, overrides)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return nil end
	local profile = profiles[player]
	if not profile then return nil end
	if not PetConfig.Species or not PetConfig.Species[speciesId] then return nil end

	local maxSlots = validNumber(PetConfig.MaxSlots, 10)
	if #profile.order >= maxSlots then return nil end

	overrides = overrides or {}

	local level = validNumber(overrides.Level, nil)
	if level == nil then level = randomInteger(ACQUISITION.LevelMin, ACQUISITION.LevelMax, 1) end
	level = math.floor(math.clamp(level, 1, 9999))

	local size = validNumber(overrides.SizeMultiplier, nil)
	if size == nil then size = randomNumber(ACQUISITION.SizeMin, ACQUISITION.SizeMax, 1) end
	size = math.clamp(size, 0.1, 10)

	local stage = validNumber(overrides.Stage, 1)
	stage = math.floor(math.clamp(stage, 1, 999))
	if not PetConfig.GetStage(speciesId, stage) then stage = 1 end

	local id = "pet_" .. profile.nextId
	profile.nextId += 1

	profile.pets[id] = {
		Id             = id,
		Species        = speciesId,
		Stage          = stage,
		XP             = 0,
		Level          = level,
		SizeMultiplier = size,
	}

	table.insert(profile.order, id)
	commit(player)
	return id
end

function PetManager.Equip(player, petId)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return false end
	local profile = profiles[player]
	if not profile or profile.busy or not profile.pets[petId] then return false end
	if profile.equipped == petId and PetManager.GetPetModel(player) then return true end

	profile.equipped = petId
	profile.busy     = true

	local okSpawn, err = pcall(spawnPet, player, true)
	if not okSpawn then warn("[PetManager] Equip spawnPet failed:", err) end

	local summonTime = getTiming("Summon", 3)
	task.delay(math.max(0, summonTime + 0.6), function()
		if profiles[player] == profile then profile.busy = false end
	end)

	commit(player)
	return true
end

function PetManager.Unequip(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	local profile = profiles[player]
	if not profile or profile.busy then return end
	profile.equipped = nil
	despawn(player)
	commit(player)
end

function PetManager.AddXP(player, amount, petId)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	local profile = profiles[player]
	if not profile then return end

	amount = validNumber(amount, 0)
	if amount <= 0 then return end

	petId = petId or profile.equipped
	local data = petId and profile.pets[petId]
	if not data then return end

	local cfg        = PetConfig.GetStage(data.Species, data.Stage)
	local xpToEvolve = validNumber(cfg and cfg.XPToEvolve, nil)
	if not xpToEvolve then return end

	local currentXP = validNumber(data.XP, 0)
	data.XP = math.clamp(currentXP + amount, 0, xpToEvolve)
	commit(player)
end

function PetManager.Evolve(player, petId)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return false end
	local profile = profiles[player]
	if not profile or profile.busy then return false end

	local data  = profile.pets[petId]
	local model = PetManager.GetPetModel(player)
	if not data or profile.equipped ~= petId or not model then return false end

	local cfg        = PetConfig.GetStage(data.Species, data.Stage)
	local xpToEvolve = validNumber(cfg and cfg.XPToEvolve, nil)
	local currentXP  = validNumber(data.XP, 0)
	if not xpToEvolve or currentXP < xpToEvolve then return false end
	if not PetConfig.GetStage(data.Species, data.Stage + 1) then return false end

	profile.busy = true

	local userId  = player.UserId
	local buildup = getTiming("EvolveBuildup", 1)
	local reveal  = getTiming("EvolveReveal",  2)

	if remote then remote:FireAllClients("FX", "EvolveStart", userId) end

	task.wait(math.max(0, buildup))

	if profiles[player] ~= profile or profile.equipped ~= petId then
		profile.busy = false
		return false
	end

	local pivot    = model.Parent and model:GetPivot() or nil
	local oldStage = data.Stage
	local oldXP    = data.XP

	data.Stage += 1
	data.XP     = 0

	local spawned = spawnPet(player, false, pivot)
	if not spawned then
		data.Stage   = oldStage
		data.XP      = oldXP
		profile.busy = false
		return false
	end

	if remote then remote:FireAllClients("FX", "EvolveReveal", userId, data.Stage) end

	commit(player)

	task.delay(math.max(0, reveal + 0.8), function()
		if profiles[player] == profile then profile.busy = false end
	end)

	return true
end

-------------------------------------------------------------------- release system

--[[
	ReleasePet: removes pet from inventory and re-spawns it as a wild pet.
	The wild pet keeps its level, stage, and size. It also gets:
	  - PreviousOwnerId / PreviousOwnerLevel (taming difficulty scaling)
	  - Released = true
	Previously-owned pets are harder to re-tame (steeper penalty curve).
]]
function PetManager.ReleasePet(player, petId)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return false end
	local profile = profiles[player]
	if not profile or profile.busy then return false end

	local data = profile.pets[petId]
	if not data then return false end

	if profile.equipped == petId then
		profile.equipped = nil
		despawn(player)
	end

	profile.pets[petId] = nil
	for i, id in ipairs(profile.order) do
		if id == petId then
			table.remove(profile.order, i)
			break
		end
	end

	commit(player)

	local character = player.Character
	local root      = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return true end -- inventory cleared, no wild spawn needed

	local angle    = randomNumber(0, math.pi * 2, 0)
	local distance = randomNumber(ACQUISITION.WildRadiusMin, ACQUISITION.WildRadiusMax, 20)
	local basePos  = root.Position + Vector3.new(
		math.cos(angle) * distance,
		3,
		math.sin(angle) * distance
	)

	local pos = getGroundPosition(basePos, {})

	local cfg = PetConfig.GetStage(data.Species, data.Stage)
	if not cfg then return true end

	local okBuild, model = pcall(Builder.Build, data.Species, data.Stage, false)
	if not okBuild or typeof(model) ~= "Instance" or not model:IsA("Model") then return true end

	local body = model.PrimaryPart
	if not body then model:Destroy(); return true end

	model.Name = "WildPet_" .. tostring(randomInteger(100000, 999999, 100000))
	model:SetAttribute("IsWild",             true)
	model:SetAttribute("SpeciesId",          data.Species)
	model:SetAttribute("Stage",              data.Stage)
	model:SetAttribute("Level",              data.Level or 1)
	model:SetAttribute("SizeMultiplier",     data.SizeMultiplier or 1)
	model:SetAttribute("Claimed",            false)
	model:SetAttribute("Released",           true)
	model:SetAttribute("PreviousOwnerId",    player.UserId)
	model:SetAttribute("PreviousOwnerLevel", validNumber(player:GetAttribute("Level"), 1))
	-- No WildOwnerUserId: released pets are world-shared

	local size = validNumber(data.SizeMultiplier, 1)
	if size ~= 1 then pcall(function() model:ScaleTo(size) end) end

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored   = true
			d.CanCollide = false
			d.CanQuery   = true
			d.CanTouch   = false
			d.Massless   = true
		end
	end

	if not body:FindFirstChild("PetAttach") then
		local attach  = Instance.new("Attachment")
		attach.Name   = "PetAttach"
		attach.Parent = body
	end

	model:PivotTo(CFrame.new(pos))
	model.Parent = workspace

	if remote then
		remote:FireClient(player, "PetReleased", data.Species, model)
	end

	return true
end

-------------------------------------------------------------------- skills

PetManager.Skills = {}

function PetManager.RegisterSkill(name, fn)
	if typeof(name) == "string" and type(fn) == "function" then
		PetManager.Skills[name] = fn
	end
end

function PetManager.GetUnlockedSkills(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return {} end
	local profile = profiles[player]
	local data    = profile and profile.equipped and profile.pets[profile.equipped]
	if not data then return {} end
	local stage = PetConfig.GetStage(data.Species, data.Stage)
	if not stage or typeof(stage.Skills) ~= "table" then return {} end
	return stage.Skills
end

function PetManager.CastSkill(player, name, ...)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return nil end
	local model = PetManager.GetPetModel(player)
	local fn    = PetManager.Skills[name]
	if not model or type(fn) ~= "function" then return nil end
	local unlocked = PetManager.GetUnlockedSkills(player)
	if typeof(unlocked) ~= "table" or not table.find(unlocked, name) then return nil end
	local ok, result = pcall(fn, player, model, ...)
	if not ok then warn("[PetManager] CastSkill error:", result); return nil end
	return result
end

-------------------------------------------------------------------- wild stray pets

local WILD_SPECIES       = {}
local WILD_STAGE_WEIGHTS = { 6, 3 }
local WILD_STAGE_MAX     = 2
local WILD_FALLBACK_SPECIES = "Kun"

local function pickWild()
	local keys = {}
	for id, def in pairs(PetConfig.Species or {}) do
		if (typeof(id) == "string" or typeof(id) == "number")
			and type(def) == "table"
			and type(def.Stages) == "table"
			and #def.Stages > 0 then
			table.insert(keys, id)
		end
	end

	if #keys == 0 then
		warn("[PetManager] PetConfig.Species empty � no strays can spawn.")
		return nil, nil
	end

	local speciesId
	for _ = 1, 8 do
		local pool      = #WILD_SPECIES > 0 and WILD_SPECIES or nil
		local candidate = pool
			and pool[randomInteger(1, #pool, 1)]
			or  keys[randomInteger(1, #keys, 1)]
		if candidate and PetConfig.Species[candidate] and #PetConfig.Species[candidate].Stages > 0 then
			speciesId = candidate
			break
		end
	end

	speciesId = speciesId or keys[1] or WILD_FALLBACK_SPECIES
	if not PetConfig.Species[speciesId] then
		warn("[PetManager] No valid wild species. Fallback invalid:", WILD_FALLBACK_SPECIES)
		return nil, nil
	end

	local stages   = PetConfig.Species[speciesId].Stages
	local maxStage = math.clamp(math.min(#stages, WILD_STAGE_MAX), 1, #stages)
	local total, weights = 0, {}

	for i = 1, maxStage do
		local w = math.max(0.01, validNumber(WILD_STAGE_WEIGHTS[i], 1))
		weights[i] = w; total += w
	end

	if total <= 0 then return speciesId, 1 end

	local roll, stage = rng:NextNumber(0, total), 1
	for i = 1, maxStage do
		roll -= weights[i]
		if roll <= 0 then stage = i; break end
	end

	return speciesId, math.clamp(stage, 1, #stages)
end

local function spawnWildPet(speciesId, stage, position)
	local cfg = PetConfig.GetStage(speciesId, stage)
	if not cfg then warn("[PetManager] Invalid wild stage:", speciesId, stage); return nil end

	local okBuild, model = pcall(Builder.Build, speciesId, stage, false)
	if not okBuild or typeof(model) ~= "Instance" or not model:IsA("Model") then
		warn("[PetManager] Builder.Build failed for wild pet:", speciesId, stage); return nil
	end

	local body = model.PrimaryPart
	if not body then warn("[PetManager] Wild pet no PrimaryPart:", speciesId, stage); model:Destroy(); return nil end

	model.Name = "WildPet_" .. tostring(randomInteger(100000, 999999, 100000))
	model:SetAttribute("IsWild",         true)
	model:SetAttribute("SpeciesId",      speciesId)
	model:SetAttribute("Stage",          stage)
	model:SetAttribute("Level",          randomInteger(ACQUISITION.LevelMin, ACQUISITION.LevelMax, 1))
	model:SetAttribute("SizeMultiplier", randomNumber(ACQUISITION.SizeMin,   ACQUISITION.SizeMax,  1))
	model:SetAttribute("Claimed",        false)

	local size = validNumber(model:GetAttribute("SizeMultiplier"), 1)
	if size ~= 1 then pcall(function() model:ScaleTo(size) end) end

	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored   = true
			d.CanCollide = false
			d.CanQuery   = true -- client taming click/raycast must hit it
			d.CanTouch   = false
			d.Massless   = true
		end
	end

	if not body:FindFirstChild("PetAttach") then
		local attach  = Instance.new("Attachment")
		attach.Name   = "PetAttach"
		attach.Parent = body
	end

	model:PivotTo(CFrame.new(position))
	return model
end

local function spawnWildPetsForPlayer(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or not player.Parent then return end
	local profile = profiles[player]
	if not profile or profile.wildSpawning then return end

	local character = player.Character
	local root      = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	profile.wildSpawning = true

	local spawned = 0
	for _, model in ipairs(workspace:GetChildren()) do
		if model:IsA("Model")
			and model:GetAttribute("IsWild") == true
			and model:GetAttribute("WildOwnerUserId") == player.UserId then
			spawned += 1
		end
	end

	local wildCount = validNumber(ACQUISITION.WildCount, 0)
	if spawned < wildCount then
		local exclude = {}
		if character and character.Parent then table.insert(exclude, character) end
		if petsFolder and petsFolder.Parent  then table.insert(exclude, petsFolder) end

		for _ = spawned + 1, wildCount do
			if profiles[player] ~= profile or not player.Parent then break end

			local angle    = randomNumber(0, math.pi * 2, 0)
			local distance = randomNumber(ACQUISITION.WildRadiusMin, ACQUISITION.WildRadiusMax, 25)
			local basePos  = root.Position + Vector3.new(
				math.cos(angle) * distance, 3, math.sin(angle) * distance
			)

			local position  = getGroundPosition(basePos, exclude)
			local speciesId, stage = pickWild()
			if speciesId then
				local model = spawnWildPet(speciesId, stage, position)
				if model then
					if profiles[player] ~= profile or not player.Parent then
						model:Destroy(); break
					end
					model:SetAttribute("WildOwnerUserId", player.UserId)
					model.Parent = workspace
				end
			end
		end
	end

	profile.wildSpawning = false
end

-------------------------------------------------------------------- setup

local function onPlayerAdded(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
	if profiles[player] then return end

	-- Pets load from DataService; nil = player left or was kicked (data failed to load).
	local stored = DataService.WaitFor(player)
	if not stored or profiles[player] then return end
	profiles[player] = bindProfile(stored)
	sync(player) -- a RequestSync that arrived before the load finished was dropped

	player.CharacterAdded:Connect(function(character)
		local profile = profiles[player]
		if not profile then return end
		local root = character:WaitForChild("HumanoidRootPart", 10)
		if not root then return end

		if profile.equipped then
			task.wait(0.5)
			if player.Character == character and profiles[player] == profile then
				spawnPet(player, false)
			end
		end

		task.delay(0.5, function()
			if profiles[player] == profile then spawnWildPetsForPlayer(player) end
		end)
	end)

	if player.Character then
		task.spawn(function()
			local character = player.Character
			local root      = character and character:WaitForChild("HumanoidRootPart", 10)
			if root and profiles[player] then
				PetManager.SpawnEquipped(player, false) -- character spawned while data was loading
				spawnWildPetsForPlayer(player)
			end
		end)
	end

	player.CharacterRemoving:Connect(function() despawn(player) end)
end

function PetManager.SpawnEquipped(player, summon)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then return false end
	local profile = profiles[player]
	if not profile or not profile.equipped or profile.busy then return false end
	if petsFolder and petsFolder:FindFirstChild(tostring(player.UserId)) then return true end
	local okSpawn, spawned = pcall(spawnPet, player, summon == true)
	return okSpawn and spawned == true
end

function PetManager.SpawnWildForPlayer(player)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		warn("[PetManager] SpawnWildForPlayer needs a Player, got:", player); return
	end
	spawnWildPetsForPlayer(player)
end

-------------------------------------------------------------------- cleanup

local function cleanupWildPetsForPlayer(player)
	for _, model in ipairs(workspace:GetChildren()) do
		if model:IsA("Model")
			and model:GetAttribute("IsWild") == true
			and model:GetAttribute("WildOwnerUserId") == player.UserId then
			model:Destroy()
		end
	end
end

-------------------------------------------------------------------- init

function PetManager.Init()
	if initialized then return end
	initialized = true

	remote = ReplicatedStorage:FindFirstChild("PetEvent")
	if not remote or not remote:IsA("RemoteEvent") then
		remote      = Instance.new("RemoteEvent")
		remote.Name = "PetEvent"
	end

	petsFolder = workspace:FindFirstChild("Pets")
	if not petsFolder then
		petsFolder      = Instance.new("Folder")
		petsFolder.Name = "Pets"
	end

	Taming.Init({
		remote    = remote,
		profiles  = profiles,
		GivePet   = PetManager.GivePet,
		Equip     = PetManager.Equip,
		Sync      = commit, -- taming changes (new pet, nickname) get saved too
		SpawnWild = spawnWildPetsForPlayer,
		TameRange = ACQUISITION.WildTameRange,
	})

	local function onServerEvent(player, action, arg)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then return end
		if typeof(action) ~= "string" then return end

		local now = os.clock()
		if lastAction[player] and now - lastAction[player] < 0.25 then return end
		lastAction[player] = now

		if action == "RequestSync" then
			sync(player)

		elseif action == "Equip" and typeof(arg) == "string" then
			PetManager.Equip(player, arg)

		elseif action == "Unequip" then
			PetManager.Unequip(player)

		elseif action == "Evolve" and typeof(arg) == "string" then
			PetManager.Evolve(player, arg)

		elseif action == "ReleasePet" and typeof(arg) == "string" then
			PetManager.ReleasePet(player, arg)

		elseif action == "DebugXP" and typeof(arg) == "string" and RunService:IsStudio() then
			PetManager.AddXP(player, 50, arg)

		elseif action == "Spawn" then
			PetManager.SpawnEquipped(player, true)

		elseif action == "DebugSpawnWild" and RunService:IsStudio() then
			spawnWildPetsForPlayer(player)

			-- Taming: all validation + rules live in PetTamingService.
		elseif action == "RequestTame" and typeof(arg) == "Instance" and arg:IsA("Model") then
			Taming.Request(player, arg)

		elseif action == "TameNickname" and typeof(arg) == "string" then
			Taming.Nickname(player, arg)

		elseif action == "TameFinish" then
			Taming.Finish(player)

		elseif action == "AttackImpact" and typeof(arg) == "Vector3" then
			if arg.X ~= arg.X or arg.Y ~= arg.Y or arg.Z ~= arg.Z then return end

			local profile = profiles[player]
			local model   = PetManager.GetPetModel(player)
			local data    = profile and profile.equipped and profile.pets[profile.equipped]
			if not profile or profile.busy or not model or not data then return end

			local last = lastAttack[player]
			if last and now - last < ATTACK_COOLDOWN then return end

			local stage = PetConfig.GetStage(data.Species, data.Stage)
			if not stage or typeof(stage.Skills) ~= "table" then return end
			if not table.find(stage.Skills, "Devour") then return end

			local character = player.Character
			local root      = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid  = character and character:FindFirstChildOfClass("Humanoid")
			if not root or not humanoid or humanoid.Health <= 0 then return end
			if (arg - root.Position).Magnitude > 140 then return end

			lastAttack[player] = now

			local sizeMult   = validNumber(data.SizeMultiplier, 1)
			local stageScale = validNumber(stage.Scale,         1)
			local radius     = 8 + stageScale * sizeMult * 22

			for _, targetPlayer in Players:GetPlayers() do
				if targetPlayer ~= player then
					local tc = targetPlayer.Character
					local th = tc and tc:FindFirstChildOfClass("Humanoid")
					local tr = tc and tc:FindFirstChild("HumanoidRootPart")
					if th and th.Health > 0 and tr and (tr.Position - arg).Magnitude <= radius then
						th:TakeDamage(DEVOUR_DAMAGE)
						if remote then remote:FireAllClients("FX", "AttackImpact", arg, player.UserId) end
						break
					end
				end
			end
		end
	end

	remote.OnServerEvent:Connect(onServerEvent)

	if not remote.Parent     then remote.Parent     = ReplicatedStorage end
	if not petsFolder.Parent then petsFolder.Parent = workspace end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do task.spawn(onPlayerAdded, player) end

	Players.PlayerRemoving:Connect(function(player)
		Taming.CleanupPlayer(player)
		despawn(player)
		cleanupWildPetsForPlayer(player)
		profiles[player]   = nil
		lastAction[player] = nil
		lastAttack[player] = nil
	end)
end

PetManager.Init()

return PetManager