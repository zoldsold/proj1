--[[
	PetConfig (ModuleScript -> ReplicatedStorage)

	Single source of truth for pets. Server and client both read this file.
	To add a stage or whole new species, edit this table only.

	Confirmed from show: pet starts as small catfish and can be
	grown into giant whale Kun. Stages 2 and 3 are placeholders for
	steps in between; colours are your own choice. Change freely.
]]
-- v1.0.0.0.1
local PetConfig = {}

PetConfig.MaxSlots = 9 -- inventory grid is 3 x 3

-- Seconds. Server and client cinematics both read these so they stay in sync.
PetConfig.Timing = {
	SummonRise  = 5,   -- how long pet takes to rise out of summon ring
	Summon      = 3.4, -- length of summon cinematic
	EvolveBuildup = 2.8, -- white-silhouette / energy-gathering phase before flash
	EvolveReveal  = 4.4, -- reveal + title card
}

-- pet spawns this far BELOW its follow spot so it can rise out of ring
function PetConfig.SummonDrop(stageCfg)
	return 4 + stageCfg.Scale * 5
end

PetConfig.Species = {
	Kun = {
		DisplayName = "Kun",
		Description = "catfish spirit beast that grows by devouring.",
		Stages = {
			{
				Name = "Spirit Catfish",
				Form = "Catfish",
				Scale = 0.55,
				XPToEvolve = 100,
				Stats = { Power = 5, Vitality = 20 },
				Colors = {
					Body  = Color3.fromRGB(70, 88, 120),
					Belly = Color3.fromRGB(176, 196, 220),
					Glow  = Color3.fromRGB(90, 210, 255),
				},
				FollowOffset = Vector3.new(2.6, 2.4, 3.0),
				Light = 0.6,
				Aura = false,
				Skills = {},
			},
			{
				Name = "Storm Catfish",
				Form = "Catfish",
				Scale = 0.9,
				XPToEvolve = 300,
				Stats = { Power = 14, Vitality = 55 },
				Colors = {
					Body  = Color3.fromRGB(52, 78, 132),
					Belly = Color3.fromRGB(160, 190, 225),
					Glow  = Color3.fromRGB(80, 230, 255),
				},
				FollowOffset = Vector3.new(3.6, 3.0, 4.2),
				Light = 1.2,
				Aura = false,
				Skills = {},
			},
			{
				Name = "Young Kun",
				Form = "Whale",
				Scale = 0.6,
				XPToEvolve = 800,
				Stats = { Power = 40, Vitality = 160 },
				Colors = {
					Body  = Color3.fromRGB(30, 52, 108),
					Belly = Color3.fromRGB(140, 175, 215),
					Glow  = Color3.fromRGB(100, 200, 255),
				},
				FollowOffset = Vector3.new(5.5, 5.5, 8.5),
				Light = 2,
				Aura = true,
				Skills = { "Devour" },
			},
			{
				Name = "Devouring Kun",
				Form = "Whale",
				Scale = 1.0,
				XPToEvolve = nil, -- final form
				Stats = { Power = 120, Vitality = 500 },
				Colors = {
					Body  = Color3.fromRGB(18, 26, 66),
					Belly = Color3.fromRGB(110, 140, 190),
					Glow  = Color3.fromRGB(140, 235, 255),
				},
				FollowOffset = Vector3.new(7, 9, 7),
				Light = 5,
				Aura = true,
				Skills = { "Devour", "TidalMaw" },
			},
		},
	},
}

function PetConfig.GetStage(speciesId, stage)
	local species = PetConfig.Species[speciesId]
	return species and species.Stages[stage]
end

function PetConfig.GetMaxStage(speciesId)
	local species = PetConfig.Species[speciesId]
	return species and #species.Stages or 0
end

return PetConfig