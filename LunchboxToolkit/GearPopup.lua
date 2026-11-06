--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — GearPopup
    The visible half of the gear check: one window listing what in the bags is
    wearable now and what a level will unlock, the same list as text for
    /lt scan, and the small bank prompt that asks before the bank is read.

    Everything shown comes from GearCheck:Scan, which returns plain rows. This
    file decides order, wording and layout and nothing else: it never equips,
    sells or moves an item. A row's only action is to put its link in chat, and
    a hover's only action is the client's own item tooltip.

    Frames are built on the first open and only outside combat. Once built, the
    window is shown, hidden, moved and rewritten — so a fight that starts while
    it is open cannot ask the client to create anything.

    No frame has a name, because a named frame is a new global and this file
    adds exactly one: LT.GearPopup. The cost is that Escape does not close it;
    every window here has a Close button and the main window's header button.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local GearPopup = {}
LT.GearPopup = GearPopup
LT.Modules = LT.Modules or {}
LT.Modules.GearPopup = GearPopup

GearPopup.CHAT_LIMIT = 25
GearPopup.WIDTH      = 560
GearPopup.PADDING    = 16

-- The gear-check options are owned by Database.defaultOptions(); this file
-- keeps no second copy of their values. The table below is a live view, not a
-- snapshot: reading a key asks the real defaults table, so a default changed in
-- one place cannot drift from the other. When that module is absent (or an
-- offline harness) each key falls back to the value it ships with — never to a
-- blanket "true", which would switch the opt-in bag check on in a client that
-- could not answer.
GearPopup.SHIPPED_OPTIONS = {
    gearCheckOnBagOpen  = false,
    gearCheckOnLevel    = true,
    gearCheckBankPrompt = true,
    trainerHint         = true,
}

GearPopup.OPTION_DEFAULTS = setmetatable({}, {
    __index = function(_, key)
        local database = LT.Database
        if type(database) == "table" and type(database.defaultOptions) == "function" then
            local ok, defaults = pcall(database.defaultOptions)
            if ok and type(defaults) == "table" and defaults[key] ~= nil then
                return defaults[key]
            end
        end
        return GearPopup.SHIPPED_OPTIONS[key]
    end,
})

-- Why a scan could not answer, in the words the player reads. The keys are
-- GearCheck's own reason strings; an unknown one is still reported rather than
-- swallowed.
GearPopup.reasons = {
    combat              = "The gear check cannot run in combat.",
    empty               = "No upgrades in the bags right now.",
    emptyBank           = "Nothing in the bank or the bags beats what you are wearing.",
    ["no-gear-check"]   = "The gear check module is not loaded, so the bags cannot be read.",
    ["no-item-stats"]   = "The item stats module is not loaded, so items cannot be read.",
    ["no-usability"]    = "The usability module is not loaded, so items cannot be judged.",
    ["no-compare"]      = "The comparison module is not loaded, so upgrades cannot be ranked.",
    ["no-container-api"] = "This client exposes no bag API, so the bags cannot be read.",
}

function GearPopup:ReasonText(reason)
    local key = tostring(reason or "")
    return self.reasons[key] or ("The gear check could not run (" .. key .. ").")
end

-- Which containers the last bank scan read, in the words the player reads. The
-- route is decided by GearCheck (purchased bank tabs first, the legacy bag list
-- second), so this text and the scan can never disagree; nil when no bank was
-- read.
GearPopup.BANK_ROUTES = {
    ["bank-tabs"] = "bank tabs",
    ["bank-bags"] = "bank bags",
}

function GearPopup:BankRouteText(result)
    local route = type(result) == "table" and result.bankRoute or nil
    return self.BANK_ROUTES[route]
end

------------------------------------------------------------------------------
-- Palette and measurements
--
-- Every colour is read from Palette at call time, so this file cannot drift
-- from the legend. Both helpers degrade to plain text and white rather than
-- erroring on a client where the palette did not load.
------------------------------------------------------------------------------

local function wrap(key, text)
    local palette = LT.Palette
    if type(palette) == "table" and type(palette.Wrap) == "function" then
        local ok, value = pcall(palette.Wrap, palette, key, text)
        if ok and type(value) == "string" then return value end
    end
    return tostring(text)
end

local function rgb(key)
    local palette = LT.Palette
    if type(palette) == "table" and type(palette.RGB) == "function" then
        local ok, colour = pcall(palette.RGB, palette, key)
        if ok and type(colour) == "table" then return colour end
    end
    return { r = 1, g = 1, b = 1 }
end

-- Font strings are the only honest source for a height: a client with a taller
-- font gets a taller row instead of text landing on the next line. The
-- fallback only covers a font string that cannot answer at all.
local function textHeight(fontString, fallback)
    if fontString and type(fontString.GetStringHeight) == "function" then
        local ok, height = pcall(fontString.GetStringHeight, fontString)
        if ok and type(height) == "number" and height > 0 then return height end
    end
    return fallback or 12
end

local function ui()
    local module = LT.UI
    if type(module) == "table" and type(module.MakeLabel) == "function"
        and type(module.MakeButton) == "function" then
        return module
    end
    return nil
end

------------------------------------------------------------------------------
-- Client state, read through guards
------------------------------------------------------------------------------

function GearPopup:CombatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

-- This character's stored value when it is a boolean; otherwise the default,
-- which OPTION_DEFAULTS resolves from Database.defaultOptions() at read time.
function GearPopup:Option(key)
    local fallback = self.OPTION_DEFAULTS[key] == true

    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return fallback
    end

    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then return fallback end

    local value = options[key]
    if type(value) ~= "boolean" then return fallback end
    return value
end

local function activeIndex()
    local builds = LT.Builds
    if type(builds) ~= "table" or type(builds.GetActiveIndex) ~= "function" then
        return 1
    end

    local ok, index = pcall(builds.GetActiveIndex, builds)
    if ok and tonumber(index) then return tonumber(index) end
    return 1
end

local function scoringLevel()
    local levels = LT.Levels
    if type(levels) == "table" and type(levels.GetScoringLevel) == "function" then
        local ok, level = pcall(levels.GetScoringLevel, levels)
        if ok and tonumber(level) then return tonumber(level) end
    end

    local stored = LT.player and tonumber(LT.player.level)
    return stored or 0
end

------------------------------------------------------------------------------
-- The list itself (pure)
--
-- These four functions take plain tables and return plain tables and strings,
-- so the offline harness drives exactly the code the client drives.
------------------------------------------------------------------------------

-- now rows first, then soon rows, each tagged with its group and with `bank`
-- when the row came from the bank walk. Anything that is not a table is
-- skipped rather than trusted.
function GearPopup:Classify(result)
    local entries = {}
    if type(result) ~= "table" then return entries end

    for _, group in ipairs({ "now", "soon" }) do
        local rows = result[group]

        if type(rows) == "table" then
            for index = 1, #rows do
                local row = rows[index]
                if type(row) == "table" then
                    entries[#entries + 1] = {
                        group = group,
                        row   = row,
                        bank  = row.source == "bank",
                    }
                end
            end
        end
    end

    return entries
