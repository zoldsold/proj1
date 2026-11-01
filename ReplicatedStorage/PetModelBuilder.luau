--[[
	PetModelBuilder (ModuleScript -> ReplicatedStorage)

	Builds pet out of plain ellipsoid parts joined by Motor6Ds, so system works with no uploaded assets.
	Used by the server (the real pet) and by inventory UI (viewport previews).

	To use real mesh model later: replace Builder.Build so it returns a
	Model whose PrimaryPart is named "Body". Keep the "PetAttach" Attachment
	and the Motor6D swim attributes if you still want swim animation.

	Front of pet is -Z (Roblox convention).

	WHALE MESH SWAP:
	Set WHALE_MESH_ID to your uploaded rbxassetid to use the real whale.obj mesh.
	Leave it as "" to use the default ellipsoid parts.
]]
-- v1.0.0.0.1
local PetConfig = require(script.Parent:WaitForChild("PetConfig"))

local Builder = {}

local NEON = Enum.Material.Neon

-- Set this to your uploaded whale mesh asset ID, e.g. "rbxassetid://12345678"
-- Leave as "" to use procedural ellipsoid parts instead.
local WHALE_MESH_ID = ""

-------------------------------------------------------------------- helpers

local function helpers(model, s)
	local function C(x, y, z)
		return CFrame.new(x * s, y * s, z * s)
	end

	local function P(name, sx, sy, sz, color, material)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = Vector3.new(sx, sy, sz) * s
		part.Color = color
		part.Material = material or Enum.Material.SmoothPlastic
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
		part.Parent = model
		return part
	end

	-- c0 = pivot in parent's space, c1 = pivot in child's space.
	-- swim = { Axis, Amp (degrees), Speed, Phase } makes joint wag when animated.
	local function J(parent, child, c0, c1, swim)
		local motor = Instance.new("Motor6D")
		motor.Name = child.Name
		motor.Part0 = parent
		motor.Part1 = child
		motor.C0 = c0
		motor.C1 = c1 or CFrame.new()
		if swim then
			for key, value in swim do
				motor:SetAttribute(key, value)
			end
		end
		motor.Parent = parent
		return motor
	end

	return C, P, J
end

-------------------------------------------------------------------- catfish

local function buildCatfish(model, s, col)
	local C, P, J = helpers(model, s)

	local body = P("Body", 2.2, 2.0, 5.0, col.Body)
	model.PrimaryPart = body

	local head = P("Head", 2.8, 1.5, 2.6, col.Body)
	J(body, head, C(0, -0.15, -2.3))

	local belly = P("Belly", 1.8, 0.9, 3.6, col.Belly)
	J(body, belly, C(0, -0.65, -0.3))

	-- glowing eyes
	for _, side in { -1, 1 } do
		local eye = P(side < 0 and "EyeL" or "EyeR", 0.42, 0.42, 0.42, col.Glow, NEON)
		J(body, eye, C(side * 1.0, 0.3, -2.6))
	end

	-- barbels (whiskers), two pairs, wiggling
	local barbels = {
		{ name = "BarbelA", x = 0.9, y = -0.25, len = 3.4, yaw = 24, phase = 0 },
		{ name = "BarbelB", x = 0.7, y = -0.55, len = 2.0, yaw = 50, phase = 1.3 },
	}
	for _, d in barbels do
		for _, side in { -1, 1 } do
			local b = P(d.name .. (side < 0 and "L" or "R"), 0.13, 0.13, d.len, col.Belly)
			J(
				body,
				b,
				C(side * d.x, d.y, -3.1) * CFrame.Angles(0, math.rad(-side * d.yaw), 0),
				C(0, 0, d.len / 2),
				{ Axis = "Y", Amp = 14, Speed = 3.2, Phase = d.phase + (side < 0 and 0.8 or 0) }
			)
		end
	end

	-- pectoral fins
	for _, side in { -1, 1 } do
		local fin = P(side < 0 and "FinL" or "FinR", 1.5, 0.22, 1.0, col.Body)
		J(
			body,
			fin,
			C(side * 1.0, -0.35, -1.4) * CFrame.Angles(0, 0, math.rad(-side * 15)),
			C(-side * 0.75, 0, 0),
			{ Axis = "Z", Amp = 18 * side, Speed = 4, Phase = 0 }
		)
	end

	local dorsal = P("Dorsal", 0.2, 0.9, 1.0, col.Body)
	J(body, dorsal, C(0, 1.15, -0.3) * CFrame.Angles(math.rad(20), 0, 0))

	-- glowing spine
	local spine = P("Spine", 0.3, 0.14, 2.4, col.Glow, NEON)
	J(body, spine, C(0, 1.0, 0.1))

	-- tail: two chained joints so it whips
	local tailBase = P("TailBase", 1.2, 1.2, 2.4, col.Body)
	J(body, tailBase, C(0, 0, 2.1), C(0, 0, -1.2), { Axis = "Y", Amp = 10, Speed = 5, Phase = 0 })
	local tailFin = P("TailFin", 0.3, 2.2, 1.8, col.Body)
	J(tailBase, tailFin, C(0, 0, 1.1), C(0, 0, -0.9), { Axis = "Y", Amp = 20, Speed = 5, Phase = 0.8 })
