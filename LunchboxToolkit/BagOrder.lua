--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — BagOrder

    The *ordering* BankStack uses, implemented here from its behaviour (read from
    the installed copy at M:/_forever_, never from its code: BankStack is
    "All rights reserved"). What the order does, highest to lowest:

      1. empty slots last
      2. pet cages last (same pet: by pet name)
      3. the same item: smaller stacks first, then original order
      4. quality, higher first
      5. item class, in the auction house's own order
         (weapon, armour, quiver, container, gem, enhancement, consumable,
          reagent, glyph, trade good, profession, recipe, battle pet, key, misc,
          projectile, currency, permanent, quest item)
      6. armour and weapons: by equip slot (head, neck, shoulder, ... relic)
      7. otherwise subclass, in the auction house's order
      8. then item level (higher first), vendor price (higher first), name, id
      9. anything still tied keeps the order it had

    `reverse` flips every comparison.

    Movement is deliberately narrow: only containers with **no family
    restriction** are sorted (a herb bag keeps its herbs), one swap per tick,
    never in combat, and every swap is verified before the next. Nothing is
    destroyed, equipped or used. `/lt sort preview` prints the plan and moves
    nothing.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local BagOrder = {}
LT.BagOrder = BagOrder

BagOrder.PET_CAGE_ID = 82800

-- Equip-slot order, from Blizzard's own inventory layout. Not a sort rule of
-- anybody's addon: it is the order the paper doll uses.
BagOrder.EQUIP_ORDER = {
    INVTYPE_AMMO = 0, INVTYPE_HEAD = 1, INVTYPE_NECK = 2, INVTYPE_SHOULDER = 3,
    INVTYPE_BODY = 4, INVTYPE_CHEST = 5, INVTYPE_ROBE = 5, INVTYPE_WAIST = 6,
    INVTYPE_LEGS = 7, INVTYPE_FEET = 8, INVTYPE_WRIST = 9, INVTYPE_HAND = 10,
    INVTYPE_FINGER = 11, INVTYPE_TRINKET = 12, INVTYPE_CLOAK = 13,
    INVTYPE_WEAPON = 14, INVTYPE_SHIELD = 15, INVTYPE_2HWEAPON = 16,
    INVTYPE_WEAPONMAINHAND = 18, INVTYPE_WEAPONOFFHAND = 19,
    INVTYPE_HOLDABLE = 20, INVTYPE_RANGED = 21, INVTYPE_THROWN = 22,
    INVTYPE_RANGEDRIGHT = 23, INVTYPE_RELIC = 24, INVTYPE_TABARD = 25,
}

-- The class order comes from the auction house's display order, by name so a
-- client that renumbers the enum still sorts the same way.
local CLASS_NAMES = {
    "Weapon", "Armor", "Quiver", "Container", "Gem", "ItemEnhancement",
    "Consumable", "Reagent", "Glyph", "Tradegoods", "Profession", "Recipe",
    "Battlepet", "Key", "Miscellaneous", "Projectile",
    "CurrencyTokenObsolete", "PermanentObsolete", "Questitem",
}

local classRank
local function classOrder()
    if classRank then return classRank end
    classRank = {}
    local enum = type(Enum) == "table" and Enum.ItemClass or nil
    if type(enum) == "table" then
        for index, name in ipairs(CLASS_NAMES) do
            local value = enum[name]
            if type(value) == "number" then classRank[value] = index end
        end
    end
    return classRank
end

-- Subclass order per class, from the client's own auction lists.
local subclassRank
local function subclassOrder()
    if subclassRank then return subclassRank end
    subclassRank = {}
    if type(C_AuctionHouse) == "table"
        and type(C_AuctionHouse.GetAuctionItemSubClasses) == "function" then
        for classID in pairs(classOrder()) do
            local ok, list = pcall(C_AuctionHouse.GetAuctionItemSubClasses, classID)
            if ok and type(list) == "table" then
                local map = {}
                for index, subID in ipairs(list) do map[subID] = index end
                subclassRank[classID] = map
            end
        end
    end
    return subclassRank
end

local function number(value)
    if type(value) == "number" then return value end
    return nil
end

-- One record per occupied slot. The fields are fetched once so the comparator
-- is pure and testable without a client.
function BagOrder:Record(bag, slot, order)
    local info
    if type(C_Container) == "table" and type(C_Container.GetContainerItemInfo) == "function" then
        local ok, got = pcall(C_Container.GetContainerItemInfo, bag, slot)
        if ok and type(got) == "table" then info = got end
    end
    if not info or not number(info.itemID) then return nil end

    local itemID = info.itemID
    local name, _, quality, itemLevel, _, _, _, _, equipLoc, _, sellPrice,
        classID, subClassID = C_Item.GetItemInfo(itemID)

    return {
        bag = bag, slot = slot, order = order,
        itemID = itemID,
        count = number(info.stackCount) or 1,
        locked = info.isLocked == true,
        name = name or ("item " .. tostring(itemID)),
        quality = number(quality) or number(info.quality) or 0,
        itemLevel = number(itemLevel) or 0,
        price = number(sellPrice) or 0,
        equipLoc = equipLoc,
        classID = number(classID),
        subClassID = number(subClassID),
        link = info.hyperlink,
    }
