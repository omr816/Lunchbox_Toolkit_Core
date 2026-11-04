--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — BestSetup

    One question, five possible answers: for each weapon configuration this
    character could actually wear, what is the best pair of items that is
    *available right now* — worn or in the bags — and what does it score?

    This is the page the player asked for on 2026-11-03: a Warrior sees the best
    two-hander, the best dual-wield pair and the best one-hand-and-shield pair;
    a Rogue sees only the dual-wield pair, because a shield and a two-hander are
    things that class can never use; a Mage sees a one-hander and a held item.

    Rules, all of them data rather than class names:
      * an item is a candidate when the character can wear it at this level and
        `Score` can score it; "can never use" and "needs level 40" are both out
      * the two-handed card takes one two-handed weapon and nothing else
      * dual wield takes two *different* one-handers: an off-hand weapon, or a
        main-hand one that the client says can fill the off hand
      * one-hand-and-shield takes a one-hander and a shield
      * one-handed takes a one-hander and, for a caster, a held item
      * ranged takes a bow, gun, crossbow or thrown weapon
      * a card with no answer is reported as unavailable, never guessed

    Nothing in this module equips, moves, sells or destroys anything: it only names
    the pair and its score. A page built on it may ask the client to equip that pair
    (`GearPopup:Equip`), which is the player's click and not this module's decision.
    The chooser (`BestSetup:Choose`) is pure: it reads only the records handed to
    it, so the whole decision can be tested without a client.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local BestSetup = {}
LT.BestSetup = BestSetup
LT.Modules.BestSetup = BestSetup

-- The cards, in the order the page shows them. The keys are the same weapon
-- configuration keys every build already uses.
BestSetup.STYLES = { "2H", "DUAL_WIELD", "1H_SHIELD", "1H", "RANGED" }

BestSetup.CACHE_LIMIT = 2
BestSetup.cache = {}
local cacheOrder = {}

------------------------------------------------------------------------------
-- Small reads
------------------------------------------------------------------------------

local function secretValue(value)
    if type(LT.IsSecret) ~= "function" then return false end
    local ok, result = pcall(LT.IsSecret, LT, value)
    return ok and result == true
end

-- InCombatLockdown is the only source for this; a client that cannot answer is
-- not treated as combat, because nothing here builds a frame.
local function combatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

local function playerLevel()
    local levels = LT.Levels
    if type(levels) == "table" and type(levels.GetCurrentLevel) == "function" then
        local ok, level = pcall(levels.GetCurrentLevel, levels)
        if ok and tonumber(level) then return tonumber(level) end
    end

    local stored = LT.player and tonumber(LT.player.level)
    if stored then return stored end

    local ok, level = pcall(UnitLevel, "player")
    if ok and tonumber(level) then return tonumber(level) end

    return 1
end

-- Does the client think this character may ever put one weapon in each hand?
-- Asked once per computation; an unanswered question keeps dual wield on the
-- page rather than deleting a whole card from a class that can use it.
local function canDualWield()
    if type(CanDualWield) ~= "function" then return true end
    local ok, value = pcall(CanDualWield)
    if not ok then return true end
    return value ~= false
end

------------------------------------------------------------------------------
-- The chooser (pure)
--
-- candidates: array of { link, name, score, equipLoc, source }
-- Returns, per style key: { key, main, off, total, available, reason }
------------------------------------------------------------------------------

local function better(candidate, incumbent)
    if not incumbent then return true end
    local a = tonumber(candidate.score)
    local b = tonumber(incumbent.score)
    if not a then return false end
    if not b then return true end
    if a ~= b then return a > b end
    -- A tie is decided by link so the page cannot flicker between two equals.
    return tostring(candidate.link) < tostring(incumbent.link)
end

local function isMainHand(loc)
    return loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONMAINHAND"
end

local function isOffHandWeapon(loc)
    return loc == "INVTYPE_WEAPON" or loc == "INVTYPE_WEAPONOFFHAND"
end

local function isRangedWeapon(loc)
    return loc == "INVTYPE_RANGED" or loc == "INVTYPE_RANGEDRIGHT" or loc == "INVTYPE_THROWN"
