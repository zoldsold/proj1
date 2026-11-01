local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PhysicsService = game:GetService("PhysicsService")

PhysicsService:RegisterCollisionGroup("Enemies")
PhysicsService:RegisterCollisionGroup("DashingPlayer")
PhysicsService:CollisionGroupSetCollidable("DashingPlayer", "Enemies", false)
-- DashingPlayer still collides with Default, so walls and floors stay solid

local function setGroup(character, groupName)
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = groupName
		end
	end
end

local DashEvent = ReplicatedStorage:WaitForChild("DashEvent")

local MODES = {
	Slide = { cooldown = 0.8, iframes = 0.23 },
	Teleport = { cooldown = 1.5, iframes = 0.3 },
}

local lastDash = {}

DashEvent.OnServerEvent:Connect(function(player, mode)
	local config = MODES[mode] -- rejects anything that isn't a real mode
	if not config then return end

	local character = player.Character
	if not character then return end

	local now = os.clock()
	if lastDash[player] and now - lastDash[player] < config.cooldown - 0.1 then return end
	lastDash[player] = now

	character:SetAttribute("Invincible", true)
	if mode == "Slide" then
		setGroup(character, "DashingPlayer")
		task.delay(config.iframes, function()
			if character.Parent then
				setGroup(character, "Default")
			end
		end)
	end
	
	task.delay(config.iframes, function()
		if character.Parent then
			character:SetAttribute("Invincible", false)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	lastDash[player] = nil
end)