end

-- a before b? Pure: every field is on the record.
function BagOrder:Less(a, b)
    local aID, bID = a and a.itemID, b and b.itemID
    if not aID and not bID then return (a.order or 0) < (b.order or 0) end
    if not aID then return false end          -- empties last
    if not bID then return true end

    local aPet, bPet = aID == self.PET_CAGE_ID, bID == self.PET_CAGE_ID
    if aPet ~= bPet then return bPet end      -- pet cages last

    if aID == bID then
        if aPet and a.name ~= b.name then return a.name < b.name end
        if a.count ~= b.count then return a.count < b.count end
        return (a.order or 0) < (b.order or 0)
    end

    if a.quality ~= b.quality then return a.quality > b.quality end

    local classes = classOrder()
    local aClass = classes[a.classID] or 99
    local bClass = classes[b.classID] or 99
    if aClass ~= bClass then return aClass < bClass end

    local enum = type(Enum) == "table" and Enum.ItemClass or nil
    local isGear = enum and (a.classID == enum.Armor or a.classID == enum.Weapon)
    if isGear then
        local aSlot = self.EQUIP_ORDER[a.equipLoc] or -1
        local bSlot = self.EQUIP_ORDER[b.equipLoc] or -1
        if aSlot ~= bSlot then return aSlot < bSlot end
    else
        local subs = subclassOrder()[a.classID]
        if subs and a.subClassID ~= b.subClassID then
            local aSub, bSub = subs[a.subClassID] or 99, subs[b.subClassID] or 99
            if aSub ~= bSub then return aSub < bSub end
        end
    end

    if a.itemLevel ~= b.itemLevel then return a.itemLevel > b.itemLevel end
    if a.price ~= b.price then return a.price > b.price end
    if a.name ~= b.name then return a.name < b.name end
    if aID ~= bID then return aID < bID end
    return (a.order or 0) < (b.order or 0)
end

function BagOrder:Compare(a, b, reverse)
    if reverse then return self:Less(b, a) end
    return self:Less(a, b)
end