end

-------------------------------------------------------------------- whale (Kun)

local function buildWhale(model, s, col)
	local C, P, J = helpers(model, s)

	-- Body: use real mesh if WHALE_MESH_ID is set, else ellipsoid part
	local body
	if WHALE_MESH_ID ~= "" then
		body = Instance.new("Part")
		body.Name = "Body"
		body.Size = Vector3.new(4.4, 4.0, 10.0) * s
		body.Color = col.Body
		body.Material = Enum.Material.SmoothPlastic
		body.CanCollide = false
		body.CanQuery = false
		body.CanTouch = false
		body.Massless = true
		body.TopSurface = Enum.SurfaceType.Smooth
		body.BottomSurface = Enum.SurfaceType.Smooth
		body.Parent = model

		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.FileMesh
		mesh.MeshId = WHALE_MESH_ID
		-- Scale the mesh to match the part size (tune X/Y/Z if mesh proportions differ)
		mesh.Scale = Vector3.new(s, s, s)
		mesh.Parent = body
	else
		body = P("Body", 4.4, 4.0, 10.0, col.Body)
	end
	model.PrimaryPart = body

	local snout = P("Snout", 3.8, 3.2, 3.6, col.Body)
	J(body, snout, C(0, -0.1, -4.0))

	local belly = P("Belly", 3.0, 1.6, 7.5, col.Belly)
	J(body, belly, C(0, -1.45, -0.4))

	-- lower jaw, slowly working: the "devouring" mouth
	local jaw = P("Jaw", 3.2, 1.2, 4.6, col.Belly)
	J(
		body,
		jaw,
		C(0, -1.5, -1.2) * CFrame.Angles(math.rad(-5), 0, 0),
		C(0, 0, 2.3),
		{ Axis = "X", Amp = 5, Speed = 1.6, Phase = 0 }
	)

	for _, side in { -1, 1 } do
		local eye = P(side < 0 and "EyeL" or "EyeR", 0.55, 0.55, 0.55, col.Glow, NEON)
		J(body, eye, C(side * 1.75, 0.4, -4.2))
	end

	local dorsal = P("Dorsal", 0.35, 1.8, 1.6, col.Body)
	J(body, dorsal, C(0, 2.0, 2.4) * CFrame.Angles(math.rad(25), 0, 0))

	-- glowing markings: spine + two flank lines
	local spine = P("Spine", 0.35, 0.16, 3.6, col.Glow, NEON)
	J(body, spine, C(0, 1.95, -0.5))
	for _, side in { -1, 1 } do
		local line = P(side < 0 and "FlankL" or "FlankR", 0.14, 0.14, 3.6, col.Glow, NEON)
		J(body, line, C(side * 2.1, 0.5, -0.3))
	end

	-- flippers
	for _, side in { -1, 1 } do
		local flipper = P(side < 0 and "FlipperL" or "FlipperR", 2.4, 0.3, 1.2, col.Body)
		J(
			body,
			flipper,
			C(side * 1.7, -1.1, -1.8) * CFrame.Angles(0, 0, math.rad(-side * 20)),
			C(-side * 1.2, 0, 0),
			{ Axis = "Z", Amp = 14 * side, Speed = 1.8, Phase = 0.5 }
		)
	end

	-- tail: whales pitch up/down (X axis), unlike catfish
	local tail = P("TailStock", 2.4, 2.2, 4.8, col.Body)
	J(body, tail, C(0, 0, 4.0), C(0, 0, -2.4), { Axis = "X", Amp = 8, Speed = 2.2, Phase = 0 })
	local fluke = P("Fluke", 6.4, 0.36, 2.2, col.Body)
	J(tail, fluke, C(0, 0, 2.3), C(0, 0, -1.0), { Axis = "X", Amp = 16, Speed = 2.2, Phase = 0.9 })
