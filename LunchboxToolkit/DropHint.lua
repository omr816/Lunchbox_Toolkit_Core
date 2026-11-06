--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Drop hint
    Which item to destroy when the bags are full.

    Destroying an item is gold that was decided against, so the cost of losing
    an item is what a vendor would have paid for it. The item to lose is
    therefore the cheapest by TOTAL stack value, not by unit price: five cloth
    at 4c each costs 20c to lose, which is still cheaper than one sword worth
    25c. That is the whole rule of this file, and the reason every row keeps
    both its unit price and its stack total.

    The add-on never deletes an item itself. When the suggestion is acted on,
    DropHint:DestroySuggestion only HANDS the suggested item to the client's own
    delete dialog; the confirmation the player already knows is what acts, and
    cancelling puts the item back in its slot. No call to DeleteCursorItem is made
    from this file. Quest items are never suggested, gear the player could equip
    right now is kept out of the first suggestion, and an account-wide ignore list
    hides anything the player has already judged (LunchboxToolkitDB.dropIgnore).

    In the bags themselves: the item the suggestion would destroy carries a small
    corner marker, and the bag frame carries one button in its own header -- Sort
    normally, and "Sell junk" at a merchant with junk selling on, where the first
    press marks the junk and a second press inside ten seconds sells exactly
    those. The marker is drawn only while a bag is open, it never takes a click,
    and no bag button's script is read, replaced or hooked: an ordinary click is
    the client's own click, exactly once. Items join the ignore list through
    /lt drop ignore [item] (shift-click the item into the box) and leave it
    through /lt drop forget <id> or the Forget button in /lt drop list.

    That corner belongs to one marker at a time. Triage, the GearCheck upgrade
    arrow and the vendor plugin's cheapest-to-lose marker all register a provider
    through DropHint:AddOverlay; the highest-priority answer for a slot is drawn
    and the rest are dropped, so the three can never stack.

    Load order: after QuestRewards (money formatting) and ItemStats / Usability
    (identity and verdicts). None of them is required at load time — every call
    into them is guarded, so a missing module costs a sentence, not the command.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local DropHint = {}
LT.DropHint = DropHint
LT.Modules.DropHint = DropHint

DropHint.MAX_LISTED      = 5   -- suggestion lines in /lt drop
DropHint.MAX_ALL         = 25  -- item lines in each block of /lt drop all
DropHint.MAX_IGNORE_ROWS = 12  -- rows the ignore window draws before it stops

-- Bag-marker rules, kept public so the self test and the marker harness read
-- the same numbers the drawing does instead of copying them.
DropHint.MARK_EDGE = 2            -- one border edge, in UI units; four sides
DropHint.DESTROY_AT_FREE_SLOTS = 0  -- destroy hint only when no bag slot is free
DropHint.MIN_GLYPH, DropHint.MAX_GLYPH = 10, 18
DropHint.ARM_SECONDS = 10           -- a second press inside this sells the junk

------------------------------------------------------------------------------
-- Options
--
-- One table owns the defaults (Database.defaultOptions); this file reads the
-- live value and falls back to that table, never to a second copy here.
------------------------------------------------------------------------------

local function option(key)
    local database = LT.Database
    if type(database) ~= "table" then return false end

    if type(database.GetOptions) == "function" then
        local ok, options = pcall(database.GetOptions, database)
        if ok and type(options) == "table" and type(options[key]) == "boolean" then
            return options[key]
        end
    end

    if type(database.defaultOptions) == "function" then
        local ok, defaults = pcall(database.defaultOptions)
        if ok and type(defaults) == "table" then return defaults[key] == true end
    end

    return false
end

-- L-17 (T-137): which frames the bag marks belong on. BagSort owns the switch
-- and Database owns the default; this reads it through that one accessor rather
-- than keeping a second copy of the stored key. A replacement addon draws the
-- bags on frames this file never sees, so the marks are skipped and the player
-- is told once - the same answer for every overlay above.
local replacementNoticed = false

local function handBagsToReplacement()
    local sort = LT.BagSort
    if type(sort) ~= "table" or type(sort.UsesReplacementBags) ~= "function" then
        return false
    end

    local ok, replacement = pcall(sort.UsesReplacementBags, sort)
    return ok and replacement == true
end

------------------------------------------------------------------------------
-- Reading the bags
------------------------------------------------------------------------------

-- C_Container was verified present on this client; the pre-C_Container globals
-- are kept as a fallback because they cost six lines and a missing bag API
-- would cost the whole command.
local function containerAPI()
    local modern = C_Container
    if type(modern) == "table"
        and type(modern.GetContainerNumSlots) == "function"
        and type(modern.GetContainerItemLink) == "function" then
        return {
            slots  = modern.GetContainerNumSlots,
            link   = modern.GetContainerItemLink,
            info   = modern.GetContainerItemInfo,
            modern = true,
        }
    end

    if type(GetContainerNumSlots) == "function" and type(GetContainerItemLink) == "function" then
        return {
            slots  = GetContainerNumSlots,
            link   = GetContainerItemLink,
            info   = GetContainerItemInfo,
            modern = false,
        }
    end

    return nil
end

local function stackCount(api, bag, slot)
    if type(api.info) ~= "function" then return 1 end

    local ok, first, second = pcall(api.info, bag, slot)
    if not ok then return 1 end

    if api.modern then
        -- C_Container returns one table; the old global returns a list whose
        -- second value is the count.
        if type(first) == "table" then
            return tonumber(first.stackCount) or 1
        end
        return 1
    end

    return tonumber(second) or 1
end

local function itemIDFromLink(text)
    return tonumber(tostring(text or ""):match("item:(%d+)"))
end

-- The merchant's price, from QuestRewards alone: it reads the client's own
-- tooltip Sell Price line, which is the number the merchant pays. GetItemInfo's
-- sellPrice return is not used here because on Forever it can still carry the
-- item's Classic-era price. A price the client has not shown is nil, never
-- zero, because zero would make an unknown item look free to destroy.
local function sellPrice(link)
    local rewards = LT.QuestRewards
    if type(rewards) ~= "table" or type(rewards.SellPrice) ~= "function" then
        return nil
    end

    local ok, price = pcall(rewards.SellPrice, link)
    price = ok and LT:Number(price) or nil

    if price and price > 0 then return price end
    return nil
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

-- Quest items are the one thing a full bag never asks about: they are wanted
-- later or they are worth nothing, and a destroyed quest item can cost a whole
-- quest chain.
local function isQuestItem(identity)
    if type(identity) ~= "table" then return false end
    if tonumber(identity.classID) == 12 then return true end
    return identity.itemType == "Quest"
end

-- "You could put this on right now". Only a claim the Usability module makes;
-- when it cannot answer, the item is treated as ordinary, not as gear.
local function wearNow(link)
    local usability = LT.Usability
    if type(usability) ~= "table" or type(usability.GetVerdict) ~= "function" then
        return false
    end

    local ok, result = pcall(usability.GetVerdict, usability, link)
    return ok and type(result) == "table" and result.verdict == usability.USABLE
end

local function nameFromLink(link)
    local identity = identityOf(link)
    if identity and type(identity.name) == "string" and identity.name ~= "" then
        return identity.name
    end

    local bracket = tostring(link or ""):match("%[(.-)%]")
    if bracket and bracket ~= "" then return bracket end
    return nil
end
-- Every occupied slot of the backpack and the four bag slots, as plain rows.
-- The bank is deliberately absent: its contents are not the bag problem this
-- answers, and reading them would mean remembering what is in there.
function DropHint:Scan()
    local api = containerAPI()
    if not api then
        return nil, "the client exposes no container API"
    end

    local rows = {}
    local lastBag = tonumber(NUM_BAG_SLOTS) or 4

    for bag = 0, lastBag do
        local okSlots, slots = pcall(api.slots, bag)
        slots = okSlots and tonumber(slots) or 0

        for slot = 1, slots do
            local okLink, link = pcall(api.link, bag, slot)

            if okLink and type(link) == "string" and link ~= "" then
                local identity = identityOf(link)

                table.insert(rows, {
                    link      = link,
                    name      = (identity and identity.name) or nameFromLink(link),
                    itemID    = (identity and tonumber(identity.itemID)) or itemIDFromLink(link),
                    bag       = bag,
                    slot      = slot,
                    count     = stackCount(api, bag, slot),
                    unitPrice = sellPrice(link),
                    quest     = isQuestItem(identity),
                    wearNow   = wearNow(link),
                })
            end
        end
    end

    return rows
end

------------------------------------------------------------------------------
-- The rule
------------------------------------------------------------------------------

-- What losing this row costs: the whole stack, because the client's destroy
-- dialog takes the stack. Nine flint at 2c costs 18c to lose, not 2c.
function DropHint.StackCost(row)
    if type(row) ~= "table" then return 0 end

    local count = tonumber(row.count) or 1
    if count < 1 then count = 1 end

    return (tonumber(row.unitPrice) or 0) * count
end

-- Pure: rows are plain tables and the ignore list is a plain set of item IDs,
-- so a full bag can be replayed without a bag. Returns
--   priced          every priced row, cheapest stack first
--   ranked          the same list without gear the player could equip now
--   wearable        only that gear, also cheapest first
--   unpriced        no vendor price: losing it costs no gold, but it may matter
--   cheapest        the one thing to suggest, or nil
--   cheapestWearable  the cheapest thing held back for being wearable, or nil
function DropHint.Rank(rows, ignore, limit)
    local result = {
        priced = {}, ranked = {}, wearable = {}, unpriced = {},
        questCount = 0, ignoredCount = 0, pricedCount = 0,
    }

    for _, row in ipairs(rows or {}) do
        if row.quest then
            result.questCount = result.questCount + 1
        elseif ignore and row.itemID and ignore[row.itemID] then
            result.ignoredCount = result.ignoredCount + 1
        elseif not row.unitPrice then
            table.insert(result.unpriced, row)
        else
            result.pricedCount = result.pricedCount + 1
            table.insert(result.priced, row)
        end
    end

    local function cheaperFirst(a, b)
        local costA, costB = DropHint.StackCost(a), DropHint.StackCost(b)
        if costA ~= costB then return costA < costB end

        local unitA, unitB = tonumber(a.unitPrice) or 0, tonumber(b.unitPrice) or 0
        if unitA ~= unitB then return unitA < unitB end

        local nameA, nameB = tostring(a.name), tostring(b.name)
        if nameA ~= nameB then return nameA < nameB end

        return tostring(a.itemID or 0) < tostring(b.itemID or 0)
    end

    table.sort(result.priced, cheaperFirst)

    for _, row in ipairs(result.priced) do
        if row.wearNow then
            table.insert(result.wearable, row)
        else
            table.insert(result.ranked, row)
        end
    end

    result.cheapest = result.ranked[1]
    result.cheapestWearable = result.wearable[1]
    result.limit = tonumber(limit) or DropHint.MAX_LISTED

    return result
end
------------------------------------------------------------------------------
-- The ignore list (account-wide)
------------------------------------------------------------------------------

-- Returns the live table so a caller can add or remove an entry; nil when the
-- Database module is missing, which is reported rather than silently ignored.
local function ignoreList()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetDropIgnore) ~= "function" then
        return nil
    end

    local ok, list = pcall(database.GetDropIgnore, database)
    if ok and type(list) == "table" then return list end
    return nil
end

-- The words after the command, joined back with single spaces: an item link
-- contains "[Linen Cloth]", and the split on whitespace tore that in two.
local function argumentText(words, fromIndex)
    if type(words) ~= "table" or #words < fromIndex then return "" end

    local text = table.concat(words, " ", fromIndex)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

------------------------------------------------------------------------------
-- Printing
------------------------------------------------------------------------------

local function money(copper)
    local rewards = LT.QuestRewards
    if type(rewards) == "table" and type(rewards.moneyText) == "function" then
        local ok, text = pcall(rewards.moneyText, copper)
        if ok and type(text) == "string" then return text end
    end

    -- No QuestRewards: say the number rather than nothing.
    return tostring(tonumber(copper) or 0) .. "c"
end

local function where(row)
    local bag = tonumber(row.bag) or 0
    local label = (bag == 0) and "backpack" or ("bag " .. tostring(bag))
    return label .. " slot " .. tostring(row.slot or "?")
end

