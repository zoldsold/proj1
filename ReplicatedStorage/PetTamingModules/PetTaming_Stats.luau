-- v1.0.0.0.1
--[[
	PetTamingStats (ModuleScript -> ReplicatedStorage)

	Everything shown on the stat card lives here, so editing a pet or adding a
	stat never touches cinematic code.

	  - Add a species: copy a block into Stats.Species (key = PetConfig species id).
	  - Add a stat row: append to Rows inside Stats.Compute.
	  - Grade: pass it in (wild model attribute "Grade") once you add it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PetConfig = require(ReplicatedStorage:WaitForChild("PetConfig"))

local Stats = {}

Stats.GradePlaceholder = "-" -- shown until a grade system exists ("" = fully blank)
Stats.SizeExponent     = 2   -- weight ~ SizeMultiplier ^ this

Stats.Default = {
	Weight      = { Base = 12, PerStage = { 1, 2.4, 6 } },
	Suggestions = { "Buddy", "Luna", "Mochi", "Ember", "Nova", "Pixel", "Sage", "Koko" },
}

Stats.Species = {
	-- Kun = {
	--	Weight      = { Base = 30, PerStage = { 1, 3, 12 } },
	--	Suggestions = { "Tiny", "Splash", "Drift" },
	-- },
}

function Stats.Compute(speciesId, stage, sizeMultiplier, level, grade)
	local def    = Stats.Species[speciesId] or Stats.Default
	local w      = def.Weight or Stats.Default.Weight
	local mult   = (w.PerStage and w.PerStage[stage]) or 1
	local size   = tonumber(sizeMultiplier) or 1
	local weight = w.Base * mult * size ^ Stats.SizeExponent
	weight = math.floor(weight * 10 + 0.5) / 10

	local okMax, maxStage = pcall(PetConfig.GetMaxStage, speciesId)
	if not okMax or type(maxStage) ~= "number" then maxStage = stage end

	local gradeText = Stats.GradePlaceholder
	if type(grade) == "string" and grade ~= "" then gradeText = grade end

	return {
		Weight = weight,
		Rows = {
			{ Label = "GRADE",  Text = gradeText },
			{ Label = "WEIGHT", Text = string.format("%.1f kg", weight), Number = weight, Format = "%.1f kg" },
			{ Label = "STAGE",  Text = stage .. " / " .. maxStage },
		},
		Suggestions = def.Suggestions or Stats.Default.Suggestions,
	}
end

return Stats