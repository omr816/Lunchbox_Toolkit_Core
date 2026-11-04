--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — TalentValuation

    Scores each available talent point and ranks them so /lbs can recommend
    what to take, not just list options. Text output only: this module builds no
    frames and owns no widgets.

    Pipeline
      1. SpecAdvisor reads the active tree (classic or C_Traits) into `trees`.
      2. This module matches each available talent to its static row in
         TalentValues (by name), which supplies `kind`, `max`, `row`, `col` and
         the rank tooltip `rt`.
      3. Each talent is scored as

             score = (next-rank increment) x (stat weight)

         The increment is the NEXT rank's effect only: a 1-point talent uses its
         full effect, while a 3/5-point talent uses the per-rank step (the value
         at the next rank minus the value at the current rank).
      4. A talent whose point would open the talent directly below it (same
         tree, next row, same column, and that talent is not reachable yet) earns
         a bonus of 40% of that gated talent's score.
      5. Candidates are sorted by score, highest first.

    Weight precedence, per stat:
      active profile weights  ->  TalentValues.ForeverEP for the class/role
      ->  neutral 1.

    Profile weights are per RATING for hit/crit/haste/dodge/parry/block, while
    ForeverEP is per 1% for the same stats (see TalentValues.RatingPerPercent).
    A percent-shaped tooltip is detected from `rt.f` (a %s slot followed by %%)
    rather than guessed from the kind, and is scaled by /100: +5% is 0.05, not
    5. Rating-shaped percents then convert % -> rating before a profile weight
    is applied, and stay a percentage when the ForeverEP weight is used, so the
    two sources stay comparable to each other and to point stats. A talent whose
    `mentions` names specific abilities is discounted to 0.2x a global talent.

    Every client call sits behind a pcall and every value is secret-guarded. A
    missing API or a missing data row degrades to a small provisional score with
    a note, never an error.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local TalentValuation = {}
LT.TalentValuation = TalentValuation
LT.Modules = LT.Modules or {}
LT.Modules.TalentValuation = TalentValuation

------------------------------------------------------------------------------
-- Guarded helpers
------------------------------------------------------------------------------

local function isSecret(value)
    if type(LT.IsSecret) == "function" then
        return LT:IsSecret(value) == true
    end
    local checker = rawget(_G, "issecretvalue")
    if type(checker) ~= "function" then return false end
    local ok, result = pcall(checker, value)
    return ok and result == true
end

local function safeNumber(value)
    if isSecret(value) then return nil end
    return tonumber(value)
end

------------------------------------------------------------------------------
-- Fixed configuration (documented; see header)
------------------------------------------------------------------------------

-- A talent with one of these kinds has no single weightable stat, so it earns a
-- small neutral score rather than being dropped. `resist` is included because
-- resistances are per-school and situational: neither weight set has one
-- "resist" channel, so it cannot be scored like a real stat.
local NEUTRAL_SCORE       = 0.001 -- unknown-kind: no weightable stat, rank last
local NO_RANK_DATA_SCORE  = 0.001 -- no rank-tooltip: unvaluable, rank last
-- A talent whose effect names specific abilities only affects those abilities,
-- so it is worth a fraction of a talent that affects everything.
local ABILITY_SCOPE_FACTOR = 0.2

-- Classes whose damage always scales from a weapon, and classes that never do.
-- Hybrids (PALADIN, SHAMAN, DRUID) are decided from the active weights.
local CASTER_CLASSES    = { MAGE = true, WARLOCK = true, PRIEST = true }
local PHYSICAL_CLASSES  = { WARRIOR = true, ROGUE = true, HUNTER = true }

-- The melee primary stat for each class that has one; a caster build always
-- uses intellect (handled by the caster branch of resolveKind).
local PRIMARY_MELEE = {
    WARRIOR = "strength",
    PALADIN = "strength",
    HUNTER  = "agility",
    ROGUE   = "agility",
    SHAMAN  = "strength",
    DRUID   = "agility",
}