end

-- The first `limit` entries, and how many were left out.
function GearPopup:Limit(entries, limit)
    local list = type(entries) == "table" and entries or {}
    local maximum = tonumber(limit) or self.CHAT_LIMIT
    if maximum < 0 then maximum = 0 end

    local shown = {}
    for index = 1, math.min(#list, maximum) do
        shown[index] = list[index]
    end

    return shown, math.max(0, #list - maximum)
end

local function slotLabel(row)
    local stated = row.slotLabel
    if type(stated) == "string" and stated ~= "" then return stated end

    local itemStats = LT.ItemStats
    if type(itemStats) == "table" and type(itemStats.GetSlotLabel) == "function" then
        local ok, label = pcall(itemStats.GetSlotLabel, itemStats, row.slot)
        if ok and type(label) == "string" and label ~= "" then return label end
    end

    return "Slot " .. tostring(row.slot)
end

-- "Chest: +12.4 (now 40.1 → 52.5)", with "bank · " in front for a bank row and
-- "at level 40" after a row that is only waiting for a level. The delta carries
-- the palette's verdict: purple for wearable now, green for not yet.
function GearPopup:DescribeRow(row, group)
    if type(row) ~= "table" then return "" end

    local text = ""
    if row.package then
        -- Two items in one answer. Saying "two items" and "wear both" is the
        -- difference between a package and a single slot swap.
        text = wrap("muted", "two items") .. " · "
    elseif row.source == "bank" then
        text = wrap("muted", "bank") .. " · "
    end

    text = text .. wrap("muted", slotLabel(row)) .. ": "

    local delta = tonumber(row.delta)
    local score = tonumber(row.score)
    local verdict = (group == "soon") and "caution" or "go"

    if delta then
        if delta == 0 and row.emptySlot then
            text = text .. wrap(verdict, "fills an empty slot")
        else
            text = text .. wrap(verdict, LT:FormatSigned(delta, 1))
        end
    else
        text = text .. wrap("unknown", "no score")
    end

    if delta and score and not (delta == 0 and row.emptySlot) then
        text = text .. " " .. wrap("muted", "(now "
            .. LT:FormatNumber(score - delta, 1) .. " → " .. LT:FormatNumber(score, 1) .. ")")
    end

    local required = tonumber(row.requiredLevel)
    if group == "soon" and required then
        text = text .. " " .. wrap("caution", "at level " .. tostring(required))
    end

    return text
end

-- Worn total plus the deltas of the rows the character can wear now. A "soon"
-- row is deliberately left out: it needs a level first, so it cannot be part of
-- "with these". Returns the projected total and how many rows it counted.
function GearPopup:ProjectedTotal(worn, entries)
    local total = tonumber(worn)
    if not total then return nil, 0 end

    -- One slot can be headlined more than once (two rings, two trinkets), so the
    -- projection takes the best row per slot. Summing every row would count the
    -- same worn item twice and overstate "with these".
    local best = {}
    for index = 1, #(entries or {}) do
        local entry = entries[index]
        if type(entry) == "table" and entry.group == "now" then
            local row = entry.row
            local delta = type(row) == "table" and tonumber(row.delta) or nil
            if delta then
                local slot = type(row) == "table" and row.slot or nil
                local key = slot and tostring(slot) or ("#" .. tostring(index))
                if not best[key] or delta > best[key] then best[key] = delta end
            end
        end
    end

    local count = 0
    for _, delta in pairs(best) do
        total = total + delta
        count = count + 1
    end

    return total, count
end

------------------------------------------------------------------------------
-- Sums the worn items through the same scorer GearSets uses, so the total on
-- the Equipment page and a saved set's total are the same arithmetic.
------------------------------------------------------------------------------

function GearPopup:WornTotal(buildIndex)
    local gearSets = LT.GearSets
    local score = LT.Score
    local slots = LT.InventorySlots

    if type(gearSets) ~= "table" or type(gearSets.GetEquippedLink) ~= "function" then
        return nil
    end
    if type(score) ~= "table" or type(slots) ~= "table" then return nil end

    local scorer = score.ScoreItemWithImbue or score.ScoreItem
    if type(scorer) ~= "function" then return nil end

    local total, counted = 0, 0

    for _, slot in ipairs(slots) do
        local okLink, link = pcall(gearSets.GetEquippedLink, gearSets, slot.slot)

        if okLink and type(link) == "string" and link ~= "" and not LT:IsSecret(link) then
            local okScore, result = pcall(scorer, score, link, buildIndex)

            if okScore and type(result) == "table" and result.ok
                and tonumber(result.score) then
                total = total + tonumber(result.score)
                counted = counted + 1
            end
        end
    end

    if counted == 0 then return nil end
    return total, counted
end

------------------------------------------------------------------------------
-- Scanning
------------------------------------------------------------------------------

-- GearCheck refuses in combat and names what is missing. Both become one
-- sentence instead of an error, and a refused scan never reaches a frame.
function GearPopup:Scan(opts)
    local gearCheck = LT.GearCheck
    if type(gearCheck) ~= "table" or type(gearCheck.Scan) ~= "function" then
        return nil, self:ReasonText("no-gear-check")
    end

    local ok, result = pcall(gearCheck.Scan, gearCheck, opts or {})
    if not ok or type(result) ~= "table" then
        return nil, "The gear check could not run."
    end

    if result.reason then return nil, self:ReasonText(result.reason) end
    return result
end

------------------------------------------------------------------------------
-- The Equipment line, computed once per (build, level, revision)
--
-- UI:Refresh redraws the page on every event and asks for this line each time.
-- Recomputing it rescores all 19 worn items through the scorer, so the answer
-- is kept until something it was made from changes. The revision is GearCheck's
-- own cache key: that module already bumps it on level, build, profile,
-- gear-set, equipment and bag changes, so this file adds no listener of its own
-- and cannot disagree with the scan it is added to.
------------------------------------------------------------------------------

GearPopup.SUMMARY_CACHE_LIMIT = 8   -- one line per build slot, per revision seen
GearPopup.summaryCache = {}         -- key -> line; false means "computed, no line"

local summaryOrder = {}             -- keys in insertion order, oldest first

-- A revision bump makes every old key unreachable (the new key carries the new
-- revision), so stale lines only need to age out, not be swept: the table is
-- capped and the oldest entries go first.
local function storeSummary(key, line)
    if GearPopup.summaryCache[key] == nil then
        summaryOrder[#summaryOrder + 1] = key
    end

    GearPopup.summaryCache[key] = line

    while #summaryOrder > GearPopup.SUMMARY_CACHE_LIMIT do
        local oldest = table.remove(summaryOrder, 1)
        GearPopup.summaryCache[oldest] = nil
    end
end

-- The pure part: one string names one answer. Exposed so the offline harness
-- builds exactly the key the client builds.
function GearPopup:SummaryKey(buildIndex, level, revision)
    if revision == nil then return nil end
    return tostring(buildIndex) .. "|" .. tostring(level) .. "|" .. tostring(revision)
end

-- The revision, or nil when no module can supply one. nil means "compute every
-- time": with no invalidation source a cached line could outlive the gear it
-- describes, and a stale number is worse than a repeated computation.
function GearPopup:SummaryRevision(buildIndex, level)
    local gearCheck = LT.GearCheck
    if type(gearCheck) ~= "table" or type(gearCheck.Key) ~= "function" then return nil end

    local ok, revision = pcall(gearCheck.Key, gearCheck, buildIndex, level)
    if ok and type(revision) == "string" and revision ~= "" then return revision end
    return nil
end

-- Worn total plus the scan's deltas, as the line the page shows. Never cached
-- by itself; SummaryLine owns the cache.
function GearPopup:BuildSummaryLine(buildIndex)
    local worn = self:WornTotal(buildIndex)
    if not worn then return nil end

    local result = self:Scan({ buildIndex = buildIndex })
    local entries = self:Classify(result)
    local total, count = self:ProjectedTotal(worn, entries)

    local wornText = LT:FormatNumber(worn, 1)

    if count > 0 and total then
        return wornText .. wrap("muted", " worn · ")
            .. wrap("go", LT:FormatNumber(total, 1) .. " with these " .. tostring(count))
    end

    return wornText .. " worn"
end

-- The one line under the Equipment page heading: "412.3 worn · 458.9 with
-- these 4". Worn is recomputed from the worn items; the upgrade total is that
-- plus the deltas of the rows the character can wear now. With no such rows the
-- line is the worn total alone, because "with these 0" says nothing. A key that
-- repeats answers from the cache; a new level or revision produces a new key,
-- so the old line can never be served.
function GearPopup:SummaryLine(buildIndex)
    local index = tonumber(buildIndex) or activeIndex()
    local level = scoringLevel()
    local key = self:SummaryKey(index, level, self:SummaryRevision(index, level))

    if key then
        local hit = self.summaryCache[key]
        if hit ~= nil then
            if hit == false then return nil end
            return hit
        end
    end

    local line = self:BuildSummaryLine(index)
    if key then storeSummary(key, line or false) end
    return line
end

------------------------------------------------------------------------------
-- Chat: /lt scan
------------------------------------------------------------------------------

-- Rows first, then one count line. At most CHAT_LIMIT rows, so a full bank
-- cannot scroll the answer away; the count line always says how many there are.
function GearPopup:PrintList(opts)
    local result, refusal = self:Scan(opts or {})
    if not result then
        LT:Warn(refusal)
        return 0
    end

    local entries = self:Classify(result)

    if #entries == 0 then
        LT:Print(self:ReasonText("empty"))
        return 0
    end

    local nowCount, soonCount, bankCount = 0, 0, 0
    for index = 1, #entries do
        local entry = entries[index]
        if entry.group == "soon" then
            soonCount = soonCount + 1
        else
            nowCount = nowCount + 1
        end
        if entry.bank then bankCount = bankCount + 1 end
    end

    local shown, overflow = self:Limit(entries, self.CHAT_LIMIT)

    for index = 1, #shown do
        local entry = shown[index]
        local row = entry.row
        local prefix = row.link or row.name or "item"
        LT:Print(tostring(prefix) .. "  " .. self:DescribeRow(row, entry.group))
    end

    local summary = tostring(nowCount) .. " wearable now, " .. tostring(soonCount) .. " soon"
    if bankCount > 0 then
        summary = summary .. ", " .. tostring(bankCount) .. " in the bank"
        local route = self:BankRouteText(result)
        if route then summary = summary .. " (" .. route .. ")" end
    end

    if overflow > 0 then
        LT:Print(tostring(#shown) .. " of " .. tostring(#entries) .. " upgrades shown — "
            .. summary .. ".")
    else
        LT:Print(tostring(#entries) .. " upgrade" .. (#entries == 1 and "" or "s")
            .. ": " .. summary .. ".")
    end

    return #shown
end

------------------------------------------------------------------------------
-- Remembered place
--
-- The popup stores its corner as a fraction of the UI area in the character
-- record, beside the main window's own place, so a resolution change lands in
-- the same relative spot. The fraction is clamped on every open.
------------------------------------------------------------------------------

local function windowRecord()
    local database = LT.Database
    if type(database) ~= "table" or type(database.Get) ~= "function" then return nil end

    local ok, character = pcall(database.Get, database)
    if not ok or type(character) ~= "table" then return nil end

    if type(character.window) ~= "table" then character.window = {} end
    return character.window
end

local function screenSize()
    if not UIParent or type(UIParent.GetWidth) ~= "function" then return 0, 0 end

    local okWidth, width = pcall(UIParent.GetWidth, UIParent)
    local okHeight, height = pcall(UIParent.GetHeight, UIParent)

    width = okWidth and tonumber(width) or 0
    height = okHeight and tonumber(height) or 0

    return width, height
end

------------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------------

local frame
local titleLabel, contextLabel, overflowLabel
local rows = {}
local rowHeight = 0
local hasContent = false

local function hideRows()
    for index = 1, #rows do
        local row = rows[index]
        row:Hide()
        row.link = nil
        row.slot = nil
        row.bound = nil
        row.nameLabel:SetText("")
        row.detailLabel:SetText("")
        row.icon:Hide()
    end
end

local function buildRow(index)
    if rows[index] then return rows[index] end
    if not frame then return nil end
    if GearPopup:CombatLocked() then return nil end

    local widgets = ui()
    if not widgets then return nil end

    local ok, created = pcall(CreateFrame, "Button", nil, frame)
    if not ok or not created then return nil end

    local row = created
    row:SetPoint("TOPLEFT", 0, 0)
    row:SetSize(GearPopup.WIDTH - (GearPopup.PADDING * 2), 18)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", 2, 0)
    icon:Hide()
    row.icon = icon

    local name = widgets:MakeLabel(row, "", "GameFontNormalSmall", rgb("text"))
    name:SetPoint("LEFT", 24, 0)
    name:SetWidth(180)
    name:SetJustifyH("LEFT")
    if name.SetWordWrap then pcall(name.SetWordWrap, name, false) end
    row.nameLabel = name

    local detail = widgets:MakeLabel(row, "", "GameFontNormalSmall", rgb("muted"))
    detail:SetPoint("LEFT", 210, 0)
    detail:SetWidth(GearPopup.WIDTH - (GearPopup.PADDING * 2) - 210)
    detail:SetJustifyH("LEFT")
    if detail.SetWordWrap then pcall(detail.SetWordWrap, detail, false) end
    row.detailLabel = detail

    row:SetScript("OnEnter", function(self)
        if self.link then
            local hover = rgb("brand")
            self.nameLabel:SetTextColor(hover.r, hover.g, hover.b)
            GearPopup:ShowItemTooltip(self, self.link)
        end
    end)

    row:SetScript("OnLeave", function(self)
        if self.link then
            local plain = rgb("text")
            self.nameLabel:SetTextColor(plain.r, plain.g, plain.b)
            GearPopup:HideItemTooltip()
        end
    end)

    row:SetScript("OnClick", function(self)
        if not self.link then return end

        -- A package row is two items; equipping one of them alone would be the
        -- wrong answer, so both links go to chat and the client does the swap.
        if self.extraLink then
            GearPopup:DropLink(self.link)
            GearPopup:DropLink(self.extraLink)
            LT:Print("Two items: the link pair is in chat; wear both in the client.")
            return
        end

        -- A soulbound item is safe to wear: taking it off loses nothing. Anything
        -- else keeps the old click, which puts the link in chat, and says why so
        -- the difference is visible rather than mysterious.
        if self.bound == true then
            local ok, why = GearPopup:Equip(self.link, self.slot, self.bagID, self.bagSlot)
            if ok then
                LT:Print("Equipped " .. tostring(self.nameLabel:GetText() or "the item") .. ".")
            else
                LT:Print("Could not equip: " .. tostring(why) .. ".")
            end
            if LT.UI and type(LT.UI.Refresh) == "function" then pcall(LT.UI.Refresh, LT.UI) end
            return
        end

        GearPopup:DropLink(self.link)
        if self.bound == false then
            LT:Print("Not equipped from here: this item would bind to you ("
                .. tostring(self.bindSource or "no source") .. "). "
                .. "The link is in chat; wear it in the client.")
        elseif self.bound == nil then
            LT:Print("Not equipped from here: the client did not say whether this item "
                .. "is bound (" .. tostring(self.bindSource or "no source") .. "). "
                .. "The link is in chat; wear it in the client.")
        end
    end)

    rows[index] = row
    return row
end

-- The client's own item tooltip, never a copy of it. SetHyperlink is the one
-- call that can refuse a link the client has not cached, so it decides whether
-- the tooltip is shown at all.
function GearPopup:ShowItemTooltip(owner, link)
    if not GameTooltip or type(GameTooltip.SetOwner) ~= "function" then return end
    if type(link) ~= "string" or link == "" then return end

    if not pcall(GameTooltip.SetOwner, GameTooltip, owner, "ANCHOR_RIGHT") then return end

    pcall(GameTooltip.ClearLines, GameTooltip)

    if not pcall(GameTooltip.SetHyperlink, GameTooltip, link) then
        pcall(GameTooltip.Hide, GameTooltip)
        return
    end

    pcall(GameTooltip.Show, GameTooltip)
end

function GearPopup:HideItemTooltip()
    if not GameTooltip then return end
    pcall(GameTooltip.Hide, GameTooltip)
end

-- The only action a row has: put its link where chat already understands it.
-- The one write this addon performs on the character, and it exists because the
-- player asked for it on two pages: Best setup and the Equipment upgrade list.
-- Nothing is moved, sold or destroyed - the replaced item stays in the bags - and
-- it refuses in combat, because the client refuses equipment changes mid-fight.
function GearPopup:Equip(link, slot, bagID, bagSlot)
    if type(InCombatLockdown) == "function" then
        local okLocked, locked = pcall(InCombatLockdown)
        if okLocked and locked == true then return false, "not while you are in combat" end
    end

    if type(link) ~= "string" or link == "" then return false, "no item to equip" end

    -- This client has no EquipItemByName (report 2026-11-05). Using the item from
    -- its own bag slot is the same action a right-click performs, and it is what
    -- the client actually exposes.
    local use = (type(C_Container) == "table" and C_Container.UseContainerItem) or UseContainerItem
    if type(bagID) == "number" and type(bagSlot) == "number" and type(use) == "function" then
        local okUse, err = pcall(use, bagID, bagSlot)
        if okUse then return true end
        if type(EquipItemByName) ~= "function" then return false, tostring(err) end
    end

    if type(EquipItemByName) ~= "function" then
        return false, "this client exposes neither a bag use nor EquipItemByName"
    end

    local ok, err = pcall(EquipItemByName, link, tonumber(slot) or nil)
    if not ok then return false, tostring(err) end
    return true
end

function GearPopup:DropLink(link)
    if type(link) ~= "string" or link == "" then return end

    local chat = DEFAULT_CHAT_FRAME
    if chat and type(chat.AddMessage) == "function" then
        local ok = pcall(chat.AddMessage, chat, link)
        if ok then return end
    end

    LT:Print(link)
end

local function iconFor(link)
    local itemStats = LT.ItemStats
    if type(itemStats) == "table" and type(itemStats.GetIdentity) == "function" then
        local ok, identity = pcall(itemStats.GetIdentity, itemStats, link)
        if ok and type(identity) == "table" and type(identity.texture) == "string"
            and identity.texture ~= "" then
            return identity.texture
        end
    end

    -- The identity route answers for an item the client has cached; this second
    -- route asks for the icon by link directly, so a row still draws art when the
    -- identity table is incomplete.
    if type(GetItemIcon) == "function" then
        local ok, texture = pcall(GetItemIcon, link)
        if ok and type(texture) == "string" and texture ~= "" then return texture end
    end

    return nil
end

-- Would equipping this item bind it? A soulbound item can be worn and taken off
-- again with nothing lost, so a click may equip it. Bind-on-equip is a decision
-- the player should make in the client, not by a mis-click here, so those keep
-- the old behaviour (the link goes to chat).
--
-- C_Item.IsBound wants a bag location this popup does not carry; the item's own
-- bind type answers instead: 1 = bind on pickup, 4 = quest bind. 2 bind on equip
-- and 3 bind on use are the two that would be changed by wearing it.
--
-- Both item-info calls return positional values (the bind type is the 14th), not
-- a table, so one reader takes whichever function is present.
local function bindStateFrom(getInfo, link)
    local ok, bind = pcall(function() return select(14, getInfo(link)) end)
    local number = ok and tonumber(bind) or nil
    if number then return number == 1 or number == 4 end
    return nil
end

-- The client can answer "is this bound" directly from the bag location, which is
-- the only reliable answer on Forever: the 14th return of GetItemInfo is a
-- modern-client field there, and a bound item was being read as unbound ("this
-- item would bind to you" on an item the player had worn before - report
-- 2026-11-05). Location first, then the tooltip's own words, then the old field.
local function bindStateFromLocation(bag, slot)
    if type(bag) ~= "number" or type(slot) ~= "number" then return nil end
    if type(C_Item) ~= "table" or type(C_Item.IsBound) ~= "function" then return nil end
    local ok, bound = pcall(C_Item.IsBound, { bagID = bag, slotIndex = slot })
    if ok and type(bound) == "boolean" then return bound end
    return nil
end

-- Pure: given a line reader, decide from the tooltip's own words. Kept separate
-- from GameTooltip so /lt test can exercise it without a character or an item.
-- Soulbound wins over a "Binds when …" line, because an item that has been worn
-- shows both "Binds when equipped" and "Soulbound".
function GearPopup.BindFromLines(reader)
    if type(reader) ~= "function" then return nil end

    local bound = nil
    for index = 1, 40 do
        local ok, text = pcall(reader, index)
        if not ok or type(text) ~= "string" or text == "" then break end

        if text:find("Soulbound", 1, true) then
            bound = true
        elseif bound == nil and (text:find("Binds when equipped", 1, true)
            or text:find("Binds when used", 1, true)
            or text:find("Binds when picked up", 1, true)) then
            bound = false
        end
    end

    return bound
end

local function bindStateFromTooltip(link)
    if type(GameTooltip) ~= "table" or type(GameTooltip.SetHyperlink) ~= "function" then
        return nil
    end
    local okLink = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
    if not okLink then return nil end

    local found = GearPopup.BindFromLines(function(index)
        local line = _G["GameTooltipTextLeft" .. tostring(index)]
        return line and line.GetText and line:GetText() or nil
    end)

    if GameTooltip.Hide then pcall(GameTooltip.Hide, GameTooltip) end
    return found
end

local function bindState(link, bag, slot, source)
    if type(link) ~= "string" or link == "" then return nil end

    local located = bindStateFromLocation(bag, slot)
    if located ~= nil then
        if source then source[1] = "C_Item.IsBound" end
        return located
    end

    local tooltip = bindStateFromTooltip(link)
    if tooltip ~= nil then
        if source then source[1] = "tooltip" end
        return tooltip
    end

    local modern = (type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function")
        and C_Item.GetItemInfo or nil
    if modern then
        local state = bindStateFrom(modern, link)
        if state ~= nil then
            if source then source[1] = "C_Item.GetItemInfo" end
            return state
        end
    end

    if type(GetItemInfo) == "function" then
        local state = bindStateFrom(GetItemInfo, link)
        if state ~= nil and source then source[1] = "GetItemInfo" end
        return state
    end

    if source then source[1] = "none" end
    return nil
end

local function contextText()
    local index = activeIndex()
    local builds = LT.Builds

    local name
    if type(builds) == "table" and type(builds.Get) == "function" then
        local ok, build = pcall(builds.Get, builds, index)
        if ok and type(build) == "table" and type(build.name) == "string" then
            name = build.name
        end
    end

    local level = scoringLevel()
    local text = "Slot " .. tostring(index) .. " · " .. tostring(name or ("Build " .. tostring(index)))
    if level and level > 0 then text = text .. " · level " .. tostring(level) end

    return text
end

local function buildFrame()
    if frame then return frame end
    if GearPopup:CombatLocked() then return nil end

    local widgets = ui()
    if not widgets then return nil end

    local ok, created = pcall(CreateFrame, "Frame", nil, UIParent)
    if not ok or not created then return nil end

    local window = created
    window:SetWidth(GearPopup.WIDTH)
    window:SetHeight(120)
    if window.SetFrameStrata then window:SetFrameStrata("DIALOG") end
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    pcall(window.RegisterForDrag, window, "LeftButton")
    window:SetScript("OnDragStart", function(self) self:StartMoving() end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        GearPopup:SavePlace()
    end)

    -- The main window's own chrome, not a second look: the shared edge every
    -- window and popup draws.
    LT.Chrome.Window(window)

    titleLabel = widgets:MakeLabel(window, "Gear check", "GameFontNormal", rgb("brand"))
    titleLabel:SetPoint("TOPLEFT", GearPopup.PADDING, -GearPopup.PADDING)

    -- Headings and context are placed from the measured title height, so a
    -- taller client font pushes them down instead of overlapping.
    local titleHeight = textHeight(titleLabel, 16)

    contextLabel = widgets:MakeLabel(window, contextText(), "GameFontNormalSmall", rgb("muted"))
    contextLabel:SetPoint("TOPLEFT", GearPopup.PADDING, -(GearPopup.PADDING + titleHeight + 2))
    contextLabel:SetWidth(GearPopup.WIDTH - (GearPopup.PADDING * 2))
    contextLabel:SetJustifyH("LEFT")
    if contextLabel.SetWordWrap then pcall(contextLabel.SetWordWrap, contextLabel, false) end

    overflowLabel = widgets:MakeLabel(window, "", "GameFontNormalSmall", rgb("muted"))
    overflowLabel:SetPoint("TOPLEFT", GearPopup.PADDING, -120)
    overflowLabel:SetWidth(GearPopup.WIDTH - (GearPopup.PADDING * 2))
    overflowLabel:SetJustifyH("LEFT")
    if overflowLabel.SetWordWrap then pcall(overflowLabel.SetWordWrap, overflowLabel, false) end
    overflowLabel:Hide()

    local close = widgets:MakeButton(window, "Close", 70, 20, function()
        GearPopup:Hide()
    end)
    close:SetPoint("TOPRIGHT", -8, -8)

    window:Hide()
    frame = window
    return window
end

-- How many rows fit on screen at the measured row height. The window never
-- grows past the UI area: it shows what fits and says how many it hid.
function GearPopup:EntryLimit(measuredRowHeight)
    local _, uiHeight = screenSize()
    if uiHeight <= 0 then return 12 end

    local chrome = 140     -- title, context line, close row, margins
    local fit = math.floor((uiHeight - chrome) / math.max(measuredRowHeight, 12))

    fit = fit - 2          -- room for the two section headings
    if fit < 4 then fit = 4 end
    if fit > 30 then fit = 30 end
    return fit
end

function GearPopup:Populate(entries)
    if not frame then return false end
    if GearPopup:CombatLocked() then return false end

    hideRows()

    local sample = buildRow(1)
    if not sample then return false end

    -- A hidden font string cannot report a height, so the measuring row is
    -- shown while its text is measured and hidden again by the layout below.
    sample:Show()

    -- Measure with real text in both columns: the row is one line, and its
    -- height is that line plus the gap under it.
    sample.nameLabel:SetText("Ag")
    sample.detailLabel:SetText("Ag")
    rowHeight = math.max(16, math.max(textHeight(sample.nameLabel, 12),
        textHeight(sample.detailLabel, 12)) + 4)
    sample.nameLabel:SetText("")
    sample.detailLabel:SetText("")

    local limit = self:EntryLimit(rowHeight)
    local shown, overflow = self:Limit(entries, limit)

    local items = {}
    local group

    for index = 1, #shown do
        local entry = shown[index]

        if entry.group ~= group then
            group = entry.group
            items[#items + 1] = {
                heading = (group == "soon") and "Soon" or "Wear now",
            }
        end

        items[#items + 1] = { entry = entry }
    end

    local titleHeight = textHeight(titleLabel, 16)
    local contextHeight = textHeight(contextLabel, 12)

    local y = -(GearPopup.PADDING + titleHeight + 2 + contextHeight + 10)

    for index = 1, #items do
        local item = items[index]
        local row = buildRow(index)
        if not row then break end

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, y)
        row:SetSize(GearPopup.WIDTH - (GearPopup.PADDING * 2), rowHeight)

        if item.heading then
            local brand = rgb("brand")
            row.link = nil
            row.slot = nil
            row.bound = nil
            row.icon:Hide()
            row.nameLabel:SetTextColor(brand.r, brand.g, brand.b)
            row.nameLabel:SetText(wrap("brand", item.heading))
            row.detailLabel:SetText("")
        else
            local entry = item.entry
            local data = entry.row
            local plain = rgb("text")

            row.link = data.link
            row.extraLink = data.extraLink
            row.slot = data.slot
            row.bagID = data.bagID
            row.bagSlot = data.bagSlot
            local bindSource = {}
            row.bound = bindState(data.link, data.bagID, data.bagSlot, bindSource)
            row.bindSource = bindSource[1]
            row.nameLabel:SetTextColor(plain.r, plain.g, plain.b)
            row.nameLabel:SetText(tostring(data.name or data.link or "item"))
            row.detailLabel:SetText(self:DescribeRow(data, entry.group))

            local texture = iconFor(data.link)
            if texture then
                row.icon:SetTexture(texture)
                row.icon:Show()
            else
                row.icon:Hide()
            end
        end

        row:Show()
        y = y - rowHeight
    end

    if overflow > 0 then
        overflowLabel:ClearAllPoints()
        overflowLabel:SetPoint("TOPLEFT", GearPopup.PADDING, y - 2)
        overflowLabel:SetText(tostring(overflow) .. " more not shown; /lt scan lists "
            .. tostring(math.min(overflow, self.CHAT_LIMIT)) .. " in chat.")
        overflowLabel:Show()
        y = y - (textHeight(overflowLabel, 12) + 6)
    else
        overflowLabel:Hide()
    end

    contextLabel:SetText(contextText())

    local height = -y + GearPopup.PADDING
    if height < 90 then height = 90 end
    frame:SetHeight(height)

    hasContent = true
    return true
end

function GearPopup:Place()
    if not frame then return end

    local uiWidth, uiHeight = screenSize()
    local width = frame:GetWidth() or self.WIDTH
    local height = frame:GetHeight() or 160

    local record = windowRecord()
    local x, y

    if record and type(record.popupX) == "number" and type(record.popupY) == "number" then
        x = record.popupX * uiWidth
        y = record.popupY * uiHeight
    else
        x = (uiWidth - width) / 2
        y = (uiHeight - height) / 2
    end

    if uiWidth > 0 and uiHeight > 0 then
        if uiWidth > width then
            x = math.max(0, math.min(uiWidth - width, x))
        else
            x = (uiWidth - width) / 2
        end

        if uiHeight > height then
            y = math.max(0, math.min(uiHeight - height, y))
        else
            y = (uiHeight - height) / 2
        end
    end

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, -y)
end

function GearPopup:SavePlace()
    if not frame then return end

    local record = windowRecord()
    if not record then return end

    local uiWidth, uiHeight = screenSize()
    if uiWidth <= 0 or uiHeight <= 0 then return end

    local scale = frame:GetEffectiveScale() or 1
    local left, top = frame:GetLeft(), frame:GetTop()

    if not UIParent or type(UIParent.GetLeft) ~= "function" then return end
    local okLeft, uiLeft = pcall(UIParent.GetLeft, UIParent)
    local okTop, uiTop = pcall(UIParent.GetTop, UIParent)

    if not left or not top or not okLeft or not okTop then return end
    if not uiLeft or not uiTop then return end

    record.popupX = ((left - uiLeft) / scale) / uiWidth
    record.popupY = ((uiTop - top) / scale) / uiHeight
end

function GearPopup:Hide()
    if frame then frame:Hide() end
end

function GearPopup:IsShown()
    return frame ~= nil and frame:IsShown() and true or false
end

-- Opening runs the scan first: an empty scan never builds a frame, so a level-up
-- with nothing to show costs no window at all. In combat nothing is read and
-- nothing is created; a window that already has a list may still be shown again,
-- because showing is not building.
function GearPopup:Open(opts)
    opts = opts or {}

    if self:CombatLocked() then
        if frame and hasContent then
            self:Place()
            frame:Show()
            if frame.Raise then pcall(frame.Raise, frame) end
            return true, "Showing the last scan; the bags are not read in combat."
        end
        return false, self:ReasonText("combat")
    end

    local result = opts.result
    if type(result) ~= "table" then
        local refusal
        result, refusal = self:Scan({ includeBank = opts.includeBank == true })
        if not result then return false, refusal end
    end

    local entries = self:Classify(result)
    if #entries == 0 then return false, self:ReasonText("empty") end

    local window = buildFrame()
    if not window then return false, "The gear check window could not be created." end

    if not self:Populate(entries) then
        return false, "The gear check window could not be filled."
    end

    self:Place()
    window:Show()
    if window.Raise then pcall(window.Raise, window) end
    return true
end

------------------------------------------------------------------------------
-- The bank prompt
--
-- One small window, one question, nothing read until the player says Scan. It
-- is a separate frame because it must not bring the list window into being.
------------------------------------------------------------------------------

local prompt

local function buildPrompt()
    if prompt then return prompt end
    if GearPopup:CombatLocked() then return nil end

    local widgets = ui()
    if not widgets then return nil end

    local ok, created = pcall(CreateFrame, "Frame", nil, UIParent)
    if not ok or not created then return nil end

    local window = created
    window:SetSize(250, 74)
    if window.SetFrameStrata then window:SetFrameStrata("DIALOG") end
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    pcall(window.RegisterForDrag, window, "LeftButton")
    window:SetScript("OnDragStart", function(self) self:StartMoving() end)
    window:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    -- Same edge as the list window: the prompt is a smaller window, not a
    -- different kind of thing.
    LT.Chrome.Window(window)

    local title = widgets:MakeLabel(window, "Scan the bank too?", "GameFontNormal", rgb("brand"))
    title:SetPoint("TOP", 0, -10)

    local scan = widgets:MakeButton(window, "Scan", 95, 20, function()
        GearPopup:ScanBank()
    end)
    scan:SetPoint("BOTTOMLEFT", 14, 12)

    local later = widgets:MakeButton(window, "Not now", 95, 20, function()
        GearPopup:HidePrompt()
    end)
    later:SetPoint("BOTTOMRIGHT", -14, 12)

    window:Hide()
    prompt = window
    return window
end

function GearPopup:ShowBankPrompt()
    if not self:Option("gearCheckBankPrompt") then return false end
    if self:CombatLocked() then return false end

    local window = buildPrompt()
    if not window then return false end

    window:ClearAllPoints()

    -- Beside the bank window where the client has one, and in a fixed spot
    -- where it does not; the clamp keeps either on screen. On this client
    -- BankFrame is the hidden wrapper and BankPanel is the window actually on
    -- screen, so the panel is tried first and BankFrame only as a last resort.
    local function frameLike(value)
        local kind = type(value)
        return kind == "table" or kind == "userdata"
    end

    local anchor
    if frameLike(BankFrame) and frameLike(BankFrame.BankPanel) then
        anchor = BankFrame.BankPanel
    elseif frameLike(_G.BankPanel) then
        anchor = _G.BankPanel
    elseif frameLike(BankFrame) then
        anchor = BankFrame
    end

    local beside = false
    if anchor and type(anchor.GetLeft) == "function" then
        beside = pcall(window.SetPoint, window, "TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    end

    if not beside then
        pcall(window.SetPoint, window, "CENTER", UIParent, "CENTER", 0, 140)
    end

    window:Show()
    if window.Raise then pcall(window.Raise, window) end
    return true
end

function GearPopup:HidePrompt()
    if prompt then prompt:Hide() end
end

function GearPopup:ScanBank()
    self:HidePrompt()

    if self:CombatLocked() then
        LT:Warn(self:ReasonText("combat"))
        return false
    end

    local result, refusal = self:Scan({ includeBank = true })
    if not result then
        LT:Warn(refusal)
        return false
    end

    if #self:Classify(result) == 0 then
        local message = self:ReasonText("emptyBank")
        local route = self:BankRouteText(result)
        if route then message = message .. " Read from the " .. route .. "." end
        LT:Print(message)
        return false
    end

    local shown, reason = self:Open({ result = result })
    if not shown then LT:Print(reason) end
    return shown
end

------------------------------------------------------------------------------
-- Level-up
--
-- PLAYER_LEVEL_UP only raises a flag; the scan runs when the character is out
-- of combat, which is the same moment at the end of a fight and the moment the
-- event arrives when the level was gained outside one.
------------------------------------------------------------------------------

local function soon(fn)
    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        if pcall(C_Timer.After, 0, fn) then return true end
    end

    fn()
    return false
end

local function currentLevel()
    local levels = LT.Levels
    if type(levels) == "table" and type(levels.GetCurrentLevel) == "function" then
        local ok, level = pcall(levels.GetCurrentLevel, levels)
        if ok and tonumber(level) then return tonumber(level) end
    end

    local stored = LT.player and tonumber(LT.player.level)
    if stored then return stored end

    local ok, level = pcall(UnitLevel, "player")
    if ok and tonumber(level) then return tonumber(level) end

    return nil
end

-- One line for the trainer, or nil. Two things are announced: an armour or
-- weapon type this class unlocks at exactly the level just reached ("Mail at
-- 40"), and a weapon-master type the class may use but this character has not
-- trained yet (once per session). The option is the gate: off means silent.
function GearPopup:TrainerHint(level)
    if not self:Option("trainerHint") then return nil end

    local newLevel = tonumber(level)
    local usability = LT.Usability
    if not newLevel or type(usability) ~= "table" then return nil end

    local classToken = LT.player and LT.player.class
    local parts = {}
    local unlocked = {}

    local packs = LT.ClassPacks
    if classToken and type(packs) == "table" and type(packs.GetUsable) == "function" then
        local ok, usable = pcall(packs.GetUsable, packs, classToken)

        if ok and type(usable) == "table" then
            for _, family in ipairs({ "armour", "weapons" }) do
                local rules = usable[family]

                if type(rules) == "table" then
                    for key, rule in pairs(rules) do
                        if type(rule) == "table" and tonumber(rule.fromLevel) == newLevel then
                            unlocked[key] = true
                            local label = tostring(key)
                            if type(usability.GetLabel) == "function" then
                                local okLabel, named = pcall(usability.GetLabel, usability, key)
                                if okLabel and type(named) == "string" then label = named end
                            end
                            parts[#parts + 1] = label .. " at " .. tostring(newLevel)
                        end
                    end
                end
            end
        end
    end

    table.sort(parts)

    self.trainerHintSeen = self.trainerHintSeen or {}

    local masters = usability.WEAPON_MASTER
    if classToken and type(masters) == "table"
        and type(usability.KnowsProficiency) == "function" then
        local weapon = {}

        for key in pairs(masters) do
            if not self.trainerHintSeen[key] and not unlocked[key] then
                local rule
                if type(usability.GetRule) == "function" then
                    local okRule, got = pcall(usability.GetRule, usability,
                        classToken, "weapons", key)
                    rule = okRule and got or nil
                end

                -- A type the pack marks "never" is not trainable for this class;
                -- nil and true both mean the class may use it.
                local allowed = not (type(rule) == "table" and rule.never)

                if allowed then
                    local okKnown, known = pcall(usability.KnowsProficiency, usability, key)
                    if okKnown and known == false then
                        local label = tostring(key)
                        if type(usability.GetLabel) == "function" then
                            local okLabel, named = pcall(usability.GetLabel, usability, key)
                            if okLabel and type(named) == "string" then label = named end
                        end
                        self.trainerHintSeen[key] = true
                        weapon[#weapon + 1] = label
                    end
                end
            end
        end

        table.sort(weapon)
        if #weapon > 0 then
            -- L-5: one type per line, each with its trainer and city, never one
            -- lumped sentence. `ListProficiency` (L-13) is the source: it already
            -- knows the faction trainer and whether the class may train the type.
            local lines = {}
            if type(usability.ListProficiency) == "function" then
                local okList, list = pcall(usability.ListProficiency, usability, classToken)
                if okList and type(list) == "table" then
                    for _, entry in ipairs(list) do
                        if type(entry) == "table" and entry.state == "learnable"
                            and type(entry.trainer) == "table"
                            and not self.trainerHintSeen[entry.kind] then
                            local where = tostring(entry.trainer.name or "")
                            if type(entry.trainer.zone) == "string" and entry.trainer.zone ~= "" then
                                where = where .. (where ~= "" and ", " or "") .. entry.trainer.zone
                            end
                            lines[#lines + 1] = {
                                kind = entry.kind,
                                label = tostring(entry.label or entry.kind),
                                where = where,
                            }
                        end
                    end
                end
            end

            if #lines == 0 then
                for _, label in ipairs(weapon) do
                    lines[#lines + 1] = { label = label, where = "" }
                end
            end

            -- Two-handers are the biggest early power spike, so they come first
            -- up to level 20; after that the list is alphabetical and the cap is
            -- what keeps it readable.
            local function isTwoHanded(label)
                local lower = string.lower(tostring(label))
                return lower:find("two%-handed") ~= nil or lower:find("two handed", 1, true) ~= nil
            end
            local band = tonumber(newLevel) or 0
            table.sort(lines, function(a, b)
                if band <= 20 then
                    local at, bt = isTwoHanded(a.label), isTwoHanded(b.label)
                    if at ~= bt then return at end
                end
                return a.label < b.label
            end)

            while #lines > 3 do table.remove(lines) end
            for _, entry in ipairs(lines) do
                if entry.kind then self.trainerHintSeen[entry.kind] = true end
                local text = entry.label
                if entry.where ~= "" then text = text .. " - " .. entry.where end
                parts[#parts + 1] = text
            end
        end
    end

    if #parts == 0 then return nil end
    return "Trainer: " .. table.concat(parts, "; ") .. "."
end

function GearPopup:OnLevelUp(level)
    self.pendingLevelUp = true
    self.pendingLevel = tonumber(level)
    self:ConsumePending()
end

function GearPopup:OnRegenEnabled()
    if self.pendingLevelUp then self:ConsumePending() end
end

function GearPopup:ConsumePending()
    if not self.pendingLevelUp then return end
    if self:CombatLocked() then return end

    -- A frame later: the client is still delivering the level-up when the event
    -- arrives, and a scan there would race the level the client is about to
    -- report. The flag stays raised until that frame actually runs.
    soon(function()
        if not GearPopup.pendingLevelUp then return end
        if GearPopup:CombatLocked() then return end

        local newLevel = tonumber(GearPopup.pendingLevel) or currentLevel()

        GearPopup.pendingLevelUp = false
        GearPopup.pendingLevel = nil

        if GearPopup:Option("gearCheckOnLevel") then
            local result = GearPopup:Scan({ includeBank = false })
            local count = (type(result) == "table" and type(result.now) == "table")
                and #result.now or 0

            if count > 0 then
                if type(LT.Print) == "function" then
                    pcall(LT.Print, LT, "Level-up check: " .. tostring(count)
                        .. " upgrade(s) to wear.")
                end
                GearPopup:Open({ result = result })
            elseif type(LT.Print) == "function" then
                pcall(LT.Print, LT, "Level-up check: no upgrade in the bags.")
            end
        end

        local hint = GearPopup:TrainerHint(newLevel)
        if hint and type(LT.Print) == "function" then
            pcall(LT.Print, LT, hint)
        end
    end)
end

-- Optional auto-open on bag-open (default off). The upgrade arrows now mark the
-- bag items, so this window is a secondary, opt-in surface.
function GearPopup:OnBagOpened()
    if not self:Option("gearCheckOnBagOpen") then return end
    if self:CombatLocked() then return end
    if self:IsShown() then return end

    -- BAG_OPEN, the EventRegistry callback and the waker can all report one
    -- opening; the pending flag covers the same frame, the one-second guard
    -- covers a callback that arrives a frame later. Either way it runs once.
    local now
    if type(GetTime) == "function" then
        local ok, value = pcall(GetTime)
        now = ok and tonumber(value) or nil
    end

    if self.bagOpenPending then return end
    if now and self.bagOpenAt and (now - self.bagOpenAt) < 1 then return end

    self.bagOpenAt = now or self.bagOpenAt
    self.bagOpenPending = true

    soon(function()
        GearPopup.bagOpenPending = false
        if GearPopup:CombatLocked() then return end
        local result = GearPopup:Scan({ includeBank = false })
        if result then GearPopup:Open({ result = result }) end
    end)
end

-- The bag-open signal on Forever is EventRegistry's
-- "ContainerFrame.OpenBag" callback; BAG_OPEN and the combined-bags frame's
-- OnShow are extra paths for a client that fires neither or only one. All three
-- lead to OnBagOpened, whose guard makes a second path in one opening a no-op.
function GearPopup:EnsureBagOpenHook()
    if self.bagOpenHook then return true end
    if type(EventRegistry) ~= "table" or type(EventRegistry.RegisterCallback) ~= "function" then
        return false
    end

    local ok = pcall(EventRegistry.RegisterCallback, EventRegistry,
        "ContainerFrame.OpenBag", function() GearPopup:OnBagOpened() end, self)

    if ok then self.bagOpenHook = true end
    return ok
end

-- Registration is attempted once as this file finishes and again at PLAYER_LOGIN
-- (Initialize runs there through the core's login stage and through this file's
-- own listener), because EventRegistry is not guaranteed to exist at file load.
-- A failed attempt is silent; the next one tries again.
function GearPopup:Initialize()
    self:EnsureBagOpenHook()

    if self.bagOpenWaker then return end

    local combined = _G.ContainerFrameCombinedBags
    if type(combined) ~= "table" and type(combined) ~= "userdata" then return end

    local ok, waker = pcall(CreateFrame, "Frame", nil, combined)
    if not ok or (type(waker) ~= "table" and type(waker) ~= "userdata") then return end

    self.bagOpenWaker = waker
    pcall(waker.SetScript, waker, "OnShow", function() GearPopup:OnBagOpened() end)
end

------------------------------------------------------------------------------
-- Client events
--
-- One hidden listener, created at file load (outside combat by definition) and
-- guarded like the core's own frame: an event this client does not know must
-- never raise.
------------------------------------------------------------------------------

do
    local ok, listener = pcall(CreateFrame, "Frame", nil, UIParent)

    if ok and listener then
        local watched = {
            "PLAYER_LOGIN",
            "PLAYER_LEVEL_UP",
            "PLAYER_REGEN_ENABLED",
            "BANKFRAME_OPENED",
            "BANKFRAME_CLOSED",
            "BAG_OPEN",
        }

        for _, event in ipairs(watched) do
            pcall(listener.RegisterEvent, listener, event)
        end

        listener:SetScript("OnEvent", function(_, event, arg1)
            local okEvent, err = pcall(function()
                if event == "PLAYER_LOGIN" then
                    -- The retry for the bag-open registration and the waker: both
                    -- need frames that exist by this point, and EventRegistry may
                    -- not have existed when this file was read.
                    GearPopup:Initialize()
                elseif event == "PLAYER_LEVEL_UP" then
                    GearPopup:OnLevelUp(arg1)
                elseif event == "PLAYER_REGEN_ENABLED" then
                    GearPopup:OnRegenEnabled()
                elseif event == "BANKFRAME_OPENED" then
                    GearPopup:ShowBankPrompt()
                elseif event == "BANKFRAME_CLOSED" then
                    GearPopup:HidePrompt()
                elseif event == "BAG_OPEN" then
                    GearPopup:OnBagOpened()
                end
            end)

            if not okEvent then
                LT:Error("The gear check failed on " .. tostring(event) .. ": " .. tostring(err))
            end
        end)
    else
        -- Without the listener the level-up and bank prompts never fire. Say so
        -- once at load instead of leaving two switches that do nothing.
        LT:Error("The gear check could not listen for level-ups or the bank on this client.")
    end
end

-- The first attempt, at file load; the PLAYER_LOGIN paths above retry it.
GearPopup:EnsureBagOpenHook()
