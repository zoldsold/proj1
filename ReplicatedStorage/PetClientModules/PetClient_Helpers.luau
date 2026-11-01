-- PetClient_Helpers (ModuleScript -> ReplicatedStorage/PetClientModules)
-- Shared client-side helpers for pet rendering and VFX.
-- Provides:
--   - stageCfgOf(model)  : fetch a PetConfig stage by SpeciesId + Stage
--   - groundBelow(pos, petsFolder, ignoreList) : raycast down onto world terrain
--   - petBody(userId, petsFolder) : find a pet's Body BasePart
--   - fadeInModel(model, dur)     : tween a pet from invisible to visible
--   - timeline(dur, fn)           : run fn(alpha) every frame for dur seconds
--   - ease(a, style, dir)         : normalized easing (0..1 in, 0..1 out)
--   - nextNumber(a, b)            : random float in [a, b]
--   - Easing constants: SINE, QUAD, QUART + IN, OUT, INOUT
-- v1.0.0.0.1
local TweenService      = game:GetService("TweenService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PetConfig = require(ReplicatedStorage:WaitForChild("PetConfig"))

local Helpers = {}

------------------------------------------------------------------ easing constants

-- TweenInfo easing styles
Helpers.SINE  = Enum.EasingStyle.Sine
Helpers.QUAD  = Enum.EasingStyle.Quad
Helpers.QUART = Enum.EasingStyle.Quart

-- Easing directions
-- FIX: INOUT was previously aliased to Enum.EasingDirection.Out.
Helpers.IN    = Enum.EasingDirection.In
Helpers.OUT   = Enum.EasingDirection.Out
Helpers.INOUT = Enum.EasingDirection.InOut

------------------------------------------------------------------ stage lookup

-- Return the stage config for a pet model, or nil if it can't be resolved.
-- Reads the model's "SpeciesId" and "Stage" attributes and looks them up
-- in the shared PetConfig table.
function Helpers.stageCfgOf(model)
	if not model or not model.Parent then return nil end

	local speciesId = model:GetAttribute("SpeciesId")
	local stage     = model:GetAttribute("Stage")
	if not speciesId or not stage then return nil end

	return PetConfig.GetStage(speciesId, stage)
end

------------------------------------------------------------------ ground raycast

-- Raycast down from `position` to find the world surface (terrain or BasePart).
--
-- Parameters:
--   position      - start point (Vector3)
--   petsFolder    - (unused at runtime, kept for API stability)
--   ignoreList    - optional table of Instances to exclude from the raycast
--
-- Returns:
--   A Vector3 position on the ground, or `position` itself on failure.
--   Always returns a valid Vector3 — never nil.
function Helpers.groundBelow(position, petsFolder, ignoreList)
	if typeof(position) ~= "Vector3" then
		position = Vector3.new(0, 0, 0)
	end

	-- Raycast downward. We start a little above `position` to avoid
	-- immediate self-hits when the position is flush with the ground.
	local rayOrigin = position + Vector3.new(0, 0.5, 0)
	local rayDirection = Vector3.new(0, -500, 0)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = false
	params.FilterDescendantsInstances = ignoreList or {}

	local raycast = workspace:Raycast(rayOrigin, rayDirection, params)
	if raycast and raycast.Position then
		return raycast.Position
	end

	-- Fallback: nothing below, return position unchanged
	return position
end

------------------------------------------------------------------ pet lookup

-- Return the pet model's "Body" BasePart for a user id string, or nil.
function Helpers.petBody(userId, petsFolder)
	if not petsFolder then
		petsFolder = workspace:FindFirstChild("Pets")
	end
	if not petsFolder then return nil end

	local model = petsFolder:FindFirstChild(tostring(userId))
	if not model then return nil end

	local body = model:FindFirstChild("Body")
	if body and body:IsA("BasePart") then return body end
	return nil
end

------------------------------------------------------------------ timeline + ease

-- Run `fn(alpha)` every frame for `duration` seconds.  alpha is 0..1.
-- Yields until finished so callers can sequence cutscene beats.
function Helpers.timeline(duration, fn)
	local elapsed = 0
	duration = math.max(tonumber(duration) or 0, 0)

	if duration <= 0 then
		fn(1)
		return
	end

	while elapsed < duration do
		elapsed += RunService.RenderStepped:Wait()
		fn(math.clamp(elapsed / duration, 0, 1))
	end

	fn(1)
end

-- Manual easing: raw 0..1 alpha + EasingStyle + EasingDirection -> eased 0..1.
-- Only the styles the pet modules actually use are implemented.
local POW = {
	[Enum.EasingStyle.Linear] = 1,
	[Enum.EasingStyle.Quad]   = 2,
	[Enum.EasingStyle.Cubic]  = 3,
	[Enum.EasingStyle.Quart]  = 4,
	[Enum.EasingStyle.Quint]  = 5,
}

-- Ease-out shape for a given style: fast start, slow finish.
local function easeOutShape(a, style)
	if style == Enum.EasingStyle.Sine then
		return math.sin((a * math.pi) / 2)
	end
	return a ^ (POW[style] or 2)
end

function Helpers.ease(a, style, dir)
	a = math.clamp(tonumber(a) or 0, 0, 1)

	if dir == Enum.EasingDirection.In then
		-- Mirror the out curve horizontally.
		return 1 - easeOutShape(1 - a, style)
	elseif dir == Enum.EasingDirection.InOut then
		if a < 0.5 then
			return (1 - easeOutShape(1 - a * 2, style)) * 0.5
		end
		return 0.5 + easeOutShape(a * 2 - 1, style) * 0.5
	end

	return easeOutShape(a, style) -- Default / Out
end

------------------------------------------------------------------ misc helpers

-- Random float in [a, b].
function Helpers.nextNumber(a, b)
	return a + math.random() * (b - a)
end

-- Smooth step: 3t^2 - 2t^3, clamped to [0, 1]
function Helpers.smoothStep(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Fade a pet model in from fully transparent.
function Helpers.fadeInModel(model, duration)
	duration = tonumber(duration) or 0.9
	local parts = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Transparency = 1
			table.insert(parts, d)
		end
	end

	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, p in ipairs(parts) do
		local target = p:GetAttribute("BaseTransparency")
		TweenService:Create(p, info, { Transparency = target or 0 }):Play()
	end
end

return Helpers