-- kind -> target stat. `percent` marks a rating-shaped stat (its profile weight
-- is per RATING, so a percent-shaped tooltip converts via RatingPerPercent).
-- The actual percent-vs-flat call is made from `rt.f` in scoreTalent, not from
-- this flag. `caster` is the spell-channel name to use instead of `stat` for a
-- caster. `primary`/`damage` are resolved against class + melee/caster.
TalentValuation.KindTarget = {
    cooldown     = { stat = "neutral" },
    mana         = { stat = "intellect" },
    health       = { stat = "stamina" },
    resist       = { stat = "neutral" },
    armor        = { stat = "armor" },
    parry        = { stat = "parry",   percent = true },
    dodge        = { stat = "dodge",   percent = true },
    block        = { stat = "block",   percent = true },
    haste        = { stat = "haste",   percent = true },
    attackpower  = { stat = "attackPower" },
    spellpower   = { stat = "spellPower" },
    crit         = { stat = "crit",    percent = true, caster = "spellCrit" },
    hit          = { stat = "hit",     percent = true, caster = "spellHit" },
    primary      = { stat = "primary" },
    damage       = { stat = "damage" },
    other        = { stat = "neutral" },
}

-- RatingPerPercent uses the plain channel name even when the profile splits the
-- spell variant, so spellCrit/spellHit/spellHaste read the crit/hit/haste rate.
local RATING_KEY = {
    crit = "crit",      spellCrit = "crit",
    hit = "hit",        spellHit = "hit",
    haste = "haste",    spellHaste = "haste",
    dodge = "dodge",    parry = "parry", block = "block",
}

-- ForeverEP does not split spell/melee crit/hit/haste: a caster's crit is stored
-- on the shared "crit" channel. When a spell channel is missing there, try the
-- plain channel.
local PLAIN_CHANNEL = { spellCrit = "crit", spellHit = "hit", spellHaste = "haste" }

-- Lowercased keys are camel-cased back to the profile's canonical channel so
-- any key ("attackpower", "weapondps") lands on the canonical one
-- ("attackPower", "weaponDPS").
local CAMEL = {
    attackpower = "attackPower", spellpower = "spellPower",
    rangedattackpower = "rangedAttackPower", feralattackpower = "feralAttackPower",
    healingpower = "healingPower",
    spellcrit = "spellCrit", spellhit = "spellHit", spellhaste = "spellHaste",
    blockvalue = "blockValue", armorpen = "armorPen",
    weapondps = "weaponDPS", weaponavgdamage = "weaponAvgDamage",
    weaponspeed = "weaponSpeed",
    mainhanddps = "mainHandDps", offhanddps = "offHandDps", rangeddps = "rangedDps",
    manaper5 = "mp5", mp5 = "mp5",
}

local function canonKey(key)
    if type(key) ~= "string" then return nil end
    local lower = key:lower()
    return CAMEL[lower] or lower
end

local function normalizeWeights(weights)
    local out = {}
    if type(weights) ~= "table" then return out end
    for key, value in pairs(weights) do
        local canon = canonKey(key)
        local number = safeNumber(value)
        if canon and number ~= nil then
            out[canon] = number
        end
    end
    return out
end

TalentValuation.NormalizeWeights = normalizeWeights

local function formatScore(value)
    local number = safeNumber(value)
    if not number then return "0.00" end
    return string.format("%.2f", number)
end

------------------------------------------------------------------------------
-- Pure scoring pieces (run outside the client)
------------------------------------------------------------------------------