end

local function total(main, off)
    local sum = tonumber(main and main.score) or 0
    if off then sum = sum + (tonumber(off.score) or 0) end
    return sum
end

-- The best off-hand that is not the item already chosen for the main hand: one
-- weapon cannot be worn twice. `pool` is filtered by the caller's predicate.
local function bestOff(candidates, accept, excludeLink)
    local pick
    for _, candidate in ipairs(candidates) do
        if candidate.link ~= excludeLink and accept(candidate.equipLoc) then
            if better(candidate, pick) then pick = candidate end
        end
    end
    return pick
end

local function bestMain(candidates, accept)
    local pick
    for _, candidate in ipairs(candidates) do
        if accept(candidate.equipLoc) and better(candidate, pick) then pick = candidate end
    end
    return pick
end

function BestSetup:Choose(candidates, style, options)
    options = options or {}
    candidates = type(candidates) == "table" and candidates or {}

    local result = { key = style, main = nil, off = nil, total = 0, available = false }

    if style == "2H" then
        local main = bestMain(candidates, function(loc) return loc == "INVTYPE_2HWEAPON" end)
        if main then
            result.main, result.total, result.available = main, total(main), true
        else
            result.reason = "no two-handed weapon available"
        end
        return result
    end

    if style == "RANGED" then
        local main = bestMain(candidates, isRangedWeapon)
        if main then
            result.main, result.total, result.available = main, total(main), true
        else
            result.reason = "no ranged weapon available"
        end
        return result
    end

    if style == "DUAL_WIELD" then
        if options.canDualWield == false then
            result.reason = "this character cannot dual wield yet"
            return result
        end

        local main = bestMain(candidates, isMainHand)
        local off = bestOff(candidates, isOffHandWeapon, main and main.link)
        if main and off then
            result.main, result.off = main, off
            result.total, result.available = total(main, off), true
        elseif not main then
            result.reason = "no one-handed weapon available"
        else
            result.reason = "only one dual-wieldable weapon available"
        end
        return result
    end

    if style == "1H_SHIELD" then
        local main = bestMain(candidates, isMainHand)
        local off = bestOff(candidates, function(loc) return loc == "INVTYPE_SHIELD" end)
        if main and off then
            result.main, result.off = main, off
            result.total, result.available = total(main, off), true
        elseif not main then
            result.reason = "no one-handed weapon available"
        else
            result.reason = "no shield available"
        end
        return result
    end

    if style == "1H" then
        local main = bestMain(candidates, isMainHand)
        local off = bestOff(candidates, function(loc) return loc == "INVTYPE_HOLDABLE" end)
        if main then
            result.main, result.off = main, off
            result.total, result.available = total(main, off), true
        else
            result.reason = "no one-handed weapon available"
        end
        return result
    end

    result.reason = "unknown weapon configuration " .. tostring(style)
    return result
end

-- The style a single item belongs to, and which hand it would fill. Used by the
-- tooltip to say "this is X below the best you own". Returns nil for anything
-- that is not a weapon, a shield or a held item.
function BestSetup:StyleFor(equipLoc)
    if equipLoc == "INVTYPE_2HWEAPON" then return "2H", "main" end
    if equipLoc == "INVTYPE_SHIELD" then return "1H_SHIELD", "off" end
    if equipLoc == "INVTYPE_HOLDABLE" then return "1H", "off" end
    if isRangedWeapon(equipLoc) then return "RANGED", "main" end
    if isMainHand(equipLoc) then return "DUAL_WIELD", "main" end
    if isOffHandWeapon(equipLoc) then return "DUAL_WIELD", "off" end
    return nil
end

------------------------------------------------------------------------------
-- Gathering candidates from the client
------------------------------------------------------------------------------

-- A card is only worth showing when the class could ever use it. The class packs
-- already answer that per weapon and armour type, so no class names are written
-- here: a rule that is missing is not a refusal (the pack says nothing), while
-- `never = true` is. The keys are the same ones Usability maps subclass ids to.
local WEAPONS_TWO_HAND = { "Axe2H", "Mace2H", "Sword2H", "Staff", "Polearm" }
local WEAPONS_ONE_HAND = { "Axe1H", "Mace1H", "Sword1H", "Dagger", "Fist" }
local WEAPONS_RANGED = { "Bow", "Gun", "Crossbow", "Thrown", "Wand" }

