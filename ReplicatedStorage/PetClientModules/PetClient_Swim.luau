-- v1.0.0.1
--[[
	PetClient_Swim (ModuleScript -> ReplicatedStorage/PetClientModules)

	Drives the bobbing / swimming animation of the pet model by advancing a shared time parameter on
	the procedural animator (PetModelBuilder.NewAnimator). Runs on Heartbeat so it stays in
	lock-step with the physics-follow loop.

	CHANGES v1.0.0.1:
	  - Race fix: a model could be tracked twice (two animators fighting each other) because the guard
	    was only set after WaitForChild yielded. `pending` now closes that window.
	  - NewAnimator / Step are pcall'd. A failure used to die silently and the pet just stood still;
	    now it warns ONCE with the model path and the reason, so the real cause shows up in Output.
	  - dt is clamped so a long frame hitch cannot snap the animation.
]]
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Builder = require(ReplicatedStorage:WaitForChild("PetModelBuilder"))

local Swim = {}

Swim.animated = {} -- [model] = { animator, t }

local pending = {} -- [model] = true while waiting for Body / building the animator
local warned  = {} -- [key] = true, so each problem is reported once

local function warnOnce(key, message)
	if warned[key] then return end
	warned[key] = true
	warn("[PetClient_Swim] " .. message)
end

function Swim.trackPet(model)
	if Swim.animated[model] or pending[model] then return end
	pending[model] = true

	-- Hide while spawning so the summon VFX can fade it in.  Matches the
	-- server's 3s "Spawning" flag + PetClient_VFX.fadeInModel.
	if model:GetAttribute("Spawning") then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Transparency = 1
			end
		end
	end

	local body = model:WaitForChild("Body", 10)
	if not body or not model.Parent then
		pending[model] = nil
		warnOnce("body:" .. model.Name, model:GetFullName() .. " has no 'Body' part, swim animation skipped.")
		return
	end
	task.wait()

	local ok, animator = pcall(Builder.NewAnimator, model, false)
	pending[model] = nil
	if not ok or type(animator) ~= "table" or type(animator.Step) ~= "function" then
		warnOnce("anim:" .. model.Name, "NewAnimator failed for " .. model:GetFullName() .. ": " .. tostring(animator))
		return
	end

	Swim.animated[model] = {
		animator = animator,
		t        = 0, -- use 0; deterministic
	}
end

function Swim.start(petsFolder)
	petsFolder.ChildAdded:Connect(function(model)
		if model:IsA("Model") then task.spawn(Swim.trackPet, model) end
	end)
	for _, model in petsFolder:GetChildren() do
		if model:IsA("Model") then task.spawn(Swim.trackPet, model) end
	end

	RunService.Heartbeat:Connect(function(dt)
		dt = math.min(dt, 0.1)
		for model, st in Swim.animated do
			if not model.Parent then
				Swim.animated[model] = nil
				continue
			end
			local speed = model:GetAttribute("MoveSpeed") or 0
			local dash  = model:GetAttribute("DashBlend")  or 0
			st.t += dt * (1 + math.clamp(speed / 25, 0, 1.2) + dash * 1.2)
			local ok, err = pcall(st.animator.Step, st.t, 1 + math.clamp(speed / 40, 0, 0.5) + dash * 0.6)
			if not ok then
				warnOnce("step:" .. model.Name, "animator.Step errored for " .. model:GetFullName() .. ": " .. tostring(err))
				Swim.animated[model] = nil -- stop retrying a broken animator every frame
			end
		end
	end)
end

return Swim