-- Resolve a kind to a concrete weight channel.
-- Returns stat, isPercent, isNeutral.
local function resolveKind(kind, classToken, caster, overrideStat)
    local target = TalentValuation.KindTarget[kind]
    if not target then return nil, false, true end    -- unknown kind -> neutral

    local stat = target.stat
    if stat == "neutral" then return nil, false, true end

    -- An explicit `stat` on the talent row wins for the two ambiguous kinds. A
    -- Shaman talent whose own text says Intellect must not resolve to Strength
    -- just because the class's melee primary happens to be Strength.
    if type(overrideStat) == "string" and overrideStat ~= ""
        and (stat == "primary" or stat == "damage") then
        local canon = canonKey(overrideStat)
        if canon then return canon, false, false end
    end

    if stat == "primary" then
        if caster then return "intellect", false, false end
        return PRIMARY_MELEE[classToken] or "strength", false, false
    elseif stat == "damage" then
        if caster then return "spellPower", false, false end
        return "attackPower", false, false
    elseif target.caster and caster then
        return target.caster, target.percent == true, false
    end

    return stat, target.percent == true, false
end

TalentValuation.ResolveKind = resolveKind

local function firstNumber(values)
    if type(values) ~= "table" then return nil end
    for _, value in ipairs(values) do
        local number = safeNumber(value)
        if number then return number end
    end
    return nil
end

-- The next-rank incremental effect. `rt.v[rank]` is the cumulative tooltip value
-- at that rank, so the step is rt.v[rank+1] - rt.v[rank], with rank 0 as the
-- zero baseline (a 1-point talent therefore uses its full effect).
-- Returns a number, or nil when there is no rank data.
local function computeIncrement(rt, rank, maxRank)
    if type(rt) ~= "table" or type(rt.v) ~= "table" then return nil end

    local current = safeNumber(rank) or 0
    local nextRank = current + 1
    if nextRank < 1 then return nil end

    local top = safeNumber(maxRank) or 0
    if top > 0 and nextRank > top then return nil end

    local nextValue = firstNumber(rt.v[nextRank])
    if nextValue == nil then return nil end

    local currentValue = 0
    if nextRank > 1 then
        local previous = firstNumber(rt.v[nextRank - 1])
        if previous ~= nil then currentValue = previous end
    end

    return nextValue - currentValue
end

TalentValuation.ComputeIncrement = computeIncrement

-- Whether the first %s slot of a rank-tooltip format is percent-shaped. The
-- data writes the tooltip's literal percent as "%%", so a slot written "%s%%"
-- is a percentage while a bare "%s" slot is a flat number. Only the first slot
-- matters: that is the slot ComputeIncrement reads as the next-rank increment.
local function isPercentFormat(format)
    if type(format) ~= "string" then return nil end
    local at = format:find("%s", 1, true)
    if not at then return nil end
    return format:sub(at + 2, at + 3) == "%%"
end

-- Look up a weight for one channel: profile -> ForeverEP -> neutral 1.
local function lookupWeight(stat, ctx)
    local profileWeights = ctx.profileWeights or {}
    local foreverEP = ctx.foreverEP or {}

    if profileWeights[stat] ~= nil then
        return profileWeights[stat], "profile"
    end

    local epStat = stat
    if foreverEP[epStat] == nil and PLAIN_CHANNEL[stat] then
        epStat = PLAIN_CHANNEL[stat]
    end
    if foreverEP[epStat] ~= nil then
        return foreverEP[epStat], "foreverEP"
    end

    return 1, "neutral"
end

-- Primary attributes that a "+X% stat" talent multiplies. The WoW UnitStat
-- indices (strength=1 .. spirit=5) let us read the player's CURRENT value so
-- "+2% Intellect" is valued as 0.02 * current intellect, not 0.02 flat points.
local PRIMARY_STAT_INDEX = {
    strength = 1, agility = 2, stamina = 3, intellect = 4, spirit = 5,
}

local function readCurrentStat(stat)
    local index = PRIMARY_STAT_INDEX[stat]
    if not index then return nil end
    if type(UnitStat) ~= "function" then return nil end
    local ok, value = pcall(UnitStat, "player", index)
    if not ok then return nil end
    local n = safeNumber(value)
    if not n or n <= 0 then return nil end
    return n
