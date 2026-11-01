--!nonstrict
-- ProfileSchema.spec v1.0.0.4
-- ModuleScript next to ProfileSchema. Run in the Studio command bar:
--   require(game.ServerScriptService.Data.ProfileSchema.spec).run()
local Schema = require(script.Parent.ProfileSchema)

local config = {
	GetMaxStage = function(species)
		return species == "Kun" and 4 or 0
	end,
}

return {
	run = function()
		local fresh = Schema.prepare(nil, config, 100)
		assert(fresh.version == Schema.CURRENT_VERSION and fresh.money == 0 and next(fresh.pets) == nil)
		assert(fresh.meta.created == 100 and fresh.progress.level == 1)

		local bad = Schema.prepare({
			version = 1,
			money = 0 / 0,
			equipped = "ghost",
			pets = {
				a = { Species = "Kun", Stage = 99, XP = -5, Nickname = string.rep("x", 100) },
				b = "junk",
				c = { Species = "Future", Stage = 7, Extra = "kept" },
			},
		}, config, 100)
		assert(bad.money == 0, "NaN money")
		assert(bad.equipped == nil, "equipped must point at a real pet")
		assert(bad.pets.a.Stage == 4 and bad.pets.a.XP == 0 and #bad.pets.a.Nickname == 32)
		assert(bad.pets.b == nil, "junk entry dropped")
		assert(bad.pets.c.Stage == 7 and bad.pets.c.Extra == "kept", "unknown species + extras survive")

		local ok = Schema.prepare({ version = 1, money = 5.9, pets = { a = Schema.newPet("a", "Kun") }, equipped = "a" }, config, 100)
		assert(ok.money == 5 and ok.equipped == "a")

		local r = Schema.prepare({
			version = 1,
			nextId = 1,
			order = { "pet_3", "ghost", "pet_3" },
			pets = { pet_3 = { Species = "Kun", Level = 0, SizeMultiplier = 99 }, pet_1 = { Species = "Kun" } },
		}, config, 100)
		assert(r.pets.pet_3.Level == 1 and r.pets.pet_3.SizeMultiplier == 10 and r.pets.pet_1.SizeMultiplier == 1)
		assert(#r.order == 2 and r.order[1] == "pet_3" and r.order[2] == "pet_1", "order repaired")
		assert(r.nextId == 4, "nextId above every used id")

		local nilData, why =Schema.prepare({ version = Schema.CURRENT_VERSION + 1 }, config, 100)
		assert(nilData == nil and why == "newer")
		local nilData2, why2 = Schema.prepare({ money = 1 }, config, 100)
		assert(nilData2 == nil and why2 == "corrupt")
		local m = { money = 0 / 0 }
		Schema.clampMoney(m)
		assert(m.money == 0, "NaN money cleared")
		m.money = 1e30
		Schema.clampMoney(m)
		assert(m.money == Schema.MAX_MONEY, "huge money capped")

		local ids = {}
		for i = 1, 250 do
			ids[i] = "r" .. i
		end
		local c = Schema.prepare({ version = 1, receipts = ids }, config, 100)
		assert(#c.receipts == Schema.MAX_RECEIPTS and c.receipts[#c.receipts] == "r250", "newest receipts kept")
		local pr = { level = 1, xp = 0 }
		Schema.addXP(pr, 250)
		assert(pr.level == 2 and pr.xp == 150, "one level-up, remainder kept")
		pr = { level = 1, xp = 0 }
		Schema.addXP(pr, 350)
		assert(pr.level == 3 and pr.xp == 50, "two level-ups in one grant")
		Schema.addXP(pr, 1e30)
		assert(pr.level > 3 and pr.xp >= 0, "huge grant is capped, never negative")
		print("ProfileSchema: all checks passed")
	end,
}
