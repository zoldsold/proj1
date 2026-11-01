--[[
	PetClient (LocalScript -> StarterPlayer > StarterPlayerScripts)

	Main entry point. Thin orchestrator that wires up modules:
	- PetClient_Helpers: easing, timeline, stage lookup, alpha helpers
	- PetClient_Follow:  constraints + pet state
	- PetClient_Motion:  per-frame movement (PetMotionConfig)
	- PetClient_Swim:    swimming animation
	- PetClient_VFX:     effect primitives + summon/evolve sequences
	- PetClient_Cinema:  cutscenes + UI overlays
	- PetClient_Attack:  right-click input + impact detection
	- PetTaming_Cinema:  4-phase taming cinematic on actual wild model
]]
-- v1.0.0.1
-- CHANGES v1.0.0.1: the Heartbeat movement loop moved to PetClient_Motion (config-driven: speed, ground/flying
--   height, click + drag-follow). This script only wires modules.
-- v1.0.0.0.4 CHANGES: Handle TameBegin event → play PetTaming_Cinema on actual wild model.
--          No duplicate pet spawn during taming. Cinematic locks camera via
--          PetCinematic attribute. TameResult "success" fires AFTER cinematic.
--          Handle PetReleased event → play short farewell VFX.

local Players         = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService      = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local PetConfig = require(ReplicatedStorage:WaitForChild("PetConfig"))

local TamingModules = ReplicatedStorage:WaitForChild("PetTamingModules")
local ModulesFolder = ReplicatedStorage:WaitForChild("PetClientModules")
local PetEvent      = ReplicatedStorage:WaitForChild("PetEvent")


local Follow        = require(ModulesFolder:WaitForChild("PetClient_Follow"))
local Motion        = require(ModulesFolder:WaitForChild("PetClient_Motion"))
local Swim          = require(ModulesFolder:WaitForChild("PetClient_Swim"))
local VFX           = require(ModulesFolder:WaitForChild("PetClient_VFX"))
local Cinema        = require(ModulesFolder:WaitForChild("PetClient_Cinema"))
local Attack        = require(ModulesFolder:WaitForChild("PetClient_Attack"))
local Taming        = require(TamingModules:WaitForChild("PetTaming_Main"))
local TamingCinema  = require(TamingModules:WaitForChild("PetTaming_Cinematic"))

local player     = Players.LocalPlayer
local playerGui  = player:WaitForChild("PlayerGui")
local camera     = workspace.CurrentCamera
local petsFolder = workspace:WaitForChild("Pets")

------------------------------------------------------------------ 1. Follow setup

player.CharacterAdded:Connect(function(character)
	character:WaitForChild("HumanoidRootPart")
	task.wait(0.3)
	local userIdStr = tostring(player.UserId)
	if petsFolder:FindFirstChild(userIdStr) then
		Follow.setup(player, userIdStr, petsFolder)
	end
end)

PetEvent.OnClientEvent:Connect(function(action, arg)
	if action ~= "PetSpawned" then return end
	task.delay(0.2, function()
		Follow.setup(player, arg, petsFolder)
	end)
end)

------------------------------------------------------------------ 2. Movement

Motion.init(player, petsFolder, PetEvent)
RunService.Heartbeat:Connect(Motion.step)

------------------------------------------------------------------ 3. Swim animation

Swim.start(petsFolder)

------------------------------------------------------------------ 4. Attack input

Attack.bindInput(player, petsFolder, camera)

------------------------------------------------------------------ 4b. Taming input

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.E then
		Taming.tryTameNearest()
	end
end)

------------------------------------------------------------------ 5. Server FX events

PetEvent.OnClientEvent:Connect(function(action, kind, userId, extra)
	if action ~= "FX" then return end

	task.spawn(function()
		if kind == "AttackImpact" then
			if typeof(userId) == "Vector3" then
				Attack.burstImpact(userId)
			end
			return
		end

		if kind == "Summon" then
			local model = petsFolder:WaitForChild(tostring(userId), 3)
			if not model then return end
			local ground = VFX.summonVFX(model, petsFolder)
			local mine   = userId == player.UserId
			if mine then
				Cinema.runCinematic(function()
					Cinema.summonCinematic(model, ground, petsFolder)
				end)
			end

		elseif kind == "EvolveStart" then
			Cinema.revealed[userId] = nil
			local mine = userId == player.UserId
			if mine then
				Cinema.runCinematic(function()
					Cinema.evolveCinematic(userId, petsFolder)
				end)
			else
				VFX.evolveBuildupVFX(userId, PetConfig.Timing.EvolveBuildup, petsFolder)
			end

		elseif kind == "EvolveReveal" then
			Cinema.revealed[userId] = extra
			local mine = userId == player.UserId
			if not mine then
				task.wait(0.2)
				VFX.evolveRevealVFX(userId, petsFolder)
			end
		end
	end)
end)

------------------------------------------------------------------ 6. Taming ceremony (TameBegin / TameAbort)
-- Server fires TameBegin with the actual wild model + outcome. The cinematic
-- owns the PetCinematic lock for its whole length; PetTaming_Main releases it
-- when the server sends TameResult.

PetEvent.OnClientEvent:Connect(function(action, payload)
	if action == "TameBegin" then
		task.spawn(TamingCinema.play, payload)
	elseif action == "TameAbort" then
		TamingCinema.abort(payload)
	end
end)