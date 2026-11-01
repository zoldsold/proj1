-- v1.0.0.2
-- CHANGES v1.0.0.2: every magic-circle effect (circles, motes, burst, cracks, storm, cloud, rain, thunder, links, grade,
--   depth of field, camera framing) now lives in Config.Effects. Config.Camera / Config.FX were folded into it.
--   Lightning arcs (the lines inside the circles) were removed.
-- v1.0.0.1: Taming.PetDistance (fixed ceremony spacing).
--[[
	PetTamingConfig (ModuleScript -> ReplicatedStorage)

	Single source of truth for the taming ceremony: rules, timings, colours.
	Server reads rules + cue times; client reads visuals. Edit values here only.
]]

local Config = {}

-- 0.25 - 1. Multiplies particle density. Lower it for weak devices.
Config.Quality = 1

-- Upload the two *_v1.0.0.0.1.png files, paste "rbxassetid://<id>" here.
-- Left empty: falls back to MagicCircleConfig.ImageId (purple, no tinting).
Config.Images = {
	Full = "rbxassetid://194930871644981",
	Ring = "rbxassetid://120174687980437", -- ring-only version, used for the "final form" of circle 2
}

Config.Taming = {
	BaseChance              = 0.9,
	PenaltyPerLevel         = 0.05,
	PenaltyPerLevelReleased = 0.09, -- re-taming a released pet is harder
	MinChance               = 0.10,
	MaxChance               = 0.95,
	FailDamage              = 20,   -- HP lost on failure (never lethal)
	ConcussionSeconds       = 5,    -- cannot tame again for this long
	SessionTimeout          = 180,  -- server force-ends a stuck success session
	RequireGrounded         = true,
	PetDistance             = 5,    -- studs between player and wild pet during the ceremony (wide pets are pushed out so they never overlap)
}

Config.Nickname = { MinLength = 1, MaxLength = 16 }

-- Every visual knob of the magic-circle ceremony. Client-only (the server never reads this block).
-- Ranges are { min, max }. Config.Quality scales particle density on top of the rates below.
Config.Effects = {
	-- One glowing seal (circles 1-3).
	Circle = {
		Canvas     = 512,
		Brightness = 2,
		HaloScale  = 1.14,                                  -- canvas vs art size: room for the soft halo
		HaloAlpha  = 0.4,
		InnerScale = 0.62,
		Spin       = { Inner = -1.5, Rim = 0.6, Halo = -0.35 }, -- layer spin relative to the circle's own spin
		Pulse      = { Rate = 4, Depth = 0.1 },
		Flicker    = { OffTime = 0.03, OffSpread = 0.09, DimAlpha = 0.12 },
		Light      = { Enabled = true, RangePerRadius = 2.4, MinRange = 8, MaxRange = 60, Brightness = 2.2 },
	},

	-- Particles gathering into a circle.
	Motes = {
		Rate = 40, Size = 0.55, Lifetime = { 1.8, 3.0 }, Speed = { 2, 6 }, Lift = 3, Spread = 12,
		GlintRate = 28, GlintSize = 0.22, GlintLifetime = { 0.7, 1.3 }, GlintSpeed = { 6, 14 }, GlintLift = 6,
	},

	-- One-shot burst (failure shatter, success reaction).
	Burst = {
		SparkSize = 0.9, SparkLifetime = { 0.8, 1.6 }, SparkSpeed = { 14, 34 }, SparkDrag = 2.5, SparkGravity = 22,
		EmberRatio = 0.35, EmberSize = 1.1, EmberLifetime = { 1.4, 2.4 }, EmberSpeed = { 2, 8 }, EmberLift = 5,
		Flash     = { Range = 28, Brightness = 5, Time = 0.7 },
		Shockwave = { Enabled = true, BaseReach = 4, ReachPerCount = 0.12, Time = 0.9 },
	},

	-- Cracks across circle 1 on failure.
	Crack = { Rays = 9, Steps = 4, Width = 0.16, Wobble = 0.7 },

	-- Recall storm: light column + cloud + rain + sparks.
	Storm = {
		Height = 120,
		Column = { Width = 3.5, Opacity = 0.52, Pulse = 0.12 },                -- Width = multiple of circle-1 radius
		Cloud  = {
			Size = Vector3.new(100, 3, 100), Drop = 6, Spin = 0.2,               -- Drop = studs below the column top 44
			ColorA = Color3.fromRGB(70, 60, 110), ColorB = Color3.fromRGB(35, 35, 60),
			Rate = 16, ParticleSize = { 18, 30 }, Lifetime = { 5, 8 },
		},
		Rain   = { Rate = 160, Speed = { 80, 95 }, Color = Color3.fromRGB(190, 210, 255), Width = 30 },
		Sparks = { Rate = 60, Size = 0.5, Lifetime = { 1.2, 2 }, Speed = { 4, 9 } },
	},

	-- Thunder claps while the storm is active.
	Thunder = {
		Interval = 0.8, Spread = 1.5,                                          -- seconds between claps: Interval + random * Spread
		Flash = { Color = Color3.fromRGB(200, 215, 255), Alpha = 0.4, Time = 0.3 },
		Shake = { Strength = 1.2, Time = 0.35 },
		Light = { Color = Color3.fromRGB(190, 200, 255), Brightness = 7, Range = 60, Fade = 0.45 },
	},

	-- Vertical filaments between circles. Off by default (they read as lines).
	Links = { Enabled = false, Count = 8, Width = 0.24, Opacity = 0.8 },

	-- Screen grade: 0 (normal) .. 1 (storm).
	Grade = {
		Brightness = -0.16, Contrast = 0.12, Saturation = -0.25, Tint = Color3.fromRGB(175, 185, 255),
		BloomSize = 28, BloomThreshold = 0.9, BloomBase = 0.35, BloomGain = 0.5,
	},
	DepthOfField = { Enabled = true, MinQuality = 0.5, FarIntensity = 0.3, InFocusRadius = 30, FocusSpeed = 4 },

	-- Camera framing for the rising circles; distances are computed from the circle size, so every tier fits.
	Camera = {
		FitFov = 56,                                                           -- FOV assumed when sizing shots (smaller = further back)
		Margin = 1.18,                                                         -- breathing room around the stack (1 = exact fit)
		Elevation = { Low = 18, Rise = 30, Crest = 22, Storm = 13 },           -- degrees above the stack centre
		Fov       = { Bloom = 62, Suspense = 58, Rise = 62, Recall = 64 },
	},
}