local function allowedKeys(classToken, family, keys)
    local usability = LT.Usability
    if type(usability) ~= "table" or type(usability.GetRule) ~= "function" then return nil end

    local mentioned, positive = false, false
    for _, key in ipairs(keys) do
        local ok, rule = pcall(usability.GetRule, usability, classToken, family, key)
        if ok and rule ~= nil then
            mentioned = true
            local never = type(rule) == "table" and rule.never == true
            if not never then positive = true end
        end
    end

    -- true: the pack allows at least one key. false: it spoke about this family
    -- and allowed none of it. nil: it says nothing, which is not a refusal.
    if positive then return true end
    if mentioned then return false end
    return nil
end

-- Which cards this character's class should see, in page order.
--
-- The class's own starter templates are the source: every template names the
-- weapon configuration it is built for, and those templates are already
-- validated against the class's usable rules at load. A Shaman's templates are
-- two-handed, dual wield and shield, so a bare one-hander and a ranged card are
-- never shown; a Rogue's are dual wield only. The player's own words were "on
-- shaman no need for one handed, dont show it and dont show ranged".
function BestSetup:RelevantStyles(classToken)
    local token = classToken or (LT.player and LT.player.class)
    local packs = LT.ClassPacks
    local wanted = {}

    if type(token) == "string" and type(packs) == "table" and type(packs.Get) == "function" then
        local ok, definition = pcall(packs.Get, packs, token)
        if ok and type(definition) == "table" and type(definition.templates) == "table" then
            for _, template in ipairs(definition.templates) do
                local setup = type(template) == "table" and template.weaponSetup or nil
                if type(setup) == "string" then wanted[setup] = true end
            end
        end
    end

    local list = {}
    for _, key in ipairs(self.STYLES) do
        if wanted[key] then list[#list + 1] = key end
    end

    -- A class pack with no templates to read: fall back to its usable rules, and
    -- if even those cannot be settled, show every card rather than an empty page
    -- that looks like a bug.
    if #list == 0 and type(token) == "string" then
        local twoHand = allowedKeys(token, "weapons", WEAPONS_TWO_HAND)
        local oneHand = allowedKeys(token, "weapons", WEAPONS_ONE_HAND)
        local ranged = allowedKeys(token, "weapons", WEAPONS_RANGED)
        local shield = allowedKeys(token, "armour", { "Shield" })
        local dual = canDualWield() and oneHand ~= false

        if twoHand ~= false then list[#list + 1] = "2H" end
        if dual then list[#list + 1] = "DUAL_WIELD" end
        if shield ~= false and oneHand ~= false then list[#list + 1] = "1H_SHIELD" end
        if oneHand ~= false and shield == false and not dual then list[#list + 1] = "1H" end
        if ranged ~= false then list[#list + 1] = "RANGED" end
    end

    if #list == 0 then return { "2H", "DUAL_WIELD", "1H_SHIELD", "1H", "RANGED" } end
    return list
end

local function scoreOf(link, buildIndex)
    local score = LT.Score
    if type(score) ~= "table" or type(score.ScoreItemWithImbue) ~= "function" then
        return nil
    end

    local ok, result = pcall(score.ScoreItemWithImbue, score, link, buildIndex)
    if not ok or type(result) ~= "table" or not result.ok then return nil end
    if type(result.score) ~= "number" then return nil end
    return result.score
end

-- Usability is asked first, exactly as the tooltip does, so the page cannot
-- recommend something the character can never wear.
local function usableNow(link, identity, level)
    if not identity then return false end

    local required = tonumber(identity.requiredLevel)
    if required and required > level then return false end

    local usability = LT.Usability
    if type(usability) ~= "table" or type(usability.GetVerdict) ~= "function" then
        return identity.canUse ~= false
    end

    local ok, verdict = pcall(usability.GetVerdict, usability, link, { identity = identity })
    if not ok or type(verdict) ~= "table" then return identity.canUse ~= false end

    if verdict.verdict == usability.NEVER then return false end
    if verdict.verdict == usability.DEFERRED then return false end
    if verdict.verdict == usability.UNKNOWN then return identity.canUse ~= false end
    return true
end

local function addCandidate(list, seen, link, source, buildIndex, level)
    if type(link) ~= "string" or link == "" then return end
    if secretValue(link) then return end
    if not link:find("item:", 1, true) then return end
    if seen[link] then return end

    local itemStats = LT.ItemStats
    if type(itemStats) ~= "table" or type(itemStats.GetIdentity) ~= "function" then return end

    local ok, identity = pcall(itemStats.GetIdentity, itemStats, link)
    if not ok or type(identity) ~= "table" then return end
    if not identity.equipLoc then return end
    if not usableNow(link, identity, level) then return end

    local score = scoreOf(link, buildIndex)
    if not score then return end

    seen[link] = true
    list[#list + 1] = {
        link = link,
        name = type(identity.name) == "string" and identity.name or nil,
        icon = identity.texture,
        score = score,
        equipLoc = identity.equipLoc,
        source = source,
    }
end

-- Worn items are candidates too: the best available pair is often the pair the
-- character is already wearing, and a page that only read the bags would claim
-- otherwise the moment the bags were empty.
local function gather(buildIndex, level)
    local candidates, seen = {}, {}
    local gearSets = LT.GearSets

    if type(gearSets) == "table" and type(gearSets.GetEquippedLink) == "function" then
        for _, slot in ipairs({ 16, 17, 18 }) do
            local ok, link = pcall(gearSets.GetEquippedLink, gearSets, slot)
            if ok then addCandidate(candidates, seen, link, "worn", buildIndex, level) end
        end
    end

    local gearCheck = LT.GearCheck
    if type(gearCheck) == "table" and type(gearCheck.EachBagLink) == "function" then
        pcall(gearCheck.EachBagLink, gearCheck, function(link)
            addCandidate(candidates, seen, link, "bags", buildIndex, level)
            return true
        end)
    end

    return candidates
end

------------------------------------------------------------------------------
-- Public result, cached on the same revision the gear check uses
------------------------------------------------------------------------------

function BestSetup:Key(buildIndex, level)
    local gearCheck = LT.GearCheck
    if type(gearCheck) == "table" and type(gearCheck.Key) == "function" then
        local ok, key = pcall(gearCheck.Key, gearCheck, buildIndex, level)
        if ok and type(key) == "string" then return key end
    end

    local profiles = LT.Profiles
    return tostring(buildIndex) .. "|" .. tostring(level) .. "|"
        .. tostring(profiles and profiles.revision or 0)
end

function BestSetup:Invalidate()
    self.cache = {}
    cacheOrder = {}
end

-- Returns { buildIndex, level, styles = { result... }, best = key|nil,
--           bestTotal, candidates = count, worn = {...} } or nil + reason.
function BestSetup:Compute(buildIndex, opts)
    opts = opts or {}

    if combatLocked() then return nil, "combat" end

    local builds = LT.Builds
    if type(builds) ~= "table" or type(builds.GetActiveIndex) ~= "function" then
        return nil, "no-builds"
    end

    local index = tonumber(buildIndex)
    if not index then
        local ok, active = pcall(builds.GetActiveIndex, builds)
        if not ok then return nil, "no-builds" end
        index = tonumber(active) or 1
    end

    local level = playerLevel()
    local key = self:Key(index, level)
    local hit = self.cache[key]
    if hit and not opts.noCache then return hit end

    local candidates = gather(index, level)
    local dual = canDualWield()

    local styles = {}
    local bestKey, bestTotal
    for _, style in ipairs(self:RelevantStyles()) do
        local result = self:Choose(candidates, style, { canDualWield = dual })
        local definition = type(LT.GetWeaponSetupDefinition) == "function"
            and LT:GetWeaponSetupDefinition(style) or nil
        result.label = (definition and definition.label) or style
        styles[#styles + 1] = result

        if result.available and (not bestTotal or result.total > bestTotal) then
            bestKey, bestTotal = style, result.total
        end
    end

    -- The pair actually worn, so the page can put "equipped now" above the sets
    -- and every card can be read against it.
    local worn = { main = nil, off = nil, total = 0 }
    local gearSets = LT.GearSets
    local itemStats = LT.ItemStats
    if type(gearSets) == "table" and type(gearSets.GetEquippedLink) == "function"
        and type(itemStats) == "table" and type(itemStats.GetIdentity) == "function" then
        for _, hand in ipairs({ { key = "main", slot = 16 }, { key = "off", slot = 17 } }) do
            local ok, link = pcall(gearSets.GetEquippedLink, gearSets, hand.slot)
            if ok and type(link) == "string" and link ~= "" and not secretValue(link) then
                local okId, identity = pcall(itemStats.GetIdentity, itemStats, link)
                local score = scoreOf(link, index)
                if okId and type(identity) == "table" and score then
                    worn[hand.key] = {
                        link = link,
                        name = type(identity.name) == "string" and identity.name or nil,
                        icon = identity.texture,
                        score = score,
                    }
                    worn.total = worn.total + score
                end
            end
        end
    end

    local result = {
        buildIndex = index,
        level = level,
        styles = styles,
        best = bestKey,
        bestTotal = bestTotal,
        worn = worn,
        candidates = #candidates,
    }

    if not opts.noCache then
        if self.cache[key] == nil then table.insert(cacheOrder, key) end
        self.cache[key] = result
        while #cacheOrder > self.CACHE_LIMIT do
            self.cache[table.remove(cacheOrder, 1)] = nil
        end
    end

    return result
end

-- How far one item is from the best this character owns for its own hand and
-- style: positive means the hovered item is better than the best available.
function BestSetup:ForItem(itemLink, buildIndex)
    local itemStats = LT.ItemStats
    if type(itemStats) ~= "table" or type(itemStats.GetIdentity) ~= "function" then return nil end

    local ok, identity = pcall(itemStats.GetIdentity, itemStats, itemLink)
    if not ok or type(identity) ~= "table" then return nil end

    local style, hand = self:StyleFor(identity.equipLoc)
    if not style then return nil end

    local computed = self:Compute(buildIndex)
    if type(computed) ~= "table" then return nil end

    local entry
    for _, candidate in ipairs(computed.styles) do
        if candidate.key == style then entry = candidate break end
    end
    if not entry or not entry.available then return nil end

    local best = hand == "off" and entry.off or entry.main
    if not best then return nil end

    local score = scoreOf(itemLink, computed.buildIndex)
    if not score then return nil end

    return {
        style = style,
        label = entry.label,
        hand = hand,
        bestLink = best.link,
        bestName = best.name,
        bestScore = best.score,
        delta = score - best.score,
        sameItem = best.link == itemLink,
    }
end

-- The same events GearCheck invalidates on. One listener, two caches, so the
-- page and the scan can never disagree about the bags.
for _, event in ipairs({
    LT.EVENT_LEVEL, LT.EVENT_BUILDS, LT.EVENT_PROFILE, LT.EVENT_GEARSET,
    "EQUIPMENT_CHANGED", "INVENTORY_CHANGED",
}) do
    if type(event) == "string" and type(LT.On) == "function" then
        pcall(LT.On, LT, event, function()
            BestSetup:Invalidate()
        end, "BestSetup")
    end
end

do
    local frame = LT.frame
    if (type(frame) == "table" or type(frame) == "userdata")
        and type(frame.RegisterEvent) == "function"
        and type(frame.HookScript) == "function" then
        local watched = {
            BAG_UPDATE_DELAYED = true,
            GET_ITEM_INFO_RECEIVED = true,
            ITEM_DATA_LOAD_RESULT = true,
        }
        for event in pairs(watched) do pcall(frame.RegisterEvent, frame, event) end

        pcall(frame.HookScript, frame, "OnEvent", function(_, event)
            if watched[event] then BestSetup:Invalidate() end
        end)
    end
end
