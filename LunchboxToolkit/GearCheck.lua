--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — GearCheck
    What in the bags would be worn now, and what will be worth wearing later.

    This module answers one question and draws nothing. It walks the backpack
    (and the bank, when asked) and returns two lists of plain rows; every frame
    and every string belongs to the UI.

      now   the character can wear it at this level, has the training, and it
            scores higher than the item it would replace
      soon  the same, except the item's own level requirement, or the level at
            which the character's class unlocks the armour or weapon type, is
            above the character's level; the row carries the gating level so the
            caller can say "at level 40" rather than guessing

    An item whose type the character can never use, or which needs a proficiency
    the character has not trained and whose unlock level is not known, is in
    neither list: "soon" means a level the client actually stated.

    Nothing here equips, sells, moves or destroys anything, and no bag slot is
    read while the character is in combat.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local GearCheck = {}
LT.GearCheck = GearCheck
LT.Modules.GearCheck = GearCheck

GearCheck.SOURCE_BAGS = "bags"
GearCheck.SOURCE_BANK = "bank"

-- A scan result is a handful of plain rows, so four entries is enough for the
-- caller to move between the two build slots and back without rescanning.
GearCheck.CACHE_LIMIT = 4

GearCheck.cache = {}
GearCheck.revision = 0

local cacheOrder = {}

------------------------------------------------------------------------------
-- Reading the client state
------------------------------------------------------------------------------

local function secretValue(value)
    if type(LT.IsSecret) ~= "function" then return false end
    local ok, result = pcall(LT.IsSecret, LT, value)
    return ok and result == true
end

-- C_Container was verified present on this client; the pre-C_Container globals
-- are kept as a fallback because they cost six lines and a missing bag API
-- would cost the whole scan. Both routes are reads.
local function containerAPI()
    local modern = C_Container
    if type(modern) == "table"
        and type(modern.GetContainerNumSlots) == "function"
        and type(modern.GetContainerItemLink) == "function" then
        return {
            slots  = modern.GetContainerNumSlots,
            link   = modern.GetContainerItemLink,
            modern = true,
        }
    end

    if type(GetContainerNumSlots) == "function" and type(GetContainerItemLink) == "function" then
        return {
            slots  = GetContainerNumSlots,
            link   = GetContainerItemLink,
            modern = false,
        }
    end

    return nil
end

-- The backpack is bag 0; the equipped bags follow it, which is why the walk is
-- "0 .. NUM_BAG_SLOTS" (NUM_BAG_SLOTS + 1 containers).
local function bagCount()
    return tonumber(NUM_BAG_SLOTS) or 4
end

-- The modern bank is a set of purchased tabs, and each tab id is itself a
-- container the bag API can read. C_Bank is the only honest source for which
-- tabs this character owns; an id the client did not list is never guessed at.
-- nil means "this client cannot answer", which is not "no tabs".
local function bankTabContainers()
    if type(C_Bank) ~= "table" then return nil end
    if type(C_Bank.CanViewBank) ~= "function"
        or type(C_Bank.FetchPurchasedBankTabIDs) ~= "function" then
        return nil
    end

    local okView, canView = pcall(C_Bank.CanViewBank)
    if not okView or canView == false then return nil end

    local bankType = (type(Enum) == "table" and type(Enum.BankType) == "table")
        and Enum.BankType.Character or nil

    local okIds, ids
    if bankType then
        okIds, ids = pcall(C_Bank.FetchPurchasedBankTabIDs, bankType)
    else
        okIds, ids = pcall(C_Bank.FetchPurchasedBankTabIDs)
    end

    if not okIds or type(ids) ~= "table" then return nil end

    local list = {}
    for index = 1, #ids do
        local container = tonumber(ids[index])
        if container then table.insert(list, container) end
    end

    if #list == 0 then return nil end
    return list
end