-- Seconds. Server and client BOTH read these, so cues stay in sync.
Config.Timeline = {
	Intro      = 3,
	Bloom      = 2.0,  -- circle 1 appears
	Suspense   = 5,  -- outcome hidden
	-- failure branch
	Crack      = 2.2,
	Aftermath  = 2.6,
	-- success branch
	Rise       = 4,  -- circle 2 rises
	Settle     = 10,
	Recall     = 7.0,  -- circle 3 + recall animation (stage 1 + 2)
	Dissolve   = 10,
	StatReveal = 4.6,
}
Config.ServerCueLag = 0.1

function Config.FailHitAt()
	local T = Config.Timeline
	return T.Intro + T.Bloom + T.Suspense + T.Crack
end

function Config.FailEndAt()
	return Config.FailHitAt() + Config.Timeline.Aftermath
end

Config.Circle = {
	BaseRadius = 10,
	ScaleMid   = 1.25, -- circle 2 radius vs circle 1
	ScaleTop   = 1.55, -- circle 3 radius vs circle 1
	HeightMid  = 3.4,  -- studs above ground
	HeightTop  = 7.8,
}

-- Circle size + colour by player level (swap Level for "power" later).
Config.Tiers = {
	{ minLevel = 50, scale = 2.2,  color = Color3.fromRGB(255, 215, 60)  },
	{ minLevel = 25, scale = 1.6,  color = Color3.fromRGB(180, 100, 255) },
	{ minLevel = 10, scale = 1.15, color = Color3.fromRGB(80, 200, 255)  },
	{ minLevel = 1,  scale = 0.75, color = Color3.fromRGB(120, 240, 160) },
}

function Config.tierOf(level)
	for _, tier in ipairs(Config.Tiers) do
		if level >= tier.minLevel then return tier end
	end
	return Config.Tiers[#Config.Tiers]
end

Config.Colors = {
	Fail  = Color3.fromRGB(255, 70, 70),
	Storm = Color3.fromRGB(150, 110, 255),
	Gold  = Color3.fromRGB(255, 205, 92),
	Panel = Color3.fromRGB(14, 18, 30),
	Text  = Color3.fromRGB(235, 240, 250),
	Sub   = Color3.fromRGB(146, 159, 184),
	Dark  = Color3.fromRGB(44, 50, 70),
}

Config.Captions = {
	Intro    = "Something stirs in the air...",
	Bloom    = "The seal awakens.",
	Suspense = "...",
	Rise     = "Another seal answers.",
	Recall   = "The bond is called forth.",
	Final    = "A bond is formed.",
	Fail     = "The seal could not hold.",
}

-- Paste "rbxassetid://<id>" to enable. Empty = silent.
Config.Sounds = {
	Bloom = "", Rise = "", Crack = "", Shatter = "", Thunder = "",
	Reveal = "", Confirm = "", React = "",
}

Config.Toasts = {
	dazed    = "You are still dazed.",
	airborne = "Stand on the ground to tame.",
	full     = "Your collection is full.",
	busy     = "Not right now.",
	invalid  = "That cannot be tamed.",
}

return Config