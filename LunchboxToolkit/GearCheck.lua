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

-- One row, or nil when the item does not beat what is worn. The comparison's
-- headline is the best swap for this item; rings and trinkets can target more
-- than one slot, and the number the caller shows must match the slot it names.
local function rowFor(link, identity, source, comparison)
    local difference = tonumber(comparison.difference)
    if not difference or difference <= 0 then return nil end

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
        requiredLevel = tonumber(identity.requiredLevel),
        source        = source,
    }
end

------------------------------------------------------------------------------
-- The walk
------------------------------------------------------------------------------

local function evaluate(link, source, context)
    local itemStats = LT.ItemStats

    local okGet, _, identity = pcall(itemStats.Get, itemStats, link)

    -- The client answers for a link only once it has cached the item, so a
    -- missing identity may be "not yet" rather than "never". Such a scan is
    -- not stored: freezing an empty answer at login would hide every upgrade
    -- until some unrelated inventory event happened to invalidate it.
    if not okGet or type(identity) ~= "table" then
        context.unreadable = true
        return
    end

    if not equippable(identity) then return end

    local verdict = verdictFor(link, identity, context.level)
    if not verdict then return end

    local placement, required = GearCheck:Placement(verdict, identity, context.level)
    if not placement then return end

    local comparison = compareFor(link, context.buildIndex)
    if not comparison then return end

    local row = rowFor(link, identity, source, comparison)
    if not row then return end

    if required then row.requiredLevel = required end
    if tonumber(verdict.unlockLevel) then row.unlockLevel = tonumber(verdict.unlockLevel) end

    if placement == "soon" then
        table.insert(context.soon, row)
    else
        table.insert(context.now, row)
    end
end

local function scanBag(api, bag, source, context)
    local okSlots, slots = pcall(api.slots, bag)
    local count = okSlots and tonumber(slots) or 0
    if count <= 0 then return end

    for slot = 1, count do
        local okLink, link = pcall(api.link, bag, slot)

        if okLink and type(link) == "string" and link ~= ""
            and not secretValue(link) and link:find("item:", 1, true) then
            evaluate(link, source, context)
        end
    end
end

local function sortRows(rows)
    table.sort(rows, function(a, b)
        if a.delta ~= b.delta then return a.delta > b.delta end
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
    if not includeBank then
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

    if includeBank or context.unreadable then
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