-- Containers for one scope. Only family-free containers are returned; a named
-- bag (herbs, ore, enchant) is reported and left alone.
function BagOrder:Containers(scope)
    local containers, skipped = {}, {}
    local function add(bag)
        if type(bag) ~= "number" then return end
        local free, family
        if type(C_Container) == "table" and type(C_Container.GetContainerNumFreeSlots) == "function" then
            local ok, f, fam = pcall(C_Container.GetContainerNumFreeSlots, bag)
            if ok then free, family = f, fam end
        end
        if family and family ~= 0 then
            skipped[#skipped + 1] = tostring(bag)
            return
        end
        containers[#containers + 1] = bag
    end

    if scope ~= "bank" then
        add(0)
        for bag = 1, (tonumber(NUM_BAG_SLOTS) or 4) do add(bag) end
    end
    if scope == "bank" or scope == "all" then
        add(tonumber(BANK_CONTAINER) or -1)
        for bag = 5, 4 + (tonumber(NUM_BANKBAGS) or 6) do add(bag) end
    end

    return containers, skipped
end

function BagOrder:IsBankOpen()
    local frame = _G.BankFrame
    if type(frame) == "table" and type(frame.IsShown) == "function" then
        local ok, shown = pcall(frame.IsShown, frame)
        if ok and shown then return true end
    end
    if type(C_Bank) == "table" and type(C_Bank.CanViewBank) == "function" then
        local ok, can = pcall(C_Bank.CanViewBank, Enum and Enum.BankType and Enum.BankType.Character)
        if ok and can then return true end
    end
    return false
end

-- Build the plan: what sits where now, and where each item should end up.
function BagOrder:Plan(scope)
    local wanted = tostring(scope or "bags"):lower()
    if wanted == "all" and not self:IsBankOpen() then
        return nil, "open the bank first: the client will not move bank items otherwise"
    end

    local containers, skipped = self:Containers(wanted)
    if #containers == 0 then return nil, "no containers to sort" end

    local slots, records = {}, {}
    local order = 0
    for _, bag in ipairs(containers) do
        local count = 0
        if type(C_Container) == "table" and type(C_Container.GetContainerNumSlots) == "function" then
            local ok, value = pcall(C_Container.GetContainerNumSlots, bag)
            if ok then count = number(value) or 0 end
        end
        for slot = 1, count do
            order = order + 1
            local record = self:Record(bag, slot, order)
            local entry = { bag = bag, slot = slot, order = order, itemID = record and record.itemID }
            slots[#slots + 1] = entry
            records[#records + 1] = record or entry
        end
    end

    local reverse = self:Reverse()
    local target = {}
    for index, record in ipairs(records) do target[index] = record end
    table.sort(target, function(a, b) return self:Compare(a, b, reverse) end)

    return { scope = wanted, slots = slots, records = records, target = target,
        skipped = skipped }
end

-- The swaps that turn `slots` into `target`, in order. Same-item slots are
-- interchangeable, so only swaps that move a different item are emitted.
function BagOrder:Swaps(plan)
    local current = {}
    for index, entry in ipairs(plan.slots) do current[index] = { bag = entry.bag,
        slot = entry.slot, itemID = entry.itemID } end

    local swaps = {}
    for index = 1, #plan.target do
        local want = plan.target[index].itemID
        if want and current[index].itemID ~= want then
            for other = index + 1, #current do
                if current[other].itemID == want then
                    swaps[#swaps + 1] = {
                        from = current[index], to = current[other],
                    }
                    current[index], current[other] = current[other], current[index]
                    break
                end
            end
        end
    end
    return swaps
end

function BagOrder:Describe(plan)
    local lines = { "Sort plan for " .. plan.scope .. " (" .. #plan.target
        .. " slots, " .. (#plan.slots - #plan.target) .. " free beyond the items)" }
    for index = 1, math.min(#plan.target, 40) do
        local record = plan.target[index]
        if record and record.itemID then
            lines[#lines + 1] = string.format("  %2d. %s x%d", index,
                tostring(record.name), tonumber(record.count) or 1)
        else
            lines[#lines + 1] = string.format("  %2d. (empty)", index)
        end
    end
    if #plan.target > 40 then
        lines[#lines + 1] = "  … " .. (#plan.target - 40) .. " more"
    end
    if #plan.skipped > 0 then
        lines[#lines + 1] = "  left alone (not a normal bag): " .. table.concat(plan.skipped, ", ")
    end
    return lines
end

-- One swap per tick, verified. Nothing is destroyed, equipped or used.
function BagOrder:Apply(plan)
    if type(InCombatLockdown) == "function" then
        local ok, locked = pcall(InCombatLockdown)
        if ok and locked then return false, "not while you are in combat" end
    end
    if type(C_Container) ~= "table" or type(C_Container.PickupContainerItem) ~= "function" then
        return false, "this client has no container pickup function"
    end

    local swaps = self:Swaps(plan)
    if #swaps == 0 then return true, "already in that order" end

    local schedule = type(C_Timer) == "table" and type(C_Timer.After) == "function"
    if not schedule then return false, "this client cannot pace the moves" end

    local step = 0
    local function nextSwap()
        step = step + 1
        local swap = swaps[step]
        if not swap then
            if type(LT.Print) == "function" then
                pcall(LT.Print, LT, "Bag order applied: " .. tostring(#swaps) .. " move(s).")
            end
            return
        end

        local function pickup(bag, slot)
            local ok = pcall(C_Container.PickupContainerItem, bag, slot)
            return ok
        end

        if not pickup(swap.from.bag, swap.from.slot) then
            pcall(LT.Warn or LT.Print, LT, "Bag order stopped: the client refused a move.")
            return
        end
        if not pickup(swap.to.bag, swap.to.slot) then
            pcall(LT.Warn or LT.Print, LT, "Bag order stopped: the destination refused.")
            return
        end
        if type(GetCursorInfo) == "function" then
            local ok, kind = pcall(GetCursorInfo)
            if ok and kind then
                pcall(ClearCursor)
                pcall(LT.Warn or LT.Print, LT, "Bag order stopped: an item stayed on the cursor.")
                return
            end
        end

        C_Timer.After(0.08, nextSwap)
    end

    C_Timer.After(0.1, nextSwap)
    return true, "sorting " .. tostring(#swaps) .. " move(s)…"
end

-- Stored switches: sortMode = "client" | "order", sortReverse = boolean.
local function options()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then return nil end
    local ok, table_ = pcall(database.GetOptions, database)
    if ok and type(table_) == "table" then return table_ end
    return nil
end

function BagOrder:Mode()
    local options_ = options()
    if options_ and options_.sortMode == "order" then return "order" end
    return "client"
end

function BagOrder:Reverse()
    local options_ = options()
    return options_ ~= nil and options_.sortReverse == true
end

function BagOrder:SetMode(mode)
    local options_ = options()
    if not options_ then return false end
    options_.sortMode = (mode == "order") and "order" or "client"
    if LT.Database and type(LT.Database.Save) == "function" then
        pcall(LT.Database.Save, LT.Database, "options:sortMode")
    end
    return true
end

function BagOrder:SetReverse(on)
    local options_ = options()
    if not options_ then return false end
    options_.sortReverse = on == true
    if LT.Database and type(LT.Database.Save) == "function" then
        pcall(LT.Database.Save, LT.Database, "options:sortReverse")
    end
    return true
end
