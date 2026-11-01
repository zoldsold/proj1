--!strict
--[[ MagicCircleService v1.0.0.1
	Location: ServerScriptService/MagicCircleService (ModuleScript)
	Server decides WHEN/WHERE; clients render. Sends only tiny messages to
	nearby players, so cost per circle is O(players in server), not O(world).

	API:
		local id = Service.Start(tamer, petModelOrPartOrVector3)
		Service.End(id, success: boolean)
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("MagicCircleConfig"))

local remote = ReplicatedStorage:FindFirstChild(Config.RemoteName) :: RemoteEvent?
if not remote then
	local created = Instance.new("RemoteEvent")
	created.Name = Config.RemoteName
	created.Parent = ReplicatedStorage
	remote = created
end
local remoteEvent = remote :: RemoteEvent

local sessions: { [number]: { Player } } = {}
local nextId = 0

local Service = {}

local function resolvePosition(target: Instance | Vector3): Vector3?
	if typeof(target) == "Instance" then
		if target:IsA("Model") then
			return target:GetPivot().Position
		elseif target:IsA("BasePart") then
			return target.Position
		end
		return nil
	end
	return target
end

function Service.End(id: number, success: boolean)
	local recipients = sessions[id]
	if not recipients then
		return
	end
	sessions[id] = nil
	for _, player in recipients do
		if player.Parent then
			remoteEvent:FireClient(player, "End", id, success)
		end
	end
end

function Service.Start(tamer: Player, target: Instance | Vector3, duration: number?): number?
	local pos = resolvePosition(target)
	if not pos then
		return nil
	end
	local length = duration or 3

	local recipients: { Player } = {}
	for _, player in Players:GetPlayers() do
		if player == tamer then
			table.insert(recipients, player)
		else
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root and (root.Position - pos).Magnitude <= Config.MaxViewDistance then
				table.insert(recipients, player)
			end
		end
	end

	nextId += 1
	local id = nextId
	sessions[id] = recipients
	for _, player in recipients do
		remoteEvent:FireClient(player, "Start", id, pos, length)
	end

	task.delay(Config.SessionTimeout, function()
		Service.End(id, false) -- no-op if already ended
	end)
	return id
end

return Service