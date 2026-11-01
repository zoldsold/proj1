-- ProfileSchema v1.0.0.4
-- ServerScriptService/Data/ProfileSchema (ModuleScript)
-- Pure data logic, no Roblox APIs: defaults, migrations, validation.
-- Add a field: put it in default(), bump CURRENT_VERSION, add MIGRATIONS[oldVersion].
-- Pet fields (Id, Species, Stage, XP, Level, SizeMultiplier, Nickname), `order`
-- (display order of pet ids), `nextId` and `equipped` mirror PetManager's profile.
-- Extra fields on a pet are preserved.

local Schema = {}

Schema.CURRENT_VERSION = 1
Schema.MAX_MONEY = 1e15 -- exact in a double, far below 2^53
Schema.MAX_RECEIPTS = 200 -- newest Robux purchase ids kept for idempotent grants
Schema.MAX_LEVEL = 1e6
local MAX_NICKNAME = 32

local function deepCopy(t)
	if type(t) ~= "table" then
		return t
	end
	local c = {}
	for k, v in pairs(t) do
		c[k] = deepCopy(v)
	end
	return c
end

-- MIGRATIONS[n] upgrades data from version n to n+1. Never edit a shipped one.
local MIGRATIONS = {
	-- [1] = function(data) data.newField = 0 return data end,
}

function Schema.default(now)
	return {
		version = Schema.CURRENT_VERSION,
		money = 0,
		pets = {}, -- [petId: string] = { Id, Species, Stage, XP, Level, SizeMultiplier, Nickname }
		order = {}, -- petIds in inventory order
		nextId = 1, -- next "pet_<n>" id; never reused
		receipts = {}, -- recent purchase ids already granted (see DataService.GrantOnce)
		-- equipped = "<petId>"  (absent = nothing equipped; JSON has no nil)
		progress = { level = 1, xp = 0, stats = {}, flags = {} }, -- placeholder for future systems
		meta = { created = now or 0, lastSave = 0, sessions = 0 },
	}
end

function Schema.newPet(id, species, nickname)
	return { Id = tostring(id), Species = species, Stage = 1, XP = 0, Level = 1, SizeMultiplier = 1, Nickname = nickname }
end

local function int(v, lo, hi, def)
	if type(v) ~= "number" or v ~= v then -- not a number, or NaN
		return def
	end
	return math.max(lo, math.min(hi, math.floor(v)))
end

local function num(v, lo, hi, def)
	if type(v) ~= "number" or v ~= v then
		return def
	end
	return math.max(lo, math.min(hi, v))
end

-- Forces money into a storable range (NaN/inf/negative/huge). Safe to call on a live profile.
function Schema.clampMoney(data)
	data.money = int(data.money, 0, Schema.MAX_MONEY, 0)
end

-- XP needed to go from `level` to the next one. Change the curve here only.
function Schema.xpForLevel(level)
	return 100 * level
end

-- Adds XP to profile.progress and applies level-ups. `amount` must already be validated.
function Schema.addXP(progress, amount)
	progress.xp = progress.xp + math.min(math.floor(amount), 1e9)
	while progress.level < Schema.MAX_LEVEL and progress.xp >= Schema.xpForLevel(progress.level) do
		progress.xp = progress.xp - Schema.xpForLevel(progress.level)
		progress.level = progress.level + 1
	end
end

local function cleanNick(s)
	if type(s) ~= "string" then
		return nil
	end
	s = s:match("^%s*(.-)%s*$")
	local len = utf8.len(s)
	if not len or len == 0 then
		return nil
	end
	if len > MAX_NICKNAME then
		s = s:sub(1, utf8.offset(s, MAX_NICKNAME + 1) - 1)
	end
	return s
end

-- Repairs types/ranges in place. `config` (optional) is PetConfig, used to cap Stage.
-- Unknown species are kept as-is so a config change can never delete a player's pet.
function Schema.sanitize(data, config)
	Schema.clampMoney(data)

	local pets = {}
	if type(data.pets) == "table" then
		for key, p in pairs(data.pets) do
			if type(p) == "table" and type(p.Species) == "string" then
				local id = tostring(p.Id or key)
				local maxStage = config and config.GetMaxStage(p.Species) or 0
				local pet = deepCopy(p)
				pet.Id = id
				pet.Stage = int(p.Stage, 1, maxStage > 0 and maxStage or 999, 1)
				pet.XP = int(p.XP, 0, 1e12, 0)
				pet.Level = int(p.Level, 1, 9999, 1)
				pet.SizeMultiplier = num(p.SizeMultiplier, 0.1, 10, 1)
				pet.Nickname = cleanNick(p.Nickname)
				pets[id] = pet
			end
		end
	end
	data.pets = pets

	-- order: keep valid unique ids, append any pet missing from it; nextId stays above every used id
	local order, seen, maxN = {}, {}, 0
	if type(data.order) == "table" then
		for _, id in ipairs(data.order) do
			id = tostring(id)
			if pets[id] and not seen[id] then
				seen[id] = true
				order[#order + 1] = id
			end
		end
	end
	local missing = {}
	for id in pairs(pets) do
		if not seen[id] then
			missing[#missing + 1] = id
		end
		local n = tonumber(id:match("^pet_(%d+)$"))
		if n and n > maxN then
			maxN = n
		end
	end
	table.sort(missing)
	for _, id in ipairs(missing) do
		order[#order + 1] = id
	end
	data.order = order
	data.nextId = math.max(int(data.nextId, 1, 1e12, 1), maxN + 1)

	local src, receipts = type(data.receipts) == "table" and data.receipts or {}, {}
	for i = math.max(1, #src - Schema.MAX_RECEIPTS + 1), #src do
		if type(src[i]) == "string" then
			receipts[#receipts + 1] = src[i]
		end
	end
	data.receipts = receipts
	if type(data.equipped) ~= "string" or not pets[data.equipped] then
		data.equipped = nil
	end

	if type(data.progress) ~= "table" then
		data.progress = {}
	end
	local pr = data.progress
	pr.level = int(pr.level, 1, Schema.MAX_LEVEL, 1)
	pr.xp = int(pr.xp, 0, 1e15, 0)
	if type(pr.stats) ~= "table" then
		pr.stats = {}
	end
	if type(pr.flags) ~= "table" then
		pr.flags = {}
	end

	if type(data.meta) ~= "table" then
		data.meta = {}
	end
	local m = data.meta
	m.created = int(m.created, 0, 2 ^ 40, 0)
	m.lastSave = int(m.lastSave, 0, 2 ^ 40, 0)
	m.sessions = int(m.sessions, 0, 1e9, 0)
	return data
end

-- raw = stored profile or nil (new player). Returns data, or nil + "corrupt" | "newer".
function Schema.prepare(raw, config, now)
	if raw == nil then
		return Schema.sanitize(Schema.default(now), config)
	end
	if type(raw) ~= "table" or type(raw.version) ~= "number" then
		return nil, "corrupt"
	end
	if raw.version > Schema.CURRENT_VERSION then
		return nil, "newer" -- saved by a newer server; never overwrite it
	end
	while raw.version < Schema.CURRENT_VERSION do
		local step = MIGRATIONS[raw.version]
		if not step then
			return nil, "corrupt"
		end
		raw = step(raw)
		raw.version = raw.version + 1
	end
	return Schema.sanitize(raw, config)
end

return Schema
