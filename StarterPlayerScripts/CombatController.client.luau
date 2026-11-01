local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Player = Players.LocalPlayer
local CombatRemote = ReplicatedStorage:WaitForChild("CombatRemote")

local CombatClient = {}
CombatClient.__index = CombatClient

function CombatClient.new()
	local self = setmetatable({}, CombatClient)
	
	self.Player = Player
	self.Character = nil
	self.Attacking = false
	self.Blocking = false

	self:_connectCharacter()
	self:_bindInputs()
	
	return self
end

function CombatClient:_connectCharacter()
	local function onCharacterAdded(Character)
		self.Character = Character
		self.Blocking = false
		self.Attacking = false
	end
	
	if self.Player.Character then
		onCharacterAdded(self.Player.Character)
	end
	
	self.Player.CharacterAdded:Connect(onCharacterAdded)
end

function CombatClient:_bindInputs()
	UserInputService.InputBegan:Connect(function(i,gp)
	
		if gp then return end
		
		if i.UserInputType == Enum.UserInputType.MouseButton1 then
			CombatRemote:FireServer("Attack")
		elseif i.KeyCode == Enum.KeyCode.F then
			if self.Blocking then
				self.Blocking = true
				CombatRemote:FireServer("Block", true)
			end
		end
	end)
	
	UserInputService.InputEnded:Connect(function(i,gp)
		if gp then return end
		
		if i.KeyCode == Enum.KeyCode.F then
			if self.Blocking then
				self.Blocking = false
				CombatRemote:FireServer("Block", false)
			end
		end
	end)
end

return CombatClient.new()