-- One line per row: the item itself (a real link, so it hovers), the stack, what
-- losing the stack costs, and where it sits.
local function describe(row)
    local count = tonumber(row.count) or 1
    local parts = { tostring(row.link or row.name or "?") }

    if count > 1 then
        parts[#parts + 1] = " x" .. tostring(count)
    end

    parts[#parts + 1] = " - " .. money(DropHint.StackCost(row)) .. " to lose"

    if count > 1 then
        parts[#parts + 1] = " (" .. money(tonumber(row.unitPrice) or 0) .. " each)"
    end

    parts[#parts + 1] = ", " .. where(row)
    return table.concat(parts)
end

function DropHint:PrintSuggestions(limit)
    local rows, err = self:Scan()
    if err then
        LT:Error("The bags could not be read: " .. tostring(err))
        return
    end

    local result = self.Rank(rows, ignoreList(), limit or self.MAX_LISTED)

    local header = tostring(#rows) .. " items in the bags: " .. tostring(result.pricedCount)
        .. " with a vendor price, " .. tostring(result.questCount) .. " quest item(s) left alone"
    if result.ignoredCount > 0 then
        header = header .. ", " .. tostring(result.ignoredCount) .. " ignored"
    end
    LT:Print(header .. ".")

    if not result.cheapest then
        if result.cheapestWearable then
            LT:Warn("Nothing but gear you could equip carries a price. The cheapest of those is "
                .. describe(result.cheapestWearable) .. " — check it before destroying it.")
        else
            LT:Print("Nothing here has a vendor price. /lt drop all shows what is in the bags.")
        end
        return
    end

    -- L-10: the bag context's one line, on the number the merchant would pay
    -- for the whole stack -- exactly the value destroying throws away.
    LT:Print("Destroy this one (" .. money(DropHint.StackCost(result.cheapest))
        .. "): " .. tostring(result.cheapest.link or result.cheapest.name)
        .. " — the cheapest stack to lose:")

    for index = 1, math.min(#result.ranked, result.limit) do
        print("  " .. tostring(index) .. ". " .. describe(result.ranked[index]))
    end

    local lastShown = result.ranked[math.min(#result.ranked, result.limit)]
    if result.cheapestWearable and lastShown
        and DropHint.StackCost(result.cheapestWearable) < DropHint.StackCost(lastShown) then
        LT:Warn("Cheaper but you could equip it now: " .. describe(result.cheapestWearable)
            .. " — not suggested.")
    end

    if #result.unpriced > 0 then
        LT:Print(tostring(#result.unpriced)
            .. " item(s) have no vendor price — losing those costs no gold, so they are not ranked.")
    end

    LT:Print("Hide one with /lt drop ignore [item], shift-clicking the item into the box.")
end
function DropHint:PrintAll()
    local rows, err = self:Scan()
    if err then
        LT:Error("The bags could not be read: " .. tostring(err))
        return
    end

    local result = self:Rank(rows, ignoreList(), self.MAX_ALL)

    LT:Print(tostring(#rows) .. " items: " .. tostring(result.pricedCount) .. " with a vendor price, "
        .. tostring(result.questCount) .. " quest item(s) left alone, "
        .. tostring(result.ignoredCount) .. " ignored.")

    if #result.priced == 0 then
        LT:Print("Nothing in the bags carries a vendor price.")
    else
        LT:Print("Cheapest stack first:")
        for index = 1, math.min(#result.priced, self.MAX_ALL) do
            local row = result.priced[index]
            local note = row.wearNow and "  (you could equip this now)" or ""
            print("  " .. tostring(index) .. ". " .. describe(row) .. note)
        end

        if #result.priced > self.MAX_ALL then
            LT:Print(tostring(#result.priced - self.MAX_ALL) .. " more not shown.")
        end
    end

    if #result.unpriced > 0 then
        LT:Print("No vendor price (" .. tostring(#result.unpriced) .. "):")
        for index = 1, math.min(#result.unpriced, self.MAX_ALL) do
            local row = result.unpriced[index]
            print("  " .. tostring(index) .. ". " .. tostring(row.link or row.name or "?")
                .. " x" .. tostring(tonumber(row.count) or 1) .. ", " .. where(row))
        end
    end
end

function DropHint:PrintIgnoreList()
    local list = ignoreList()
    if not list then
        LT:Error("The saved ignore list is unavailable.")
        return
    end

    local entries = {}
    for itemID, name in pairs(list) do
        table.insert(entries, { id = tonumber(itemID) or 0, itemID = itemID, name = name })
    end
    table.sort(entries, function(a, b) return a.id < b.id end)

    if #entries == 0 then
        LT:Print("Nothing is ignored. /lt drop ignore [item] hides an item for every character.")
        return
    end

    LT:Print(tostring(#entries) .. " ignored item(s), shared by every character on this account:")
    for _, entry in ipairs(entries) do
        local name = (type(entry.name) == "string" and entry.name ~= "")
            and entry.name or "(name not recorded)"
        print("  " .. tostring(entry.itemID) .. " — " .. name)
    end

    LT:Print("/lt drop forget <id> puts one back.")
end

function DropHint:AddIgnore(words)
    local text = argumentText(words, 3)
    if text == "" then
        LT:Print("Shift-click the item into the box: /lt drop ignore [item].")
        return
    end

    local itemID = itemIDFromLink(text)
    local name = nil

    if itemID then
        name = nameFromLink(text)
    else
        -- A typed name is matched against the bags, because that is where the
        -- player is looking; an item that is not in the bags cannot be named.
        local needle = string.lower(text)
        local foundID, ambiguous = nil, false

        for _, row in ipairs(self:Scan() or {}) do
            local rowName = string.lower(tostring(row.name or ""))

            if rowName == needle or rowName:find(needle, 1, true) then
                if foundID and foundID ~= row.itemID then ambiguous = true end
                foundID = foundID or row.itemID
                name = name or row.name
            end
        end

        if ambiguous then
            LT:Print("\"" .. text .. "\" matches more than one item. Shift-click the exact one into the box.")
            return
        end

        itemID = foundID
    end

    if not itemID then
        LT:Print("No item called \"" .. text .. "\" is in the bags. Shift-click it into the box instead.")
        return
    end

    local list = ignoreList()
    if not list then
        LT:Error("The saved ignore list is unavailable.")
        return
    end

    list[itemID] = name or true

    LT:Print("Ignored " .. tostring(name or itemID) .. " (" .. tostring(itemID)
        .. ") for every character. /lt drop forget " .. tostring(itemID) .. " undoes it.")
end

function DropHint:RemoveIgnore(words)
    local text = argumentText(words, 3)
    if text == "" then
        LT:Print("Use /lt drop forget <item id>, or shift-click the item: /lt drop forget [item].")
        return
    end

    local list = ignoreList()
    if not list then
        LT:Error("The saved ignore list is unavailable.")
        return
    end

    local itemID = itemIDFromLink(text) or tonumber(text)

    if not itemID then
        local needle = string.lower(text)
        for id, name in pairs(list) do
            if type(name) == "string" and string.lower(name):find(needle, 1, true) then
                itemID = id
                break
            end
        end
    end

    if not itemID or list[itemID] == nil then
        LT:Print(tostring(text) .. " is not on the ignore list. /lt drop list shows it.")
        return
    end

    local name = list[itemID]
    list[itemID] = nil

    LT:Print("No longer ignoring " .. tostring(name ~= true and name or itemID)
        .. " (" .. tostring(itemID) .. ").")
end

------------------------------------------------------------------------------
-- The bags themselves: the marker and the one header button
------------------------------------------------------------------------------

-- Chrome and verdict colours come from the one palette; a missing Palette costs
-- colour, never the drawing itself.
local Palette = LT.Palette

-- The glyph drawn in the corner of the item this add-on suggests destroying. It
-- is the client's own crossed-out "pass" mark from the group loot window -- a
-- small X, never a coin: a coin belongs only to the vendor marker. The thin
-- border around it is chrome, the add-on's own colour, because which item is
-- cheapest is a fact about the bags and not a judgement passed on the item.
local MARK_GLYPH = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
local MARK_EDGE = DropHint.MARK_EDGE
local GLYPH_MIN, GLYPH_MAX = DropHint.MIN_GLYPH, DropHint.MAX_GLYPH

-- Set whenever the answer may have changed (a bag event, an item price arriving
-- late, the ignore list being edited) and cleared by the next marker refresh.
local needsRefresh = true

-- Font strings and buttons built the way Legend builds its own: the client's
-- templates where they exist, a flat panel where they do not.
local function plainLabel(parent, text, font, colour)
    local ok, created = pcall(parent.CreateFontString, parent, nil, "OVERLAY", font)

    if ok and created then
        created:SetText(tostring(text))
        if colour then created:SetTextColor(colour[1], colour[2], colour[3]) end
        return created
    end

    return nil
end

local function plainButton(parent, text, width, height, onClick)
    local ok, created = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")

    if ok and created and created.SetText then
        created:SetSize(width, height)
        created:SetText(tostring(text))
        created:SetScript("OnClick", onClick)
        return created
    end

    local flat = CreateFrame("Button", nil, parent)
    flat:SetSize(width, height)

    local idle = Palette and Palette.chrome.buttonBg or nil
    local hot = Palette and Palette.chrome.buttonHot or nil

    local background = flat:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(true)
    if idle then background:SetColorTexture(idle[1], idle[2], idle[3], idle[4]) end

    local caption = flat:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caption:SetPoint("CENTER")
    caption:SetText(tostring(text))
    flat.label = caption

    flat:SetScript("OnClick", onClick)

    if idle and hot then
        flat:SetScript("OnEnter", function()
            background:SetColorTexture(hot[1], hot[2], hot[3], hot[4])
        end)
        flat:SetScript("OnLeave", function()
            background:SetColorTexture(idle[1], idle[2], idle[3], idle[4])
        end)
    end

    return flat
end

-- Mapping used here, and why it is not the old bag+1/slot guess.
--
-- On this client (Interface 16001, WoW: Forever) each bag window frame answers
-- GetID() with the container index it draws: ContainerFrame1 is container 0,
-- the backpack. Inside a frame the item button for a slot answers GetID() with
-- that slot, which is the same pair the client's own bag click reads (the
-- parent's container id and the button's slot id). A button's global name is
-- only a lookup key: the number in "ContainerFrameNItemM" is the window's
-- position in the client's frame list, not necessarily bag + 1 after a client
-- adds or reorders bag frames (the E8 wrong-slot report). So the frame is
-- resolved by its own GetID(), never by the container number assumed from its
-- name, and the slot is confirmed from the button's GetID() when the client
-- exposes it. Only when neither id can be read does the name remain the
-- fallback, and then a marker still has to pass the draw-time link check below.
local function numericID(frame)
    if type(frame) ~= "table" or type(frame.GetID) ~= "function" then return nil end

    local ok, id = pcall(frame.GetID, frame)
    return ok and tonumber(id) or nil
end

-- A real item button exposes GetIconAnchor, which is where a marker or an icon
-- belongs. It is not required -- a client that omits it still gets markers --
-- but it is the preferred candidate when two frames both name the same slot.
local function hasIconAnchor(value)
    return type(value) == "table" and type(value.GetIconAnchor) == "function"
end

-- Every frame has CreateTexture, so that test alone accepted container frames,
-- scroll boxes and plain children (C-18). An item button is identified by its
-- object type and must answer a numeric slot id, plus a numeric bag id where
-- the client exposes GetBagID.
local function isItemButton(value)
    if type(value) ~= "table" then return false end

    if type(value.GetObjectType) ~= "function" then return false end

    local ok, otype = pcall(value.GetObjectType, value)
    if not ok or (otype ~= "Frame" and otype ~= "Button") then return false end

    if numericID(value) == nil then return false end

    if type(value.GetBagID) == "function" then
        local ok, bag = pcall(value.GetBagID, value)
        if not ok or tonumber(bag) == nil then return false end
    end

    return true
end

-- Children of a frame, walked the way the client exposes them. Retail/Forever
-- answer through GetNumChildren/GetChild; classic through GetChildren. A client
-- that implements only one still resolves its buttons.
local function childrenOf(parent)
    if type(parent) ~= "table" then return nil end

    if type(parent.GetNumChildren) == "function" and type(parent.GetChild) == "function" then
        local ok, count = pcall(parent.GetNumChildren, parent)
        if ok and type(count) == "number" then
            local list = {}
            for i = 1, count do
                local okChild, child = pcall(parent.GetChild, parent, i)
                if okChild and type(child) == "table" then
                    list[#list + 1] = child
                end
            end
            return list
        end
    end

    if type(parent.GetChildren) == "function" then
        local ok, children = pcall(parent.GetChildren, parent)
        if ok and type(children) == "table" then return children end
    end

    return nil
end

-- The bag window that draws this container. The frame's GetID() is the answer;
-- the historical ContainerFrame(bag+1) is used only when no frame names the bag
-- and it does not name a different one.
local function containerFrameFor(bag)
    bag = tonumber(bag)
    if not bag then return nil end

    local lastIndex = tonumber(NUM_CONTAINER_FRAMES)
    if not lastIndex or lastIndex < 1 then
        lastIndex = (tonumber(NUM_BAG_SLOTS) or 4) + 1
    end

    for index = 1, lastIndex do
        local frame = _G["ContainerFrame" .. tostring(index)]

        if type(frame) == "table" and numericID(frame) == bag then
            return frame
        end
    end

    local fallback = _G["ContainerFrame" .. tostring(bag + 1)]
    if type(fallback) ~= "table" then return nil end

    local frameID = numericID(fallback)
    if frameID ~= nil and frameID ~= bag then return nil end

    return fallback
end

local function buttonBySlot(parent, slot, depth)
    if depth > 8 or type(parent) ~= "table" then return nil end

    local children = childrenOf(parent)
    if not children then return nil end

    local fallback = nil
    for _, child in ipairs(children) do
        if isItemButton(child) and numericID(child) == slot then
            if hasIconAnchor(child) then return child end
            fallback = fallback or child
        end
    end
    if fallback then return fallback end

    for _, child in ipairs(children) do
        local found = buttonBySlot(child, slot, depth + 1)
        if found then return found end
    end

    return nil
end

-- Walks a combined-bags frame for the button that shows (bag, slot). A button
-- answers its bag through GetBagID and its slot through GetID; a client without
-- GetBagID falls back to the parent's GetID for the bag. Returns nil when the
-- frame has no such button.
local function buttonByBagSlot(root, bag, slot)
    if type(root) ~= "table" then return nil end

    local stack = { root }
    local seen = {}

    while #stack > 0 do
        local node = table.remove(stack)
        if type(node) == "table" and not seen[node] then
            seen[node] = true

            if isItemButton(node) then
                local buttonBag = nil
                if node.GetBagID then
                    local ok, id = pcall(node.GetBagID, node)
                    buttonBag = ok and tonumber(id) or nil
                end
                if buttonBag == nil and type(node.GetParent) == "function" then
                    local ok, parent = pcall(node.GetParent, node)
                    if ok then buttonBag = numericID(parent) end
                end

                local buttonSlot = numericID(node)

                if buttonBag == bag and buttonSlot == slot then
                    return node
                end
            end

            local children = childrenOf(node)
            if children then
                for i = #children, 1, -1 do
                    stack[#stack + 1] = children[i]
                end
            end
        end
    end

    return nil
end

-- Combined-bags buttons, collected through the frame's own
-- EnumerateValidItems iterator (WoWForeverSuite Items.lua). The ScrollBox is
-- virtualised: only the buttons materialised right now are returned, and they
-- are rebuilt as the player scrolls, so the map is refreshed on every draw and
-- never cached across bag events. Bags yield (index, button); the bank yields
-- (button, marker). Each button answers its bag via GetBagID and its slot via
-- GetID, so the map is keyed (bag, slot).
local combinedButtonMap = {}
local diagButtonsOnce = false
local diagUpgradesOnce = false
local diagParentOnce = false

-- Depth-first collection of every item button under a frame, keyed by
-- (bag, slot). The bag is answered by GetBagID when the button has it, and by
-- the parent frame's GetID otherwise (the classic per-bag frames). This is the
-- classic path; the combined ScrollBox uses EnumerateValidItems instead.
local function collectAllButtons(root, map, seen)
    if type(root) ~= "table" then return 0 end
    seen = seen or {}
    if seen[root] then return 0 end
    seen[root] = true

    local count = 0

    if isItemButton(root) then
        local bag = nil
        if type(root.GetBagID) == "function" then
            local okBag, id = pcall(root.GetBagID, root)
            bag = okBag and tonumber(id) or nil
        end
        if bag == nil and type(root.GetParent) == "function" then
            local okParent, parent = pcall(root.GetParent, root)
            if okParent then bag = numericID(parent) end
        end
        local slot = numericID(root)

        if bag ~= nil and slot ~= nil then
            map[bag] = map[bag] or {}
            map[bag][slot] = root
            count = count + 1

            if not root.__ltBagHook and type(root.HookScript) == "function" then
                root.__ltBagHook = true
                pcall(root.HookScript, root, "OnShow", function() needsRefresh = true end)
            end
        end
    end

    local children = childrenOf(root)
    if children then
        for _, child in ipairs(children) do
            count = count + collectAllButtons(child, map, seen)
        end
    end

    return count
end

local function collectCombinedButtons()
    combinedButtonMap = {}
    local total = 0

    local function collectEnumerated(frame)
        if type(frame) ~= "table" or type(frame.EnumerateValidItems) ~= "function" then return 0 end
        local count = 0
        local ok = pcall(function()
            for first, second in frame:EnumerateValidItems() do
                local button = type(first) == "number" and second or first
                if type(button) == "table" and type(button.GetBagID) == "function"
                    and type(button.GetID) == "function" then
                    local okBag, bag = pcall(button.GetBagID, button)
                    local okSlot, slot = pcall(button.GetID, button)
                    bag, slot = okBag and tonumber(bag) or nil, okSlot and tonumber(slot) or nil

                    if bag ~= nil and slot ~= nil then
                        combinedButtonMap[bag] = combinedButtonMap[bag] or {}
                        combinedButtonMap[bag][slot] = button
                        count = count + 1

                        if not button.__ltBagHook and type(button.HookScript) == "function" then
                            button.__ltBagHook = true
                            pcall(button.HookScript, button, "OnShow", function() needsRefresh = true end)
                        end
                    end
                end
            end
        end)
        if not ok then return 0 end
        return count
    end

    -- Combined bags (Forever) + per-bag frames (classic): both answer
    -- through EnumerateValidItems on the virtualised ScrollBox. This mirrors the
    -- working addon's VisitContainer, which iterates every container frame the
    -- same way rather than walking children.
    total = total + collectEnumerated(_G.ContainerFrameCombinedBags)

    local cc = _G.ContainerFrameContainer
    if type(cc) == "table" and type(cc.ContainerFrames) == "table" then
        for _, f in ipairs(cc.ContainerFrames) do
            if type(f) == "table" and type(f.EnumerateValidItems) == "function" then
                total = total + collectEnumerated(f)
            else
                total = total + collectAllButtons(f, combinedButtonMap)
            end
        end
    end

    if not diagButtonsOnce and type(LT.Diag) == "function" then
        diagButtonsOnce = true
        pcall(LT.Diag, LT, "[Bag] buttons=" .. tostring(total)
            .. " combined=" .. tostring(type(_G.ContainerFrameCombinedBags) == "table")
            .. " containerFrames=" .. tostring(type(cc) == "table" and type(cc.ContainerFrames) == "table" and #cc.ContainerFrames or "nil"))
    end
end

-- The FrameXML item button for a bag and slot, or nil. The container frame is
-- resolved from its own id; the button is accepted only when its own id is the
-- slot asked for (or when this client exposes no id, in which case its name is
-- the only evidence and the draw still verifies the slot's link).
local function itemButton(bag, slot)
    bag, slot = tonumber(bag), tonumber(slot)
    if not bag or not slot then return nil end

    -- Combined bags (Forever): one virtualised frame. Its own
    -- EnumerateValidItems walk (collected once per draw) is authoritative; the
    -- child-walker below is only a fallback for a client with no iterator.
    local fromMap = combinedButtonMap[bag] and combinedButtonMap[bag][slot]
    if type(fromMap) == "table" then return fromMap end

    local combined = _G.ContainerFrameCombinedBags
    if type(combined) == "table" and type(combined.EnumerateValidItems) ~= "function" then
        local found = buttonByBagSlot(combined, bag, slot)
        if found then return found end
    end

    local frame = containerFrameFor(bag)
    local frameName = nil

    if type(frame) == "table" and type(frame.GetName) == "function" then
        local okName, name = pcall(frame.GetName, frame)
        if okName and type(name) == "string" and name ~= "" then frameName = name end
    end

    local candidate = frameName and _G[frameName .. "Item" .. tostring(slot)] or nil

    -- The name encodes the slot ("ContainerFrame1Item1" -> bag 0 slot 1).
    -- GetID is unreliable on some clients (it returns the combined slot index,
    -- not the per-bag slot), so trust the name rather than re-checking the id.
    -- A frame that exposes GetIconAnchor is preferred over one that does not.
    local candidateOK = isItemButton(candidate)
    if candidateOK and hasIconAnchor(candidate) then return candidate end

    if frame then
        local found = buttonBySlot(frame, slot, 0)
        if isItemButton(found) then
            if hasIconAnchor(found) or not candidateOK then return found end
            return candidate
        end
    end

    if candidateOK then return candidate end

    -- Last resort, only when no container frame could be resolved at all: the
    -- historical name, still refused when its own frame or slot id names a
    -- different container or slot.
    if frame == nil then
        local legacy = _G["ContainerFrame" .. tostring(bag + 1) .. "Item" .. tostring(slot)]

        if isItemButton(legacy) then
            local legacySlot = numericID(legacy)
            local legacyFrame = nil

            if type(legacy.GetParent) == "function" then
                local okParent, parent = pcall(legacy.GetParent, legacy)
                if okParent then legacyFrame = numericID(parent) end
            end

            if (legacySlot == nil or legacySlot == slot)
                and (legacyFrame == nil or legacyFrame == bag) then
                return legacy
            end
        end
    end
    return nil
end

-- Whether any bag frame is on screen. Everything below is parented to those
-- frames, so this is asked before any work, never to decide what to draw.
local function bagsShown()
    -- Combined bags (Forever): one frame holds every bag.
    local combined = _G.ContainerFrameCombinedBags
    if type(combined) == "table" and type(combined.IsShown) == "function"
        and combined:IsShown() then
        return true
    end

    local lastBag = tonumber(NUM_BAG_SLOTS) or 4

    for bag = 0, lastBag do
        local frame = containerFrameFor(bag)

        if type(frame) == "table" and type(frame.IsShown) == "function"
            and frame:IsShown() then
            return true
        end
    end

    return false
end

-- Combat is read through one guarded call, the same way the tooltip reads it. A
-- client without the API is "not in combat", which leaves this file behaving as
-- it did before the rule. Nothing here builds a frame or attaches a tooltip
-- during a fight; the poll below carries that work over to the first tick after
-- the fight ends, because a click refused mid-fight cannot be given back and a
-- frame built there can be tainted for the rest of the session.
local function inCombatNow()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

------------------------------------------------------------------------------
-- Overlays: one marker per bag button, chosen by priority
--
-- A bag button can be interesting for more than one reason at once: it is the
-- cheapest thing to lose, it is an upgrade the character can wear now, or the
-- vendor plugin named it. They share one corner, so they must share one marker.
-- Every provider is asked about every slot; the highest-priority non-nil answer
-- is drawn and the others are dropped. Priority decides, never registration or
-- draw order; equal priorities keep the provider registered first, which keeps
-- a redraw stable.
--
-- A result is { colour, glyph, glyphColour }:
--   colour       border tint, { r, g, b, a }
--   glyph        texture path for the corner glyph
--   glyphColour  optional tint for that glyph, { r, g, b, a }
-- A provider returns nil for "not me". Providers are pcall'd, so a broken one
-- costs its own marker, never the rest of the draw.
------------------------------------------------------------------------------

local PRIORITY_UPGRADE = 30   -- "wear it now", the strongest claim
local PRIORITY_TRIAGE  = 20   -- the cheapest thing to destroy, as before
local PRIORITY_VENDOR  = 10   -- the vendor helper's cheapest-to-lose

local UPGRADE_COLOUR       = { 0.25, 0.90, 0.35, 1 }
local UPGRADE_GLYPH        = "Interface\\BUTTONS\\Arrow-Up-Up"
local UPGRADE_GLYPH_COLOUR = { 0.25, 0.90, 0.35, 1 }
-- GearQuest's arrow: the texture is cropped to the arrow shape and drawn taller
-- than it is wide (16:21). Its TexCoord + aspect are carried on the result.
local UPGRADE_TEXCOORD     = { 0.08, 0.92, 0.02, 0.72 }
local UPGRADE_ASPECT       = 21 / 16

local VENDOR_COLOUR       = { 1.00, 0.82, 0.10, 1 }
local VENDOR_GLYPH        = "Interface\\Icons\\INV_Misc_Coin_01"
local VENDOR_GLYPH_COLOUR = { 1.00, 0.82, 0.10, 1 }

local overlays = {}
local overlaySeq = 0

-- What the triage and vendor providers answer from. Plain data, checked against
-- the container whenever it is stored, drawn or swept: the vendor row is kept
-- only while its own bag and slot still hold its link.
-- triageAllowed is the free-slot rule, decided once per draw.
local triageBag, triageSlot, triageLink
local triageAllowed = false
local vendorRow

-- The junk-sale arming state. The first press marks every junk row (the
-- overlay provider below draws the border), the second within ARM_SECONDS sells
-- exactly those rows; a timeout, a merchant close, a bag close or combat
-- disarms. The set is keyed bag -> slot -> link, and is re-checked at sell time
-- like every other row in this file.
local junkArmedSet
local junkArmedList
local bagArmed = false
local bagArmedAt = 0

-- The free-slot count the last draw saw. The tick compares against it, because
-- a stack leaving or joining the bags changes what may be marked even when the
-- client fires no bag event this file listens to.
local freeSlotsSeen = nil

-- GearCheck's "now" links, filled once per bag opening. A "soon" row is
-- deliberately absent: an item the character cannot wear yet is not an upgrade.
local upgradeScanned = false
local upgradeSet

local refreshing = false
local vendorHooked = false

-- One shared secret-value guard. A restricted link is never compared, keyed or
-- drawn; that slot simply gets no overlay from this file.
local function secretValue(value)
    if type(LT.IsSecret) ~= "function" then return false end
    local ok, result = pcall(LT.IsSecret, LT, value)
    return ok and result == true
end

-- The link a container slot holds right now, or nil when it is empty, the
-- client will not answer, or the value is restricted. This is the only reading
-- a marker is allowed to draw from: a row made a moment ago is evidence about
-- what was there, never proof of what is there at draw time.
local function currentLink(bag, slot)
    local api = containerAPI()
    if not api then return nil end

    bag, slot = tonumber(bag), tonumber(slot)
    if not bag or not slot then return nil end

    local ok, link = pcall(api.link, bag, slot)
    if not ok or type(link) ~= "string" or link == "" or secretValue(link) then
        return nil
    end

    return link
end

-- Pure enough to be reasoned about without the client: the row names a bag,
-- a slot and a link, and the caller passes the link read from that slot at draw
-- time. A nil link, a restricted one, or any difference is "wrong slot".
local function rowMatchesSlot(row, link, bag, slot)
    if type(row) ~= "table" then return false end

    local rowBag, rowSlot = tonumber(row.bag), tonumber(row.slot)
    if rowBag == nil or rowSlot == nil then return false end
    if bag ~= nil and rowBag ~= tonumber(bag) then return false end
    if slot ~= nil and rowSlot ~= tonumber(slot) then return false end

    local rowLink = row.link
    if type(rowLink) ~= "string" or rowLink == "" or secretValue(rowLink) then
        return false
    end

    return type(link) == "string" and link ~= "" and not secretValue(link)
        and link == rowLink
end

-- Is this remembered row still standing in its own slot? Used before the vendor
-- row is stored and again while the bags are open, so a row that named a sold
-- or emptied slot cannot be drawn back onto it.
local function rowStillInBags(row)
    if type(row) ~= "table" then return false end

    local bag, slot = tonumber(row.bag), tonumber(row.slot)
    if not bag or not slot then return false end

    return rowMatchesSlot(row, currentLink(bag, slot), bag, slot)
end

local function buttonIdentity(button)
    if type(button) ~= "table" then return nil, nil end

    local slot = numericID(button)
    local bag = nil

    -- Combined-bags buttons answer the bag directly (GetBagID); classic frames
    -- answer through the parent container's GetID.
    if type(button.GetBagID) == "function" then
        local ok, id = pcall(button.GetBagID, button)
        bag = ok and tonumber(id) or nil
    end

    if bag == nil and type(button.GetParent) == "function" then
        local ok, parent = pcall(button.GetParent, button)
        if ok and type(parent) == "table" then bag = numericID(parent) end
    end

    return bag, slot
end

local function brandColour()
    if type(Palette) ~= "table" or type(Palette.Colour) ~= "function" then return nil end
    local ok, colour = pcall(Palette.Colour, Palette, "brand")
    if ok and type(colour) == "table" then return colour end
    return nil
end

------------------------------------------------------------------------------
-- Free bag slots: what decides whether the destroy hint is allowed at all
------------------------------------------------------------------------------

-- Pure. The destroy hint answers "the bags are full": with even one free slot
-- there is somewhere to put the next thing, so nothing needs losing.
-- DESTROY_AT_FREE_SLOTS is therefore 0, and the test is "no slot left at all",
-- never "one slot left" -- the off-by-one that put a border and an X on the
-- bags while one slot was still empty (player report E8).
-- nil (the client would not say) is not a full bag, so the hint is withheld.
function DropHint.ShouldOfferDestroy(freeSlots)
    local free = tonumber(freeSlots)
    if free == nil then return false end
    return free <= DropHint.DESTROY_AT_FREE_SLOTS
end

-- Free slots of the backpack and the equipped bags, or nil when no route can
-- count them. Every client call is guarded; a secret number is refused before
-- any arithmetic, exactly like a secret link.
function DropHint.FreeBagSlots()
    local api = containerAPI()
    local lastBag = tonumber(NUM_BAG_SLOTS) or 4

    local counter = nil
    if type(C_Container) == "table"
        and type(C_Container.GetContainerNumFreeSlots) == "function" then
        counter = C_Container.GetContainerNumFreeSlots
    elseif type(GetContainerNumFreeSlots) == "function" then
        counter = GetContainerNumFreeSlots
    end

    local total, answered = 0, false

    for bag = 0, lastBag do
        local free

        if counter then
            local ok, value = pcall(counter, bag)
            if ok and not secretValue(value) then free = tonumber(value) end
        end

        -- No free-slot API, or it refused this bag: count the empty slots the
        -- same walk the scan uses. Slots minus occupied is the same number.
        if free == nil and api then
            local okSlots, slots = pcall(api.slots, bag)
            slots = okSlots and tonumber(slots) or nil

            if slots then
                local occupied = 0

                for slot = 1, slots do
                    local okLink, link = pcall(api.link, bag, slot)
                    if okLink and type(link) == "string" and link ~= "" then
                        occupied = occupied + 1
                    end
                end

                free = math.max(0, slots - occupied)
            end
        end

        if free ~= nil then
            total = total + free
            answered = true
        end
    end

    if not answered then return nil end
    return total
end

-- Public: another module contributes a marker without learning how the bags are
-- read. fn(link, bag, slot) returns a result table or nil. Registering the same
-- id again replaces its priority and function and keeps its tie-break place.
function DropHint:AddOverlay(id, priority, fn)
    if type(id) ~= "string" or id == "" then return false end
    if type(priority) ~= "number" or priority ~= priority then return false end
    if type(fn) ~= "function" then return false end

    for _, entry in ipairs(overlays) do
        if entry.id == id then
            entry.priority = priority
            entry.fn = fn
            needsRefresh = true
            return true
        end
    end

    overlaySeq = overlaySeq + 1
    overlays[#overlays + 1] = {
        id = id, priority = priority, fn = fn, order = overlaySeq,
    }

    needsRefresh = true

    -- A provider added while the bags are already open must not wait for the
    -- next bag event to appear. During file load RefreshMarkers does not exist
    -- yet, hence the type check.
    if bagsShown() and not inCombatNow()
        and type(DropHint.RefreshMarkers) == "function" then
        pcall(DropHint.RefreshMarkers, DropHint)
    end

    return true
end

-- The one place priority is decided. The row is re-read from the container at
-- draw time first: an empty slot, a slot that now holds something else, or a
-- restricted link returns nil before any provider is asked, so no marker can be
-- chosen for a slot whose item this draw cannot prove. Ties go to the provider
-- registered first.
local function resolveOverlay(row)
    if type(row) ~= "table" then return nil end

    local bag, slot = tonumber(row.bag), tonumber(row.slot)
    local link = row.link

    if not bag or not slot then return nil end
    if type(link) ~= "string" or link == "" or secretValue(link) then return nil end

    local now = currentLink(bag, slot)
    if now == nil or now ~= link then return nil end

    local best, bestPriority, bestOrder

    for _, entry in ipairs(overlays) do
        local ok, result = pcall(entry.fn, now, bag, slot)

        if ok and type(result) == "table" then
            if best == nil or entry.priority > bestPriority
                or (entry.priority == bestPriority and entry.order < bestOrder) then
                best, bestPriority, bestOrder = result, entry.priority, entry.order
            end
        end
    end

    return best, now
end

-- One scan per bag opening, never in combat: the caller has already refused the
-- fight. A failed scan leaves the set empty -- no arrow is better than a wrong
-- one -- and the next opening tries again.
local function ensureUpgradeScan()
    if upgradeScanned then return end

    upgradeScanned = true
    upgradeSet = {}

    local gear = LT.GearCheck
    if type(gear) ~= "table" or type(gear.Scan) ~= "function" then return end

    local ok, result = pcall(gear.Scan, gear)
    if not ok or type(result) ~= "table" or result.reason then return end

    -- `now` is already sorted best-first, so the first row that names a worn
    -- slot is that slot's best swap. Marking only it keeps two gloves in the
    -- bags from each wearing the arrow: the arrow is the answer "wear this one".
    local seenSlot = {}
    for _, row in ipairs(result.now or {}) do
        local link = type(row) == "table" and row.link or nil

        if type(link) == "string" and link ~= "" and not secretValue(link) then
            local slot = type(row) == "table" and tonumber(row.slot) or nil
            if slot == nil then
                upgradeSet[link] = true
            elseif not seenSlot[slot] then
                seenSlot[slot] = true
                upgradeSet[link] = true
            end
        end
    end

    if not diagUpgradesOnce and type(LT.Diag) == "function" then
        diagUpgradesOnce = true
        local count = 0
        for _ in pairs(upgradeSet) do count = count + 1 end
        pcall(LT.Diag, LT, "[Bag] upgrades=" .. tostring(count)
            .. " now=" .. tostring(#(result.now or {})))
    end
end

local function invalidateUpgradeScan()
    upgradeScanned = false
    upgradeSet = nil
end

-- A build switch changes which item is the upgrade, so the next bag opening
-- must rescan rather than trust an arrow gathered for the previous spec.
function DropHint:InvalidateUpgrades()
    invalidateUpgradeScan()
    needsRefresh = true

    if not inCombatNow() and bagsShown()
        and type(DropHint.RefreshMarkers) == "function" then
        pcall(DropHint.RefreshMarkers, DropHint)
    end
end

-- The vendor painter, called by the plugin after every refresh. The row is
-- remembered only after the bags confirm it: the same bag and slot must hold
-- the same link at that moment. A row that fails (the item was sold, moved, or
-- the plugin handed over a stale answer) is stored as nil, so a sale failure
-- cannot put the gold marker back on a slot the client has already emptied.
-- nil means "no marker" and is obeyed immediately when the bags are open.
local function noteVendorRow(row)
    if type(row) == "table" and rowStillInBags(row) then
        vendorRow = row
    else
        vendorRow = nil
    end

    needsRefresh = true

    if not bagsShown() or inCombatNow() or refreshing then return end
    if type(DropHint.RefreshMarkers) ~= "function" then return end

    pcall(DropHint.RefreshMarkers, DropHint)
end

-- Registered once, and retried on every draw so a plugin loaded after this file
-- is still picked up. SetMarkerPainter refreshes the plugin immediately, which
-- is why this is never called in combat.
local function ensureVendorHook()
    if vendorHooked then return true end

    local vendor = LT.Vendor
    if type(vendor) ~= "table" or type(vendor.SetMarkerPainter) ~= "function" then
        return false
    end

    if inCombatNow() then return false end

    local ok, accepted = pcall(vendor.SetMarkerPainter, vendor, noteVendorRow)
    if not ok or accepted == false then return false end

    vendorHooked = true
    return true
end

-- The three providers. Registration order deliberately does NOT match priority:
-- a draw that used order instead of priority would put triage on top.
DropHint:AddOverlay("upgrade", PRIORITY_UPGRADE, function(link, bag, slot)
    if not upgradeSet then return nil end
    if type(link) ~= "string" or link == "" or secretValue(link) then return nil end

    if upgradeSet[link] then
        return {
            colour        = UPGRADE_COLOUR,
            glyph         = UPGRADE_GLYPH,
            glyphColour   = UPGRADE_GLYPH_COLOUR,
            glyphTexCoord = UPGRADE_TEXCOORD,
            glyphAspect   = UPGRADE_ASPECT,
            edge          = 4,     -- a thicker border than the triage/vendor marks
            glyphScale    = 1.6,   -- a larger arrow
        }
    end

    return nil
end)

DropHint:AddOverlay("vendor", PRIORITY_VENDOR, function(link, bag, slot)
    local row = vendorRow
    if type(row) ~= "table" then return nil end

    -- The plugin already drops quest, soulbound and upgrade rows from its own
    -- ranking; this is the second check, so a row that reaches the painter by
    -- another route still cannot put a coin on a quest item or a soulbound one.
    if row.quest == true or row.bound == true or row.upgrade == true then
        return nil
    end

    -- The remembered row is re-read at draw time, exactly like the triage row:
    -- its bag and slot must still hold its link. A link without a slot is not
    -- evidence this file can check, so it is refused rather than marked blind.
    if not rowStillInBags(row) then return nil end
    if row.bag ~= bag or row.slot ~= slot then return nil end
    if link ~= row.link then return nil end

    return {
        colour      = VENDOR_COLOUR,
        glyph       = VENDOR_GLYPH,
        glyphColour = VENDOR_GLYPH_COLOUR,
    }
end)

DropHint:AddOverlay("triage", PRIORITY_TRIAGE, function(link, bag, slot)
    if not triageAllowed then return nil end
    if triageBag == nil or triageSlot == nil then return nil end
    if triageBag ~= bag or triageSlot ~= slot then return nil end
    if triageLink == nil or link ~= triageLink then return nil end

    -- The X glyph, never the vendor coin: gold and a coin belong only to the
    -- merchant marker.
    return { colour = brandColour(), glyph = MARK_GLYPH }
end)

-- The armed junk sale: every junk row the second press will sell wears a coin
-- so the player can see exactly what is about to leave the bags. It wins over
-- the upgrade and triage markers while armed, because it answers the press that
-- is waiting, and it disappears with the arming state.
local PRIORITY_JUNKARM = 40

DropHint:AddOverlay("junkarm", PRIORITY_JUNKARM, function(link, bag, slot)
    local armed = junkArmedSet
    if not armed then return nil end

    local slots = armed[bag]
    if not slots or slots[slot] ~= link then return nil end

    return {
        colour      = VENDOR_COLOUR,
        glyph       = VENDOR_GLYPH,
        glyphColour = VENDOR_GLYPH_COLOUR,
        edge        = 3,
    }
end)

-- Every marker this file has drawn, so the previous one can be taken down when
-- the suggestion moves to another item or the bags settle.
local marked = {}

local function markerFor(button)
    if button.__ltDropMarker then return button.__ltDropMarker end

    local ok, overlay = pcall(CreateFrame, "Frame", nil, button)
    if not ok or type(overlay) ~= "table" then return nil end

    -- The button is the whole slot, icon included, so the marker hugs it.
    overlay:SetAllPoints(button)

    if button.GetFrameLevel and overlay.SetFrameLevel then
        local okLevel, level = pcall(button.GetFrameLevel, button)
        if okLevel and type(level) == "number" then
            -- Above the slot's own highlight and cooldown swirl.
            pcall(overlay.SetFrameLevel, overlay, level + 6)
        end
    end

    -- Four separate edges, each anchored to the side it draws. Anchoring both
    -- horizontal edges to TOPLEFT (the old drawing) put the "bottom" line near
    -- the top and left the border open, which is the two-sided, thick artefact
    -- the player saw. Every edge is exactly MARK_EDGE thick and sits on the
    -- marker's own edge, so the four meet at the corners.
    overlay.__edges = {}

    local sides = {
        { name = "top", from = "TOPLEFT", to = "TOPRIGHT", height = true },
        { name = "bottom", from = "BOTTOMLEFT", to = "BOTTOMRIGHT", height = true },
        { name = "left", from = "TOPLEFT", to = "BOTTOMLEFT", width = true },
        { name = "right", from = "TOPRIGHT", to = "BOTTOMRIGHT", width = true },
    }

    for _, side in ipairs(sides) do
        local okEdge, texture = pcall(overlay.CreateTexture, overlay, nil, "OVERLAY")

        if okEdge and (type(texture) == "table" or type(texture) == "userdata") then
            texture.__ltSide = side.name
            texture:SetPoint(side.from, overlay, side.from, 0, 0)
            texture:SetPoint(side.to, overlay, side.to, 0, 0)

            if side.height then
                texture:SetHeight(MARK_EDGE)
            else
                texture:SetWidth(MARK_EDGE)
            end

            overlay.__edges[#overlay.__edges + 1] = texture
        end
    end

    local okGlyph, glyph = pcall(overlay.CreateTexture, overlay, nil, "OVERLAY")
    if okGlyph and glyph then
        if glyph.SetTexture then pcall(glyph.SetTexture, glyph, MARK_GLYPH) end
        glyph:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", -1, 1)
        glyph:SetSize(GLYPH_MIN, GLYPH_MIN)
        glyph:Hide()
        overlay.__glyph = glyph
    end

    overlay:Hide()
    button.__ltDropMarker = overlay
    return overlay
end

-- Takes one marker down. Hidden, not destroyed: the frames and textures are
-- built once per button (see applyMarker) and every later draw reuses them.
-- Defined before applyMarker because a slot that stops naming an item has to
-- lose its marker inside the same call that refused to draw a new one.
local function clearMark(button)
    if type(button) ~= "table" then return end

    local overlay = button.__ltDropMarker
    if type(overlay) ~= "table" then return end

    pcall(overlay.Hide, overlay)

    local glyph = overlay.__glyph
    if type(glyph) == "table" then pcall(glyph.Hide, glyph) end
end

-- Draws (or redraws) one button with the result the registry chose. The frames
-- and textures are built once per button and every later draw reuses them, so
-- drawing the same slot twice cannot stack a second marker on it. `row` is the
-- slot the marker names, remembered so BAG_UPDATE can take the marker down the
-- moment that slot no longer holds the item.
local function applyMarker(button, result, row)
    -- A marker names an item. A slot with no readable link holds no item this
    -- file can name, so it never gets a border or a glyph -- and any marker
    -- already sitting there is taken down now, not at the next event (E8). The
    -- guard sits before markerFor so an empty slot does not grow a frame either,
    -- and it is here rather than only at the call site because every draw path
    -- ends up in this one function.
    local link = type(row) == "table" and row.link or nil

    if type(link) ~= "string" or link == "" or secretValue(link) then
        clearMark(button)
        return false
    end

    -- Carry the button's own idea of what it shows. The client's bag click reads
    -- (parent frame id, button id); when both answer, they must be the row's bag
    -- and slot, or this is the wrong button and gets no marker.
    local bag, slot = tonumber(row.bag), tonumber(row.slot)
    if not bag or not slot then
        clearMark(button)
        return false
    end

    local buttonBag, buttonSlot = buttonIdentity(button)
    if buttonBag ~= nil and buttonBag ~= bag then
        clearMark(button)
        return false
    end
    -- The slot id is not re-checked: GetID is unreliable on some clients (it
    -- returns a combined index), so the button's name is the slot authority.

    local overlay = markerFor(button)
    if not overlay then return false end

    overlay.__bag = bag
    overlay.__slot = slot
    overlay.__link = link
    overlay.__buttonBag = buttonBag
    overlay.__buttonSlot = buttonSlot

    result = type(result) == "table" and result or {}

    local colour = result.colour
    if type(colour) ~= "table" then colour = brandColour() end

    if type(colour) == "table" then
        local edge = tonumber(result.edge) or MARK_EDGE
        for _, texture in ipairs(overlay.__edges or {}) do
            pcall(texture.SetColorTexture, texture,
                colour[1], colour[2], colour[3], colour[4])

            local side = texture.__ltSide
            if side == "top" or side == "bottom" then
                pcall(texture.SetHeight, texture, edge)
            elseif side == "left" or side == "right" then
                pcall(texture.SetWidth, texture, edge)
            end
        end
    end

    local glyph = overlay.__glyph
    if glyph then
        local path = result.glyph
        if type(path) ~= "string" or path == "" then path = MARK_GLYPH end
        pcall(glyph.SetTexture, glyph, path)

        local texCoord = result.glyphTexCoord
        if type(texCoord) == "table" and #texCoord == 4 then
            pcall(glyph.SetTexCoord, glyph, texCoord[1], texCoord[2], texCoord[3], texCoord[4])
        else
            pcall(glyph.SetTexCoord, glyph, 0, 1, 0, 1)
        end

        local tint = result.glyphColour
        if type(tint) == "table" then
            pcall(glyph.SetVertexColor, glyph, tint[1], tint[2], tint[3], tint[4] or 1)
        else
            pcall(glyph.SetVertexColor, glyph, 1, 1, 1, 1)
        end

        local width = button.GetWidth and button:GetWidth() or nil
        local height = button.GetHeight and button:GetHeight() or nil
        local scale = tonumber(result.glyphScale) or 1
        local aspect = tonumber(result.glyphAspect) or 1
        local size = GLYPH_MIN

        if type(width) == "number" and type(height) == "number" then
            size = math.floor(math.min(width, height) * 0.45 * scale + 0.5)
            if size < GLYPH_MIN then size = GLYPH_MIN end
            local cap = math.floor(GLYPH_MAX * scale + 0.5)
            if size > cap then size = cap end
        end

        pcall(glyph.SetSize, glyph, size, size * aspect)
        glyph:Show()
    end

    overlay:Show()
    return true
end

-- Every marker comes down. The bag buttons are swept as well as the `marked`
-- table on purpose: `marked` can be empty while a button still carries a drawn
-- overlay (a draw that failed halfway, a module reinitialised in the same
-- session, a marker whose entry was never recorded). A marker left on a slot is
-- exactly the state this has to be able to clear.
local function clearMarkers()
    for button in pairs(marked) do
        clearMark(button)
    end

    marked = {}

    local api = containerAPI()
    if not api then return end

    local lastBag = tonumber(NUM_BAG_SLOTS) or 4

    for bag = 0, lastBag do
        local okSlots, slots = pcall(api.slots, bag)
        slots = okSlots and tonumber(slots) or 0

        for slot = 1, slots do
            clearMark(itemButton(bag, slot))
        end
    end
end

-- Takes down every marker whose slot no longer holds the item it named. This
-- is the cheap half of a redraw and it touches only the buttons this file has
-- marked, so it can run on BAG_UPDATE (which fires for every slot write) without
-- a scan. It is what makes the border leave the slot the moment the item does,
-- instead of waiting for BAG_UPDATE_DELAYED.
local function clearStaleMarkers()
    local api = containerAPI()
    if not api then return false end
    if inCombatNow() then return false end

    local cleared = false

    for button in pairs(marked) do
        local overlay = button.__ltDropMarker

        if type(overlay) ~= "table" then
            marked[button] = nil
        else
            local bag, slot = overlay.__bag, overlay.__slot
            local current

            if bag ~= nil and slot ~= nil then
                local okLink, link = pcall(api.link, bag, slot)
                if okLink and type(link) == "string" and link ~= "" then
                    current = link
                end
            end

            -- No link now, or a different one: the item this marker named has
            -- left the slot. Both are "the slot emptied" and both clear.
            if current == nil or (overlay.__link ~= nil and current ~= overlay.__link) then
                clearMark(button)
                marked[button] = nil
                cleared = true
            end
        end
    end

    return cleared
end

-- Alt-click used to be this add-on's "never suggest this again": every bag
-- button's OnClick was replaced with a wrapper so the gesture could be answered
-- before the client picked the item up. That replacement is gone. Handing a
-- wrapped OnClick back to the client is still the client's click path with this
-- file in the middle of it, and the review of this fork rejected it.
--
-- HookScript("OnMouseDown") was the alternative, and it cannot be made safe. It
-- does run before the client's OnClick, but it cannot cancel it: the item is
-- still picked up and the player is left holding what they had just asked the
-- add-on to skip. Clearing the cursor from the hook is not a fix either -- at
-- mouse-down nothing of this click has been picked up yet, so a guarded
-- ClearCursor would put down whatever the player was already carrying, and
-- clearing afterwards needs a timer whose race can clear the wrong item.
--
-- The gesture is therefore dropped rather than half-kept, and the ignore list is
-- reached by command: /lt drop ignore [item], /lt drop forget <id> and
-- /lt drop list. None of them touches a bag button, so an ordinary click stays
-- the client's own click, once.

local function attachTooltip(frame, text)
    if type(frame) ~= "table" or type(frame.SetScript) ~= "function" then return end

    frame:SetScript("OnEnter", function(self)
        if type(GameTooltip) ~= "table" or type(GameTooltip.SetOwner) ~= "function" then return end

        pcall(GameTooltip.SetOwner, GameTooltip, self, "ANCHOR_TOP")
        if type(GameTooltip.AddLine) == "function" then
            pcall(GameTooltip.AddLine, GameTooltip, text)
        end
        if type(GameTooltip.Show) == "function" then pcall(GameTooltip.Show, GameTooltip) end
    end)

    frame:SetScript("OnLeave", function()
        if type(GameTooltip) == "table" and type(GameTooltip.Hide) == "function" then
            pcall(GameTooltip.Hide, GameTooltip)
        end
    end)
end

-- One button in the bag frame's own header: "Sort" by default, "Sell junk" at a
-- merchant with junk selling allowed. It is parented to the frame that draws the
-- bags, so a second bag window cannot cover it, and it cannot float free when
-- the bags close.
local bagButton
local bagButtonParent
local bagButtonSell

local function nowSeconds()
    if type(GetTime) ~= "function" then return 0 end
    local ok, value = pcall(GetTime)
    return ok and tonumber(value) or 0
end

local function frameName(frame)
    if type(frame) ~= "table" or type(frame.GetName) ~= "function" then return "?" end
    local ok, name = pcall(frame.GetName, frame)
    if ok and type(name) == "string" and name ~= "" then return name end
    return "?"
end

-- The client's merchant state. MERCHANT_SHOW/MERCHANT_CLOSED keep the plugin's
-- own flag current; the frame is only the fallback for a merchant that was
-- already open, the same rule the Vendor plugin uses.
local function merchantOpen()
    local vendor = LT.Vendor
    if type(vendor) == "table" and type(vendor.atMerchant) == "boolean" then
        return vendor.atMerchant
    end

    local frame = MerchantFrame
    if type(frame) == "table" and type(frame.IsShown) == "function" then
        local ok, shown = pcall(frame.IsShown, frame)
        if ok then return shown == true end
    end

    return false
end

local function junkSaleAllowed()
    return option("junkSale")
end

-- The frame that draws the bags this button lives in: the one combined frame
-- when the client has it, otherwise the backpack's own window.
local function bagButtonHost()
    local combined = _G.ContainerFrameCombinedBags
    if type(combined) == "table" and type(combined.CreateTexture) == "function" then
        return combined
    end

    local frame = containerFrameFor(0) or _G.ContainerFrame1
    if type(frame) == "table" and type(frame.CreateTexture) == "function" then
        return frame
    end

    return nil
end

-- The client's own header buttons ("Clean Up Bags") sit on the same header. A
-- child at the parent's frame level can be drawn under them, which is how our
-- Sort button was reported missing on 2026-11-05 while the cleanup button was
-- visible. Raise ours clear of the parent's level.
local function raiseAbove(button, parent)
    if type(button) ~= "table" or type(button.SetFrameLevel) ~= "function" then return end
    if type(parent) ~= "table" or type(parent.GetFrameLevel) ~= "function" then return end
    local ok, level = pcall(parent.GetFrameLevel, parent)
    if ok and tonumber(level) then
        pcall(button.SetFrameLevel, button, tonumber(level) + 20)
    end
end

local function anchorBagButton(button, parent)
    if type(button) ~= "table" or type(button.ClearAllPoints) ~= "function" then return end
    button:ClearAllPoints()
    -- Outside the frame, on its left edge. The combined bag frame exposes no
    -- named header children on this client ("header children" came back empty),
    -- its search box covers the header, and anchoring above it can run off the
    -- top of the screen when the window sits high. The strip left of the window
    -- is empty on this layout and belongs to the client's own empty space.
    button:SetPoint("TOPRIGHT", parent, "TOPLEFT", -6, 0)
    raiseAbove(button, parent)
end

-- Takes the armed junk sale down. The markers come off with it: the next draw no
-- longer matches the arm set, so the borders leave at once.
local function disarmJunk()
    local wasArmed = bagArmed or junkArmedSet ~= nil
    bagArmed = false
    bagArmedAt = 0
    junkArmedSet = nil
    junkArmedList = nil

    if not wasArmed then return end

    needsRefresh = true
    if not inCombatNow() and bagsShown() and type(DropHint.RefreshMarkers) == "function" then
        pcall(DropHint.RefreshMarkers, DropHint)
    end
end

-- The Vendor plugin owns its own two-press arming. These two rows keep this
-- file's markers in step with it: JunkRows() is the armed list (nil when
-- cleared) and SetJunkPainter(fn) calls back with it on every arm and clear.
-- Nothing is sold from here on this path; the plugin's confirm does that.
local function noteJunkRows(rows)
    local had = junkArmedSet ~= nil or bagArmed

    junkArmedSet = nil
    junkArmedList = nil
    bagArmed = false
    bagArmedAt = 0

    if type(rows) == "table" and #rows > 0 then
        local set = {}
        local list = {}

        for _, row in ipairs(rows) do
            if type(row) == "table" then
                local bag, slot = tonumber(row.bag), tonumber(row.slot)
                local link = row.link

                if bag and slot and type(link) == "string" and link ~= ""
                    and not secretValue(link) then
                    set[bag] = set[bag] or {}
                    set[bag][slot] = link
                    list[#list + 1] = row
                end
            end
        end

        if #list > 0 then
            junkArmedSet = set
            junkArmedList = list
            bagArmed = true
            bagArmedAt = nowSeconds()
        end
    end

    if not had and junkArmedSet == nil then return end

    needsRefresh = true
    if not inCombatNow() and bagsShown() and not refreshing
        and type(DropHint.RefreshMarkers) == "function" then
        pcall(DropHint.RefreshMarkers, DropHint)
    end
end

-- Registered once, and retried on every draw so a plugin loaded after this file
-- is still picked up. SetJunkPainter refreshes the plugin immediately, which is
-- why this is never called in combat.
local junkPainterHooked = false

local function ensureJunkPainter()
    if junkPainterHooked then return true end

    local vendor = LT.Vendor
    if type(vendor) ~= "table" or type(vendor.SetJunkPainter) ~= "function" then
        return false
    end
    if inCombatNow() then return false end

    -- The flag is set first: SetJunkPainter calls back immediately, and a
    -- callback that asks for a draw must not re-enter this registration.
    junkPainterHooked = true

    local ok, accepted = pcall(vendor.SetJunkPainter, vendor, noteJunkRows)
    if not ok or accepted == false then
        junkPainterHooked = false
        return false
    end

    return true
end

-- The grey stacks in the bags, as plain rows. The client's own quality field is
-- the only test: "grey" is what the vendor pays least for and what the player
-- means by junk. Quest items and unpriced rows are never included.
local function greyRows()
    local rows = DropHint:Scan()
    if not rows then return nil end

    local result = {}
    for _, row in ipairs(rows) do
        if type(row) == "table" and not row.quest and row.unitPrice then
            local identity = identityOf(row.link)
            if identity and tonumber(identity.quality) == 0 then
                result[#result + 1] = row
            end
        end
    end

    return result
end

-- The fallback arming used when the Vendor plugin exposes no arm/confirm pair:
-- mark every grey stack now, sell exactly those rows on the second press.
local function armOwnJunkSale()
    local rows = greyRows()
    if not rows then
        LT:Error("The bags could not be read, so no junk sale was armed.")
        return false
    end

    if #rows == 0 then
        LT:Print("No grey items to sell.")
        return false
    end

    local set = {}
    for _, row in ipairs(rows) do
        set[row.bag] = set[row.bag] or {}
        set[row.bag][row.slot] = row.link
    end

    junkArmedSet = set
    junkArmedList = rows
    bagArmed = true
    bagArmedAt = nowSeconds()

    LT:Print("Sell junk: " .. tostring(#rows) .. " grey stack(s) marked. Press again within "
        .. tostring(DropHint.ARM_SECONDS) .. " seconds to sell.")

    needsRefresh = true
    if bagsShown() then pcall(DropHint.RefreshMarkers, DropHint) end
    return true
end

local function sellArmedJunk()
    local list = junkArmedList or {}
    local pickup = nil

    if type(C_Container) == "table" and type(C_Container.UseContainerItem) == "function" then
        pickup = C_Container.UseContainerItem
    elseif type(UseContainerItem) == "function" then
        pickup = UseContainerItem
    end

    if not pickup then
        disarmJunk()
        LT:Error("This client exposes no way to sell an item, so nothing was sold.")
        return false
    end

    local sold, failed = 0, 0
    for _, row in ipairs(list) do
        -- Re-read the slot before every sale: a row that moved or was emptied
        -- since arming is skipped, never sold as whatever took its place.
        if rowMatchesSlot(row, currentLink(row.bag, row.slot), row.bag, row.slot) then
            local ok = pcall(pickup, row.bag, row.slot)
            if ok then sold = sold + 1 else failed = failed + 1 end
        end
    end

    disarmJunk()

    LT:Print("Sold " .. tostring(sold) .. " grey stack(s)"
        .. (failed > 0 and (", " .. tostring(failed) .. " failed") or "") .. ".")

    return sold > 0
end

-- The one click. Sort has no confirmation by design; the junk sale is the
-- two-press rule. The Vendor plugin owns the arm/confirm flow when it exposes
-- it, so both windows behave identically.
function DropHint:BagButtonClick()
    if inCombatNow() then return end

    if not (merchantOpen() and junkSaleAllowed()) then
        -- Sorting is the other action this button offers: an armed junk sale
        -- belongs to the previous press and ends here.
        disarmJunk()

        local sorter = LT.BagSort
        if type(sorter) ~= "table" or type(sorter.Run) ~= "function" then
            LT:Print("Bag sorting is not loaded.")
            return
        end

        local called, ok, sentence = pcall(sorter.Run, sorter, "bags")
        if not called then
            LT:Error("The bag sort failed: " .. tostring(ok) .. ".")
        elseif ok then
            if type(sentence) == "string" then LT:Print(sentence) end
        else
            local warn = LT.Warn or LT.Print
            if type(warn) == "function" then
                pcall(warn, LT, tostring(sentence or "the bags could not be sorted"))
            end
        end
        return
    end

    -- Timeout: a press after the window has passed simply arms again.
    if bagArmed and nowSeconds() - bagArmedAt > DropHint.ARM_SECONDS then
        disarmJunk()
    end

    local vendor = LT.Vendor
    local arm = type(vendor) == "table" and vendor.ArmJunkSale or nil
    local confirm = type(vendor) == "table" and vendor.ConfirmJunkSale or nil

    if type(arm) == "function" and type(confirm) == "function" then
        if bagArmed then
            disarmJunk()
            local ok, acted, extra = pcall(confirm, vendor)
            if not ok then
                LT:Error("The junk sale failed; nothing was confirmed.")
            elseif not acted then
                LT:Print("Junk sale: " .. tostring(extra or "nothing was sold") .. ".")
            elseif type(extra) == "table" and tonumber(extra.sold) then
                LT:Print("Sold " .. tostring(tonumber(extra.sold)) .. " junk item(s).")
            end

            -- The plugin clears its armed rows on a confirm; mirror whatever it
            -- says now rather than trusting this file's copy.
            if not junkPainterHooked and type(vendor.JunkRows) == "function" then
                local okRows, rows = pcall(vendor.JunkRows, vendor)
                if okRows then noteJunkRows(rows) end
            end
            return
        end

        local ok, armed, reason = pcall(arm, vendor)
        if not ok then
            LT:Error("The junk sale could not be armed.")
        elseif not armed then
            if reason then LT:Print("Junk sale: " .. tostring(reason) .. ".") end
        elseif not junkPainterHooked and type(vendor.JunkRows) == "function" then
            -- Nothing painted the arm (no SetJunkPainter on this plugin
            -- version); read the rows so the borders still appear.
            local okRows, rows = pcall(vendor.JunkRows, vendor)
            if okRows then noteJunkRows(rows) end
        end
        return
    end

    if bagArmed then
        sellArmedJunk()
    else
        armOwnJunkSale()
    end
end

local SORT_TEXT = "Sort"
local SELL_TEXT = "Sell junk"

-- The single button. It is built once, reparented if the client replaces the
-- combined bag frame, and never rebuilt: one button, one anchor.
local function ensureBagButton()
    if inCombatNow() then return nil end

    local parent = bagButtonHost()
    if not parent then return nil end

    if bagButton and bagButtonParent ~= parent and type(bagButton.SetParent) == "function" then
        local ok = pcall(bagButton.SetParent, bagButton, parent)
        if ok then
            bagButtonParent = parent
            anchorBagButton(bagButton, parent)
        end
    end

    if not bagButton then
        bagButton = plainButton(parent, SORT_TEXT, 92, 20, function()
            DropHint:BagButtonClick()
        end)
        if not bagButton then return nil end

        bagButtonParent = parent
        anchorBagButton(bagButton, parent)
    end

    if not diagParentOnce and type(LT.Diag) == "function" then
        diagParentOnce = true
        pcall(LT.Diag, LT, "[Bag] button parent=" .. frameName(bagButtonParent))

        -- The header is the client's own layout: the search box and its cleanup
        -- button sit somewhere in it, and guessing coordinates put ours under
        -- them. Name the children once so the anchor can be fitted to what is
        -- really there.
        if type(bagButtonParent.GetChildren) == "function" then
            local okChildren, children = pcall(bagButtonParent.GetChildren, bagButtonParent)
            if okChildren and type(children) == "table" then
                local names = {}
                for index, child in ipairs(children) do
                    if index > 14 then break end
                    local name = type(child.GetName) == "function" and select(2, pcall(child.GetName, child)) or nil
                    if type(name) == "string" and name ~= "" then
                        names[#names + 1] = name
                    end
                end
                pcall(LT.Diag, LT, "[Bag] header children: " .. table.concat(names, ", "))
            end
        end
    end

    return bagButton
end

-- The label follows the state: "Sell junk" only at a merchant with junk selling
-- allowed, "Sort" everywhere else. The tooltip is rewritten with it, because one
-- press means two different things.
local ensureDropButton

function DropHint:UpdateBagButtons()
    if inCombatNow() then return end

    local button = ensureBagButton()
    if not button then return end

    local sell = merchantOpen() and junkSaleAllowed()
    local text = sell and SELL_TEXT or SORT_TEXT

    if type(button.SetText) == "function" then
        button:SetText(text)
    elseif button.label and type(button.label.SetText) == "function" then
        button.label:SetText(text)
    end

    if sell ~= bagButtonSell then
        bagButtonSell = sell
        attachTooltip(button, sell
            and ("Sell junk: first press marks every junk item, a second press within "
                .. tostring(DropHint.ARM_SECONDS) .. " seconds sells exactly those.")
            or "Sort the bags with the client's own sort. One press, no confirmation.")
    end

    ensureDropButton()
end

------------------------------------------------------------------------------
-- Destroy the cheapest junk item
-- The request on 2026-11-05 was a button for a full bag. Destroying is
-- irreversible, so it is deliberately narrow: the cheapest grey or WHITE item,
-- out of combat, two presses with the name printed in between.
------------------------------------------------------------------------------

local DROP_TEXT = "Drop junk"
local DROP_ARM_SECONDS = 5
local dropButton, dropButtonParent
local dropArmedKey, dropArmedAt = nil, 0

local function anchorDropButton(button, parent)
    if type(button) ~= "table" or type(button.ClearAllPoints) ~= "function" then return end
    button:ClearAllPoints()
    if bagButton then
        button:SetPoint("TOPRIGHT", bagButton, "BOTTOMRIGHT", 0, -6)
    else
        button:SetPoint("TOPRIGHT", parent, "TOPLEFT", -6, -26)
    end
    raiseAbove(button, parent)
end

ensureDropButton = function()
    if inCombatNow() then return nil end

    local parent = bagButtonHost()
    if not parent or not bagButton then
        if type(LT.Diag) == "function" then
            pcall(LT.Diag, LT, "[Bag] drop button: skipped, host="
                .. tostring(parent ~= nil) .. " sort=" .. tostring(bagButton ~= nil))
        end
        return nil
    end

    if dropButton and dropButtonParent ~= parent and type(dropButton.SetParent) == "function" then
        if pcall(dropButton.SetParent, dropButton, parent) then
            dropButtonParent = parent
            anchorDropButton(dropButton, parent)
        end
    end

    if not dropButton then
        dropButton = plainButton(parent, DROP_TEXT, 92, 20, function()
            DropHint:DropButtonClick()
        end)
        if not dropButton then
            if type(LT.Diag) == "function" then
                pcall(LT.Diag, LT, "[Bag] drop button: plainButton returned nothing")
            end
            return nil
        end

        dropButtonParent = parent
        anchorDropButton(dropButton, parent)

        if type(LT.Diag) == "function" then
            local okPoint, point, _, _, x, y = pcall(dropButton.GetPoint, dropButton, 1)
            if not okPoint then point, x, y = "error", nil, nil end
            pcall(LT.Diag, LT, "[Bag] drop button: created at "
                .. tostring(point) .. " " .. tostring(x) .. "," .. tostring(y)
                .. " shown=" .. tostring(dropButton:IsShown()))
        end
        attachTooltip(dropButton, "Destroy the cheapest junk item in the bags: grey or "
            .. "white, never food, drink or a potion, and never anything with a stat. "
            .. "First press names it, a second press within " .. tostring(DROP_ARM_SECONDS)
            .. " seconds destroys it. Never in combat.")
    end

    return dropButton
end

-- Only a bonus stat makes an item worth keeping. Armour, weapon damage and speed
-- are what a grey *is*: excluding them made every grey item "carrying a stat", so
-- the button saw nothing to drop (player report 2026-11-05).
local KEEP_STATS = {
    stamina = true, strength = true, agility = true, intellect = true, spirit = true,
    hit = true, crit = true, haste = true, expertise = true, spellCrit = true,
    spellPower = true, attackPower = true, mp5 = true, spellHit = true,
}

local function isJunk(row, why)
    if type(row) ~= "table" or type(row.link) ~= "string" then
        if why then why[1] = "no link" end
        return false
    end

    local itemStats = LT.ItemStats
    if type(itemStats) ~= "table" or type(itemStats.GetIdentity) ~= "function" then
        if why then why[1] = "no item stats" end
        return false
    end

    local identity = itemStats:GetIdentity(row.link)
    if type(identity) ~= "table" then
        if why then why[1] = "no identity" end
        return false
    end

    local quality = tonumber(identity.quality)
    if not quality or quality > 1 then
        if why then why[1] = "quality " .. tostring(identity.quality) end
        return false
    end

    -- 0 is the consumable class: food, drink, potions, scrolls.
    if tonumber(identity.classID) == 0 then
        if why then why[1] = "consumable" end
        return false
    end

    if type(itemStats.Get) == "function" then
        local okStats, stats = pcall(itemStats.Get, itemStats, row.link)
        if not okStats then
            if why then why[1] = "stats unreadable" end
            return false
        end
        if type(stats) == "table" then
            for key in pairs(stats) do
                if KEEP_STATS[key] then
                    if why then why[1] = "has " .. tostring(key) end
                    return false
                end
            end
        end
    end

    return true
end

-- `commit` false names the item and arms; true destroys it. Returns
-- ok, message, key. Only a grey or white, non-consumable item is ever destroyed.
function DropHint:DropGrey(commit)
    if inCombatNow() then return false, "Not in combat: nothing was dropped." end

    local rows = self:Scan()
    if not rows then return false, "The bags could not be read." end

    local candidates = {}
    local seen = 0
    local reasons = {}
    for _, row in ipairs(rows) do
        local why = {}
        if isJunk(row, why) then
            candidates[#candidates + 1] = row
        elseif seen < 3 then
            seen = seen + 1
            reasons[#reasons + 1] = tostring(row.name or "?") .. " (" .. tostring(why[1]) .. ")"
        end
    end

    local cheapest = #candidates > 0 and DropHint.Rank(candidates, ignoreList(), 1).cheapest or nil
    if not cheapest then
        local detail = #reasons > 0 and (" — " .. table.concat(reasons, "; ")) or ""
        return false, "No grey or white non-food item to drop; nothing was destroyed." .. detail
    end

    local identity = LT.ItemStats:GetIdentity(cheapest.link)
    local key = tostring(cheapest.bag) .. ":" .. tostring(cheapest.slot)
    local name = tostring(cheapest.name or (identity and identity.name) or "item")

    if not commit then
        return true, "Press again within " .. tostring(DROP_ARM_SECONDS)
            .. "s to destroy " .. name .. ".", key
    end

    local pickup = (type(C_Container) == "table" and C_Container.PickupContainerItem)
        or PickupContainerItem
    if type(pickup) ~= "function" or type(DeleteCursorItem) ~= "function" then
        return false, "This client does not allow destroying items from the bags.", key
    end

    if not pcall(pickup, cheapest.bag, cheapest.slot) then
        return false, "The client refused to pick " .. name .. " up.", key
    end
    if not pcall(DeleteCursorItem) then
        return false, name .. " was picked up but not destroyed.", key
    end

    return true, "Destroyed " .. name .. ".", key
end

function DropHint:DropButtonClick()
    local now = type(GetTime) == "function" and GetTime() or 0
    local confirm = dropArmedKey ~= nil and (now - dropArmedAt) <= DROP_ARM_SECONDS

    local ok, message, key = self:DropGrey(confirm)
    if ok and not confirm then
        dropArmedKey, dropArmedAt = key, now
    else
        dropArmedKey, dropArmedAt = nil, 0
    end

    LT:Print(tostring(message))
    self:Changed()
end

-- One item id goes on the account-wide list or comes off it, and everything that
-- shows that list is redrawn. The Forget button in the window uses ForgetEntry;
-- this is the toggle a plugin can call with a link it already holds.
function DropHint:ToggleIgnore(link)
    local list = ignoreList()
    if not list then
        LT:Error("The saved ignore list is unavailable; nothing was changed.")
        return
    end

    local itemID = itemIDFromLink(link)
    if not itemID then
        LT:Print("That item's link carries no id, so it cannot be remembered.")
        return
    end

    local name = nameFromLink(link) or ("item " .. tostring(itemID))

    if list[itemID] ~= nil then
        list[itemID] = nil
        LT:Print("No longer ignoring " .. tostring(name) .. " (" .. tostring(itemID) .. ").")
    else
        list[itemID] = name
        LT:Print("Ignoring " .. tostring(name) .. " (" .. tostring(itemID)
            .. ") on every character. /lt drop forget " .. tostring(itemID) .. " undoes it.")
    end

    self:Changed()
end

-- The Forget button of one row in the window.
function DropHint:ForgetEntry(itemID)
    local list = ignoreList()
    if not list or itemID == nil or list[itemID] == nil then return end

    local name = list[itemID]
    list[itemID] = nil

    LT:Print("No longer ignoring " .. tostring(name ~= true and name or itemID)
        .. " (" .. tostring(itemID) .. ").")

    self:Changed()
end

-- The Destroy button, and the only place in this file that touches an item.
--
-- It picks the suggested item up and opens the client's own delete dialog; the
-- dialog is what deletes, and cancelling puts the item back in the slot. Nothing
-- here calls DeleteCursorItem. Four refusals, before anything is picked up:
-- combat (a click refused mid-fight cannot be given back, so the whole command
-- waits for the fight to end), no suggestion, no dialog this client will open,
-- and something already on the cursor -- the last because the dialog would then
-- delete whatever the player was carrying rather than the item this add-on named.
function DropHint:DestroySuggestion()
    if inCombatNow() then
        LT:Print("Nothing is destroyed in combat. The suggestion is still here after the fight.")
        return
    end

    local rows, why = self:Scan()
    if not rows then
        LT:Error("The bags could not be read: " .. tostring(why or "no container API") .. ".")
        return
    end

    local pick = DropHint.Rank(rows, ignoreList(), 1).cheapest

    if not pick then
        LT:Print("Nothing to suggest: no priced item in the bags is left to lose.")
        return
    end

    local dialog = nil
    if type(StaticPopupDialogs) == "table" then
        if StaticPopupDialogs["DELETE_GOOD_ITEM"] then
            dialog = "DELETE_GOOD_ITEM"
        elseif StaticPopupDialogs["DELETE_ITEM"] then
            dialog = "DELETE_ITEM"
        end
    end

    if not dialog or type(StaticPopup_Show) ~= "function" then
        LT:Error("This client has no delete dialog to open, so nothing was touched. "
            .. "Destroy the item by hand.")
        return
    end

    local api = containerAPI()
    local pickup = (type(C_Container) == "table" and C_Container.PickupContainerItem)
        or PickupContainerItem

    if not api or type(pickup) ~= "function" then
        LT:Error("This client exposes no way to pick an item up, so nothing was touched.")
        return
    end

    -- The suggestion was ranked a moment ago. Before anything is picked up,
    -- the slot is read again and must still hold that exact item: destroying
    -- whatever moved into the slot instead is the E8 wrong-item report.
    if not rowMatchesSlot(pick, currentLink(pick.bag, pick.slot), pick.bag, pick.slot) then
        needsRefresh = true

        if not inCombatNow() and bagsShown()
            and type(DropHint.RefreshMarkers) == "function" then
            pcall(DropHint.RefreshMarkers, DropHint)
        end

        LT:Print("The bags changed, so nothing was picked up. The suggestion has been redrawn.")
        return
    end

    if type(CursorHasItem) == "function" then
        local okCursor, holding = pcall(CursorHasItem)
        if okCursor and holding then
            LT:Print("Something is already on the cursor. Put it down first; nothing was destroyed.")
            return
        end
    end

    local okPick = pcall(pickup, pick.bag, pick.slot)

    local gotIt = true
    if type(CursorHasItem) == "function" then
        local okCursor, holding = pcall(CursorHasItem)
        gotIt = okCursor and holding and true or false
    end

    if not okPick or not gotIt then
        if type(ClearCursor) == "function" then pcall(ClearCursor) end
        LT:Error("The item could not be picked up, so nothing was destroyed.")
        return
    end

    local name = pick.name or "this item"
    local okShow = pcall(StaticPopup_Show, dialog, name)

    if not okShow then
        if type(ClearCursor) == "function" then pcall(ClearCursor) end
        LT:Error("The delete dialog would not open; the item was put back.")
        return
    end

    -- The item left its slot the moment it was picked up, so the marker that
    -- named it must not be left sitting on the now-empty slot while the dialog
    -- is open (player report E8). Clearing and redrawing here also puts the
    -- marker back straight away if the player cancels and the item returns.
    clearMarkers()
    needsRefresh = true

    if not inCombatNow() and bagsShown()
        and type(DropHint.RefreshMarkers) == "function" then
        pcall(DropHint.RefreshMarkers, DropHint)
    end
end

------------------------------------------------------------------------------
-- The ignore list window
------------------------------------------------------------------------------

-- Wide enough for "item id - name" plus a Forget button, and short enough to sit
-- beside the bags on a small UI. Rows stop at MAX_IGNORE_ROWS: a list longer than
-- that is read with /lt drop print, which prints every id in chat.
local WINDOW_WIDTH = 360
local WINDOW_PAD = 14
local WINDOW_HEAD = 46
local WINDOW_ROW = 20
local WINDOW_TAIL = 58

local ignoreWindow
local ignoreRows = {}

-- The saved list as a sorted array. Ids are sorted numerically rather than by
-- name so the order does not jump about as names are recorded.
local function sortedIgnoreEntries()
    local list = ignoreList()
    if not list then return nil end

    local entries = {}
    for itemID, name in pairs(list) do
        table.insert(entries, { itemID = itemID, name = name, id = tonumber(itemID) or 0 })
    end

    table.sort(entries, function(a, b) return a.id < b.id end)
    return entries
end

local function buildIgnoreWindow()
    local ok, window = pcall(CreateFrame, "Frame", "LunchboxToolkitDropIgnoreFrame", UIParent)
    if not ok or type(window) ~= "table" then return nil end

    window:SetWidth(WINDOW_WIDTH)
    window:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    if window.SetFrameStrata then window:SetFrameStrata("DIALOG") end

    -- The same edge as the main window, from the module that owns chrome: one
    -- draw for every window, so the ignore list cannot look like a different
    -- add-on from the window that opened it.
    LT.Chrome.Window(window)

    window:EnableMouse(true)
    window:SetMovable(true)
    pcall(window.RegisterForDrag, window, "LeftButton")
    window:SetScript("OnDragStart", function(self) self:StartMoving() end)
    window:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    window:Hide()

    local title = plainLabel(window, "Ignored items", "GameFontNormal",
        Palette and Palette:Colour("brand") or nil)
    if title then title:SetPoint("TOPLEFT", WINDOW_PAD, -WINDOW_PAD) end

    local subtitle = plainLabel(window,
        "/lt drop ignore [item] skips one. Every character on this account skips these.",
        "GameFontNormalSmall", Palette and Palette:Colour("muted") or nil)
    if subtitle then subtitle:SetPoint("TOPLEFT", WINDOW_PAD, -WINDOW_PAD - 18) end

    window.__empty = plainLabel(window, "Nothing is ignored yet.", "GameFontNormalSmall",
        Palette and Palette:Colour("muted") or nil)
    if window.__empty then
        window.__empty:SetPoint("TOPLEFT", WINDOW_PAD, -WINDOW_HEAD)
        window.__empty:Hide()
    end

    window.__footer = plainLabel(window, "", "GameFontNormalSmall",
        Palette and Palette:Colour("muted") or nil)

    local close = plainButton(window, "Close", 70, 20, function() window:Hide() end)
    if close then close:SetPoint("BOTTOMRIGHT", -WINDOW_PAD, WINDOW_PAD) end

    -- Escape closes it like any other dialog.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "LunchboxToolkitDropIgnoreFrame")
    end

    ignoreWindow = window
    return window
end

-- One row: "id - name" on the left, Forget on the right. Rows are built once and
-- reused, so re-opening the window does not pile up frames.
local function rowFor(index)
    local row = ignoreRows[index]
    if row then return row end

    local holder = CreateFrame("Frame", nil, ignoreWindow)
    holder:SetHeight(WINDOW_ROW)

    local top = -(WINDOW_HEAD + (index - 1) * WINDOW_ROW)
    holder:SetPoint("TOPLEFT", ignoreWindow, "TOPLEFT", WINDOW_PAD, top)
    holder:SetPoint("TOPRIGHT", ignoreWindow, "TOPRIGHT", -WINDOW_PAD, top)

    row = { frame = holder }

    row.forget = plainButton(holder, "Forget", 58, 16, function()
        DropHint:ForgetEntry(holder.__itemID)
    end)
    if row.forget then row.forget:SetPoint("RIGHT", holder, "RIGHT", 0, 0) end

    row.name = plainLabel(holder, "", "GameFontNormalSmall",
        Palette and Palette:Colour("text") or nil)

    if row.name then
        row.name:SetPoint("LEFT", holder, "LEFT", 0, 0)

        if row.forget then
            row.name:SetPoint("RIGHT", row.forget, "LEFT", -6, 0)
        end

        if row.name.SetWordWrap then pcall(row.name.SetWordWrap, row.name, false) end
        if row.name.SetJustifyH then pcall(row.name.SetJustifyH, row.name, "LEFT") end
    end

    ignoreRows[index] = row
    return row
end

function DropHint:RefreshIgnoreWindow()
    if not ignoreWindow then return end

    -- Rows are created lazily, so a refresh can build frames. In combat the list
    -- keeps the content it was last drawn with and the regen event redraws it.
    if inCombatNow() then return end

    local entries = sortedIgnoreEntries()
    if not entries then
        ignoreWindow:Hide()
        return
    end

    local shown = math.min(#entries, self.MAX_IGNORE_ROWS)

    for index = 1, shown do
        local row = rowFor(index)
        local entry = entries[index]

        row.frame.__itemID = entry.itemID
        row.frame:Show()

        if row.name then
            local name = (type(entry.name) == "string" and entry.name ~= "")
                and entry.name or "(name not recorded)"

            row.name:SetText(tostring(entry.itemID) .. " - " .. name)
        end
    end

    for index = shown + 1, #ignoreRows do
        ignoreRows[index].frame:Hide()
    end

    if ignoreWindow.__empty then
        if #entries == 0 then
            ignoreWindow.__empty:Show()
        else
            ignoreWindow.__empty:Hide()
        end
    end

    local rest = #entries - shown

    if ignoreWindow.__footer then
        local text = "/lt drop forget <id> removes one from chat; /lt drop print lists the ids."

        if rest > 0 then
            text = tostring(rest) .. " more are not shown; /lt drop print lists every one."
        end

        ignoreWindow.__footer:SetText(text)
        ignoreWindow.__footer:ClearAllPoints()
        ignoreWindow.__footer:SetPoint("TOPLEFT", WINDOW_PAD,
            -(WINDOW_HEAD + math.max(shown, 1) * WINDOW_ROW + 4))
    end

    ignoreWindow:SetHeight(WINDOW_PAD + WINDOW_HEAD
        + math.max(shown, 1) * WINDOW_ROW + WINDOW_TAIL)
end

-- /lt drop list: the account-wide ignore list, in its own window.
function DropHint:ShowIgnoreList()
    if not ignoreList() then
        LT:Error("The saved ignore list is unavailable.")
        return
    end

    local window = ignoreWindow

    if not window then
        -- Building the window means creating frames, which combat refuses. The
        -- list still answers in chat rather than the command doing nothing.
        if inCombatNow() then
            LT:Print("The ignored list window cannot be built in combat; the list is printed here instead.")
            self:PrintIgnoreList()
            return
        end

        window = buildIgnoreWindow()
    end

    if not window then
        -- A client that will not give us a frame still gets the answer in chat.
        self:PrintIgnoreList()
        return
    end

    self:RefreshIgnoreWindow()
    window:Show()
end

------------------------------------------------------------------------------
-- Keeping the marker in step
------------------------------------------------------------------------------

-- The poll. The bags redraw through FrameXML functions this file would rather not
-- hook, so the marker is kept in step by looking four times a second -- but only
-- while a bag frame is on screen. The OnUpdate script is removed the moment the
-- bags close and put back when one opens, so a closed bag costs nothing at all,
-- not even an empty callback.
local TICK_SECONDS = 0.25

local driver        -- the frame that owns the events and the poll
local tickerOn = false
local elapsedTotal = 0
local wakers = {}   -- one hidden child of each bag frame, so an opening bag arms the poll

local function stopTicker()
    if not tickerOn or not driver then return end

    if type(driver.SetScript) == "function" then
        pcall(driver.SetScript, driver, "OnUpdate", nil)
    end

    tickerOn = false
    elapsedTotal = 0
end

-- The bags going away takes the poll out of the client entirely, not just out of
-- its work: the markers come down, the flag is armed for the next open, and the
-- OnUpdate script is removed.
local function idlePoll()
    if bagsShown() then return end

    -- Unconditional: the sweep inside clearMarkers takes down an overlay the
    -- `marked` table has already forgotten, which is the case this guards.
    clearMarkers()

    -- The bags are gone: the next opening asks GearCheck once more rather than
    -- trusting an arrow gathered while items were moving.
    invalidateUpgradeScan()
    freeSlotsSeen = nil
    needsRefresh = true
    stopTicker()
end

local function tick(_, elapsed)
    elapsedTotal = elapsedTotal + (tonumber(elapsed) or 0)
    if elapsedTotal < TICK_SECONDS then return end
    elapsedTotal = 0

    if not bagsShown() then
        idlePoll()
        return
    end

    -- Nothing is built or marked during a fight; the flag stays set, so the
    -- first tick after PLAYER_REGEN_ENABLED draws what combat refused.
    if inCombatNow() then return end

    -- A junk sale armed but not confirmed inside its window disarms itself.
    if bagArmed and nowSeconds() - bagArmedAt > DropHint.ARM_SECONDS then
        disarmJunk()
    end

    -- The stale sweep runs on every tick, not only when BAG_UPDATE fires. A
    -- slot the client emptied without an event (player report E8: a marker left
    -- on an empty slot) must lose its marker within one tick; this walks only
    -- the buttons this file marked, so a tick with nothing stale costs one link
    -- read per marker. A cleared marker means the answer changed, so it asks for
    -- the redraw below in the same tick.
    if clearStaleMarkers() then needsRefresh = true end

    -- Free space is the other half of the destroy rule: one stack leaving or
    -- joining the bags changes whether an X is allowed at all, and the client
    -- does not promise an event this file listens to for every such change.
    local free = DropHint.FreeBagSlots()
    if free ~= freeSlotsSeen then
        freeSlotsSeen = free
        needsRefresh = true
    end

    -- The merchant row is checked against the bags every tick as well: a sale
    -- can empty its slot without a painter call from the plugin.
    if vendorRow ~= nil and not rowStillInBags(vendorRow) then
        vendorRow = nil
        needsRefresh = true
    end

    -- Only a bag event, a bag opening or a change asks for a rescan. A tick with
    -- the flag clear costs the sweep and the free-slot count above.
    if needsRefresh then DropHint:RefreshMarkers() end
end

local function startTicker()
    if tickerOn or not driver then return end
    if type(driver.SetScript) ~= "function" then return end
    if not bagsShown() then return end

    tickerOn = pcall(driver.SetScript, driver, "OnUpdate", tick)
    elapsedTotal = 0
end

-- A child of a shown frame is itself shown, and Show reaches its children, so an
-- OnShow here fires when the player opens that bag and not before. That is what
-- arms the poll without polling: the bag frames themselves are the signal.
--
-- Each waker is a frame parented to a Blizzard frame, so a fight refuses the
-- whole loop; PLAYER_REGEN_ENABLED runs ensureWakers() again from the event
-- handler and the wakers missing from the fight are built there.
local function ensureWakers()
    if inCombatNow() then return end

    local parents = {}

    -- Combined bags (Forever) is a single frame, not one per bag.
    local combined = _G.ContainerFrameCombinedBags
    if type(combined) == "table" then parents[#parents + 1] = combined end

    local lastBag = tonumber(NUM_BAG_SLOTS) or 4
    for bag = 0, lastBag do
        local parent = containerFrameFor(bag)
        if type(parent) == "table" then parents[#parents + 1] = parent end
    end

    for _, parent in ipairs(parents) do
        if not wakers[parent] then
            local ok, waker = pcall(CreateFrame, "Frame", nil, parent)

            if ok and type(waker) == "table" then
                wakers[parent] = waker
                pcall(waker.SetScript, waker, "OnShow", function() startTicker() end)
                -- The same signal in reverse: the last bag closing stops the poll
                -- there and then instead of a tick later.
                pcall(waker.SetScript, waker, "OnHide", function() idlePoll() end)
            end
        end
    end
end

-- The whole draw: which marker wins each slot and the count on the button.
-- Called by the poll and after every change.
function DropHint:RefreshMarkers()
    needsRefresh = false

    -- Overlay frames and buttons are all built in here, so a fight refuses the
    -- whole draw and the flag goes back up for the first tick after it ends.
    if inCombatNow() then
        needsRefresh = true
        return
    end

    -- The switch says a replacement addon owns the bag frames: take down any
    -- mark this file drew earlier and draw none now. The addon's own Sort /
    -- Sell junk button is not an item mark, so it still gets its label. Nothing
    -- is hidden from the player silently - the first skipped draw says so once.
    if handBagsToReplacement() then
        clearMarkers()
        freeSlotsSeen = DropHint.FreeBagSlots()

        if not replacementNoticed then
            replacementNoticed = true
            if type(LT.Print) == "function" then
                pcall(LT.Print, LT, "bag frames are left to the replacement addon "
                    .. "(bag frames = replacement) — no bag marks are drawn")
            end
        end

        if type(self.UpdateBagButtons) == "function" then
            pcall(self.UpdateBagButtons, self)
        end
        return
    end

    -- A provider can ask for a draw from inside a draw: registering the vendor
    -- painter refreshes the plugin, which calls back here. Remember the request
    -- and let the outer draw finish instead of re-entering it.
    if refreshing then
        needsRefresh = true
        return
    end

    refreshing = true

    local ok, err = pcall(function()
        ensureWakers()
        clearMarkers()

        if not bagsShown() then return end

        -- The scan is one per opening and is asked for before the vendor hook,
        -- so the plugin's own call to GearCheck finds the cache already warm.
        -- The arrow on a bag item is a marker, not a window: the option's own
        -- help says it is drawn either way. Gating the scan on the option meant
        -- no arrow was ever drawn with the option off (its default), which is
        -- exactly what the player saw on 2026-11-05. The scan is one per bag
        -- opening and cached, so drawing the arrow costs nothing extra.
        ensureUpgradeScan()
        ensureVendorHook()
        ensureJunkPainter()

        -- One walk of the virtualised combined-bags frame per draw; the loop
        -- below reads the resulting (bag, slot) map.
        collectCombinedButtons()

        local rows = self:Scan()
        if not rows then return end

        local cheapest = DropHint.Rank(rows, ignoreList(), 1).cheapest

        -- The destroy hint is a full-bags answer. With even one free slot
        -- (more than DESTROY_AT_FREE_SLOTS, which is 0) there is room for the
        -- next drop, so nothing is marked for destroying -- the rule is asked
        -- once per draw, and an unreadable count (nil) keeps the hint off.
        local freeSlots = DropHint.FreeBagSlots()
        freeSlotsSeen = freeSlots
        triageAllowed = DropHint.ShouldOfferDestroy(freeSlots)
        triageBag = triageAllowed and cheapest and cheapest.bag or nil
        triageSlot = triageAllowed and cheapest and cheapest.slot or nil
        triageLink = triageAllowed and cheapest and cheapest.link or nil

        -- One button, one marker: the registry picks the winner for the slot.
        -- The walk follows the slots rather than only the rows, because a slot
        -- the scan no longer finds holds no link: any marker still drawn there
        -- is taken down here. That is the border left on an emptied bag slot
        -- after a destroy (E8), and it is why `marked` is never the only record
        -- of what is on screen.
        local bySlot = {}
        for _, row in ipairs(rows) do
            local slots = bySlot[row.bag]
            if not slots then
                slots = {}
                bySlot[row.bag] = slots
            end

            slots[row.slot] = row
        end

        local api = containerAPI()
        local lastBag = tonumber(NUM_BAG_SLOTS) or 4

        for bag = 0, lastBag do
            local bagRows = bySlot[bag] or {}
            local slots = 0

            if api then
                local okSlots, count = pcall(api.slots, bag)
                slots = okSlots and tonumber(count) or 0
            end

            -- Without the client's slot count the rows are the only slots this
            -- draw can name; they still get their markers.
            if slots < 1 then
                for slot in pairs(bagRows) do
                    if slot > slots then slots = slot end
                end
            end

            for slot = 1, slots do
                local button = itemButton(bag, slot)
                local row = bagRows[slot]
                local result

                if button and row then
                    local shown = type(button.IsShown) ~= "function" or button:IsShown()

                    -- resolveOverlay re-reads the slot and refuses a row whose
                    -- link is no longer there. The verified link is what the
                    -- providers see, never the row's remembered one.
                    if shown then result = resolveOverlay(row) end
                end

                if button then
                    if result and applyMarker(button, result, row) then
                        marked[button] = true
                    else
                        -- No row, no verified link, or no provider answer:
                        -- nothing may stay drawn on this slot, in this same
                        -- draw, not at the next event (E8).
                        clearMark(button)
                        marked[button] = nil
                    end
                end
            end
        end

        self:UpdateBagButtons()
    end)

    refreshing = false

    if not ok then
        needsRefresh = true

        if type(LT.Debug) == "function" then
            pcall(LT.Debug, LT, "drop hint: the marker draw failed: " .. tostring(err))
        end
    end
end

-- One place that answers "the ignore list just changed": the marker moves, the
-- count changes, and the window redraws if it is open.
function DropHint:Changed()
    needsRefresh = true

    -- Arms the poll when the bags are open; startTicker does nothing otherwise.
    startTicker()

    if inCombatNow() then
        -- An overlay or a button waits for the fight to end; the flag and the
        -- poll keep the work for the tick that follows it.
        return
    end

    if bagsShown() then
        self:RefreshMarkers()
    else
        self:UpdateBagButtons()
    end

    if ignoreWindow and type(ignoreWindow.IsShown) == "function" and ignoreWindow:IsShown() then
        self:RefreshIgnoreWindow()
    end
end

function DropHint:Initialize()
    if driver then return end

    local frame = CreateFrame("Frame")
    driver = frame

    -- BAG_UPDATE fires for every slot write. A destroy or a sale shows up here
    -- first, so the answer is settled here too: a marker whose item has left
    -- its slot is taken down, the free-slot count is compared, and the
    -- remembered vendor row is re-read. Any change asks for the draw in this
    -- same event instead of waiting for DELAYED or the next tick.
    for _, event in ipairs({ "BAG_UPDATE", "BAG_UPDATE_DELAYED", "BAG_OPEN", "BAG_CLOSED",
        "MERCHANT_SHOW", "MERCHANT_CLOSED",
        "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
        "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT" }) do
        -- An event this client does not know must not stop the add-on loading.
        pcall(frame.RegisterEvent, frame, event)
    end

    -- Every bag event, a bag opening and the end of a fight mean the same thing
    -- here: the answer may have changed. Item prices arrive after login, which
    -- is why an item-data event lands in the same place instead of having a
    -- path of its own.
    frame:SetScript("OnEvent", function(_, event)
        if event == "BAG_UPDATE" then
            local changed = clearStaleMarkers()

            local free = DropHint.FreeBagSlots()
            if free ~= freeSlotsSeen then
                freeSlotsSeen = free
                changed = true
            end

            if vendorRow ~= nil and not rowStillInBags(vendorRow) then
                vendorRow = nil
                changed = true
            end

            if changed then
                needsRefresh = true
                startTicker()

                -- Out of combat and with a bag on screen, redraw now so the
                -- emptied slot is clear before the event returns. In combat or
                -- with the bags closed the flag and the tick carry it over.
                if not inCombatNow() and bagsShown()
                    and type(DropHint.RefreshMarkers) == "function" then
                    pcall(DropHint.RefreshMarkers, DropHint)
                end
            end

            return
        end

        needsRefresh = true

        -- Item data arriving after login can turn an "unreadable" first scan
        -- into a real one. The upgrade scan is one-shot per bag opening, so it
        -- must be released here rather than wait for the bags to close.
        if event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
            invalidateUpgradeScan()
        end

        -- BAG_UPDATE_DELAYED is the client saying the bags have settled. Every
        -- marker comes down here and the next draw resolves them again from the
        -- providers, so a marker can never outlive the item it named. The last
        -- bag closing makes the same promise.
        if event == "BAG_UPDATE_DELAYED" then
            clearMarkers()
            if vendorRow ~= nil and not rowStillInBags(vendorRow) then
                vendorRow = nil
            end
        elseif event == "BAG_CLOSED" and not bagsShown() then
            clearMarkers()
            disarmJunk()
        elseif event == "MERCHANT_CLOSED" then
            -- No merchant, no gold answer: the row is dropped here even if the
            -- plugin's own event has not reached its painter yet. An armed junk
            -- sale belongs to the counter that just closed, so it ends here.
            vendorRow = nil
            disarmJunk()
        end

        -- A fight can refuse a click but cannot take back a sale: arming ends
        -- with the first lockout. The merchant button relabels at once when a
        -- merchant opens, without waiting for a tick.
        if event == "PLAYER_REGEN_DISABLED" then
            disarmJunk()
        elseif event == "MERCHANT_SHOW" and not inCombatNow() then
            DropHint:UpdateBagButtons()
        end

        ensureWakers()

        if bagsShown() then
            startTicker()
        elseif event == "BAG_CLOSED" then
            idlePoll()
        end

        -- The remembered merchant row is gone, so the coin must leave now
        -- rather than at the next tick.
        if event == "MERCHANT_CLOSED" and bagsShown() and not inCombatNow() then
            DropHint:RefreshMarkers()
        end

        -- The end of a fight rebuilds what combat refused, without waiting a
        -- tick: the wakers are the ensureWakers() call above, which was refused
        -- while the fight lasted, and the bag buttons come back through Changed
        -- (RefreshMarkers while a bag is open, UpdateBagButtons otherwise).
        if event == "PLAYER_REGEN_ENABLED" then DropHint:Changed() end
    end)

    -- The Forever client signals bag open/close through EventRegistry callbacks
    -- ("ContainerFrame.OpenBag" / "CloseBag"), not BAG_OPEN/BAG_CLOSED. Mirror
    -- the event handler's bag-open path so the scan and markers run on open.
    -- RegisterCallback is a method: (callbackID, callback, owner).
    if type(EventRegistry) == "table" and type(EventRegistry.RegisterCallback) == "function" then
        pcall(EventRegistry.RegisterCallback, EventRegistry, "ContainerFrame.OpenBag", function()
            needsRefresh = true
            ensureWakers()
            if bagsShown() then startTicker() end
            if not inCombatNow() and bagsShown()
                and type(DropHint.RefreshMarkers) == "function" then
                pcall(DropHint.RefreshMarkers, DropHint)
            end
        end, DropHint)
        pcall(EventRegistry.RegisterCallback, EventRegistry, "ContainerFrame.CloseBag", function()
            needsRefresh = true
            if not bagsShown() then idlePoll() end
        end, DropHint)
    end

    ensureWakers()
    if bagsShown() then startTicker() end

    -- The vendor helper is a separate addon loaded after this file, so this is
    -- the first moment both are present. Registration is also retried from the
    -- draw, which picks up a plugin loaded after this addon.
    ensureVendorHook()
    ensureJunkPainter()
end

function DropHint:Command(words)
    local action = type(words) == "table" and words[2] and string.lower(words[2]) or nil

    if action == nil or action == "now" then return self:PrintSuggestions(self.MAX_LISTED) end
    if action == "all" then return self:PrintAll() end
    if action == "ignore" then return self:AddIgnore(words) end
    if action == "forget" or action == "unignore" then return self:RemoveIgnore(words) end
    if action == "list" or action == "ignored" then return self:ShowIgnoreList() end
    if action == "print" then return self:PrintIgnoreList() end

    -- Debug: force the bag-marker draw.
    if action == "markers" then
        self:RefreshMarkers()
        return
    end

    LT:Print("Unknown option \"" .. tostring(action)
        .. "\". /lt drop, /lt drop all, /lt drop ignore [item], /lt drop forget <id>, "
        .. "/lt drop list, /lt drop print.")
end