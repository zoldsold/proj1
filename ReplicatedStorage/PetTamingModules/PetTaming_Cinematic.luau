-- v1.0.0.3
-- CHANGES v1.0.0.3: every effect constant (grade, depth of field, camera framing/FOV/elevation, thunder timing,
--   flash, shake) is read from PetTamingConfig.Effects. Lightning arcs (lines inside the circles) removed.
-- CHANGES v1.0.0.2: load-time check that PetTaming_Circles exposes the full API; if not, the ceremony
--   skips cleanly (server is released) and Output names the missing functions instead of 'attempt to call a nil value'.
-- CHANGES v1.0.0.1:
--   * Camera: shots for the rising circles are sized from the circle stack (radius x height x FOV x
--     aspect) so the whole rise is always in frame, for every tier. Storm shot frames the cloud too.
--   * Fixed spacing: the wild pet glides to Taming.PetDistance (5 studs) in front of the player.
--   * Nickname: the save is retried once and a failure is reported instead of silently showing the
--     typed name as if it had been stored.
--   * Cinematic: depth of field, climbing filaments between circles, thunder light, richer bursts.
--[[
	PetTaming_Cinema (ModuleScript -> ReplicatedStorage/PetClientModules)

	Taming ceremony director. Plays on the ACTUAL wild model; the player is
	anchored by the server. Outcome is decided by the server and arrives in the
	TameBegin payload; the first three beats are identical so it stays a surprise.

	  Shared   Intro -> Bloom (circle 1) -> Suspense
	  Failure  Crack -> Shatter (server: damage) -> Aftermath -> server concusses
	  Success  Rise (circle 2) -> Settle -> Recall (circle 3 + storm) -> Dissolve
	           -> Stat reveal -> Name your pet -> Reaction -> End prompt -> TameFinish

	API: Cinema.play(payload) / Cinema.abort(id) / Cinema.dizzy(sec) / Cinema.toast(msg)
	All durations come from PetTamingConfig.Timeline.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Lighting          = game:GetService("Lighting")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")
local Debris            = game:GetService("Debris")
local TamingModules = ReplicatedStorage:WaitForChild("PetTamingModules")

local Config    = require(TamingModules:WaitForChild("PetTaming_Config"))
local Stats     = require(TamingModules:WaitForChild("PetTaming_Stats"))
local PetConfig = require(ReplicatedStorage:WaitForChild("PetConfig"))
local PetEvent  = ReplicatedStorage:WaitForChild("PetEvent")

local Util    = require(TamingModules:WaitForChild("PetTaming_Util"))
local Circles = require(TamingModules:WaitForChild("PetTaming_Circles"))
local UI      = require(TamingModules:WaitForChild("PetTaming_UI"))

local T, CC, COL, CAP = Config.Timeline, Config.Circle, Config.Colors, Config.Captions
local FX  = Config.Effects
local CAM, TH = FX and FX.Camera, FX and FX.Thunder
local ease, shots = Util.ease, Util.shots

-- Fail loudly and early if PetTaming_Circles is stale or was pasted into the wrong script.
local circlesProblem
do
	local missing = {}
	for _, name in { "new", "motes", "links", "burst", "crack", "storm" } do
		if type(Circles[name]) ~= "function" then table.insert(missing, name) end
	end
	if not FX then
		circlesProblem = "[PetTaming_Cinema] PetTamingConfig.Effects is missing. Paste PetTaming_Config.lua v1.0.0.2."
	elseif #missing > 0 then
		local keys = {}
		for k in Circles do table.insert(keys, tostring(k)) end
		circlesProblem = string.format(
			"[PetTaming_Cinema] PetTamingModules.PetTaming_Circles is missing: %s (it exposes: %s). Paste PetTaming_Circles.lua v1.0.0.2 into that exact script.",
			table.concat(missing, ", "), table.concat(keys, ", "))
	end
end
local player = Players.LocalPlayer

local Cinema = {}
local active = nil
local dizzyActive = false

-------------------------------------------------------------------- helpers

local function groundY(char, wild, at)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = char and { char, wild } or { wild }
	local hit = Workspace:Raycast(at + Vector3.new(0, 6, 0), Vector3.new(0, -40, 0), rp)
	return hit and hit.Position.Y or nil
end

-- Sky darkening + glow + depth of field. k = 0 (normal) .. 1 (storm). Values: PetTamingConfig.Effects.
local function makeGrade(J, camera, focusPos)
	local G, D = FX.Grade, FX.DepthOfField
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name, cc.Parent = "TameCinemaCC", Lighting
	local bloom = Instance.new("BloomEffect")
	bloom.Name, bloom.Size, bloom.Threshold, bloom.Parent = "TameCinemaBloom", G.BloomSize, G.BloomThreshold, Lighting
	J:add(cc)
	J:add(bloom)

	local dof
	if D.Enabled and Config.Quality >= D.MinQuality then
		dof = Instance.new("DepthOfFieldEffect")
		dof.Name, dof.FarIntensity, dof.NearIntensity, dof.InFocusRadius, dof.FocusDistance = "TameCinemaDoF", 0, 0, D.InFocusRadius, 40
		dof.Parent = Lighting
		J:add(dof)
		-- keep the circles in focus wherever the camera goes
		J:add(RunService.Heartbeat:Connect(function(dt)
			local d = (camera.CFrame.Position - focusPos).Magnitude
			dof.FocusDistance += (d - dof.FocusDistance) * math.clamp(dt * D.FocusSpeed, 0, 1)
		end))
	end

	local g = {}
	function g.set(k)
		cc.Brightness = G.Brightness * k
		cc.Contrast = G.Contrast * k
		cc.Saturation = G.Saturation * k
		cc.TintColor = Color3.new(1, 1, 1):Lerp(G.Tint, k)
		bloom.Intensity = G.BloomBase + G.BloomGain * k
		if dof then dof.FarIntensity = D.FarIntensity * k end
	end
	g.set(0)
	return g
end

-- Drives the (anchored, otherwise static) wild model: glide to its ceremony spot (restAt), turn to
-- face the player, idle bob, shiver, scripted reactions. Restores its original pose on cleanup.
local function newPuppet(model, J, lookAtPos, restAt)
	local original = model:GetPivot()
	local goal = restAt or original.Position
	local dir = Vector3.new(lookAtPos.X - goal.X, 0, lookAtPos.Z - goal.Z)
	local rotGoal = (dir.Magnitude > 0.1) and CFrame.lookAt(Vector3.zero, dir) or original.Rotation

	local p = { t = 0, tense = 0, pos = original.Position, rot = original.Rotation }
	J:add(RunService.Heartbeat:Connect(function(dt)
		if not model.Parent then return end
		p.t += dt
		p.pos = p.pos:Lerp(goal, 1 - math.exp(-dt * 2.2))
		p.rot = p.rot:Lerp(rotGoal, 1 - math.exp(-dt * 3.5))
		local cf = CFrame.new(p.pos) * p.rot * CFrame.new(0, math.sin(p.t * 1.8) * 0.25, 0)
		if p.tense > 0 then
			cf = cf * CFrame.new((math.random() - 0.5) * 0.12 * p.tense, 0, (math.random() - 0.5) * 0.12 * p.tense)
		end
		if p.extra then cf = cf * p.extra(p.t - p.extraT0) end
		model:PivotTo(cf)
	end))
	J:add(function()
		if model.Parent then model:PivotTo(original) end
	end)

	function p:react(duration, fn)
		self.extra, self.extraT0 = fn, self.t
		task.delay(duration, function() if self.extra == fn then self.extra = nil end end)
	end
	return p
end

local function happy(t) -- hop + full spin
	local hop = math.abs(math.sin(t * math.pi * 1.6)) * 2.2 * math.max(0, 1 - t / 2.6)
	local spin = ease.outCubic(math.min(t / 1.6, 1)) * math.pi * 2
	return CFrame.new(0, hop, 0) * CFrame.Angles(0, spin, 0)
end

local function recoil(t) -- knocked back by the shattering seal
	local k = ease.outCubic(math.min(t / 0.3, 1))
	return CFrame.new(0, 0, 2.8 * k) * CFrame.Angles(-0.25 * (1 - math.min(t / 1.2, 1)), 0, 0)
end

local function fadeInFromBlack()
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then return end
	local g = Instance.new("ScreenGui")
	g.Name, g.IgnoreGuiInset, g.ResetOnSpawn, g.DisplayOrder, g.Parent = "TameFadeIn", true, false, 200, pg
	local f = Instance.new("Frame")
	f.BackgroundColor3, f.BorderSizePixel, f.Size, f.Parent = Color3.new(0, 0, 0), 0, UDim2.fromScale(1, 1), g
	TweenService:Create(f, TweenInfo.new(0.7), { BackgroundTransparency = 1 }):Play()
	Debris:AddItem(g, 1)
end

-------------------------------------------------------------------- ceremony

function Cinema.play(payload)
	if active or typeof(payload) ~= "table" then return end

	local wild = payload.WildModel
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local body = wild and wild.Parent and (wild.PrimaryPart or wild:FindFirstChildWhichIsA("BasePart", true))
	local success = payload.Outcome == "success"

	if circlesProblem then warn(circlesProblem) end
	if circlesProblem or not (root and body) then -- cannot play: let the server move on
		if success then PetEvent:FireServer("TameFinish") end
		return
	end

	local J = Util.janitor()
	local ctx = { id = payload.Id, aborted = false }
	ctx.alive = function() return not ctx.aborted end
	active = ctx
	player:SetAttribute("PetCinematic", true)
	player:SetAttribute("TameActive", ctx.id)

	local finished = false
	local function teardown(fadeBack)
		if finished then return end
		finished = true
		ctx.aborted = true
		J:clean()
		if active == ctx then active = nil end
		player:SetAttribute("TameActive", nil)
		if fadeBack then fadeInFromBlack() end
	end
	ctx.teardown = teardown

	J:add(PetEvent.OnClientEvent:Connect(function(action, id, nick)
		if action == "TameNickname" and id == ctx.id and typeof(nick) == "string" then ctx.nick = nick end
	end))

	local function run()
		local A = ctx.alive
		local function wait(s) return Util.wait(s, A) end
		local function anim(d, fn, e) Util.animate(d, fn, e or ease.linear, A) end
		local function go(f) task.spawn(f) end

		-- geometry ----------------------------------------------------
		local camera = Workspace.CurrentCamera
		local tier = Config.tierOf(tonumber(payload.PlayerLevel) or 1)
		local color, R = tier.color, CC.BaseRadius * tier.scale
		local h2, h3 = CC.HeightMid, CC.HeightTop

		local pPos, wPos0 = root.Position, wild:GetPivot().Position
		local flat0 = Vector3.new(wPos0.X - pPos.X, 0, wPos0.Z - pPos.Z)
		local look = root.CFrame.LookVector
		local fwd = flat0.Magnitude > 0.5 and flat0.Unit or Vector3.new(look.X, 0, look.Z).Unit

		-- Fixed ceremony spacing: the pet glides to PetDistance studs in front of the player
		-- (wide pets are pushed out so they never overlap), keeping its height above the ground.
		local _, bsz0 = wild:GetBoundingBox()
		local dist = math.max(Config.Taming.PetDistance or 5, math.max(bsz0.X, bsz0.Z) * 0.5 + 2)
		local wPos = pPos + fwd * dist
		do
			local g0, g1 = groundY(char, wild, wPos0), groundY(char, wild, wPos)
			wPos = Vector3.new(wPos.X, (g0 and g1) and (wPos0.Y + (g1 - g0)) or wPos0.Y, wPos.Z)
		end
		local side = fwd:Cross(Vector3.yAxis).Unit
		local sideAng = math.atan2(side.Z, side.X)
		local mid = (pPos + wPos) / 2
		local gy = groundY(char, wild, mid) or (math.min(pPos.Y, wPos.Y) - 2.5)
		local base = Vector3.new(mid.X, gy + 0.12, mid.Z)
		local spread = math.max(dist, 10)
		local lookMid = base + Vector3.new(0, 1.8, 0)
		local function P(f, s, u) return base + fwd * f + side * s + Vector3.new(0, u, 0) end

		-- camera framing --------------------------------------------------
		-- Distance that keeps a (halfW x halfH) box fully in frame at the given FOV / aspect.
		local aspect = math.max(camera.ViewportSize.X / math.max(camera.ViewportSize.Y, 1), 0.5)
		local function fitDist(halfW, halfH)
			local tv = math.tan(math.rad(CAM.FitFov) * 0.5)
			return math.max(halfH / tv, halfW / (tv * aspect)) * CAM.Margin
		end
		-- Orbit shot around a stack of circles: radius r, rising to height h above `base`. Elevation and
		-- angle ease from (e0, a0) to (e1, a1); the distance is sized for the worst case of the move.
		local function stackShot(r, h, a0, a1, duration, e0, e1)
			local function need(e) return fitDist(r, h * 0.5 * math.cos(e) + r * math.sin(e)) end
			local d = math.max(need(e0), need(e1)) + r * 0.6
			local focus = base + Vector3.new(0, h * 0.5, 0)
			return function(t)
				local k = ease.inOutQuad(math.min(t / duration, 1))
				local a, e = a0 + (a1 - a0) * k, e0 + (e1 - e0) * k
				local dir = Vector3.new(math.cos(a) * math.cos(e), math.sin(e), math.sin(a) * math.cos(e))
				return CFrame.lookAt(focus + dir * d, focus)
			end
		end
		local EL = CAM.Elevation
		local ELEV = { low = math.rad(EL.Low), rise = math.rad(EL.Rise), crest = math.rad(EL.Crest), storm = math.rad(EL.Storm) }
		local petH = math.max(bsz0.Y, 3)

		-- stage ----------------------------------------------------------
		local ui = UI.new(player:WaitForChild("PlayerGui"), J, color)
		local grade = makeGrade(J, camera, base + Vector3.new(0, 1.5, 0))
		local director = Util.Director.new(camera)
		J:add(function() director:destroy() end)
		local pet = newPuppet(wild, J, pPos, wPos)

		local storm
		local function thunder()
			if storm then storm.flash() end
			ui:flash(TH.Flash.Color, TH.Flash.Alpha, TH.Flash.Time)
			director:shake(TH.Shake.Strength, TH.Shake.Time)
			Util.sound("Thunder")
		end

		-- 1. INTRO ----------------------------------------------------
		director:cut(shots.dolly(
			CFrame.lookAt(P(-dist / 2 - 9, 5, 4.5), lookMid),
			CFrame.lookAt(P(-dist / 2 - 6, 3.4, 3.2), lookMid),
			T.Intro + T.Bloom * 0.5, ease.inOutQuad))
		ui:bars(true, 0.8)
		ui:fade(1, 1.0)
		ui:caption(CAP.Intro, T.Intro)
		go(function() anim(T.Intro, function(a) grade.set(0.15 * a) end) end)
		if not wait(T.Intro) then return end

		-- 2. BLOOM: circle 1 between player and pet (always shown) --------
		local c1 = Circles.new(J, { position = base, radius = R * 0.3, color = color, spin = 30 })
		Circles.motes(c1, color)
		Util.sound("Bloom")
		ui:caption(CAP.Bloom, T.Bloom)
		director:fov(CAM.Fov.Bloom, 1.5)
		director:cut(stackShot(R, petH, sideAng - 0.2, sideAng + 0.6, T.Bloom + T.Suspense, ELEV.low, ELEV.low + 0.06), 1.0)
		go(function()
			anim(T.Bloom, function(a)
				c1:setRadius(R * (0.3 + 0.7 * a))
				c1.alpha = math.min(a * 1.6, 1)
				c1.spin = 30 + 50 * a
			end, ease.outBack)
		end)
		go(function() anim(T.Bloom, function(a) grade.set(0.15 + 0.2 * a) end) end)
		if not wait(T.Bloom) then return end

		-- 3. SUSPENSE (identical for both outcomes) -------------------------
		ui:caption(CAP.Suspense, T.Suspense)
		pet.tense = 1
		director:fov(CAM.Fov.Suspense, 1.2)
		go(function()
			anim(T.Suspense, function(a)
				c1.spin = 80 + 120 * a
				c1:setRadius(R * (1 + math.sin(a * a * math.pi * 8) * 0.03 * a))
				grade.set(0.35 + 0.25 * a)
				director:shake(0.1 + 0.6 * a, 0.2)
			end)
		end)
		if not wait(T.Suspense) then return end

		-- ====================== FAILURE ================================
		if not success then
			local crack = Circles.crack(J, c1, COL.Fail)
			c1.flicker = true
			Util.sound("Crack")
			anim(T.Crack, function(a)
				crack:set(a, 0)
				c1.spin = 200 + 300 * a
				director:shake(0.5 + 1.2 * a, 0.2)
			end, ease.inQuad)
			if not A() then return end

			-- Shatter: server applies damage at this same cue.
			Util.sound("Shatter")
			Circles.burst(base + Vector3.new(0, 0.5, 0), COL.Fail, 80)
			c1.flicker, c1.alpha, c1.rimAlpha = false, 0, 0
			go(function() anim(0.6, function(a) crack:set(1, a) end) end)
			ui:flash(COL.Fail, 0.65, 0.5)
			director:shake(2.2, 0.6)
			pet.tense = 0
			pet:react(1.4, recoil)
			go(function() anim(0.8, function(a) grade.set(0.6 + 0.35 * a) end) end)

			local victim = pPos + Vector3.new(0, 1.6, 0)
			director:cut(function(t)
				local roll = math.sin(t * 2.4) * 0.06 * math.max(0, 1 - t / T.Aftermath)
				return CFrame.lookAt(pPos + fwd * 4.5 + side * 1.5 + Vector3.new(0, 1.8, 0), victim) * CFrame.Angles(0, 0, roll)
			end, 0.25)
			ui:caption(CAP.Fail, T.Aftermath * 0.7)
			if not wait(math.max(T.Aftermath - 0.9, 0.1)) then return end
			ui:fade(0, 0.7)
			wait(0.9)
			return
		end

		-- ====================== SUCCESS ================================
		-- 4. RISE: circle 2 flickers up out of the ground ------------------
		Util.sound("Rise")
		ui:caption(CAP.Rise, T.Rise)
		pet.tense = 1.4
		local c2 = Circles.new(J, { position = base, radius = R * CC.ScaleMid, color = color, spin = -90 })
		c2.flicker = true
		local linksA = Circles.links(J, { c1, c2 }, color)
		linksA.strength = 1
		director:fov(CAM.Fov.Rise, 1.5)
		director:cut(stackShot(R * CC.ScaleMid, h2 + 1.5, sideAng + 0.6, sideAng + 1.05, T.Rise, ELEV.low, ELEV.rise), 0.8)
		go(function()
			anim(T.Rise, function(a)
				c2:setPos(base + Vector3.new(0, h2 * a, 0))
				c2.alpha = math.min(1, a * 3)
				director:shake(0.3, 0.2)
			end, ease.outCubic)
		end)
		go(function() anim(T.Rise, function(a) grade.set(0.6 + 0.15 * a) end) end)
		if not wait(T.Rise) then return end

		-- Settle: full design fades, only the ring remains ("final form").
		c2.flicker = false
		go(function()
			anim(T.Settle, function(a)
				c2.alpha, c2.rimAlpha = 1 - a, a
				c2.spin = -90 + 60 * a
			end, ease.inOutQuad)
		end)
		director:cut(stackShot(R * CC.ScaleMid, h2 + 1.5, sideAng + 1.05, sideAng + 1.3, T.Settle, ELEV.rise, ELEV.crest), 0.6)
		if not wait(T.Settle) then return end

		-- 5. RECALL: circle 3 + storm (stage 1 activation, stage 2 channeling)
		ui:caption(CAP.Recall, T.Recall)
		Util.sound("Rise")
		local c3 = Circles.new(J, { position = base, radius = R * CC.ScaleTop, color = color, spin = 70 })
		c3.flicker = true
		Circles.motes(c1, color)
		Circles.motes(c2, color)
		storm = Circles.storm(J, base, COL.Storm, R)

		local linksB = Circles.links(J, { c2, c3 }, color)
		linksB.strength = 1

		local stormOn = true

		director:fov(CAM.Fov.Recall, 1.2)
		director:cut(stackShot(R * CC.ScaleTop, h3 + 2, sideAng + 1.3, sideAng + 1.75, T.Recall * 0.3, ELEV.crest, ELEV.crest), 1.0)

		local t1 = T.Recall * 0.3 -- stage 1: activation
		local t2 = T.Recall - t1  -- stage 2: channeling
		go(function() anim(t1, function(a) grade.set(0.75 + 0.25 * a) end, ease.inOutQuad) end)
		go(function()
			anim(t1 * 0.85, function(a)
				c3:setPos(base + Vector3.new(0, h3 * a, 0))
				c3.alpha = math.min(1, a * 3)
			end, ease.outCubic)
		end)
		if not wait(t1) then return end
		c3.flicker, c3.alpha, c3.rimAlpha = false, 1, 0.85
		-- channeling: crane out and up so the whole storm (circles to cloud) is in frame
		director:cut(stackShot(R * CC.ScaleTop, Circles.STORM_HEIGHT - 2, sideAng + 1.75, sideAng + 3.3,
			t2 + T.Dissolve, ELEV.crest, ELEV.storm), 1.4)

		go(function()
			anim(t2 * 0.45, function(a)
				storm.set(a)
			end, ease.inOutQuad)
		end)
		go(function()
			anim(t2, function(a)
				c1.spin, c2.spin, c3.spin = 90 + 170 * a, -(70 + 130 * a), 70 + 120 * a
				director:shake(0.25 + 0.3 * a, 0.2)
			end)
		end)
		go(function()
			while stormOn and wait(TH.Interval + math.random() * TH.Spread) do
				if stormOn then thunder() end
			end
		end)
		if not wait(t2) then return end

		-- Dissolve: storm fades, circles sink back (no flash: recall "end" omitted)
		stormOn = false
		go(function()
			anim(T.Dissolve, function(a)
				local k = 1 - a
				storm.set(k)
				linksA.strength, linksB.strength = k, k
				c3.alpha, c3.rimAlpha = k, 0.85 * k
				c3:setPos(base + Vector3.new(0, h3 * k, 0))
				c2.rimAlpha = k
				c2:setPos(base + Vector3.new(0, h2 * k, 0))
				c1.alpha = k
				grade.set(0.1 + 0.9 * k)
			end, ease.inOutQuad)
		end)
		if not wait(T.Dissolve) then return end

		-- 6. FULL SHOT + STAT CARD ---------------------------------------
		local camSide = spread * 0.5 + 11
		local function fullShot(push)
			return function(t)
				local pos = P(math.sin(t * 0.35) * 0.9, camSide - push * math.min(t, 8) * 0.12, 3.2 + math.sin(t * 0.3) * 0.2)
				local cf0 = CFrame.lookAt(pos, lookMid)
				return CFrame.lookAt(pos, lookMid - cf0.RightVector * (camSide * 0.2)) -- subjects sit right of the card
			end
		end
		pet.tense = 0
		director:cut(fullShot(0), 1.2)
		director:fov(52, 1.2)

		local species = wild:GetAttribute("SpeciesId")
		local stage = tonumber(wild:GetAttribute("Stage")) or 1
		local stageCfg = PetConfig.GetStage(species, stage)
		local speciesCfg = PetConfig.Species[species]
		local info = Stats.Compute(species, stage, wild:GetAttribute("SizeMultiplier"),
			wild:GetAttribute("Level"), wild:GetAttribute("Grade"))

		Util.sound("Reveal")
		ui:flash(Color3.new(1, 1, 1), 0.35, 0.4)
		ui:showStats({
			title = (stageCfg and stageCfg.Name) or tostring(species),
			species = speciesCfg and speciesCfg.DisplayName or "",
			color = color,
			rows = info.Rows,
		})
		if not wait(T.StatReveal) then return end

		-- 7. NAME YOUR PET ---------------------------------------------------
		local _, bsz = wild:GetBoundingBox()
		local pr = math.max(bsz.Magnitude * 0.5, 2)
		local closePos = wPos - fwd * (pr * 2.1 + 3) + side * (pr * 0.5 + 1) + Vector3.new(0, pr * 0.45 + 1, 0)
		local focus = wPos + Vector3.new(0, pr * 0.15, 0)
		director:cut(function(t)
			local pos = closePos + side * math.sin(t * 0.4) * 0.4
			local cf0 = CFrame.lookAt(pos, focus)
			return CFrame.lookAt(pos, focus - cf0.RightVector * (pr * 0.35))
		end, 1.4)
		director:fov(44, 1.4)

		local typed = ui:askNickname({
			min = Config.Nickname.MinLength,
			max = Config.Nickname.MaxLength,
			suggestions = info.Suggestions,
		})
		if not typed or not A() then return end

		-- The server echoes the accepted (filtered) name. Retry once, and report a failure instead of
		-- silently showing the typed name as if it had been stored (that hid a failed save before).
		for _ = 1, 2 do
			PetEvent:FireServer("TameNickname", typed)
			local waited = 0
			while not ctx.nick and waited < 3 and A() do waited += RunService.Heartbeat:Wait() end
			if ctx.nick or not A() then break end
		end
		if not A() then return end
		local nick = ctx.nick or typed
		if not ctx.nick then
			warn("[PetTaming_Cinema] Server never confirmed the nickname. Check the server TameNickname handler and pet storage.")
			Cinema.toast("Name could not be saved.")
		end
		ui:hideNickname()

		-- 8. REACTION --------------------------------------------------------
		Util.sound("React")
		pet:react(2.6, happy)
		Circles.burst(wPos + Vector3.new(0, pr, 0), COL.Gold, 60)
		ui:nameTag(body, nick, bsz.Y * 0.5 + 1.6)
		ui:setNickname(nick)
		director:shake(0.6, 0.4)
		if not wait(2.8) then return end

		-- 9. FINAL FULL SHOT + END PROMPT -----------------------------------------
		director:cut(fullShot(1), 1.6)
		director:fov(50, 1.6)
		ui:caption(CAP.Final, 3)
		if not wait(1.8) then return end

		if ui:askEnd() ~= "end" or not A() then return end
		PetEvent:FireServer("TameFinish")
		ui:fade(0, 0.7)
		wait(0.8)
	end

	local ok, err = pcall(run)
	if not ok then warn("[PetTaming_Cinema] " .. tostring(err)) end
	teardown(true)
end

function Cinema.abort(id)
	if active and (id == nil or active.id == id) then
		active.teardown(false)
	end
end

-------------------------------------------------------------------- after-effects

function Cinema.toast(message)
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg or type(message) ~= "string" then return end
	local g = Instance.new("ScreenGui")
	g.Name, g.ResetOnSpawn, g.DisplayOrder, g.Parent = "TameToast", false, 70, pg
	local l = Instance.new("TextLabel")
	l.AnchorPoint, l.Position, l.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.78), UDim2.fromOffset(340, 40)
	l.BackgroundColor3, l.BackgroundTransparency = COL.Panel, 0.15
	l.Text, l.Font, l.TextSize, l.TextColor3 = message, Enum.Font.GothamBold, 16, COL.Text
	l.Parent = g
	local c = Instance.new("UICorner")
	c.CornerRadius, c.Parent = UDim.new(0, 10), l
	TweenService:Create(l, TweenInfo.new(0.5), { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
	Debris:AddItem(g, 2.4)
end

-- Concussion: blur, camera sway, countdown. Server enforces the lockout.
function Cinema.dizzy(seconds)
	if dizzyActive or type(seconds) ~= "number" or seconds <= 0 then return end
	dizzyActive = true

	local pg = player:FindFirstChildOfClass("PlayerGui")
	local blur = Instance.new("BlurEffect")
	blur.Size, blur.Parent = 0, Lighting
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "TameDazed", false, 70
	local label = Instance.new("TextLabel")
	label.AnchorPoint, label.Position, label.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.2), UDim2.fromOffset(240, 36)
	label.BackgroundTransparency, label.Font, label.TextSize = 1, Enum.Font.GothamBlack, 22
	label.TextColor3, label.TextStrokeTransparency = COL.Fail, 0.4
	label.Parent = gui
	gui.Parent = pg

	local cam, t0 = Workspace.CurrentCamera, os.clock()
	RunService:BindToRenderStep("PetTameDizzy", Enum.RenderPriority.Camera.Value + 1, function()
		local t = os.clock() - t0
		local k = math.clamp(1 - t / seconds, 0, 1)
		cam.CFrame = cam.CFrame * CFrame.Angles(0, 0, math.sin(t * 2.3) * 0.045 * k)
		blur.Size = (6 + math.sin(t * 3) * 3) * k
		label.Text = string.format("DAZED  %.1fs", math.max(0, seconds - t))
	end)

	task.delay(seconds, function()
		RunService:UnbindFromRenderStep("PetTameDizzy")
		blur:Destroy()
		gui:Destroy()
		dizzyActive = false
	end)
end

return Cinema 