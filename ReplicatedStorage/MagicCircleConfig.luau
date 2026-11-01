--!strict
--[[ MagicCircleConfig v1.0.0.1
	Location: ReplicatedStorage/MagicCircleConfig (ModuleScript)
	All tunables live here. No logic. ]]
return table.freeze({
	ImageId = "rbxassetid://92159544437437", -- TODO: paste the uploaded MagicCircle_v1.0.0.1.png Image ID
	RemoteName = "MagicCircleRemote",

	MaxViewDistance = 120, -- server only sends to players this close (studs)
	SessionTimeout = 30, -- server auto-ends forgotten circles (seconds)

	MaxActive = 12, -- max circles a single client renders at once
	MaxPool = 6, -- idle parts kept for reuse

	Diameter = 50, -- studs
	InnerScale = 0.62, -- inner counter-rotating layer size (0-1)
	SpinSpeed = 45, -- degrees/second (inner spins 1.5x, reversed)
	Grace = 3, -- extra spin time past requested duration (seconds)
	Brightness = 5, -- SurfaceGui glow strength

	GroundRayUp = 3,
	GroundRayDown = 15,
	GroundOffset = 0.08, -- lift to avoid z-fighting

	FailColor = Color3.fromRGB(255, 70, 70),
})