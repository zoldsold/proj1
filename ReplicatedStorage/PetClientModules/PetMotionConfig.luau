-- v1.0.0.1
--[[
	PetMotionConfig (ModuleScript -> ReplicatedStorage/PetClientModules)

	Data only. Everything that decides HOW a pet moves lives here, so adding a pet or a movement
	style never touches the movement code.

	Adding a new pet: do nothing (it uses DefaultType + the Speed formula), or give it a row in
	`Species`, or put `MoveType` / `MoveSpeed` on its PetConfig stage. Precedence, highest first:
	    Species[speciesId]  >  PetConfig stage (MoveType / MoveSpeed)  >  Types / Speed defaults.
	Adding a new movement style (swimmer, burrower...): add a row to `Types`.
]]

local Motion = {}

-- Movement types: how a pet relates to the ground while travelling.
--   Gap          studs between the ground and the pet's underside (+ GapPerScale * pet scale)
--   Bob          idle bob multiplier (0 = none, 1 = the standard float)
--   WanderBob    extra vertical sway while wandering (studs)
Motion.Types = {
	Flying = { Gap = 3.5, GapPerScale = 1.5, Bob = 1, WanderBob = 3 },
	Ground = { Gap = 0.15, GapPerScale = 0,  Bob = 0, WanderBob = 0 },
}
Motion.DefaultType = "Flying"

-- Optional per-species overrides: [speciesId] = { Type = "Ground", Speed = 40, Gap = 0.4 }
Motion.Species = {}

-- Pet speed in studs/second: Base + PerScale * scale. A species/stage `Speed` / `MoveSpeed` replaces it.
-- Every mode below moves at (pet speed * SpeedMult).
Motion.Speed = { Base = 1, PerScale = 14 }

-- Smooth = exponential easing rate (higher = snappier, 0 = no easing: pure speed-limited travel).
Motion.Modes = {
	Follow = { SpeedMult = 4, Smooth = 10, OffsetSmooth = 4 }, -- trails the player; SpeedMult is only a catch-up cap
	Wander = {
		SpeedMult = 4, Smooth = 10, OffsetSmooth = 1.5,
		Radius = 12, RadiusPerScale = 6, Rate = 0.6, RatePerScale = 0.1,        -- orbit around the player
		EnterDist = 12, EnterPlayerSpeed = 1,                                   -- idle this close + player still -> wander
		ExitDist = 30, ExitPlayerSpeed = 2,                                     -- far away or player moving -> follow
	},
	-- Click: the pet travels to the clicked point at constant speed, then strikes.
	Attack = {
		SpeedMult = 5.3, Smooth = 10, Turn = 14,
		Range = 120,                 -- max cursor ray length (studs)
		Timeout = 2.5,               -- give up after this many seconds
		Reached = 6,                 -- horizontal distance that counts as arrived
		ImpactRadius = 8, ImpactRadiusPerScale = 22,
	},
	-- Hold the button after clicking: the pet tracks the cursor in real time (speed-limited, no easing lag).
	Drag = {
		SpeedMult = 4, Smooth = 10, Turn = 20,
		HoldTime = 0.15,             -- seconds held before a click becomes a drag
		ImpactInterval = 1,          -- seconds between strike checks while dragging
	},
}

Motion.Vertical = { Smooth = 12, RayStart = 3, RayLength = 500 } -- height easing + ground ray (from pet height + RayStart)
Motion.TeleportSnap = 50                                         -- player moved further than this in one frame: snap the pet

return Motion