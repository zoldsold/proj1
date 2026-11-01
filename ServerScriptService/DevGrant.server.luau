--!nonstrict
-- DevGrant v1.0.0.1
-- ServerScriptService. Studio-only: grants money, pet XP and pets to the joining player once per
-- session. Change GRANT_ID to apply the grant again. Delete before publishing.
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataService = require(script.Parent.Data.DataService)
local PetManager = require(script.Parent.PetManager)
local PetConfig = require(ReplicatedStorage:WaitForChild("PetConfig"))

local GRANT_ID = "dev1" -- change to "dev2" to apply the grant again
local GRANT = {
	Money = 1000000,
	PetXP = 500, -- added to each granted pet; the game caps XP at the stage's XPToEvolve
	Pets = {
		-- Species must be a key in PetConfig.Species (for example "Kun").
		-- Stage must exist for that species. Level 1-9999. SizeMultiplier 0.1-10.
		{ Species = "Kun", Stage = 4, Level = 100, SizeMultiplier = 1 },
	},
}

-- PetManager binds the profile a moment after DataService loads it, so retry briefly.
local function retry(fn)
	for _ = 1, 25 do
		local result = fn()
		if result then
			return result
		end
		task.wait(0.2)
	end
	return nil
end

local function grant(player)
	local profile = DataService.WaitFor(player)
	if not profile or profile.progress.flags.devGrant == GRANT_ID then
		return
	end

	DataService.AddMoney(player, GRANT.Money)

	for _, spec in GRANT.Pets do
		if not PetConfig.Species[spec.Species] then
			warn("[DevGrant] unknown species: " .. tostring(spec.Species))
		else
			local id = retry(function()
				return PetManager.GivePet(player, spec.Species, spec)
			end)
			if id then
				PetManager.AddXP(player, GRANT.PetXP, id)
			else
				warn("[DevGrant] could not give " .. spec.Species .. " (inventory full?)")
			end
		end
	end

	profile.progress.flags.devGrant = GRANT_ID
	DataService.SaveSoon(player)
	print("[DevGrant] applied " .. GRANT_ID .. " to " .. player.Name)
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(grant, player)
end)
for _, player in Players:GetPlayers() do
	task.spawn(grant, player)
end