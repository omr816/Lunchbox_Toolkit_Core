--[[--------------------------------------------------------------------------
    LunchboxToolkit_Vendor — levelling helper for the bags

    Five behaviours, only two of which ever touch the client:

      1. Marker. While a merchant window is open, one bag item is the cheapest
         thing to lose, ranked by TOTAL stack value (count x sell price), never
         by unit price: five cloth at 4c each costs 20c to lose, one sword at
         25c costs 25c. Quest items, soulbound items, items with no price, items
         the scoring engine calls an upgrade and items on this plugin's ignore
         list are never marked, and with no merchant open the mark is cleared.
      2. Grey auto-sell. Quality 0 only, only while a merchant window is open.
         Off by default; "/lbv sell on" switches it on for this character and is
         remembered. Never a quest item, never soulbound, never an item with no
         price, never an ignored id, never a GearCheck upgrade, and never a grey
         item whose worn slot is empty (grey is better than nothing). /lbv
         dryrun lists the same rows and sells nothing.
      3. Surplus framing. From GearCheck:Scan(), the best item per slot plus one
         spare is kept (rings keep two, ranged counts as a slot, trinkets and
         relics are never surplus); the rest is surplus. Nothing is sold.
      4. Score-based junk sale (off by default, junkSale option). /lbv junk
         borders every item the score calls worthless for the active build —
         quality 0, or equippable gear whose weighted score is at or below
         JUNK_SCORE_MAX. A second /lbv junk at a merchant sells exactly the
         bordered rows. Quest items, priced-less items, ignored ids, GearCheck
         upgrades and gear for an empty worn slot are never junk.
      5. Merchant errands (autoRepair option, off by default). One repair of
         all equipment on player funds only, at a repair-capable merchant, and
         one summary line with free bag slots, repair cost and junk value. The
         line is printed only when one of the three is actionable.

    What this file never does: it never destroys an item, never calls
    DeleteCursorItem, never picks an item up, never moves one and never equips
    one. The only client writes are C_Container.UseContainerItem /
    UseContainerItem on a row this file decided to sell at a merchant (a
    quality 0 row with auto-sell on, or an armed junk row) and RepairAllItems
    with player funds only when autoRepair is on.

    Frames and strings belong to the UI layer. This file exposes data and three
    callbacks, and creates no widgets:
      Vendor:Cheapest()            -> row | nil, reason, full ranking
      Vendor:SurplusRows(force)    -> { kept, surplus, counts } | nil
      Vendor:SetMarkerPainter(fn)  fn(rowOrNil) after every refresh
      Vendor:SetSurplusPainter(fn) fn(planOrNil) after every refresh
      Vendor:JunkRows()            -> armed junk rows | nil
      Vendor:SetJunkPainter(fn)    fn(rowsOrNil) when the junk set is armed/cleared
    The painters are pcall'd and are never called during combat.

    Commands. The word "vendor" is registered with the core's
    Slash:RegisterCommand at PLAYER_LOGIN, so /lt vendor is part of the one
    command surface, is listed by /lt help, and can never take a word the core
    already owns. /lbv and /ltvendor stay as aliases: their SLASH_ globals are
    set at file load, which is early enough for every client to read them.
      /lt vendor help | status | mark | ignore [item] | forget <id> | ignored |
           dryrun | junk | sell on|off | surplus on|off
      SLASH_LUNCHBOXVENDOR1 = "/lbv"
      SLASH_LUNCHBOXVENDOR2 = "/ltvendor"

    Switches. Grey auto-sell and surplus framing are per character, keyed by
    LT:GetPlayerKey() under LunchboxToolkitVendorDB.characters[key].options, so
    arming junk-selling on one alt leaves every other alt off. The junk sale and
    auto-repair switches are core options (junkSale, autoRepair), read through
    LT.Database:GetOptions(). The ignore list stays account-wide on purpose:
    "never this item" is a fact about the item, not about the alt that noticed it.

    Ignoring is the command path: /lbv ignore with a shift-clicked link, the item
    on the cursor, or the item the marker is on. No addon replaces a bag button's
    OnClick: the core's DropHint module dropped that gesture because a replaced
    client handler is a taint risk, so there is no alt-click to claim here either.

    Scoring and scan work is not repeated here: the scan a marker, a surplus
    frame or the junk pass asks for is GearCheck:Scan(), cached per (build,
    profile revision, level) by the core, item scores come from Score:ScoreItem,
    and item identities come from ItemStats' own cache. This file only walks the
    containers, and only when a painter asks for it or a command is run.

    Safety at the boundaries: every client call is pcall'd; every value the
    client hands back goes through number(), which refuses a secret value before
    any arithmetic; a scan is refused in combat; nothing is drawn in combat.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

if type(LT) ~= "table" then
    -- The TOC declares the dependency, so this only happens when the core was
    -- disabled by hand. Say so once instead of failing silently.
    if type(DEFAULT_CHAT_FRAME) == "table"
        and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
        pcall(DEFAULT_CHAT_FRAME.AddMessage, DEFAULT_CHAT_FRAME,
            "LunchboxToolkit_Vendor: the LunchboxToolkit core addon is not loaded; "
            .. "the vendor helper stays off.")
    end
    return
end

local Vendor = {}
LT.Vendor = Vendor

Vendor.VERSION = "1.0.0"
Vendor.PLUGIN_ID = "lunchbox_vendor"
Vendor.AUTO_SELL_DEFAULT = false

-- Kept per slot, before the spare: one worn item plus one spare. A ring slot is
-- half of one worn pair, so rings keep the best plus two spares. Ranged is an ordinary slot.
Vendor.KEEP_PER_SLOT = 2
Vendor.KEEP_RINGS    = 3

-- The junk sale sells an equippable item only when its weighted score for the
-- active build is at or below this number. Zero means "nothing this build
-- values"; an item with any positive weight is never sold by the rule, no
-- matter how cheap it is. The player still confirms the bordered set by hand.
Vendor.JUNK_SCORE_MAX = 0

Vendor.NEVER_SURPLUS = {
    INVTYPE_TRINKET = true,
    INVTYPE_RELIC   = true,
}

------------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------------

-- One place that decides whether a value may be used at all. A restricted value
-- is never converted, compared or multiplied: it becomes nil and the caller
-- treats the answer as "cannot say".
local function secret(value)
    if type(LT.IsSecret) ~= "function" then return false end
    local ok, result = pcall(LT.IsSecret, LT, value)
    return ok and result == true
end

local function number(value)
    local kind = type(value)

    if kind == "number" then
        if secret(value) then return nil end
        return value
    end

    if kind == "string" then
        if secret(value) then return nil end
        local ok, result = pcall(tonumber, value)
        if ok then return result end
    end

    return nil
end

local function text(value)
    if type(value) ~= "string" then return nil end
    if secret(value) then return nil end
    if value == "" then return nil end
    return value
end

local function combatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

-- One reader for the core character options (junkSale, autoRepair). A missing
-- Database module is not permission: the caller treats nil as "off".
local function coreOption(key)
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return nil
    end

    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then return nil end
    return options[key]
end

local function nowSeconds()
    if type(time) ~= "function" then return 0 end
    local ok, stamp = pcall(time)
    return ok and number(stamp) or 0
end

local function itemIDFromLink(value)
    return number(tostring(value or ""):match("item:(%d+)"))
end

local function nameFromLink(value)
    local bracket = tostring(value or ""):match("%[(.-)%]")
    if bracket and bracket ~= "" then return bracket end
    return nil
end

local function splitWords(input)
    local words = {}
    for word in tostring(input or ""):gmatch("%S+") do
        words[#words + 1] = word
    end
    return words
end

local function copyTable(value)
    local out = {}
    for key, entry in pairs(value or {}) do out[key] = entry end
    return out
end

------------------------------------------------------------------------------
-- Reading the client
------------------------------------------------------------------------------

-- C_Container is what the core uses; the pre-C_Container globals stay as a
-- fallback because a missing bag API would cost every feature in this file.
local function containerAPI()
    local modern = C_Container
    if type(modern) == "table"
        and type(modern.GetContainerNumSlots) == "function"
        and type(modern.GetContainerItemLink) == "function" then
        return {
            slots  = modern.GetContainerNumSlots,
            link   = modern.GetContainerItemLink,
            info   = modern.GetContainerItemInfo,
            use    = modern.UseContainerItem,
            modern = true,
        }
    end

    if type(GetContainerNumSlots) == "function" and type(GetContainerItemLink) == "function" then
        return {
            slots  = GetContainerNumSlots,
            link   = GetContainerItemLink,
            info   = GetContainerItemInfo,
            use    = UseContainerItem,
            modern = false,
        }
    end

    return nil
end

-- Count, quality and (on the modern route) the client's own "has no value"
-- flag. Every return is pcall'd; every number is read through number().
local function slotInfo(api, bag, slot)
    local result = { count = 1, quality = nil, hasNoValue = false }
    if type(api.info) ~= "function" then return result end

    if api.modern then
        local ok, info = pcall(api.info, bag, slot)
        if ok and type(info) == "table" then
            result.count = number(info.stackCount) or 1
            result.quality = number(info.quality)
            result.hasNoValue = info.hasNoValue == true
        end
        return result
    end

    -- Old signature: icon, itemCount, locked, quality, ...
    local ok, _, count, _, quality = pcall(api.info, bag, slot)
    if ok then
        result.count = number(count) or 1
        result.quality = number(quality)
    end

    return result
end

-- One reader for the two GetItemInfo routes. Positional returns are named here
-- once so the rest of the file does not index a pcall result by memory. The
-- sell price is deliberately not taken from this reply: on Forever it can still
-- carry the item's Classic-era price (T-47), so the merchant's own tooltip
-- figure is used instead.
local function infoFrom(fn, link)
    if type(fn) ~= "function" then return nil end

    -- name, link, quality, itemLevel, requiredLevel, class, subClass, stack,
    -- equipLoc, texture, sellPrice, classID, subClassID, bindType
    local ok, name, _, quality, _, _, _, _, _, equipLoc, _, _, classID, _, bindType =
        pcall(fn, link)
    if not ok then return nil end

    return {
        name      = text(name),
        quality   = number(quality),
        classID   = number(classID),
        bindType  = number(bindType),
        equipLoc  = text(equipLoc),
    }
end

-- The number the merchant pays for one item, read from the client's own tooltip
-- by QuestRewards. nil means "no price shown", never zero: an unknown price must
-- not make an item look free to lose or sell.
local function merchantPrice(link)
    local rewards = LT.QuestRewards
    if type(rewards) ~= "table" or type(rewards.SellPrice) ~= "function" then
        return nil
    end

    local ok, price = pcall(rewards.SellPrice, link)
    price = ok and number(price) or nil

    if price and price > 0 then return price end
    return nil
end

local function itemDetails(link)
    local details
    if type(C_Item) == "table" then
        details = infoFrom(C_Item.GetItemInfo, link)
    end

    if not details or (not details.name and not details.quality
        and not details.bindType) then
        details = infoFrom(GetItemInfo, link) or details
    end

    details = details or {}
    details.sellPrice = merchantPrice(link)
    return details
end

local function identityOf(link)
    local stats = LT.ItemStats
    if type(stats) ~= "table" or type(stats.GetIdentity) ~= "function" then
        return nil
    end

    local ok, identity = pcall(stats.GetIdentity, stats, link)
    if ok and type(identity) == "table" then return identity end
    return nil
end

-- Soulbound is a two-route question. C_Item.IsBound on an ItemLocation is the
-- client's own answer; when that is not available the item's bind type is used,
-- where 1 (binds when picked up: in the bags that is already soulbound) and 4
-- (quest bind) mean "do not touch". When neither route answers, the item is
-- refused: "cannot prove it is not soulbound" is not permission to sell.
local function itemLocation(bag, slot)
    local location = ItemLocation
    if type(location) ~= "table" or type(location.CreateFromBagAndSlot) ~= "function" then
        return nil
    end

    local ok, created = pcall(location.CreateFromBagAndSlot, bag, slot)
    if ok and created then return created end
    return nil
end

local function boundState(bag, slot, details)
    if type(C_Item) == "table" and type(C_Item.IsBound) == "function" then
        local location = itemLocation(bag, slot)
        if location then
            local ok, bound = pcall(C_Item.IsBound, location)
            if ok and type(bound) == "boolean" then return bound, true end
        end
    end

    local bindType = details and details.bindType
    if bindType == 1 or bindType == 4 then return true, true end
    if bindType == 0 or bindType == 2 or bindType == 3 then return false, true end

    return nil, false
end

local function isQuestItem(details, identity)
    local classID = details and details.classID
    if classID == 12 then return true end          -- ITEM_CLASS_QUEST
    if details and details.bindType == 4 then return true end

    local itemType = identity and identity.itemType
    if type(itemType) == "string" and not secret(itemType) and itemType == "Quest" then
        return true
    end

    return false
end

-- Which worn slots an equip location fills. A grey item is only junk when the
-- character already has something worn over it; while its slot is empty, the
-- grey item is better than nothing and must not be sold.
Vendor.EQUIP_SLOTS = {
    INVTYPE_HEAD         = { 1 },
    INVTYPE_NECK         = { 2 },
    INVTYPE_SHOULDER     = { 3 },
    INVTYPE_BODY         = { 4 },   -- shirt
    INVTYPE_CHEST        = { 5 },
    INVTYPE_ROBE         = { 5 },
    INVTYPE_WAIST        = { 6 },
    INVTYPE_LEGS         = { 7 },
    INVTYPE_FEET         = { 8 },
    INVTYPE_WRIST        = { 9 },
    INVTYPE_HAND         = { 10 },
    INVTYPE_FINGER       = { 11, 12 },
    INVTYPE_TRINKET      = { 13, 14 },
    INVTYPE_CLOAK        = { 15 },
    INVTYPE_WEAPON       = { 16, 17 },
    INVTYPE_2HWEAPON     = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_SHIELD       = { 17 },
    INVTYPE_HOLDABLE     = { 17 },
    INVTYPE_RANGED       = { 18 },
    INVTYPE_RANGEDRIGHT  = { 18 },
    INVTYPE_THROWN       = { 18 },
    INVTYPE_RELIC        = { 18 },
    INVTYPE_AMMO         = { 0 },
    INVTYPE_TABARD       = { 19 },
}

-- The worn slots this equip location fills, or nil when it is not equipment
-- (non-equip, a bag, an unknown location). Pure.
function Vendor.InventorySlots(equipLoc)
    if type(equipLoc) ~= "string" then return nil end
    return Vendor.EQUIP_SLOTS[equipLoc]
end

function Vendor.IsEquippable(equipLoc)
    return Vendor.InventorySlots(equipLoc) ~= nil
end

-- Whether one of the slots this item would fill is empty. Pure: the caller
-- passes the set of empty inventory slots. When the set is unknown the answer is
-- "cannot say", which the sweep refuses rather than selling blind.
function Vendor.HasEmptyEquipSlot(equipLoc, emptySlots)
    local slots = Vendor.InventorySlots(equipLoc)
    if not slots or type(emptySlots) ~= "table" then return false end

    for _, slot in ipairs(slots) do
        if emptySlots[slot] then return true end
    end

    return false
end

-- The worn slots the client reports empty, or nil and false when no route could
-- answer. Every read is pcall'd and a restricted result is refused before any
-- comparison.
local function emptyEquipSlots()
    local slots = {}
    local answered = false

    for slot = 0, 19 do
        local occupied = nil

        if type(GetInventoryItemID) == "function" then
            local ok, id = pcall(GetInventoryItemID, "player", slot)
            if ok and not secret(id) then
                local value = number(id)
                if value ~= nil then
                    occupied = value > 0
                    answered = true
                end
            end
        end

        if occupied == nil and type(GetInventoryItemLink) == "function" then
            local ok, link = pcall(GetInventoryItemLink, "player", slot)
            if ok and not secret(link) then
                occupied = text(link) ~= nil
                answered = true
            end
        end

        if occupied == false then slots[slot] = true end
    end

    if not answered then return nil, false end
    return slots, true
end

------------------------------------------------------------------------------
-- The bag walk
------------------------------------------------------------------------------

-- Occupied slots of the backpack and the equipped bags, as plain rows.
-- Returns rows, or nil and a reason. Never runs in combat.
function Vendor:ScanRows()
    if combatLocked() then return nil, "combat" end

    local api = containerAPI()
    if not api then return nil, "the client exposes no container API" end

    local rows = {}
    local lastBag = number(NUM_BAG_SLOTS) or 4

    for bag = 0, lastBag do
        local okSlots, slots = pcall(api.slots, bag)
        slots = okSlots and number(slots) or 0

        for slot = 1, slots do
            local okLink, link = pcall(api.link, bag, slot)

            if okLink and text(link) then
                local info     = slotInfo(api, bag, slot)
                local details  = itemDetails(link) or {}
                local identity = identityOf(link)

                local bound, boundKnown = boundState(bag, slot, details)

                local quality = details.quality
                if quality == nil and identity then quality = number(identity.quality) end

                -- A price the client has not cached is nil, never zero: zero
                -- would make an unknown item look free to lose or to sell.
                local unitPrice = details.sellPrice
                if info.hasNoValue then unitPrice = nil end
                if unitPrice and unitPrice <= 0 then unitPrice = nil end

                rows[#rows + 1] = {
                    bag        = bag,
                    slot       = slot,
                    link       = link,
                    itemID     = number(identity and identity.itemID) or itemIDFromLink(link),
                    name       = details.name
                        or text(identity and identity.name)
                        or nameFromLink(link),
                    count      = info.count,
                    quality    = quality,
                    unitPrice  = unitPrice,
                    quest      = isQuestItem(details, identity),
                    bound      = bound == true,
                    boundKnown = boundKnown,
                    equipLoc   = text(identity and identity.equipLoc) or details.equipLoc,
                }
            end
        end
    end

    return rows
end

------------------------------------------------------------------------------
-- Pure rules — no client calls, so the harness drives them directly
------------------------------------------------------------------------------

-- What losing this row costs: the whole stack.
function Vendor.StackValue(row)
    if type(row) ~= "table" then return 0 end

    local count = number(row.count) or 1
    if count < 1 then count = 1 end

    local unit = number(row.unitPrice)
    if not unit then return 0 end

    return unit * count
end

-- opts.ignore   set of itemIDs the player never wants marked
-- opts.upgrades set of itemIDs GearCheck called an upgrade (now or soon)
--
-- Rows must carry: quest, bound, boundKnown, unitPrice, itemID, count.
-- boundKnown == false is "the client would not say"; that is refused too.
function Vendor.RankToLose(rows, opts)
    opts = opts or {}

    local result = {
        eligible = {},
        excluded = { quest = 0, soulbound = 0, unpriced = 0, upgrade = 0,
                     ignored = 0 },
        cheapest = nil,
    }

    for _, row in ipairs(rows or {}) do
        local itemID = number(row.itemID)
        local unit = number(row.unitPrice)

        if row.quest then
            result.excluded.quest = result.excluded.quest + 1
        elseif row.bound == true or row.boundKnown == false then
            result.excluded.soulbound = result.excluded.soulbound + 1
        elseif not unit or unit <= 0 then
            result.excluded.unpriced = result.excluded.unpriced + 1
        elseif itemID and opts.upgrades and opts.upgrades[itemID] then
            result.excluded.upgrade = result.excluded.upgrade + 1
        elseif itemID and opts.ignore and opts.ignore[itemID] then
            result.excluded.ignored = result.excluded.ignored + 1
        else
            result.eligible[#result.eligible + 1] = row
        end
    end

    -- Cheapest stack first; the tie-breaks only make the answer stable.
    table.sort(result.eligible, function(a, b)
        local valueA, valueB = Vendor.StackValue(a), Vendor.StackValue(b)
        if valueA ~= valueB then return valueA < valueB end

        local unitA, unitB = number(a.unitPrice) or 0, number(b.unitPrice) or 0
        if unitA ~= unitB then return unitA < unitB end

        local nameA = tostring(a.name or a.link or "")
        local nameB = tostring(b.name or b.link or "")
        if nameA ~= nameB then return nameA < nameB end

        return tostring(a.itemID or 0) < tostring(b.itemID or 0)
    end)

    result.cheapest = result.eligible[1]
    return result
end

-- what would the merchant buy: quality 0, priced, not quest, not soulbound,
-- not ignored, not an upgrade, and not gear whose worn slot is empty. The
-- ignore list is applied here too: "never this one" outlives the setting that
-- chose it.
--
-- opts.emptyEquipSlots      set of empty inventory slots (see emptyEquipSlots)
-- opts.emptySlotsUnavailable  the client would not say what is worn; every
--                           equippable grey is kept rather than sold blind
-- opts.upgrades             set of itemIDs GearCheck calls an upgrade
-- opts.upgradesUnavailable  GearCheck could not answer; equippable greys kept
function Vendor.SellPlan(rows, opts)
    opts = opts or {}

    local result = {
        sell = {},
        excluded = { notGrey = 0, quest = 0, soulbound = 0, unpriced = 0,
                     emptySlot = 0, upgrade = 0, ignored = 0 },
    }

    for _, row in ipairs(rows or {}) do
        local itemID = number(row.itemID)
        local unit = number(row.unitPrice)
        local equippable = Vendor.IsEquippable(row.equipLoc)

        if number(row.quality) ~= 0 then
            result.excluded.notGrey = result.excluded.notGrey + 1
        elseif row.quest then
            result.excluded.quest = result.excluded.quest + 1
        elseif row.bound == true or row.boundKnown == false then
            result.excluded.soulbound = result.excluded.soulbound + 1
        elseif not unit or unit <= 0 then
            result.excluded.unpriced = result.excluded.unpriced + 1
        elseif equippable and (opts.emptySlotsUnavailable == true
            or Vendor.HasEmptyEquipSlot(row.equipLoc, opts.emptyEquipSlots)) then
            -- A grey item that would fill an empty worn slot is better than
            -- nothing; an unreadable equipment state is treated the same way.
            result.excluded.emptySlot = result.excluded.emptySlot + 1
        elseif equippable and (opts.upgradesUnavailable == true
            or not itemID
            or (opts.upgrades and opts.upgrades[itemID])) then
            result.excluded.upgrade = result.excluded.upgrade + 1
        elseif itemID and opts.ignore and opts.ignore[itemID] then
            result.excluded.ignored = result.excluded.ignored + 1
        else
            result.sell[#result.sell + 1] = row
        end
    end

    return result
end

-- Groups worth counting together. Rings are one group because two are worn;
-- trinkets and relics are never surplus at all.
function Vendor.SlotGroup(row)
    local equip = row.equipLoc
    if type(equip) == "string" and Vendor.NEVER_SURPLUS[equip] then return "never" end
    if equip == "INVTYPE_FINGER" then return "rings" end

    local slot = number(row.slot)
    if not slot then return "unknown" end
    if slot == 13 or slot == 14 then return "never" end
    if slot == 11 or slot == 12 then return "rings" end

    return "slot:" .. tostring(slot)
end

function Vendor.KeepCount(group)
    if group == "never" then return math.huge end
    if group == "rings" then return Vendor.KEEP_RINGS end
    return Vendor.KEEP_PER_SLOT
end

-- rows are expected best-first within each slot (GearCheck sorts by delta).
-- Returns { kept, surplus, counts = { [group] = { kept, surplus, limit } } }.
function Vendor.SurplusPlan(rows)
    local plan = { kept = {}, surplus = {}, counts = {} }

    for _, row in ipairs(rows or {}) do
        local group = Vendor.SlotGroup(row)
        local entry = plan.counts[group]

        if not entry then
            entry = { kept = 0, surplus = 0, limit = Vendor.KeepCount(group) }
            plan.counts[group] = entry
        end

        if entry.kept < entry.limit then
            entry.kept = entry.kept + 1
            plan.kept[#plan.kept + 1] = row
        else
            entry.surplus = entry.surplus + 1
            plan.surplus[#plan.surplus + 1] = row
        end
    end

    return plan
end

------------------------------------------------------------------------------
-- The plugin's own saved variables
--
-- LunchboxToolkitVendorDB, declared in the TOC. Additive only: an unknown field
-- written by a newer build is never removed, and a missing one is filled in.
--
-- Shape:
--   store.ignore                        { [itemID] = { name, added } }  account-wide
--   store.characters[key].options       { autoSell, autoSellSet, surplus } per character
--                                       autoSell defaults to false (off)
--                                       autoSellSet: the player ran /lbv sell on|off
--                                       false = default, not an explicit choice
--   store.characterOptionsMigrated      true once the flat table was read
--   store.options                       the version 1 flat table, read once, never
--                                       deleted so an older build still sees it
------------------------------------------------------------------------------

local DB_VERSION = 2

-- The core answers this; a host without it gets one honest shared bucket
-- rather than an invented character name.
local function playerKey()
    if type(LT.GetPlayerKey) == "function" then
        local ok, key = pcall(LT.GetPlayerKey, LT)
        if ok and type(key) == "string" and key ~= "" then return key, true end
    end

    return "unknown-character", false
end

local function optionsOf(store, key)
    local record = store.characters[key]
    if type(record) ~= "table" then
        record = {}
        store.characters[key] = record
    end

    if type(record.options) ~= "table" then record.options = {} end

    -- Grey auto-sell is off for a character that has never chosen. A missing
    -- value is filled with false; nothing is ever flipped to true here, so an
    -- upgraded record cannot start selling without the player switching it on.
    -- "/lbv sell on" writes autoSellSet = true, which is what /lbv status calls
    -- an explicit choice; a character that has never chosen leaves it false.
    if type(record.options.autoSell) ~= "boolean" then record.options.autoSell = false end
    if type(record.options.autoSellSet) ~= "boolean" then
        record.options.autoSellSet = false
    end

    if type(record.options.surplus) ~= "boolean" then record.options.surplus = false end

    return record.options
end

local function db()
    if type(LunchboxToolkitVendorDB) ~= "table" then
        LunchboxToolkitVendorDB = {}
    end

    local store = LunchboxToolkitVendorDB

    local version = number(store.version)
    if version == nil or version < DB_VERSION then store.version = DB_VERSION end
    if type(store.ignore) ~= "table" then store.ignore = {} end
    if type(store.characters) ~= "table" then store.characters = {} end

    -- Version 1 kept both switches in one flat table, so arming auto-sell on
    -- one character armed it on every alt. Copy a flat value into the character
    -- that is here now, once; the marker stops the next alt from inheriting it.
    -- autoSell is deliberately NOT copied: the old flat table cannot tell an
    -- explicit "on" from the old default true, and consent to sell is not
    -- something this migration may infer. Surplus framing moves nothing on the
    -- client, so its old value is safe to carry over.
    -- The flat table itself is left in place, never rewritten or deleted.
    local key, known = playerKey()
    if known and store.characterOptionsMigrated ~= true then
        local flat = store.options
        local options = optionsOf(store, key)

        if type(flat) == "table" then
            if type(flat.surplus) == "boolean" then options.surplus = flat.surplus end
        end

        store.characterOptionsMigrated = true
    end

    return store
end

-- The two switches belong to this character; the ignore list does not.
local function characterOptions()
    local key = playerKey()
    return optionsOf(db(), key)
end

-- Which character's entry is being read and written, for /lt vendor status.
function Vendor:CharacterKey()
    local key, known = playerKey()
    if known then return key end
    return nil
end

local function ignoreSet()
    local set = {}
    for key in pairs(db().ignore) do
        local id = number(key)
        if id then set[id] = true end
    end
    return set
end

function Vendor:IsIgnored(itemID)
    local id = number(itemID)
    if not id then return false end
    return db().ignore[id] ~= nil
end

function Vendor:Ignore(itemID, name)
    local id = number(itemID)
    if not id then return false end

    db().ignore[id] = {
        name  = text(name),
        added = nowSeconds(),
    }
    return true
end

function Vendor:Forget(itemID)
    local id = number(itemID)
    if not id or db().ignore[id] == nil then return false end

    db().ignore[id] = nil
    return true
end

-- The two switches this plugin owns. SetEnabled is the only writer for both;
-- the commands and the Settings page read through GetEnabled, so there is one
-- place that records a choice and one place that reads it back.
Vendor.OPTION_KEYS = {
    autoSell = "autoSell",
    surplus  = "surplus",
}

local function isOptionKey(optionKey)
    return optionKey == Vendor.OPTION_KEYS.autoSell
        or optionKey == Vendor.OPTION_KEYS.surplus
end

-- Read side. autoSell falls back to the shipped default (off) when a stored
-- record somehow has no boolean; surplus is simply off unless switched on.
function Vendor:GetEnabled(optionKey)
    if not isOptionKey(optionKey) then return false end

    local options = characterOptions()
    if optionKey == Vendor.OPTION_KEYS.autoSell then
        if type(options.autoSell) == "boolean" then return options.autoSell end
        return Vendor.AUTO_SELL_DEFAULT == true
    end

    return options.surplus == true
end

-- Write side. autoSellSet records that the player chose, which is what lets
-- /lbv status say "off" instead of "off (default)". A refresh follows so the
-- marker and the surplus frames agree with the new switch immediately.
function Vendor:SetEnabled(optionKey, enabled)
    if not isOptionKey(optionKey) then
        return false, "unknown option key"
    end
    if type(enabled) ~= "boolean" then
        return false, "enabled must be a boolean"
    end

    local options = characterOptions()
    options[optionKey] = enabled
    if optionKey == Vendor.OPTION_KEYS.autoSell then
        options.autoSellSet = true
    end

    self:Refresh()
    return true
end

-- Row data for a Settings page that wants to draw these switches. Data and
-- callbacks only: no widgets are created here. Both writer closures call
-- SetEnabled, so the page can never bypass the per-character record.
function Vendor:GetOptionRows()
    local plugin = self
    return {
        {
            key     = Vendor.OPTION_KEYS.autoSell,
            label   = "Sell grey junk at a merchant",
            help    = "Quality 0 items only, sold while a merchant window is open. Never a "
                .. "quest item, soulbound item, ignored item, GearCheck upgrade, or gear "
                .. "whose worn slot is empty. /lbv dryrun lists what would be sold. Off by "
                .. "default, and this character only.",
            default = false,
            get     = function() return plugin:GetEnabled(Vendor.OPTION_KEYS.autoSell) == true end,
            apply   = function(value) plugin:SetEnabled(Vendor.OPTION_KEYS.autoSell, value == true) end,
        },
        {
            key     = Vendor.OPTION_KEYS.surplus,
            label   = "Outline surplus gear",
            help    = "Outlines gear that is beyond the best item plus one spare per slot "
                .. "(rings keep two spares; trinkets and relics are never surplus). Nothing "
                .. "is sold. Off by default, and this character only.",
            default = false,
            get     = function() return plugin:GetEnabled(Vendor.OPTION_KEYS.surplus) == true end,
            apply   = function(value) plugin:SetEnabled(Vendor.OPTION_KEYS.surplus, value == true) end,
        },
    }
end

function Vendor:AutoSellEnabled()
    return self:GetEnabled(Vendor.OPTION_KEYS.autoSell)
end

-- nil when the player has never chosen, so the status line can say "off
-- (default)" instead of claiming a switch the player cannot remember setting.
function Vendor:AutoSellChoice()
    local options = characterOptions()
    if options.autoSellSet == true then return options.autoSell == true end
    return nil
end

function Vendor:SurplusEnabled()
    return self:GetEnabled(Vendor.OPTION_KEYS.surplus)
end

------------------------------------------------------------------------------
-- What GearCheck wants
------------------------------------------------------------------------------

-- itemIDs the scan calls an upgrade, in either list. Returns nil and a reason
-- when the question cannot be answered; the marker is then withheld rather than
-- marking something that might be wanted.
local function upgradeSet()
    local gear = LT.GearCheck
    if type(gear) ~= "table" or type(gear.Scan) ~= "function" then
        return nil, "the GearCheck module is not loaded"
    end

    local ok, result = pcall(gear.Scan, gear)
    if not ok or type(result) ~= "table" then
        return nil, "GearCheck could not answer"
    end
    if result.reason then
        return nil, "GearCheck cannot scan now (" .. tostring(result.reason) .. ")"
    end

    local set = {}
    for _, list in ipairs({ result.now or {}, result.soon or {} }) do
        for _, row in ipairs(list) do
            local id = number(row.itemID) or itemIDFromLink(row.link)
            if id then set[id] = true end
        end
    end

    return set
end

function Vendor:Cheapest()
    local rows, reason = self:ScanRows()
    if not rows then return nil, reason end

    local upgrades, upgradeReason = upgradeSet()
    if not upgrades then return nil, upgradeReason end

    local ranked = Vendor.RankToLose(rows, {
        ignore   = ignoreSet(),
        upgrades = upgrades,
    })

    return ranked.cheapest, nil, ranked
end

-- Scan rows enriched with the equip location the surplus rule needs. Ordering is
-- global delta order, which is also best-first within each slot.
function Vendor:SurplusRows(force)
    if not force and not self:SurplusEnabled() then return nil end

    local gear = LT.GearCheck
    if type(gear) ~= "table" or type(gear.Scan) ~= "function" then return nil end

    local ok, result = pcall(gear.Scan, gear)
    if not ok or type(result) ~= "table" or result.reason then return nil end

    local rows = {}
    for _, list in ipairs({ result.now or {}, result.soon or {} }) do
        for _, row in ipairs(list) do
            local copy = copyTable(row)
            if copy.equipLoc == nil then
                local identity = identityOf(copy.link)
                copy.equipLoc = identity and text(identity.equipLoc) or nil
            end
            rows[#rows + 1] = copy
        end
    end

    table.sort(rows, function(a, b)
        local deltaA, deltaB = number(a.delta) or 0, number(b.delta) or 0
        if deltaA ~= deltaB then return deltaA > deltaB end
        return tostring(a.link or "") < tostring(b.link or "")
    end)

    return Vendor.SurplusPlan(rows)
end

------------------------------------------------------------------------------
-- The merchant
------------------------------------------------------------------------------

-- MERCHANT_SHOW is the proof the merchant is open; MerchantFrame:IsShown() is
-- not. Inside MERCHANT_SHOW the frame can still report hidden, and asking it
-- first is what turned "sell on" into a silent no-op (player report E3). Once
-- an event has decided the state (true or false) the frame is not asked again,
-- so MERCHANT_CLOSED clears the sell mark even if the frame still claims to be
-- shown; the frame stays only as the fallback for a merchant that was already
-- open when this file started listening.
local function merchantOpen()
    if Vendor.atMerchant ~= nil then return Vendor.atMerchant == true end

    local frame = MerchantFrame
    if type(frame) == "table" and type(frame.IsShown) == "function" then
        local ok, shown = pcall(frame.IsShown, frame)
        if ok then return shown == true end
    end

    return false
end

-- One sale. The slot is re-read first so a plan made a moment ago cannot sell
-- whatever moved into that slot in the meantime. The client call is the only
-- write in this file.
local function sellOne(api, row)
    if type(api.use) ~= "function" then
        return false, "the client exposes no sell call"
    end
    if combatLocked() then return false, "combat" end
    if not merchantOpen() then return false, "no merchant" end

    local okLink, link = pcall(api.link, row.bag, row.slot)
    if not okLink or secret(link) or link ~= row.link then
        return false, "the slot changed"
    end

    local ok, err = pcall(api.use, row.bag, row.slot)
    if not ok then return false, tostring(err) end

    -- The sell call was accepted. The bag updates asynchronously, so reading
    -- the slot again here still shows the old item and wrongly counted every
    -- successful sale as a failure; BAG_UPDATE_DELAYED re-reads the bags and
    -- refreshes the plan instead.
    return true
end

function Vendor:PlanSell()
    local rows, reason = self:ScanRows()
    if not rows then return nil, reason end

    -- Both answers are gathered once per plan. A missing GearCheck or an
    -- unreadable equipment state does not become permission to sell: equippable
    -- greys are kept until the client can prove the slot is filled and the item
    -- is not an upgrade.
    local upgrades = upgradeSet()
    local emptySlots, slotsKnown = emptyEquipSlots()

    return Vendor.SellPlan(rows, {
        ignore               = ignoreSet(),
        upgrades             = upgrades,
        upgradesUnavailable  = upgrades == nil,
        emptyEquipSlots      = emptySlots,
        emptySlotsUnavailable = slotsKnown ~= true,
    })
end

-- The active build slot, read the same way GearCheck reads it; 1 is the
-- documented fallback when the Builds module cannot answer.
local function activeBuildIndex()
    local builds = LT.Builds
    if type(builds) == "table" and type(builds.GetActiveIndex) == "function" then
        local ok, index = pcall(builds.GetActiveIndex, builds)
        if ok then
            local value = number(index)
            if value then return value end
        end
    end

    return 1
end

-- Every bag row the junk rule calls worthless, or nil and a reason. Quality 0
-- is junk once the existing guards pass. A non-grey item is junk only when it
-- is equippable, the score module returns a number for the active build, and
-- that number is at or below JUNK_SCORE_MAX: "worthless for this build", never
-- "I could not read it". Quest items, unpriced items, ignored ids, GearCheck
-- upgrades and gear for an empty worn slot are never junk. includeScored ==
-- false restricts the answer to the grey rule (used by the errand strip while
-- the junkSale switch is off).
function Vendor:JunkCandidates(includeScored)
    local rows, reason = self:ScanRows()
    if not rows then return nil, reason end

    local upgrades = upgradeSet()
    if not upgrades then return nil, "GearCheck could not answer" end

    local emptySlots, slotsKnown = emptyEquipSlots()
    local ignore = ignoreSet()
    local scored = includeScored == true
    local buildIndex = activeBuildIndex()
    local scoreModule = LT.Score
    local canScore = type(scoreModule) == "table"
        and type(scoreModule.ScoreItem) == "function"

    local junk = {}

    for _, row in ipairs(rows) do
        local itemID = number(row.itemID)
        local unit = number(row.unitPrice)
        local equippable = Vendor.IsEquippable(row.equipLoc)

        if not row.quest
            and unit and unit > 0
            and not (itemID and ignore[itemID])
            and not (itemID and upgrades[itemID])
            and not (equippable and (slotsKnown ~= true
                or Vendor.HasEmptyEquipSlot(row.equipLoc, emptySlots)))
        then
            local score

            if number(row.quality) == 0 then
                score = 0
            elseif scored and equippable and itemID and canScore then
                local ok, result = pcall(scoreModule.ScoreItem, scoreModule,
                    row.link, buildIndex)
                if ok and type(result) == "table" and result.ok == true then
                    score = number(result.score)
                end
            end

            -- The threshold is the whole safety rule: a missing score is never
            -- treated as zero, and a positive score is never sold.
            if score and score <= Vendor.JUNK_SCORE_MAX then
                row.junkScore = score
                junk[#junk + 1] = row
            end
        end
    end

    return junk
end

-- The bordered set, for the UI layer's painter. nil means nothing is armed.
function Vendor:JunkRows()
    if type(self.junkArmed) ~= "table" then return nil end
    return self.junkArmed
end

function Vendor:SetJunkPainter(fn)
    if fn ~= nil and type(fn) ~= "function" then return false end
    self.junkPainter = fn
    if type(fn) == "function" then pcall(fn, self:JunkRows()) end
    return true
end

local function notifyJunk(rows)
    local painter = Vendor.junkPainter
    if type(painter) == "function" then pcall(painter, rows) end
end

-- Step one of the manual junk sale: compute the bordered set without touching
-- the client. Refuses in combat and without an open merchant; the junkSale
-- option must be on. Returns true when at least one row was armed.
function Vendor:ArmJunkSale()
    self.junkArmed = nil
    notifyJunk(nil)

    if coreOption("junkSale") ~= true then
        return false, "the junk sale is switched off"
    end
    if combatLocked() then return false, "combat" end
    if not merchantOpen() then return false, "no merchant" end

    local rows, reason = self:JunkCandidates(true)
    if not rows then return false, reason or "the bags could not be read" end
    if #rows == 0 then return false, "nothing worthless" end

    self.junkArmed = rows
    notifyJunk(rows)
    return true, nil, rows
end

-- Step two: sell exactly the armed rows. Each row is re-read by sellOne, so a
-- slot that moved since arming is skipped rather than guessed at. Returns true
-- when at least one row was sold, plus a report table.
function Vendor:ConfirmJunkSale()
    if combatLocked() then return false, "combat" end
    if not merchantOpen() then return false, "no merchant" end

    if coreOption("junkSale") ~= true then
        self.junkArmed = nil
        notifyJunk(nil)
        return false, "the junk sale is switched off"
    end

    local armed = self.junkArmed
    if type(armed) ~= "table" or #armed == 0 then
        return false, "no junk sale is armed"
    end

    local api = containerAPI()
    if not api then
        return false, "the client exposes no container API"
    end

    local report = { sold = 0, failed = 0, skipped = 0, value = 0 }

    for _, row in ipairs(armed) do
        local score = number(row.junkScore)
        if not score or score > Vendor.JUNK_SCORE_MAX then
            -- The set is re-checked at the moment of the sale: an item proves
            -- itself worthless or it is left alone.
            report.skipped = report.skipped + 1
        else
            local sold = sellOne(api, row)
            if sold then
                report.sold = report.sold + 1
                report.value = report.value + Vendor.StackValue(row)
            else
                report.failed = report.failed + 1
            end
        end
    end

    -- The armed set is spent whether or not every row sold; the bags are read
    -- again so no stale border survives the pass.
    self.junkArmed = nil
    notifyJunk(nil)
    if report.sold > 0 or report.failed > 0 then self:Refresh() end

    return report.sold > 0, nil, report
end

-- dryRun == true never calls the client: it reports the same plan and sells
-- nothing. A real run refuses combat and anything that is not a merchant.
function Vendor:RunAutoSell(dryRun)
    local report = { dryRun = dryRun == true, sold = 0, failed = 0 }

    if combatLocked() then
        report.reason = "combat"
        return report
    end

    if not report.dryRun and not merchantOpen() then
        report.reason = "no merchant"
        return report
    end

    local plan, reason = self:PlanSell()
    if not plan then
        report.reason = reason or "the bags could not be read"
        return report
    end

    report.plan = plan

    if report.dryRun then return report end

    local api = containerAPI()
    if not api then
        report.reason = "the client exposes no container API"
        return report
    end

    for _, row in ipairs(plan.sell) do
        local sold = sellOne(api, row)
        if sold then
            report.sold = report.sold + 1
        else
            report.failed = report.failed + 1
        end
    end

    -- Re-read the bags after the pass, whether every sale worked or one failed.
    -- The marker is handed a fresh answer (or nil) from what is actually in the
    -- slots now; a failure that emptied the slot anyway therefore cannot leave
    -- the coin on an empty slot, and a sale that left the item cannot have it
    -- marked for a slot that no longer holds it.
    if report.sold > 0 or report.failed > 0 then self:Refresh() end

    return report
end

function Vendor:ReportSold(report)
    if type(report) ~= "table" then return end
    if report.reason then
        if report.reason ~= "no merchant" then
            LT:Print("Auto-sell skipped: " .. tostring(report.reason) .. ".")
        end
        return
    end

    if report.sold == 0 and report.failed == 0 then
        -- An armed auto-sell that found nothing says so: silence used to look
        -- like the pass never ran (E3).
        if report.dryRun then return end
        LT:Print("Auto-sell is on, no grey items to sell.")
        return
    end

    LT:Print("Sold " .. tostring(report.sold) .. " grey stack(s)"
        .. (report.failed > 0 and (", " .. tostring(report.failed) .. " failed") or "")
        .. ".")
end

-- One pass per merchant opening, plus at most one short retry when the plan
-- came back empty. A grey picked up while the window is already open waits for
-- the next opening; that is predictable, where a poll would not be. The bank is
-- never read, opened or written.
Vendor.RETRY_SECONDS = 0.3

local function afterDelay(seconds, fn)
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
        return false
    end

    local ok = pcall(C_Timer.After, seconds, fn)
    return ok
end

function Vendor:MerchantOpened()
    -- The event is the proof; the frame's own visibility is not trusted here.
    self.atMerchant = true
    self.merchantSession = (self.merchantSession or 0) + 1
    local session = self.merchantSession

    -- Repair and the errand strip are merchant business, not sell business:
    -- they run even when grey auto-sell is off. Both refuse in combat, so a
    -- merchant opened mid-fight is remembered and handled after the fight.
    if combatLocked() then
        self.pendingRepair = coreOption("autoRepair") == true
        self.pendingStrip = true
    else
        self.pendingRepair = false
        self.pendingStrip = false
        -- The strip is read before the repair so the bill it shows is the one
        -- that was there when the player arrived; the repair then prints its
        -- own one-line summary.
        self:PrintErrandStrip()
        self:AutoRepair()
    end

    if not self:AutoSellEnabled() then return end

    if combatLocked() then
        self.pendingSell = true
        return
    end

    self.pendingSell = false

    local report = self:RunAutoSell(false)

    -- Rows to sell, or a reason the bags could not be read, are the answer now.
    -- An empty plan can also be a price that has not arrived yet, so it gets one
    -- guarded retry before the player is told there is nothing to sell.
    if report.reason or #(report.plan and report.plan.sell or {}) > 0 then
        self:ReportSold(report)
        return
    end

    local scheduled = afterDelay(Vendor.RETRY_SECONDS, function()
        -- The merchant closed, or another opening happened, before the retry:
        -- this pass belongs to a session that is already gone.
        if self.merchantSession ~= session or self.atMerchant ~= true then return end
        if not self:AutoSellEnabled() then return end

        if combatLocked() then
            self.pendingSell = true
            return
        end

        self.pendingSell = false
        self:ReportSold(self:RunAutoSell(false))
    end)

    -- No timer on this client: report the empty plan now rather than never.
    if not scheduled then self:ReportSold(report) end
end

------------------------------------------------------------------------------
-- Callbacks for the UI layer
--
-- No frame, texture or font string is created here. The UI agent registers a
-- painter and draws/clears the marker, the gold frames or the junk borders;
-- each is called with nil to clear.
------------------------------------------------------------------------------

function Vendor:SetMarkerPainter(fn)
    if fn ~= nil and type(fn) ~= "function" then return false end
    self.markerPainter = fn
    self:Refresh()
    return true
end

function Vendor:SetSurplusPainter(fn)
    if fn ~= nil and type(fn) ~= "function" then return false end
    self.surplusPainter = fn
    self:Refresh()
    return true
end

function Vendor:Refresh()
    if combatLocked() then
        self.dirty = true
        return
    end

    self.dirty = false

    if type(self.markerPainter) == "function" then
        -- The gold border and the coin are a merchant answer, not a bag
        -- judgement: they say "sell this one while you are at the counter".
        -- With no merchant open the painter is handed nil, which clears the
        -- mark, and MERCHANT_CLOSED reaches here through OnEvent for the same
        -- reason. No row is ranked when there is nobody to sell to.
        local cheapest

        if merchantOpen() then
            cheapest = self:Cheapest()
        end

        pcall(self.markerPainter, cheapest)
    end

    if type(self.surplusPainter) == "function" then
        pcall(self.surplusPainter, self:SurplusRows())
    end
end

------------------------------------------------------------------------------
-- Printing
------------------------------------------------------------------------------

local function money(copper)
    local rewards = LT.QuestRewards
    if type(rewards) == "table" and type(rewards.moneyText) == "function" then
        local ok, rendered = pcall(rewards.moneyText, copper)
        if ok and type(rendered) == "string" then return rendered end
    end

    return tostring(number(copper) or 0) .. "c"
end

------------------------------------------------------------------------------
-- Merchant errands: repair and the one-line strip
------------------------------------------------------------------------------

-- The repair cost the client reports, or nil when it cannot say. Only the
-- first return (the total) is read; the guild-bank answer is never used.
local function repairCost()
    if type(GetRepairAllCost) ~= "function" then return nil end
    local ok, cost = pcall(GetRepairAllCost)
    if not ok then return nil end
    return number(cost)
end

local function merchantCanRepair()
    if type(CanMerchantRepair) == "function" then
        local ok, canRepair = pcall(CanMerchantRepair)
        if ok then return canRepair == true end
    end

    -- Without the capability call, a readable repair cost is the proof that
    -- this merchant offers repairs; no cost at all is treated as "cannot".
    if type(RepairAllItems) ~= "function" then return false end
    return repairCost() ~= nil
end

-- Repairs every equipped item once, on player funds only. Refuses when the
-- autoRepair option is off, in combat, away from a merchant, at a merchant that
-- does not repair, or when there is nothing to pay for. One summary line.
function Vendor:AutoRepair()
    if coreOption("autoRepair") ~= true then
        return false, "the auto-repair switch is off"
    end
    if combatLocked() then return false, "combat" end
    if not merchantOpen() then return false, "no merchant" end
    if not merchantCanRepair() then
        return false, "this merchant cannot repair"
    end

    local cost = repairCost()
    if not cost or cost <= 0 then return false, "nothing to repair" end

    -- Player funds only means the player's own purse has to cover the bill.
    -- An unreadable purse is not permission to overdraw: the repair is skipped
    -- and the strip already shows the cost.
    if type(GetMoney) == "function" then
        local okMoney, purse = pcall(GetMoney)
        local available = okMoney and number(purse) or nil
        if available and available < cost then
            return false, "not enough money"
        end
    end

    if type(RepairAllItems) ~= "function" then
        return false, "the client exposes no repair call"
    end

    -- false is "player funds". Guild funds are never requested.
    local ok, err = pcall(RepairAllItems, false)
    if not ok then
        -- A client whose repair call refuses the argument still defaults to
        -- player funds; retry once without it rather than give up silently.
        ok, err = pcall(RepairAllItems)
    end
    if not ok then
        return false, "the repair failed: " .. tostring(err)
    end

    LT:Print("Repaired all equipment for " .. money(cost)
        .. " (player funds only).")
    return true, nil, cost
end

local function freeBagSlots()
    local api = containerAPI()
    if not api then return nil end

    local free = 0
    local lastBag = number(NUM_BAG_SLOTS) or 4

    for bag = 0, lastBag do
        local okSlots, slots = pcall(api.slots, bag)
        slots = okSlots and number(slots) or 0

        for slot = 1, slots do
            local okLink, link = pcall(api.link, bag, slot)
            if okLink and not text(link) then free = free + 1 end
        end
    end

    return free
end

-- What the junk rules would pay for right now. With the junkSale switch on
-- this is the scored set the manual sale would use; with it off it is the grey
-- auto-sell set, so the strip never promises money no rule would collect.
local function junkValue()
    local rows

    if coreOption("junkSale") == true then
        rows = Vendor:JunkCandidates(true)
    else
        local plan = Vendor:PlanSell()
        rows = plan and plan.sell or nil
    end

    if not rows then return 0 end

    local total = 0
    for _, row in ipairs(rows) do total = total + Vendor.StackValue(row) end
    return total
end

-- One line, printed only when one of the three numbers is actionable: bags
-- full, a repair bill, or junk worth selling. Reads only; never repairs.
function Vendor:PrintErrandStrip()
    if combatLocked() then return false end
    if not merchantOpen() then return false end

    local free = freeBagSlots()
    local cost = merchantCanRepair() and repairCost() or nil
    local worth = junkValue()

    local actionable = (free == 0) or (cost and cost > 0) or (worth and worth > 0)
    if not actionable then return false end

    local parts = {
        tostring(free or "?") .. " free bag slot(s)",
        cost and ("repair " .. money(cost)) or "repair not offered",
        "junk worth " .. money(worth or 0),
    }

    LT:Print("Vendor errand: " .. table.concat(parts, ", ") .. ".")
    return true
end

local function where(row)
    local bag = number(row.bag) or 0
    local label = (bag == 0) and "backpack" or ("bag " .. tostring(bag))
    return label .. " slot " .. tostring(number(row.slot) or "?")
end

local function describe(row)
    local parts = { tostring(row.link or row.name or "?") }
    local count = number(row.count) or 1

    if count > 1 then
        parts[#parts + 1] = " x" .. tostring(count)
        parts[#parts + 1] = " = " .. money(Vendor.StackValue(row)) .. " to lose"
        parts[#parts + 1] = " (" .. money(row.unitPrice) .. " each)"
    else
        parts[#parts + 1] = " = " .. money(Vendor.StackValue(row))
    end

    if row.bag ~= nil then parts[#parts + 1] = " at " .. where(row) end

    return table.concat(parts)
end

local function describeExclusions(excluded)
    return "Skipped: " .. tostring(excluded.quest) .. " quest, "
        .. tostring(excluded.soulbound) .. " soulbound or unreadable binding, "
        .. tostring(excluded.unpriced) .. " without a price, "
        .. tostring(excluded.emptySlot or 0) .. " for an empty worn slot, "
        .. tostring(excluded.upgrade or 0) .. " upgrade, "
        .. tostring(excluded.ignored) .. " ignored."
end

function Vendor:PrintCheapest()
    local cheapest, reason, ranked = self:Cheapest()

    if not cheapest then
        LT:Print("No item is marked: " .. tostring(reason or "nothing qualifies") .. ".")
        if ranked then LT:Print("  " .. describeExclusions(ranked.excluded)) end
        return
    end

    -- L-10: the bag context's one line, on the number the merchant pays for
    -- the whole stack. Without a merchant there is nobody to sell to, so the
    -- same figure is named as what destroying would throw away.
    local count = number(cheapest.count) or 1
    local named = tostring(cheapest.link or cheapest.name or "?")
    if count > 1 then named = named .. " x" .. tostring(count) end

    LT:Print((merchantOpen() and "Sell this one (" or "Destroy this one (")
        .. money(Vendor.StackValue(cheapest)) .. "): " .. named .. " at " .. where(cheapest))
    LT:Print("  " .. describeExclusions(ranked.excluded))
end

function Vendor:PrintSurplus()
    local plan = self:SurplusRows(true)

    if not plan then
        LT:Print("Surplus framing needs the GearCheck module and an out-of-combat scan.")
        return
    end

    if #plan.surplus == 0 then
        LT:Print("No surplus: every slot keeps its best item and one spare.")
        return
    end

    LT:Print("Surplus gear (" .. tostring(#plan.surplus)
        .. " item(s)); the best per slot plus a spare is kept, and nothing is sold:")
    for _, row in ipairs(plan.surplus) do
        LT:Print("  " .. tostring(row.link or row.name or "?")
            .. "  slot " .. tostring(number(row.slot) or "?")
            .. "  +" .. tostring(number(row.delta) or 0))
    end
end

function Vendor:PrintIgnored()
    local store = db()
    local ids = {}

    for key in pairs(store.ignore) do
        local id = number(key)
        if id then ids[#ids + 1] = id end
    end

    table.sort(ids)

    if #ids == 0 then
        LT:Print("Nothing is ignored. /lbv ignore [item] hides one for every "
            .. "character on this account.")
        return
    end

    LT:Print(tostring(#ids) .. " ignored item(s), shared by every character on this account:")
    for _, id in ipairs(ids) do
        local entry = store.ignore[id]
        local name = type(entry) == "table" and text(entry.name) or nil
        LT:Print("  " .. tostring(name or "?") .. " (" .. tostring(id) .. ")")
    end
end

function Vendor:PrintStatus()
    LT:Print("Vendor plugin v" .. Vendor.VERSION
        .. (self.registered and " (registered with the core)" or " (not registered yet)") .. ".")

    local choice = self:AutoSellChoice()
    local sellState = (choice == nil) and "off (default)"
        or (choice and "on (switched on here)" or "off (switched off here)")

    LT:Print("  Settings for " .. tostring(self:CharacterKey() or "this character")
        .. " only — grey auto-sell at a merchant: " .. sellState
        .. ", surplus framing: " .. (self:SurplusEnabled() and "on" or "off") .. ".")

    LT:Print("  Grey auto-sell runs when a merchant opens: quality 0, priced, "
        .. "not quest, not soulbound, not ignored, not a GearCheck upgrade.")
    LT:Print("  A grey item that would fill an empty worn slot is kept — grey is "
        .. "better than nothing. /lbv sell on turns the sweep on for this "
        .. "character; /lbv sell off turns it off again.")

    LT:Print("  Junk sale (junkSale option): " .. (coreOption("junkSale") == true
        and "on" or "off")
        .. " — /lbv junk borders worthless items, a second /lbv junk sells them. "
        .. "Auto-repair (autoRepair option): " .. (coreOption("autoRepair") == true
        and "on" or "off") .. ".")

    LT:Print("  Commands: /lt vendor (also /lbv, /ltvendor): mark, dryrun, junk, "
        .. "ignore [item], forget <id>, ignored, sell on|off, surplus on|off.")

    if self.commandRegistered and self.commandWordTaken then
        LT:Print("  The word \"vendor\" is taken by another addon; /lbv and "
            .. "/ltvendor still reach this plugin.")
    end

    LT:Print("  The marker, the surplus frames and the junk borders are drawn by "
        .. "the UI layer through Vendor:SetMarkerPainter / SetSurplusPainter / "
        .. "SetJunkPainter.")
end

------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------

local function resolveItem(value)
    local trimmed = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return nil, nil end

    local id = number(trimmed)
    if id then return id, nil end

    local fromLink = itemIDFromLink(trimmed)
    if not fromLink then return nil, nil end

    local details = itemDetails(trimmed)
    local identity = identityOf(trimmed)

    return fromLink,
        (details and details.name) or text(identity and identity.name) or nameFromLink(trimmed)
end

local function cursorItem()
    if type(GetCursorInfo) ~= "function" then return nil, nil end

    local ok, kind, id, link = pcall(GetCursorInfo)
    if not ok or kind ~= "item" then return nil, nil end

    return number(id), text(link)
end

function Vendor:CommandIgnore(words)
    local argument = table.concat(words, " ", 2)
    local id, name

    if argument ~= "" then
        id, name = resolveItem(argument)
    else
        local cursorID, cursorLink = cursorItem()

        if cursorID or cursorLink then
            id = cursorID or itemIDFromLink(cursorLink)
            name = nameFromLink(cursorLink)
            if id and not name then
                local details = itemDetails(cursorLink or "")
                name = details and details.name or nil
            end
        else
            local cheapest = self:Cheapest()
            if cheapest then id, name = cheapest.itemID, cheapest.name end
        end
    end

    if not id then
        LT:Print("Nothing to ignore. Shift-click an item into the command, "
            .. "hold one on the cursor, or mark one with /lbv mark.")
        return
    end

    if self:IsIgnored(id) then
        LT:Print(tostring(name or id) .. " (" .. tostring(id)
            .. ") is already on the ignore list.")
        return
    end

    self:Ignore(id, name)
    LT:Print("Ignoring " .. tostring(name or id) .. " (" .. tostring(id)
        .. ") for every character on this account.")
    self:Refresh()
end

function Vendor:CommandForget(words)
    local argument = table.concat(words, " ", 2)
    local id, name = resolveItem(argument)

    if not id then
        LT:Print("Usage: /lbv forget <item id|item link>. /lbv ignored lists them.")
        return
    end

    if not self:Forget(id) then
        LT:Print(tostring(name or id) .. " is not on the ignore list.")
        return
    end

    LT:Print("No longer ignoring " .. tostring(name or id) .. " (" .. tostring(id) .. ").")
    self:Refresh()
end

function Vendor:CommandDryRun()
    local report = self:RunAutoSell(true)

    if report.reason then
        LT:Print("The dry run cannot read the bags: " .. tostring(report.reason) .. ".")
        return
    end

    local plan = report.plan

    LT:Print("Dry run: nothing is sold. Auto-sell is "
        .. (self:AutoSellEnabled() and "on" or "off") .. ".")

    if #plan.sell == 0 then
        LT:Print("  Nothing matches: grey, priced, unbound, not a quest item, "
            .. "not ignored, not an upgrade, and its worn slot is filled.")
    else
        for _, row in ipairs(plan.sell) do
            LT:Print("  would sell " .. describe(row))
        end
        LT:Print("  " .. tostring(#plan.sell) .. " stack(s) would be sold.")
    end

    LT:Print("  " .. describeExclusions(plan.excluded) .. " "
        .. tostring(plan.excluded.notGrey) .. " not grey.")
end

function Vendor:CommandJunk()
    if coreOption("junkSale") ~= true then
        LT:Print("The score-based junk sale is off. Switch on junkSale in Settings, "
            .. "then /lbv junk at a merchant.")
        return
    end

    if self:JunkRows() then
        local ok, reason, report = self:ConfirmJunkSale()

        if report and (report.sold > 0 or report.failed > 0) then
            LT:Print("Sold " .. tostring(report.sold) .. " junk stack(s) for "
                .. money(report.value)
                .. (report.failed > 0 and (", " .. tostring(report.failed) .. " failed") or "")
                .. (report.skipped > 0 and (", " .. tostring(report.skipped) .. " left alone") or "")
                .. ".")
        elseif not ok then
            if report and report.skipped > 0 then
                LT:Print("Nothing was sold; " .. tostring(report.skipped)
                    .. " bordered item(s) no longer qualified.")
            elseif reason == "combat" then
                LT:Print("The junk sale waits until combat ends.")
            elseif reason == "no merchant" then
                LT:Print("Open a merchant to sell the bordered junk.")
            else
                LT:Print("Junk sale not completed: "
                    .. tostring(reason or "nothing was sold") .. ".")
            end
        else
            LT:Print("Junk sale finished; no stack was sold.")
        end
        return
    end

    local ok, reason, rows = self:ArmJunkSale()

    if not ok then
        if reason == "nothing worthless" then
            LT:Print("Nothing is worthless for this build: quality 0 or a score at or "
                .. "below " .. tostring(Vendor.JUNK_SCORE_MAX) .. ".")
        elseif reason == "combat" then
            LT:Print("The junk sale waits until combat ends.")
        elseif reason == "no merchant" then
            LT:Print("Open a merchant to border the junk, then /lbv junk again to sell it.")
        else
            LT:Print("Junk sale not armed: " .. tostring(reason or "nothing to do") .. ".")
        end
        return
    end

    LT:Print("Bordered " .. tostring(#rows) .. " worthless item(s). Run /lbv junk "
        .. "again at this merchant to sell exactly those; nothing is sold yet.")
end

function Vendor:Command(input)
    local words = splitWords(input)
    local action = words[1] and string.lower(words[1]) or "status"

    if action == "mark" or action == "cheapest" then
        return self:PrintCheapest()
    end

    if action == "ignore" then return self:CommandIgnore(words) end
    if action == "forget" or action == "unignore" then return self:CommandForget(words) end
    if action == "ignored" or action == "list" then return self:PrintIgnored() end
    if action == "dryrun" or action == "dry-run" then return self:CommandDryRun() end
    if action == "junk" then return self:CommandJunk() end

    if action == "sell" then
        local value = words[2] and string.lower(words[2]) or nil

        if value == "on" or value == "off" then
            local accepted, refused = self:SetEnabled(Vendor.OPTION_KEYS.autoSell,
                value == "on")
            if not accepted then
                LT:Print("Could not change grey auto-sell: " .. tostring(refused) .. ".")
                return
            end

            local now = self:AutoSellEnabled()
            LT:Print("Grey auto-sell at a merchant is now " .. (now and "on" or "off")
                .. " for this character only.")
            if now then
                LT:Print("Only quality 0 items with a price are sold — never quest items, "
                    .. "soulbound items, ignored items, GearCheck upgrades, or gear whose "
                    .. "worn slot is empty. /lbv dryrun lists them first.")
            else
                LT:Print("/lbv sell on turns the sweep back on; /lbv dryrun still lists "
                    .. "what it would sell.")
            end
            return
        end

        LT:Print("Usage: /lbv sell on|off. /lbv dryrun lists what would be sold.")
        return
    end

    if action == "surplus" then
        local value = words[2] and string.lower(words[2]) or nil

        if value == "on" or value == "off" then
            local accepted, refused = self:SetEnabled(Vendor.OPTION_KEYS.surplus,
                value == "on")
            if not accepted then
                LT:Print("Could not change surplus framing: " .. tostring(refused) .. ".")
                return
            end

            local now = self:SurplusEnabled()
            LT:Print("Surplus framing is now " .. (now and "on" or "off")
                .. " for this character only.")
            if now then self:PrintSurplus() end
            return
        end

        self:PrintSurplus()
        return
    end

    if action == "status" or action == "help" or action == "?" then
        return self:PrintStatus()
    end

    LT:Print("Unknown option \"" .. tostring(action) .. "\". /lbv help lists the commands.")
end

------------------------------------------------------------------------------
-- Registration and events
------------------------------------------------------------------------------

local COMMAND_HELP = "/lt vendor — bags helper: mark, dryrun, junk, ignore [item], "
    .. "ignored, sell on|off, surplus on|off (also /lbv and /ltvendor). "
    .. "Grey auto-sell and the junk sale are off by default; /lbv help lists "
    .. "what is never sold."

-- /lt vendor. The core owns the dispatch table and refuses a word that already
-- exists, so a taken word costs a working alias at most and never a broken
-- command surface. Called at PLAYER_LOGIN, once; a second call is a no-op.
function Vendor:RegisterCommands()
    -- Already decided: report whether the word is actually ours, so a caller
    -- is never told /lt vendor works when another addon owns it.
    if self.commandRegistered then
        return self.commandWordTaken ~= true
    end

    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then
        return false, "the core's slash command module is not loaded"
    end

    local ok, accepted = pcall(slash.RegisterCommand, slash, "vendor",
        function(words)
            -- The core passes the parsed line, word[1] included; Vendor:Command
            -- takes only the argument text, so the word is dropped here.
            local input = words
            if type(input) == "table" then
                input = table.concat(input, " ", 2)
            end
            Vendor:Command(input)
        end, COMMAND_HELP)

    if not ok then return false, tostring(accepted) end

    -- false means the word is already taken: this file's earlier attempt, or
    -- another addon. Stop retrying either way; /lbv and /ltvendor still work.
    self.commandRegistered = true
    self.commandWordTaken = accepted ~= true

    if accepted ~= true then
        return false, "the command word \"vendor\" is already registered"
    end

    return true
end

function Vendor:RegisterPlugin()
    if self.registered then return true end

    local api = LT.PluginAPI
    if type(api) ~= "table" or type(api.RegisterPlugin) ~= "function" then
        return false, "the core's PluginAPI is missing"
    end

    local ok, plugin, reason = pcall(api.RegisterPlugin, api, {
        id          = Vendor.PLUGIN_ID,
        name        = "Lunchbox Vendor",
        version     = Vendor.VERSION,
        author      = "Lunchbox",
        apiVersion  = 1,
        description = "Levelling helper for the bags: one cheapest-to-lose marker, "
            .. "opt-in grey auto-sell and score-based junk sale at a merchant, "
            .. "surplus upgrade framing, and auto-repair on player funds. "
            .. "Never destroys, moves or equips anything.",
    })

    if not ok then return false, tostring(plugin) end
    if not plugin then return false, tostring(reason or "registration was refused") end

    self.registered = plugin
    return true
end

function Vendor:OnEvent(event)
    if event == "PLAYER_LOGIN" then
        self:RegisterPlugin()
        self:RegisterCommands()
        self:Refresh()
        return
    end

    if event == "MERCHANT_SHOW" then
        self:MerchantOpened()
        self:Refresh()
        return
    end

    if event == "MERCHANT_CLOSED" then
        self.atMerchant = false
        -- Any retry still queued belongs to a merchant the player has left.
        self.merchantSession = (self.merchantSession or 0) + 1
        self.pendingSell = false
        self.pendingRepair = false
        self.pendingStrip = false
        -- The junk borders belong to the visit that armed them; leaving the
        -- merchant clears them instead of letting a stale set survive.
        if self.junkArmed ~= nil then
            self.junkArmed = nil
            notifyJunk(nil)
        end
        self:Refresh()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if merchantOpen() then
            if self.pendingStrip then
                self.pendingStrip = false
                self:PrintErrandStrip()
            end
            if self.pendingRepair then
                self.pendingRepair = false
                self:AutoRepair()
            end
        end
        if self.pendingSell and self:AutoSellEnabled() and merchantOpen() then
            self.pendingSell = false
            self:ReportSold(self:RunAutoSell(false))
        end
        if self.dirty then self:Refresh() end
        return
    end

    self:Refresh()
end

function Vendor:Initialize()
    if self.frame then return true end

    -- Guards the floor rule even though file load is never a combat moment.
    if combatLocked() then
        self.dirty = true
        return false
    end

    if type(CreateFrame) ~= "function" then return false end

    local ok, frame = pcall(CreateFrame, "Frame")
    if not ok or type(frame) ~= "table" then return false end

    self.frame = frame

    for _, event in ipairs({
        "PLAYER_LOGIN",
        "MERCHANT_SHOW",
        "MERCHANT_CLOSED",
        "BAG_UPDATE_DELAYED",
        "PLAYER_REGEN_ENABLED",
        "GET_ITEM_INFO_RECEIVED",
        "ITEM_DATA_LOAD_RESULT",
    }) do
        pcall(frame.RegisterEvent, frame, event)
    end

    pcall(frame.SetScript, frame, "OnEvent", function(_, event)
        Vendor:OnEvent(event)
    end)

    if type(LT.On) == "function" then
        LT:On("INVENTORY_CHANGED", function() Vendor:Refresh() end, "LunchboxToolkit_Vendor")
        LT:On("EQUIPMENT_CHANGED", function() Vendor:Refresh() end, "LunchboxToolkit_Vendor")
    end

    return true
end

------------------------------------------------------------------------------
-- Slash commands
--
-- /lt vendor is the primary word, registered with the core at PLAYER_LOGIN
-- (Vendor:RegisterCommands). The two globals below are aliases, set at file
-- load because WoW reads SLASH_<NAME><INDEX> while addons are loading; defining
-- them only at login can be too late on some clients.
------------------------------------------------------------------------------

_G.SLASH_LUNCHBOXVENDOR1 = "/lbv"
_G.SLASH_LUNCHBOXVENDOR2 = "/ltvendor"

if type(SlashCmdList) == "table" then
    SlashCmdList["LUNCHBOXVENDOR"] = function(input)
        local ok, err = pcall(Vendor.Command, Vendor, input)
        if not ok then
            pcall(LT.Error, LT, "Vendor command failed: " .. tostring(err))
        end
    end
end

Vendor:Initialize()

return Vendor