end

-------------------------------------------------------------------- public API

-- Positions every part from its joints. Needed once after building, and every
-- frame for viewport previews (ViewportFrame does not simulate joints).
function Builder.Solve(model)
	for _, motor in model:GetDescendants() do
		if motor:IsA("Motor6D") and motor.Part0 and motor.Part1 then
			motor.Part1.CFrame = motor.Part0.CFrame * motor.C0 * motor.Transform * motor.C1:Inverse()
		end
	end
end

-- preview = true  -> anchored, no lights/particles (for ViewportFrames)
-- preview = false -> real, physics-following pet
function Builder.Build(speciesId, stage, preview)
	local cfg = PetConfig.GetStage(speciesId, stage)
	assert(cfg, "Unknown pet species/stage: " .. tostring(speciesId) .. " " .. tostring(stage))

	local model = Instance.new("Model")
	model.Name = "Pet"

	if cfg.Form == "Whale" then
		buildWhale(model, cfg.Scale, cfg.Colors)
	else
		buildCatfish(model, cfg.Scale, cfg.Colors)
	end

	model:SetAttribute("SpeciesId", speciesId)
	model:SetAttribute("Stage", stage)
	Builder.Solve(model)

	local body = model.PrimaryPart

	if preview then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end
		return model
	end

	local attach = Instance.new("Attachment")
	attach.Name = "PetAttach"
	attach.Parent = body

	-- near-zero mass so following owner never tugs owner around
	body.CustomPhysicalProperties = PhysicalProperties.new(0.01, 0.3, 0, 1, 1)

	local light = Instance.new("PointLight")
	light.Name = "PetLight"
	light.Color = cfg.Colors.Glow
	light.Brightness = cfg.Light
	light.Range = 8 + 14 * cfg.Scale
	light.Parent = body

	if cfg.Aura then
		local aura = Instance.new("ParticleEmitter")
		aura.Name = "Aura"
		aura.Color = ColorSequence.new(cfg.Colors.Glow)
		aura.LightEmission = 1
		aura.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.4 + cfg.Scale * 0.5),
			NumberSequenceKeypoint.new(1, 0),
		})
		aura.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
		aura.Lifetime = NumberRange.new(1.2, 2.2)
		aura.Speed = NumberRange.new(0.5, 2)
		aura.SpreadAngle = Vector2.new(180, 180)
		aura.Rate = 8 + 10 * cfg.Scale
		aura.Parent = body
	end

	return model
end

-- Drives swim animation. Call animator.Step(time, amplitudeMultiplier) every frame.
-- manual = true for ViewportFrames (positions parts itself instead of relying on physics).
function Builder.NewAnimator(model, manual)
	local motors = {}
	for _, motor in model:GetDescendants() do
		if motor:IsA("Motor6D") and motor:GetAttribute("Axis") then
			table.insert(motors, {
				motor = motor,
				axis  = motor:GetAttribute("Axis"),
				amp   = math.rad(motor:GetAttribute("Amp")),
				speed = motor:GetAttribute("Speed"),
				phase = motor:GetAttribute("Phase") or 0,
			})
		end
	end

	local animator = {}

	function animator.Step(t, ampMul)
		for _, d in motors do
			local a = d.amp * ampMul * math.sin(t * d.speed + d.phase)
			if d.axis == "X" then
				d.motor.Transform = CFrame.Angles(a, 0, 0)
			elseif d.axis == "Y" then
				d.motor.Transform = CFrame.Angles(0, a, 0)
			else
				d.motor.Transform = CFrame.Angles(0, 0, a) 
			end
		end
		if manual then
			Builder.Solve(model)
		end
	end

	return animator
end

return Builder