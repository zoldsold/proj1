-- v1.0.0.0.3
--[[
	PetTaming_Main (ModuleScript -> ReplicatedStorage/PetClientModules)

	Client entry for taming. The client only REQUESTS (E key) and reacts to the
	server: TameBegin is handled by PetClient -> PetTaming_Cinema.
	  TameRejected -> toast, release input lock
	  TameResult   -> release input lock (+ concussion effect on failure)

	CHANGES v1.0.0.0.3: removed the old per-result cinematic aliases (the
	ceremony is now one continuous sequence driven by TameBegin) and made the
	stuck-lock safety timer aware of the long ceremony (TameActive attribute).
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TamingModules = ReplicatedStorage:WaitForChild("PetTamingModules")

local Config = require(TamingModules:WaitForChild("PetTaming_Config"))
local Cinema = require(TamingModules:WaitForChild("PetTaming_Cinematic"))

local Taming = {}

local player   = Players.LocalPlayer
local PetEvent = ReplicatedStorage:WaitForChild("PetEvent")

local lastTameAttempt = 0
local tameStartTime   = 0

local function clearTamingAttributes()
	player:SetAttribute("Taming", nil)
	player:SetAttribute("PetCinematic", nil)
end

------------------------------------------------------------------ wild lookup

-- Nearest unclaimed wild pet model within maxRange, or nil.
function Taming.findNearestWildPet(maxRange)
	maxRange = maxRange or 30
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return nil end

	local best, bestDist
	for _, model in ipairs(workspace:GetChildren()) do
		if model:IsA("Model") and model:GetAttribute("IsWild") == true and not model:GetAttribute("Claimed") then
			local modelRoot = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
			if modelRoot then
				local dist = (modelRoot.Position - root.Position).Magnitude
				if dist <= maxRange and (not bestDist or dist < bestDist) then
					best, bestDist = model, dist
				end
			end
		end
	end
	return best
end

function Taming.isDazed()
	local untilTime = player:GetAttribute("TameConcussedUntil")
	return typeof(untilTime) == "number" and workspace:GetServerTimeNow() < untilTime
end

------------------------------------------------------------------ request

function Taming.tryTameNearest()
	local now = os.clock()
	if now - lastTameAttempt < 0.4 then return false end
	lastTameAttempt = now

	if player:GetAttribute("TameActive") then return false end

	-- Stale lock from OUR request (server never answered): self-heal after 8s.
	if player:GetAttribute("PetCinematic") then
		if player:GetAttribute("Taming") and now - tameStartTime > 8 then
			clearTamingAttributes()
		else
			return false
		end
	end

	if Taming.isDazed() then
		Cinema.toast(Config.Toasts.dazed)
		return false, "dazed"
	end

	local wildPet = Taming.findNearestWildPet()
	if not wildPet then return false, "No wild pet nearby" end

	tameStartTime = now
	player:SetAttribute("Taming", true)
	player:SetAttribute("PetCinematic", true)

	-- Safety: request dropped / server silent. Never fires during the ceremony.
	task.delay(7, function()
		if player:GetAttribute("Taming") and not player:GetAttribute("TameActive")
			and os.clock() - tameStartTime >= 6.8 then
			clearTamingAttributes()
		end
	end)

	PetEvent:FireServer("RequestTame", wildPet)
	return true
end

------------------------------------------------------------------ server replies

PetEvent.OnClientEvent:Connect(function(action, kind, extra)
	if action == "TameRejected" then
		clearTamingAttributes()
		Cinema.toast(Config.Toasts[kind] or Config.Toasts.invalid)

	elseif action == "TameResult" then
		-- ("TameResult", "success") or ("TameResult", "failure", concussionSeconds)
		clearTamingAttributes()
		if kind == "failure" and type(extra) == "number" then
			Cinema.dizzy(extra)
		end
	end
end)

return Taming