end

-- Pure score for one talent. `tv` is a TalentValues talent entry; `rank` is the
-- client's current rank; `ctx` carries profileWeights/foreverEP/ratingPerPercent/
-- classToken/caster. Returns { score, kind, targetStat, increment, weight,
-- weightSource, note, scoped }.
local function scoreTalent(tv, rank, ctx)
    ctx = ctx or {}

    local result = {
        kind = tv and tv.kind,
        targetStat = nil,
        increment = nil,
        weight = nil,
        weightSource = nil,
        score = 0,
        note = nil,
        scoped = false,
    }

    -- An ability-scoped talent names the specific abilities it affects, so it is
    -- worth only a fraction of a talent that affects everything.
    local scopeFactor = 1
    if type(tv) == "table" and type(tv.mentions) == "table" and #tv.mentions > 0 then
        scopeFactor = ABILITY_SCOPE_FACTOR
        result.scoped = true
    end

    local stat, _, isNeutral = resolveKind(tv and tv.kind, ctx.classToken, ctx.caster,
        tv and tv.stat)

    -- An authored score is data, not a guess: a one-point ability with no rank
    -- tooltip (Stormstrike, Water Shield, the cooldowns) carries its own number
    -- and the sentence behind it. It is used as written, never multiplied by the
    -- ability-scope factor, because the author already accounted for the scope.
    if tv and type(tv.score) == "number" and type(tv.rt) ~= "table" then
        result.score = tv.score
        result.weightSource = "authored"
        result.note = "(authored: " .. tostring(tv.scoreWhy or "no stat channel") .. ")"
        return result
    end

    if isNeutral then
        result.score = NEUTRAL_SCORE * scopeFactor
        result.weightSource = "neutral"
        if tv and (tv.kind == "other" or tv.kind == "cooldown" or tv.kind == "resist") then
            -- Declared unevaluable, with the reason, rather than pretending it
            -- ranked the talent against a stat.
            result.note = "(not scored: no stat channel)"
        else
            result.note = "(unknown kind)"
        end
        return result
    end

    local increment = computeIncrement(tv and tv.rt, rank, tv and tv.max)
    if increment == nil then
        result.score = NO_RANK_DATA_SCORE * scopeFactor
        result.weightSource = "neutral"
        result.note = "(no rank data)"
        return result
    end

    result.increment = increment
    result.targetStat = stat

    local weight, source = lookupWeight(stat, ctx)
    result.weight = weight
    result.weightSource = source

    local amount = increment
    if isPercentFormat(tv and tv.rt and tv.rt.f) then
        -- Percent-shaped tooltip: a +5% value is 0.05, not 5.
        local ratingKey = RATING_KEY[stat]
        if ratingKey then
            -- Rating stats (crit/hit/haste/dodge/parry/block). Profile weights
            -- are per RATING, so convert % -> rating; ForeverEP and the neutral
            -- fallback are per 1% (or unitless), so keep the percentage points.
            if source == "profile" then
                local perPercent = ctx.ratingPerPercent and ratingKey
                    and safeNumber(ctx.ratingPerPercent[ratingKey])
                if perPercent and perPercent > 0 then
                    amount = (increment / 100) * perPercent
                else
                    amount = increment / 100
                end
            end
        else
            -- Percent-shaped but not rating-shaped. A primary attribute percent
            -- (e.g. "+2% Intellect") is a multiplier on the player's CURRENT
            -- stat, so value = fraction * current stat. Other percents
            -- (damage/health/armor/mana) stay a rough fraction of the weight.
            local current = readCurrentStat(stat)
            if current then
                amount = (increment / 100) * current
            else
                amount = increment / 100
            end
        end
    end

    result.score = amount * weight * scopeFactor
    return result
end

TalentValuation.ScoreTalent = scoreTalent

