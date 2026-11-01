-- v1.0.0.0.1
--[[
	PetTaming_Util (ModuleScript -> ReplicatedStorage/PetClientModules)

	Shared client helpers: janitor (guaranteed cleanup), easing, frame loops,
	scripted camera Director, sounds.
]]

local RunService        = game:GetService("RunService")
local SoundService      = game:GetService("SoundService")
local Debris            = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TamingModules = ReplicatedStorage:WaitForChild("PetTamingModules")

local Config = require(TamingModules:WaitForChild("PetTaming_Config"))

local Util = {}

-------------------------------------------------------------------- easing

Util.ease = {
	linear   = function(a) return a end,
	inQuad   = function(a) return a * a end,
	outCubic = function(a) return 1 - (1 - a) ^ 3 end,
	inOutQuad = function(a)
		if a < 0.5 then return 2 * a * a end
		return 1 - (-2 * a + 2) ^ 2 / 2
	end,
	outBack = function(a)
		local c1 = 1.70158
		return 1 + (c1 + 1) * (a - 1) ^ 3 + c1 * (a - 1) ^ 2
	end,
}

-------------------------------------------------------------------- janitor

function Util.janitor()
	local j = { items = {} }
	function j:add(item)
		table.insert(self.items, item)
		return item
	end
	function j:clean()
		for i = #self.items, 1, -1 do
			local item = self.items[i]
			local kind = typeof(item)
			if kind == "Instance" then
				pcall(item.Destroy, item)
			elseif kind == "RBXScriptConnection" then
				pcall(item.Disconnect, item)
			elseif kind == "function" then
				pcall(item)
			end
		end
		table.clear(self.items)
	end
	return j
end

-------------------------------------------------------------------- frame loops

-- Yields `duration` seconds, calling update(easedAlpha) every frame.
function Util.animate(duration, update, easing, alive)
	easing = easing or Util.ease.linear
	if duration <= 0 then
		update(1)
		return
	end
	local t = 0
	while t < duration do
		if alive and not alive() then return end
		t += RunService.Heartbeat:Wait()
		update(easing(math.min(t / duration, 1)))
	end
end

-- Yields `seconds`. Returns false if `alive()` turned false (aborted).
function Util.wait(seconds, alive)
	local t = 0
	while t < seconds do
		if alive and not alive() then return false end
		t += RunService.Heartbeat:Wait()
	end
	return alive == nil or alive()
end

-- Particle rate scaled by Config.Quality.
function Util.rate(n)
	return n * math.clamp(Config.Quality, 0.1, 1)
end

function Util.sound(name)
	local id = Config.Sounds[name]
	if type(id) ~= "string" or id == "" then return end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = 0.8
	s.Parent = SoundService
	s:Play()
	Debris:AddItem(s, 8)
end

-------------------------------------------------------------------- shots
-- A shot is a function(t) -> CFrame, t = seconds since the cut.

Util.shots = {}

function Util.shots.static(cf)
	return function() return cf end
end

function Util.shots.dolly(a, b, duration, easing)
	easing = easing or Util.ease.inOutQuad
	return function(t) return a:Lerp(b, easing(math.min(t / duration, 1))) end
end

function Util.shots.orbit(center, radius, height, a0, a1, duration, lookOffset, easing)
	easing = easing or Util.ease.inOutQuad
	return function(t)
		local ang = a0 + (a1 - a0) * easing(math.min(t / duration, 1))
		local pos = center + Vector3.new(math.cos(ang) * radius, height, math.sin(ang) * radius)
		return CFrame.lookAt(pos, center + lookOffset)
	end
end

-------------------------------------------------------------------- Director

local Director = {}
Director.__index = Director
Util.Director = Director

function Director.new(camera)
	local self = setmetatable({}, Director)
	self.camera    = camera
	self.oldType   = camera.CameraType
	self.oldFov    = camera.FieldOfView
	self.shot      = nil
	self.t0        = 0
	self.blendFrom = nil
	self.blendDur  = 0
	self.shakeAmp, self.shakeDur, self.shakeEnd = 0, 1, 0
	self.fovTarget, self.fovSpeed = camera.FieldOfView, 3
	camera.CameraType = Enum.CameraType.Scriptable
	self.conn = RunService.RenderStepped:Connect(function(dt) self:_step(dt) end)
	return self
end

-- Switch shot. blend > 0 eases from the current camera pose.
function Director:cut(shotFn, blend)
	self.blendFrom = (blend and blend > 0) and self.camera.CFrame or nil
	self.blendDur  = blend or 0
	self.shot      = shotFn
	self.t0        = os.clock()
end

function Director:shake(amplitude, duration)
	self.shakeAmp, self.shakeDur, self.shakeEnd = amplitude, math.max(duration, 0.05), os.clock() + duration
end

function Director:fov(target, speed)
	self.fovTarget = target
	self.fovSpeed  = speed or 3
end

function Director:_step(dt)
	if not self.shot then return end
	local now = os.clock()
	local cf = self.shot(now - self.t0)

	if self.blendFrom then
		local a = (now - self.t0) / self.blendDur
		if a >= 1 then
			self.blendFrom = nil
		else
			cf = self.blendFrom:Lerp(cf, Util.ease.inOutQuad(a))
		end
	end

	local left = self.shakeEnd - now
	if left > 0 then
		local k = self.shakeAmp * (left / self.shakeDur)
		cf = cf
			* CFrame.Angles(math.noise(now * 31, 0.5) * k * 0.02, math.noise(now * 29, 7.5) * k * 0.02, 0)
			* CFrame.new(math.noise(now * 37, 3.5) * k * 0.15, math.noise(now * 41, 5.5) * k * 0.15, 0)
	end

	self.camera.CFrame = cf
	self.camera.FieldOfView += (self.fovTarget - self.camera.FieldOfView) * math.clamp(dt * self.fovSpeed, 0, 1)
end

function Director:destroy()
	if self.conn then self.conn:Disconnect() self.conn = nil end
	local old = self.oldType
	self.camera.CameraType = (old == Enum.CameraType.Scriptable) and Enum.CameraType.Custom or old
	self.camera.FieldOfView = self.oldFov
end

return Util