-- The bank is the purchased tabs when the client can name them, and otherwise
-- the bank frame's own container plus, when the client reports how many bank
-- bags it has, the bags after the backpack. Without NUM_BANKBAGSLOTS only the
-- first is read: guessing bag ids could read a bag that is not there.
--
-- Returns the container list and the route that answered ("bank-tabs",
-- "bank-bags" or "none"), so the caller can say which was read.
local function bankContainers()
    local tabs = bankTabContainers()
    if tabs then return tabs, "bank-tabs" end

    local list = {}

    local main = tonumber(BANK_CONTAINER)
    if main then table.insert(list, main) end

    local count = tonumber(NUM_BANKBAGSLOTS)
    if count and count > 0 then
        local first = bagCount() + 1
        for offset = 0, count - 1 do
            table.insert(list, first + offset)
        end
    end

    return list, (#list > 0 and "bank-bags" or "none")
end

-- Every readable item link in the backpack, in slot order. The scan below has
-- its own loop because it also reads the bank and tags each row with where it
-- came from; this walker is for callers that want the whole bag and nothing
-- else (BestSetup). One definition of "a readable link", two ways to use it.
function GearCheck:EachBagLink(fn)
    if type(fn) ~= "function" then return 0 end

    local api = containerAPI()
    if not api then return 0 end

    local count = 0
    for bag = 0, bagCount() do
        local okSlots, slots = pcall(api.slots, bag)
        local total = okSlots and tonumber(slots) or 0

        if total > 0 then
            for slot = 1, total do
                local okLink, link = pcall(api.link, bag, slot)
                if okLink and type(link) == "string" and link ~= ""
                    and not secretValue(link) and link:find("item:", 1, true) then
                    count = count + 1
                    if fn(link) == false then return count end
                end
            end
        end
    end

    return count
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

local function resolveBuildIndex(opts)
    local requested = tonumber(opts and opts.buildIndex)
    if requested then return requested end

    local builds = LT.Builds
    if type(builds) == "table" and type(builds.GetActiveIndex) == "function" then
        local ok, index = pcall(builds.GetActiveIndex, builds)
        if ok and tonumber(index) then return tonumber(index) end
    end

    return 1
end

-- InCombatLockdown is the only source for this, and a client that cannot answer
-- is not treated as combat: the scan below only reads.
local function combatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

local function cannot(reason)
    return { now = {}, soon = {}, reason = reason }
end

------------------------------------------------------------------------------
-- The item itself
------------------------------------------------------------------------------

-- A weapon or a piece of armour that maps to a worn slot. Reagents, quest items
-- and ammunition have no equip location and never reach the scorer.
local function equippable(identity)
    local itemStats = LT.ItemStats
    if type(itemStats) ~= "table" or type(itemStats.GetEquippableSlots) ~= "function" then
        return identity.equipLoc ~= nil
    end

    local ok, slots = pcall(itemStats.GetEquippableSlots, itemStats, identity.equipLoc)
    return ok and type(slots) == "table" and #slots > 0
end

local function verdictFor(link, identity, level)
    local usability = LT.Usability
    if type(usability) ~= "table" or type(usability.GetVerdict) ~= "function" then
        return nil
    end

    local ok, verdict = pcall(usability.GetVerdict, usability, link, {
        identity = identity,
        level = level,
    })

    if not ok or type(verdict) ~= "table" then return nil end
    return verdict
end

-- The level at which this class unlocks the item's armour/weapon type, when the
-- class pack states one. "Mail at 40" is a level even though the item needs no
-- level of its own, so a DEFERRED training gate is a "soon" row. No client call:
-- the pack is plain data, which keeps Placement testable.
local function packUnlockLevel(verdict)
    if type(verdict) ~= "table" then return nil end

    local key, family = verdict.key, verdict.family
    if type(key) ~= "string" or (family ~= "armour" and family ~= "weapons") then
        return nil
    end

    local usability = LT.Usability
    local classToken = LT.player and LT.player.class
    if type(classToken) ~= "string" then return nil end
    if type(usability) ~= "table" or type(usability.GetRule) ~= "function" then
        return nil
    end

    local ok, rule = pcall(usability.GetRule, usability, classToken, family, key)
    if not ok or type(rule) ~= "table" then return nil end

    return tonumber(rule.fromLevel)
end

-- Pure: no client calls, so the harness can drive it. Decides which list an
-- item belongs in from the verdict Usability already reached and the item's own
-- level requirement. Returns the list name and the level that gates it.
function GearCheck:Placement(verdict, identity, level)
    local usability = LT.Usability
    if type(verdict) ~= "table" or type(usability) ~= "table" then return nil end

    local required = type(identity) == "table" and tonumber(identity.requiredLevel) or nil
    local current = tonumber(level)
    local stated = verdict.verdict

    if stated == usability.USABLE then
        return "now", required
    end

    if stated == usability.DEFERRED then
        -- A training gate the class pack puts at a level is a number like any
        -- other requirement, so it belongs in "soon" rather than being refused.
        -- The verdict keeps the number for callers that want to say why.
        local unlock = tonumber(verdict.unlockLevel) or packUnlockLevel(verdict)
        if unlock then verdict.unlockLevel = unlock end

        local gate = required
        if unlock and (not gate or unlock > gate) then gate = unlock end

        -- Only a number makes it "soon". A proficiency with no known level has
        -- nothing to report, so the item is refused rather than half-claimed.
        if gate and current and gate > current then
            return "soon", gate
        end
        return nil
    end

    -- NEVER: no level changes it. UNKNOWN: the module cannot claim the
    -- character could wear it, and a scan that cannot answer stays silent.
    return nil
end

local function compareFor(link, buildIndex)
    local compare = LT.Compare
    if type(compare) ~= "table" then return nil end

    -- AgainstEquipped is the question a bag scan asks: "is this better than
    -- what is on the character right now?" ForBuild is the fallback for a
    -- client where the equipped path is unavailable.
    local fn = compare.AgainstEquipped or compare.ForBuild
    if type(fn) ~= "function" then return nil end

    local ok, comparison = pcall(fn, compare, link, buildIndex)
    if not ok or type(comparison) ~= "table" then return nil end
    return comparison
end

local function nameFor(identity, comparison, link)
    if type(identity.name) == "string" and identity.name ~= "" then
        return identity.name
    end

    if type(comparison.itemName) == "string" and comparison.itemName ~= "" then
        return comparison.itemName
    end

    local bracket = tostring(link or ""):match("%[(.-)%]")
    if bracket and bracket ~= "" then return bracket end

    return nil
end

-- Does this item fill a slot that is empty right now? The tooltip already says
-- "grey — better than empty" on that rule (Tooltip:GreyBeatsEmpty calls this same
-- Compare function); the bag marker must agree with the panel rather than
-- silently refusing a zero-scored item that the panel just promised was worth
-- carrying.
local function hasEmptySlot(identity)
    local compare = LT.Compare
    if type(compare) ~= "table" or type(compare.HasEmptySlotFor) ~= "function" then
        return false
    end
    local ok, empty = pcall(compare.HasEmptySlotFor, compare, identity)
    return ok and empty == true
end

-- One row, or nil when the item does not beat what is worn. The comparison's
-- headline is the best swap for this item; rings and trinkets can target more
-- than one slot, and the number the caller shows must match the slot it names.
-- `emptySlot` lets a zero-difference row through: an item that fills an empty
-- slot is worth carrying even when its score is zero.
local function rowFor(link, identity, source, comparison, emptySlot, armour, bagID, bagSlot)
    local difference = tonumber(comparison.difference)
    if not difference or difference < 0 then return nil end
    if difference == 0 and not emptySlot then return nil end

    local slot = tonumber(comparison.referenceSlot)
    local headline = comparison.headline
    if not slot and type(headline) == "table" then
        slot = tonumber(headline.slot)
    end
    if not slot then return nil end

    local score = tonumber(comparison.candidateScore)
    if not score and type(comparison.candidate) == "table" then
        score = tonumber(comparison.candidate.score)
    end

    return {
        link          = link,
        name          = nameFor(identity, comparison, link),
        slot          = slot,
        score         = score,
        delta         = difference,
        emptySlot     = difference == 0,
        armour        = tonumber(armour),
        requiredLevel = tonumber(identity.requiredLevel),
        source        = source,
        -- Where it sits, so the window can equip it by location: this client
        -- has no EquipItemByName (2026-11-05).
        bagID         = tonumber(bagID),
        bagSlot       = tonumber(bagSlot),
    }
end

------------------------------------------------------------------------------
-- The walk
------------------------------------------------------------------------------

local function evaluate(link, source, context, bagID, bagSlot)
    local itemStats = LT.ItemStats

    local okGet, stats, identity = pcall(itemStats.Get, itemStats, link)

    -- The client answers for a link only once it has cached the item, so a
    -- missing identity may be "not yet" rather than "never". Such a scan is
    -- not stored: freezing an empty answer at login would hide every upgrade
    -- until some unrelated inventory event happened to invalidate it.
    if not okGet or type(identity) ~= "table" then
        context.unreadable = true
        return
    end

    if not equippable(identity) then return end

    -- One line per dropped item, capped per scan, so an item visible in the bag
    -- with no arrow can be explained from the saved chat instead of a screenshot.
    local function skip(why)
        if type(LT.Diag) ~= "function" then return end
        -- Its own switch: these lines answer "why has this item no arrow", which
        -- is useful for a minute and noise for a session. They solved the
        -- Forever empty-slot question on 2026-11-05 and are off by default now.
        local options = LT.Database and LT.Database.GetOptions and LT.Database:GetOptions()
        if type(options) ~= "table" or options.bagScanDiagnostics ~= true then return end
        if (context.skipped or 0) >= 8 then return end
        context.skipped = (context.skipped or 0) + 1
        pcall(LT.Diag, LT, "[Bag] no mark: " .. tostring(nameFor(identity, nil, link))
            .. " — " .. why
            .. " (quality " .. tostring(identity.quality)
            .. ", class " .. tostring(identity.classID) .. "/" .. tostring(identity.subClassID) .. ")")
    end

    local verdict = verdictFor(link, identity, context.level)
    if not verdict then
        skip("no verdict")
        return
    end

    local placement, required = GearCheck:Placement(verdict, identity, context.level)
    if not placement then
        skip("verdict " .. tostring(verdict.verdict) .. " key " .. tostring(verdict.key))
        return
    end

    local comparison = compareFor(link, context.buildIndex)
    if not comparison then
        skip("no comparison")
        return
    end

    local row = rowFor(link, identity, source, comparison,
        placement == "now" and hasEmptySlot(identity),
        type(stats) == "table" and stats.armor or nil,
        bagID, bagSlot)
    if not row then
        skip("difference " .. tostring(comparison.difference)
            .. " at slot " .. tostring(comparison.referenceSlot
                or (type(comparison.headline) == "table" and comparison.headline.slot))
            .. " emptySlot=" .. tostring(hasEmptySlot(identity))
            .. " equipLoc=" .. tostring(identity.equipLoc))
        return
    end

    if required then row.requiredLevel = required end
    if tonumber(verdict.unlockLevel) then row.unlockLevel = tonumber(verdict.unlockLevel) end

    if placement == "soon" then
        table.insert(context.soon, row)
    else
        table.insert(context.now, row)
    end
end

-- T-46: a one-hander is not an upgrade on its own when the hands are full of a
-- two-handed weapon. The package is 1H + the best shield in the bags, scored
-- against the worn two-hander added whole. The delta is one number for two
-- items, and the row carries both links so the caller can name and move them.
--
-- Pure part first, so /lt test can check the arithmetic without a client.
function GearCheck.PackageDelta(wornScore, weaponScore, shieldScore)
    local worn = tonumber(wornScore)
    local weapon = tonumber(weaponScore)
    local shield = tonumber(shieldScore)
    if not worn or not weapon or not shield then return nil end
    return (weapon + shield) - worn
end

local function scanWeaponPackage(context)
    local gearSets = LT.GearSets
    local score = LT.Score
    local itemStats = LT.ItemStats
    local usability = LT.Usability

    if type(gearSets) ~= "table" or type(gearSets.GetEquippedLink) ~= "function" then return end
    if type(score) ~= "table" or type(itemStats) ~= "table" then return end
    if type(itemStats.GetIdentity) ~= "function" then return end

    local scorer = score.ScoreItemWithImbue or score.ScoreItem
    if type(scorer) ~= "function" then return end

    local okMain, mainLink = pcall(gearSets.GetEquippedLink, gearSets, 16)
    if not okMain or type(mainLink) ~= "string" or mainLink == "" then return end

    local mainIdentity = itemStats:GetIdentity(mainLink)
    if type(mainIdentity) ~= "table" or mainIdentity.equipLoc ~= "INVTYPE_2HWEAPON" then return end

    local okWorn, worn = pcall(scorer, score, mainLink, context.buildIndex)
    if not okWorn or type(worn) ~= "table" or not worn.ok then return end
    local wornScore = tonumber(worn.score)
    if not wornScore then return end

    local api = containerAPI()
    if not api then return end

    local weapons, shields = {}, {}
    local function consider(link, bag, slot)
        local identity = itemStats:GetIdentity(link)
        if type(identity) ~= "table" then return end

        local equipLoc = identity.equipLoc
        local isShield = equipLoc == "INVTYPE_SHIELD"
        local isOneHand = equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONMAINHAND"
        if not isShield and not isOneHand then return end

        local verdict = verdictFor(link, identity, context.level)
        if type(verdict) ~= "table" or not usability or verdict.verdict ~= usability.USABLE then
            return
        end

        local okScore, result = pcall(scorer, score, link, context.buildIndex)
        if not okScore or type(result) ~= "table" or not result.ok then return end
        local value = tonumber(result.score)
        if not value then return end

        local entry = { link = link, name = identity.name, score = value, bag = bag, slot = slot }
        if isShield then
            shields[#shields + 1] = entry
        else
            weapons[#weapons + 1] = entry
        end
    end

    for bag = 0, (tonumber(NUM_BAG_SLOTS) or 4) do
        local okSlots, count = pcall(api.slots, bag)
        count = okSlots and tonumber(count) or 0
        for slot = 1, count do
            local okLink, link = pcall(api.link, bag, slot)
            if okLink and type(link) == "string" and link ~= "" then consider(link, bag, slot) end
        end
    end

    if #weapons == 0 or #shields == 0 then return end

    local function best(list)
        local winner
        for _, entry in ipairs(list) do
            if not winner or entry.score > winner.score then winner = entry end
        end
        return winner
    end

    local weapon = best(weapons)
    local shield = best(shields)
    local delta = GearCheck.PackageDelta(wornScore, weapon.score, shield.score)
    if not delta or delta <= 0 then return end

    table.insert(context.now, {
        link      = weapon.link,
        extraLink = shield.link,
        name      = tostring(weapon.name or "one-hander") .. " + " .. tostring(shield.name or "shield"),
        slot      = 16,
        score     = weapon.score + shield.score,
        delta     = delta,
        armour    = 0,
        package   = true,
        source    = "bags",
        bagID     = tonumber(weapon.bag),
        bagSlot   = tonumber(weapon.slot),
    })
end

local function scanBag(api, bag, source, context)
    local okSlots, slots = pcall(api.slots, bag)
    local count = okSlots and tonumber(slots) or 0
    if count <= 0 then return end

    for slot = 1, count do
        local okLink, link = pcall(api.link, bag, slot)

        if okLink and type(link) == "string" and link ~= ""
            and not secretValue(link) and link:find("item:", 1, true) then
            evaluate(link, source, context, bag, slot)
        end
    end
end

local function sortRows(rows)
    table.sort(rows, function(a, b)
        if a.delta ~= b.delta then return a.delta > b.delta end
        -- Two items that score the same are not the same item: the one with more
        -- armour is the better wear, and the per-slot choice keeps the first row.
        local armourA, armourB = tonumber(a.armour) or 0, tonumber(b.armour) or 0
        if armourA ~= armourB then return armourA > armourB end
        return tostring(a.link) < tostring(b.link)
    end)

    return rows
end

------------------------------------------------------------------------------
-- Cache
--
-- One stored result per build slot, profile revision and level. The bank is
-- never part of an entry: a cached list containing bank rows would answer a
-- bags-only question with items the caller did not ask the bank for, and what
-- the bank holds is not announced by the bag events that invalidate this.
------------------------------------------------------------------------------

function GearCheck:Key(buildIndex, level)
    local profiles = LT.Profiles

    return tostring(buildIndex) .. "|" .. tostring(level) .. "|"
        .. tostring(profiles and profiles.revision or 0) .. "|"
        .. tostring(self.revision)
end

function GearCheck:Store(key, value)
    if self.cache[key] == nil then
        table.insert(cacheOrder, key)
    end

    self.cache[key] = value

    while #cacheOrder > self.CACHE_LIMIT do
        local oldest = table.remove(cacheOrder, 1)
        self.cache[oldest] = nil
    end
end

-- Everything a stored scan was calculated from announces its own change: level,
-- build, profile and gear set through the core bus, a bag or an equipped item
-- through the inventory events, and the client's settled-bags tick through the
-- hook below.
function GearCheck:Invalidate()
    self.revision = (tonumber(self.revision) or 0) + 1
    self.cache = {}
    cacheOrder = {}
end

------------------------------------------------------------------------------
-- Scan
------------------------------------------------------------------------------

-- opts.includeBank  also read the bank (never cached)
-- opts.buildIndex   score against this build slot instead of the active one
--
-- Returns { now = rows, soon = rows }, and a reason instead of rows when the
-- question cannot be answered (combat, or a module the addon needs is absent).
-- A bank scan also carries `bankRoute`: "bank-tabs", "bank-bags" or "none".
function GearCheck:Scan(opts)
    opts = opts or {}

    if combatLocked() then
        return cannot("combat")
    end

    local itemStats = LT.ItemStats
    local usability = LT.Usability
    local compare = LT.Compare

    if type(itemStats) ~= "table" or type(itemStats.Get) ~= "function" then
        return cannot("no-item-stats")
    end

    if type(usability) ~= "table" or type(usability.GetVerdict) ~= "function" then
        return cannot("no-usability")
    end

    if type(compare) ~= "table" then
        return cannot("no-compare")
    end

    local api = containerAPI()
    if not api then
        return cannot("no-container-api")
    end

    local buildIndex = resolveBuildIndex(opts)
    local level = playerLevel()
    local includeBank = opts.includeBank == true

    local key
    if not includeBank and not opts.fresh then
        key = self:Key(buildIndex, level)
        local hit = self.cache[key]
        if hit then return LT:Copy(hit) end
    end

    local context = {
        buildIndex  = buildIndex,
        level       = level,
        now         = {},
        soon        = {},
        unreadable  = false,
    }

    for bag = 0, bagCount() do
        scanBag(api, bag, self.SOURCE_BAGS, context)
    end

    -- T-46: only when the hands hold a two-handed weapon, and only from the bags
    -- (a package is something the player is carrying).
    pcall(scanWeaponPackage, context)

    local bankRoute
    if includeBank then
        local bankBags
        bankBags, bankRoute = bankContainers()

        if type(LT.Diag) == "function" then
            pcall(LT.Diag, LT, "bank scan: " .. tostring(#bankBags)
                .. " container(s) answered by " .. tostring(bankRoute or "none"))
        end

        for _, bag in ipairs(bankBags) do
            scanBag(api, bag, self.SOURCE_BANK, context)
        end
    end

    local result = {
        now  = sortRows(context.now),
        soon = sortRows(context.soon),
    }

    -- Which containers the bank walk read, so the caller's text can say so. A
    -- bags-only scan carries no field at all: there was no bank to name.
    if includeBank then result.bankRoute = bankRoute end

    if includeBank or context.unreadable or opts.fresh then
        return result
    end

    self:Store(key, result)
    return LT:Copy(result)
end

------------------------------------------------------------------------------
-- Invalidation wiring
--
-- The same events Compare uses, so a scan and the tooltip can never disagree
-- about whether an item scores well. Three client events the core frame does
-- not listen for are registered on it and its handler is hooked: the bags
-- settling, and item data arriving (a link the client could not answer for at
-- login becomes readable later). That keeps the addon's frame count unchanged,
-- and if either call is unavailable the bag side still invalidates through
-- INVENTORY_CHANGED.
------------------------------------------------------------------------------

for _, event in ipairs({
    LT.EVENT_LEVEL, LT.EVENT_BUILDS, LT.EVENT_PROFILE, LT.EVENT_GEARSET,
    "EQUIPMENT_CHANGED", "INVENTORY_CHANGED",
}) do
    if type(event) == "string" and type(LT.On) == "function" then
        pcall(LT.On, LT, event, function()
            GearCheck:Invalidate()
        end, "GearCheck")
    end
end

do
    local frame = LT.frame
    local clientEvents = {
        "BAG_UPDATE_DELAYED",
        "GET_ITEM_INFO_RECEIVED",
        "ITEM_DATA_LOAD_RESULT",
    }

    if (type(frame) == "table" or type(frame) == "userdata")
        and type(frame.RegisterEvent) == "function"
        and type(frame.HookScript) == "function" then
        local watched = {}
        for _, event in ipairs(clientEvents) do
            watched[event] = true
            pcall(frame.RegisterEvent, frame, event)
        end

        pcall(frame.HookScript, frame, "OnEvent", function(_, event)
            if watched[event] then
                GearCheck:Invalidate()
            end
        end)
    end
end
