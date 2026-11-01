--!strict
--[[ MagicCircleController v1.0.0.2
	Location: StarterPlayer/StarterPlayerScripts (LocalScript)
	Pooled, client-only rendering. A circle is one invisible Part + SurfaceGui
	with two counter-rotating image layers. Zero server cost, zero replication.

	v1.0.0.2: waits at most 5s for the remote. If nothing creates it (the old circle system is
	unused), the script exits quietly instead of printing 'Infinite yield possible' forever.
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("MagicCircleConfig"))
local remoteInstance = ReplicatedStorage:WaitForChild(Config.RemoteName, 5)
if not remoteInstance or not remoteInstance:IsA("RemoteEvent") then
	return -- old circle system not in use: no remote on the server, nothing to render
end
local remote: RemoteEvent = remoteInstance

if Config.ImageId == "rbxassetid://92159544437437" then
	warn("[MagicCircle v1.0.0.2] Set Config.ImageId to your uploaded image.")
end

local INTRO = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FADE_IN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SUCCESS_OUT = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local FAIL_OUT = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

type Circle = {
	part: Part,
	outer: ImageLabel,
	inner: ImageLabel,
	tweens: { Tween },
	spins: { Tween },
	token: number,
}

local container = Instance.new("Folder")
container.Name = "MagicCircles"
container.Parent = Workspace

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local pool: { Circle } = {}
local active: { [number]: Circle } = {}
local inUse = 0

local function makeLabel(parent: Instance): ImageLabel
	local label = Instance.new("ImageLabel")
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.fromScale(0, 0)
	label.Image = Config.ImageId
	label.ImageTransparency = 1
	label.Parent = parent
	return label
end

local function build(): Circle
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(Config.Diameter, 0.05, Config.Diameter)

	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(512, 512)
	gui.LightInfluence = 0
	gui.Brightness = Config.Brightness
	gui.Parent = part

	return {
		part = part,
		outer = makeLabel(gui),
		inner = makeLabel(gui),
		tweens = {},
		spins = {},
		token = 0,
	}
end

local function play(list: { Tween }, inst: Instance, info: TweenInfo, goal: { [string]: any })
	local tween = TweenService:Create(inst, info, goal)
	table.insert(list, tween)
	tween:Play()
end

local function cancelAll(list: { Tween })
	for _, tween in list do
		tween:Cancel()
	end
	table.clear(list)
end

local function release(circle: Circle)
	cancelAll(circle.tweens)
	cancelAll(circle.spins)
	circle.part.Parent = nil
	inUse -= 1
	if #pool < Config.MaxPool then
		table.insert(pool, circle)
	else
		circle.part:Destroy()
	end
end

local function onEnd(id: number, success: boolean)
	local circle = active[id]
	if not circle then
		return
	end
	active[id] = nil
	local token = circle.token
	cancelAll(circle.tweens)

	local info = if success then SUCCESS_OUT else FAIL_OUT
	local outerScale = if success then 1.3 else 0
	local innerScale = Config.InnerScale * (if success then 1.3 else 0)
	local outerGoal: { [string]: any } = { Size = UDim2.fromScale(outerScale, outerScale), ImageTransparency = 1 }
	local innerGoal: { [string]: any } = { Size = UDim2.fromScale(innerScale, innerScale), ImageTransparency = 1 }
	if not success then
		outerGoal.ImageColor3 = Config.FailColor
		innerGoal.ImageColor3 = Config.FailColor
	end
	play(circle.tweens, circle.outer, info, outerGoal)
	play(circle.tweens, circle.inner, info, innerGoal)

	task.delay(info.Time + 0.05, function()
		if circle.token == token then
			release(circle)
		end
	end)
end

local function onStart(id: number, pos: Vector3, duration: number)
	if active[id] or inUse >= Config.MaxActive then
		return
	end
	local circle = table.remove(pool) or build()
	inUse += 1
	circle.token += 1
	local token = circle.token
	active[id] = circle

	-- Snap to ground (ignore own character + our own circles)
	local filter: { Instance } = { container }
	local character = Players.LocalPlayer.Character
	if character then
		table.insert(filter, character)
	end
	rayParams.FilterDescendantsInstances = filter
	local hit = Workspace:Raycast(
		pos + Vector3.new(0, Config.GroundRayUp, 0),
		Vector3.new(0, -(Config.GroundRayUp + Config.GroundRayDown), 0),
		rayParams
	)
	local y = (if hit then hit.Position.Y else pos.Y) + Config.GroundOffset
	circle.part.CFrame = CFrame.new(pos.X, y, pos.Z)

	-- Reset visual state (pooled circles carry old values)
	for _, label in { circle.outer, circle.inner } do
		label.Size = UDim2.fromScale(0, 0)
		label.ImageTransparency = 1
		label.ImageColor3 = Color3.new(1, 1, 1)
		label.Rotation = 0
	end
	circle.part.Parent = container

	local inner = Config.InnerScale
	play(circle.tweens, circle.outer, INTRO, { Size = UDim2.fromScale(1, 1) })
	play(circle.tweens, circle.inner, INTRO, { Size = UDim2.fromScale(inner, inner) })
	play(circle.tweens, circle.outer, FADE_IN, { ImageTransparency = 0 })
	play(circle.tweens, circle.inner, FADE_IN, { ImageTransparency = 0 })

	local total = duration + Config.Grace
	local spinInfo = TweenInfo.new(total, Enum.EasingStyle.Linear)
	play(circle.spins, circle.outer, spinInfo, { Rotation = Config.SpinSpeed * total })
	play(circle.spins, circle.inner, spinInfo, { Rotation = -Config.SpinSpeed * 1.5 * total })

	-- Safety net: never leave a circle stuck if End never arrives
	task.delay(total + 1, function()
		if circle.token == token and active[id] == circle then
			onEnd(id, false)
		end
	end)
end

remote.OnClientEvent:Connect(function(action: string, id: number, a: any, b: any)
	if action == "Start" then
		onStart(id, a :: Vector3, b :: number)
	elseif action == "End" then
		onEnd(id, a :: boolean)
	end
end)