------------------------------------------------------------------------------
-- TalentValues matching and the unlock bonus
------------------------------------------------------------------------------

local function normalizeName(name)
    if type(name) ~= "string" then return "" end
    return name:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Index one class's TalentValues tree: name -> { talent, tree }, plus the list
-- of talents per tree (for the unlock-bonus adjacency below).
local function buildClassIndex(classToken)
    local tv = LT.TalentValues
    if type(tv) ~= "table" or type(tv.classes) ~= "table" then return nil end
    local classData = tv.classes[classToken]
    if type(classData) ~= "table" or type(classData.trees) ~= "table" then return nil end

    local entries = {}
    local treeTalents = {}

    for treeIndex, tree in ipairs(classData.trees) do
        treeTalents[treeIndex] = treeTalents[treeIndex] or {}
        if type(tree) == "table" and type(tree.talents) == "table" then
            for _, talent in ipairs(tree.talents) do
                if type(talent) == "table" then
                    local key = normalizeName(talent.name)
                    if key ~= "" and entries[key] == nil then
                        entries[key] = { talent = talent, tree = treeIndex }
                    end
                    treeTalents[treeIndex][#treeTalents[treeIndex] + 1] = talent
                end
            end
        end
    end

    return { entries = entries, treeTalents = treeTalents }
end

-- Unlock bonus: taking the candidate `tvTalent` opens the talent directly below
-- it (same tree, next row, same column) when that talent is not reachable yet.
-- Bonus = 40% of the gated talent's own next-rank score.
--   tvTalent          the candidate's static TalentValues row (has row/col).
--   treeIndex         which static tree the candidate belongs to.
--   availableByName   set of talents currently available for a point.
--   clientRankByName  the client's current rank per talent name.
local function computeUnlockBonus(tvTalent, treeIndex, ctx, index, availableByName, clientRankByName)
    if not tvTalent or not treeIndex or type(index.treeTalents[treeIndex]) ~= "table" then
        return 0, nil
    end

    local row = safeNumber(tvTalent.row)
    local col = safeNumber(tvTalent.col)
    if not row or not col then return 0, nil end

    for _, below in ipairs(index.treeTalents[treeIndex]) do
        if safeNumber(below.row) == row + 1 and safeNumber(below.col) == col then
            -- `below` sits directly under the candidate (same column, next row).
            local belowKey = normalizeName(below.name)
            local belowRank = clientRankByName[belowKey] or 0
            local belowMax = safeNumber(below.max) or 0

            if belowMax > 0 and belowRank < belowMax then
                -- The gated talent can still take a point, and is not reachable
                -- yet, so taking the candidate is what opens it.
                if not availableByName[belowKey] then
                    local belowResult = scoreTalent(below, belowRank, ctx)
                    return 0.4 * (safeNumber(belowResult.score) or 0), below.name
                end
            end
            break
        end
    end

    return 0, nil
end

------------------------------------------------------------------------------
-- Client context (weights, melee/caster, rating table)
------------------------------------------------------------------------------

local EP_ROLE = { Tank = "tank", Damage = "dps", Healer = "heal" }

-- The ForeverEP weight table for a class, preferring the spec whose role matches
-- the active build's role. Used only when the profile has no weight for a stat.
local function resolveForeverEP(classToken, buildIndex)
    local tv = LT.TalentValues
    if type(tv) ~= "table" or type(tv.ForeverEP) ~= "table" then return nil end
    local classEP = tv.ForeverEP[classToken]
    if type(classEP) ~= "table" then return nil end

    local role = "Damage"
    if LT.Builds and type(LT.Builds.Get) == "function" then
        local ok, build = pcall(LT.Builds.Get, LT.Builds, buildIndex)
        if ok and type(build) == "table" and build.role then role = build.role end
    end
    local epRole = EP_ROLE[role] or "dps"

    local fallback
    for _, ep in pairs(classEP) do
        if type(ep) == "table" then
            fallback = fallback or ep
            if ep.role == epRole then return ep end
        end
    end
    return fallback
end

-- Melee vs caster, used to resolve `primary`/`damage` and the spell crit/hit
-- channels. Pure classes are decided by name; hybrids by their weight channels.
local function isCaster(classToken, profileWeights, foreverEP)
    if CASTER_CLASSES[classToken] then return true end
    if PHYSICAL_CLASSES[classToken] then return false end

    local weapon = profileWeights.weaponDPS or foreverEP.weaponDPS
        or profileWeights.mainHandDps
    local ap = profileWeights.attackPower or foreverEP.attackPower
    local sp = profileWeights.spellPower or foreverEP.spellPower

    if weapon then return false end
    if sp and (not ap or sp > ap) then return true end
    if ap and not sp then return false end
    if profileWeights.mp5 or profileWeights.spellCrit or profileWeights.spellHit
        or foreverEP.mp5 then return true end
    return false
end

local function buildContext(classToken, buildIndex)
    local ctx = {
        classToken = classToken,
        profileWeights = {},
        foreverEP = {},
        ratingPerPercent = {},
        caster = false,
        weightSource = "neutral",
    }

    local tv = LT.TalentValues
    if type(tv) == "table" and type(tv.RatingPerPercent) == "table" then
        ctx.ratingPerPercent = tv.RatingPerPercent
    end

    if LT.Profiles and type(LT.Profiles.GetEffective) == "function" then
        local ok, effective = pcall(LT.Profiles.GetEffective, LT.Profiles, buildIndex)
        if ok and type(effective) == "table" and effective.profile
            and type(effective.weights) == "table" then
            ctx.profileWeights = normalizeWeights(effective.weights)
            ctx.weightSource = "profile"
        end
    end

    local ep = resolveForeverEP(classToken, buildIndex)
    if ep then
        ctx.foreverEP = normalizeWeights(ep)
        if ctx.weightSource == "neutral" then ctx.weightSource = "foreverEP" end
    end

    ctx.caster = isCaster(classToken, ctx.profileWeights, ctx.foreverEP)

    return ctx
end

-- Prints the weights the advisor is using (profile + ForeverEP fallback), so the
-- capture shows which profile drove the ranking. classToken/buildIndex default to
-- the current player and the primary build (slot 1).
function TalentValuation:DumpWeights(classToken, buildIndex)
    classToken = classToken or (LT.player and LT.player.class) or "UNKNOWN"
    buildIndex = buildIndex or 1

    local ctx = buildContext(classToken, buildIndex)

    LT:Print("Weights — class " .. tostring(classToken) .. ", build " .. tostring(buildIndex)
        .. ", source " .. tostring(ctx.weightSource) .. ", caster=" .. tostring(ctx.caster))

    local function dump(table_, label)
        if type(table_) ~= "table" or next(table_) == nil then
            LT:Print("  " .. label .. ": (none)")
            return
        end
        local parts = {}
        for k, v in pairs(table_) do
            local n = tonumber(v)
            parts[#parts + 1] = tostring(k) .. "="
                .. (n and string.format("%.2f", n) or tostring(v))
        end
        table.sort(parts)
        LT:Print("  " .. label .. ": " .. table.concat(parts, ", "))
    end

    dump(ctx.profileWeights, "profile")
    dump(ctx.foreverEP, "foreverEP")
    return ctx
end

------------------------------------------------------------------------------
-- Ranking
------------------------------------------------------------------------------

-- Rank the available talents in `trees` (as returned by SpecAdvisor:Read).
-- `classToken`, `buildIndex` and `ctx` are optional overrides so the maths can
-- be exercised without the client. `buildIndex` selects the build (1 = primary,
-- 2 = offspec). Returns ranked (array, highest score first), or nil, reason.
function TalentValuation:Rank(trees, classToken, buildIndex, ctx)
    if type(trees) ~= "table" then return nil, "no talent trees" end

    classToken = classToken or (LT.player and LT.player.class) or "UNKNOWN"

    local index = buildClassIndex(classToken)
    if not index then return nil, "no TalentValues data for " .. tostring(classToken) end

    -- The available set comes from SpecAdvisor, which owns the tier gate.
    local available = {}
    if LT.SpecAdvisor and type(LT.SpecAdvisor.NextPoints) == "function" then
        local ok, list = pcall(LT.SpecAdvisor.NextPoints, trees)
        if ok and type(list) == "table" then available = list end
    end
    if #available == 0 then return {}, nil end

    buildIndex = buildIndex or 1
    ctx = ctx or buildContext(classToken, buildIndex)

    -- Name -> current rank (all trees) and the set of available names.
    local clientRankByName = {}
    for _, tree in ipairs(trees) do
        if type(tree) == "table" and type(tree.talents) == "table" then
            for _, talent in ipairs(tree.talents) do
                if type(talent) == "table" then
                    local key = normalizeName(talent.name)
                    if key ~= "" then
                        clientRankByName[key] = safeNumber(talent.rank) or 0
                    end
                end
            end
        end
    end

    local availableByName = {}
    for _, candidate in ipairs(available) do
        availableByName[normalizeName(candidate.name)] = true
    end

    -- Route hint: the authored route's next step for this class and spec, from
    -- the character's current ranks. It only annotates a candidate; it never
    -- changes a score.
    local routeStep = nil
    local routes = LT.TalentRoutes
    if type(routes) == "table" and type(routes.Next) == "function" then
        local spec
        if LT.Builds and type(LT.Builds.Get) == "function" then
            local ok, build = pcall(LT.Builds.Get, LT.Builds, buildIndex)
            if ok and type(build) == "table" then spec = build.spec end
        end
        local level = LT.player and LT.player.level
        local ok, row = pcall(routes.Next, routes, classToken, spec, level, clientRankByName)
        if ok and type(row) == "table" then routeStep = row end
    end

    local ranked = {}

    for _, candidate in ipairs(available) do
        local key = normalizeName(candidate.name)
        local entry = index.entries[key]
        local tvTalent = entry and entry.talent

        local result
        if not tvTalent then
            -- No static row: the client name is localised, or a C_Traits fallback
            -- like "Talent 123". Score it provisionally, as if it had no rank data.
            result = {
                kind = nil, targetStat = nil, increment = nil,
                weight = nil, weightSource = "neutral",
                score = NO_RANK_DATA_SCORE, note = "(no rank data)",
            }
        else
            result = scoreTalent(tvTalent, candidate.rank, ctx)
        end

        local bonus = 0
        local gatedName = nil
        if tvTalent and entry then
            bonus, gatedName = computeUnlockBonus(tvTalent, entry.tree, ctx, index,
                availableByName, clientRankByName)
        end

        result.name = candidate.name
        result.treeName = candidate.treeName
        result.treeIndex = candidate.treeIndex
        result.bonus = bonus or 0
        result.gatedName = gatedName
        result.total = (safeNumber(result.score) or 0) + (result.bonus or 0)
        result.scoreText = formatScore(result.total)

        local suffix = ""
        if result.bonus > 0 and gatedName then
            suffix = suffix .. " (+" .. formatScore(result.bonus)
                .. " unlocks " .. tostring(gatedName) .. ")"
        end
        if result.note then
            suffix = suffix .. " " .. result.note
        end
        if result.scoped then
            suffix = suffix .. " (scoped)"
        end
        if routeStep and normalizeName(candidate.name) == normalizeName(routeStep.name) then
            result.routeHint = true
            result.routeLevel = routeStep.level
            suffix = suffix .. " (route)"
        end
        result.suffix = suffix

        ranked[#ranked + 1] = result
    end

    table.sort(ranked, function(a, b)
        return a.total > b.total
    end)

    return ranked, nil
end
