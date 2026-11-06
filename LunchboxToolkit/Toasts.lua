--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Toasts
    One small movable line of text: a better item just dropped, or the bags are
    nearly full. Never more than one on screen, never anything to click, gone
    after eight seconds.

    Why a second small window rather than the chat line: the score only exists
    while a tooltip is open, so an upgrade that arrives while the loot window is
    closing is easy to miss. The toast says it in the player's own view, once,
    and then gets out of the way.

    Three sources, three rules:

      * upgrade toast — LOOT_OPENED reads the real loot slots once, scores each
        distinct item once through Compare:AgainstEquipped (the same scoring
        route GearCheck uses) and shows one line only when the item beats what
        is worn. CHAT_MSG_LOOT is deliberately not listened to: a stack split
        and a manual pickup notice are chat events, not loot slots, and would
        otherwise fire on every stack of cloth. On by default; the separate bag
        scan after a quest turn-in stays opt-in (questTurnInScan, off by
        default), so a turn-in does not walk the bags unless asked.

      * bag-space warning — BAG_UPDATE_DELAYED counts the free slots of the
        backpack and every equipped bag, and says one line at two or fewer
        (WARNING_AT). It is announced once per bag state: the low state says so
        once, not on every bag update, and the line goes away as soon as space
        is freed. On by default.

      * campfire — three lines per fire, off by default and described in its own
        section below. The one sentence about +5% experience food lives only
        there; it is not printed anywhere else in the add-on.

    Frames are built on first use and only outside combat; a toast earned in a
    fight is queued and drawn on PLAYER_REGEN_ENABLED. Nothing here is
    protected, but a frame created during a fight can be tainted for the rest
    of the session, so creation waits.

    Every colour comes from Palette; every size is measured from the font
    string after its text exists, never guessed from a row count.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Toasts = {}
LT.Toasts = Toasts
LT.Modules = LT.Modules or {}
LT.Modules.Toasts = Toasts

Toasts.HOLD_SECONDS   = 8    -- how long a toast stays on screen
Toasts.WARNING_AT     = 2    -- announced at two free slots or fewer
Toasts.PADDING        = 10
Toasts.MAX_WIDTH      = 460
Toasts.MAX_LOOT_SLOTS = 32   -- a loot window never holds more; the cap is a guard

------------------------------------------------------------------------------
-- Options
--
-- The keys (toastUpgrades, bagSpaceWarning, questTurnInScan, campfireToasts)
-- live in Database.defaultOptions(), so one table owns their defaults. This
-- file never carries a second copy: a missing key falls back to that table, and
-- a non-boolean value is treated as missing.
------------------------------------------------------------------------------

local function optionDefault(key)
    local database = LT.Database
    if type(database) == "table" and type(database.defaultOptions) == "function" then
        local ok, defaults = pcall(database.defaultOptions)
        if ok and type(defaults) == "table" then
            return defaults[key] == true
        end
    end
    return false
end

function Toasts:Option(key)
    local database = LT.Database
    if type(database) == "table" and type(database.GetOptions) == "function" then
        local ok, options = pcall(database.GetOptions, database)
        if ok and type(options) == "table" and type(options[key]) == "boolean" then
            return options[key]
        end
    end
    return optionDefault(key)
end

------------------------------------------------------------------------------
-- Client state, read through guards
------------------------------------------------------------------------------

-- A restricted value must never reach tonumber(), arithmetic or a comparison:
-- the modern client raises on it. Every bag and loot read goes through here.
local function isSecret(value)
    if type(LT.IsSecret) ~= "function" then return false end
    local ok, result = pcall(LT.IsSecret, LT, value)
    return ok and result == true
end

function Toasts:CombatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

local function screenSize()
    if not UIParent or type(UIParent.GetWidth) ~= "function" then return 0, 0 end

    local okWidth, width = pcall(UIParent.GetWidth, UIParent)
    local okHeight, height = pcall(UIParent.GetHeight, UIParent)

    if not okWidth or not okHeight then return 0, 0 end
    return tonumber(width) or 0, tonumber(height) or 0
end

local function windowRecord()
    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return nil end

    if type(character.window) ~= "table" then character.window = {} end
    return character.window
end

------------------------------------------------------------------------------
-- Palette, read at call time so this file cannot drift from the legend
------------------------------------------------------------------------------

-- The { r, g, b } shape UI:MakeLabel takes.
local function rgb(key)
    local palette = LT.Palette
    if type(palette) == "table" and type(palette.RGB) == "function" then
        local ok, colour = pcall(palette.RGB, palette, key)
        if ok and type(colour) == "table" then return colour end
    end
    return { r = 1, g = 1, b = 1 }
end

-- The { r, g, b, a } shape the texture fallback takes.
local function colourOf(key)
    local palette = LT.Palette
    if type(palette) == "table" and type(palette.Colour) == "function" then
        local ok, colour = pcall(palette.Colour, palette, key)
        if ok and type(colour) == "table" then return colour end
    end
    return { 1, 1, 1, 1 }
end

------------------------------------------------------------------------------
-- Bag space (pure text, then one guarded client read)
------------------------------------------------------------------------------

-- "bags are full" when no slot is free; a configurable threshold can still
-- announce one or two free slots. Pure: the caller can replay a bag state
-- without a bag.
function Toasts:BagWarningText(free)
    local count = tonumber(free)
    if not count then return nil end
    if count > self.WARNING_AT then return nil end

    if count < 0 then count = 0 end
    count = math.floor(count)

    if count <= 0 then return "bags are full" end
    if count == 1 then return "1 bag slot free" end
    return tostring(count) .. " bag slots free"
end

-- C_Container is confirmed present on this client; the pre-C_Container globals
-- are kept as a fallback because they cost a few lines and a missing bag API
-- would cost the whole warning.
local function freeSlotReader()
    local modern = C_Container
    if type(modern) == "table" and type(modern.GetContainerNumFreeSlots) == "function" then
        return modern.GetContainerNumFreeSlots
    end
    if type(GetContainerNumFreeSlots) == "function" then
        return GetContainerNumFreeSlots
    end
    return nil
end

local function slotReaders()
    local modern = C_Container
    if type(modern) == "table"
        and type(modern.GetContainerNumSlots) == "function"
        and type(modern.GetContainerItemLink) == "function" then
        return modern.GetContainerNumSlots, modern.GetContainerItemLink
    end
    if type(GetContainerNumSlots) == "function" and type(GetContainerItemLink) == "function" then
        return GetContainerNumSlots, GetContainerItemLink
    end
    return nil
end

-- Free slots across the backpack (container 0) and every equipped bag. nil when
-- no container API answers at all: a guessed zero would announce a full bag.
-- A restricted count or link is never converted or counted; it leaves that bag
-- unread, and an all-restricted walk answers nil rather than a number it does
-- not have.
function Toasts:FreeBagSlots()
    local lastBag = 4
    if not isSecret(NUM_BAG_SLOTS) then
        lastBag = tonumber(NUM_BAG_SLOTS) or 4
    end

    local total = 0

    local free = freeSlotReader()
    if free then
        local answered = false
        for bag = 0, lastBag do
            local ok, count = pcall(free, bag)
            if ok and not isSecret(count) and type(count) == "number" then
                total = total + count
                answered = true
            end
        end
        if answered then return total end
        total = 0
    end

    -- Fallback: an empty slot is one whose link is nil.
    local slotsFn, linkFn = slotReaders()
    if not slotsFn then return nil end

    local answered = false
    for bag = 0, lastBag do
        local okSlots, slots = pcall(slotsFn, bag)
        local readable = okSlots and not isSecret(slots)
        local count = readable and (tonumber(slots) or 0) or 0

        if count > 0 then
            for slot = 1, count do
                local okLink, link = pcall(linkFn, bag, slot)
                if okLink then
                    answered = true
                    if not isSecret(link) and link == nil then total = total + 1 end
                end
            end
        elseif readable then
            -- A bag that is not equipped has no slots and no free space.
            answered = true
        end
    end

    if answered then return total end
    return nil
end

------------------------------------------------------------------------------
-- Loot (read the real slots once, then score distinct items once)
------------------------------------------------------------------------------

-- The item links the loot window is showing, each once. Read inside the
-- LOOT_OPENED handler while the slots are still populated; a secret link is
-- never keyed or scored, the same rule the rest of the add-on follows.
function Toasts:LootLinks()
    if type(GetNumLootItems) ~= "function" or type(GetLootSlotLink) ~= "function" then
        return {}
    end

    local okCount, count = pcall(GetNumLootItems)

    -- A restricted count is never converted, compared or looped over.
    if not okCount or isSecret(count) then return {} end

    count = tonumber(count) or 0
    if count <= 0 then return {} end
    if count > self.MAX_LOOT_SLOTS then count = self.MAX_LOOT_SLOTS end

    local links = {}
    local seen = {}

    for slot = 1, count do
        local ok, link = pcall(GetLootSlotLink, slot)
        if ok and not isSecret(link) and type(link) == "string" and link ~= "" then
            if not seen[link] then
                seen[link] = true
                links[#links + 1] = link
            end
        end
    end

    return links
end

local function activeIndex()
    local builds = LT.Builds
    if type(builds) == "table" and type(builds.GetActiveIndex) == "function" then
        local ok, index = pcall(builds.GetActiveIndex, builds)
        if ok and tonumber(index) then return tonumber(index) end
    end
    return 1
end

local function nameFromLink(link)
    local bracket = tostring(link or ""):match("%[(.-)%]")
    if bracket and bracket ~= "" then return bracket end
    return nil
end

local function slotText(comparison)
    local stated = comparison.referenceSlotLabel
    if type(stated) == "string" and stated ~= "" then return stated end

    local slot = tonumber(comparison.referenceSlot)
    if not slot then
        local headline = comparison.headline
        if type(headline) == "table" then
            slot = tonumber(headline.slot)
            if not slot and type(headline.slotLabel) == "string" then
                return headline.slotLabel
            end
        end
    end
    if not slot then return nil end

    local itemStats = LT.ItemStats
    if type(itemStats) == "table" and type(itemStats.GetSlotLabel) == "function" then
        local ok, text = pcall(itemStats.GetSlotLabel, itemStats, slot)
        if ok and type(text) == "string" and text ~= "" then return text end
    end

    return "slot " .. tostring(slot)
end

-- The one line an upgrade earns, or nil. "Beats the worn item" is the only
-- claim: a positive difference from Compare:AgainstEquipped, with both the item
-- and the slot nameable. Anything less stays silent rather than guessing.
function Toasts:UpgradeText(comparison, link)
    if type(comparison) ~= "table" then return nil end
    if comparison.status ~= "upgrade" then return nil end

    local difference = tonumber(comparison.difference)
    if not difference or difference <= 0 then return nil end

    local name = comparison.itemName
    if type(name) ~= "string" or name == "" then name = nameFromLink(link) end
    if not name then return nil end

    local slot = slotText(comparison)
    if not slot then return nil end

    return "Upgrade: " .. tostring(name) .. " — " .. slot
        .. " +" .. string.format("%.1f", difference)
end

-- One comparison per item link. Compare keeps its own cache, so asking twice
-- about the same drop costs nothing extra, but the loot read never repeats.
function Toasts:Score(link)
    local compare = LT.Compare
    if type(compare) ~= "table" or type(compare.AgainstEquipped) ~= "function" then
        return nil
    end

    -- The toast says "equip it NOW": only a clean "usable" verdict may earn it.
    -- Anything unknown (item data not yet loaded) or deferred (mail at 40) or
    -- never stays silent rather than claiming an upgrade the character cannot
    -- equip yet.
    local usability = LT.Usability
    if type(usability) == "table" and type(usability.GetVerdict) == "function" then
        local okV, verdict = pcall(usability.GetVerdict, usability, link)
        if okV and type(verdict) == "table" and verdict.verdict ~= usability.USABLE then
            return nil
        end
    end

    local ok, comparison = pcall(compare.AgainstEquipped, compare, link, activeIndex())
    if not ok or type(comparison) ~= "table" then return nil end

    local text = self:UpgradeText(comparison, link)
    if not text then return nil end

    return text, tonumber(comparison.difference) or 0
end

-- The best upgrade in one loot window, as one line, or nil.
function Toasts:BestUpgrade(links)
    local bestText, bestDelta

    for index = 1, #links do
        local text, delta = self:Score(links[index])
        if text and (not bestDelta or delta > bestDelta) then
            bestText, bestDelta = text, delta
        end
    end

    return bestText
end

------------------------------------------------------------------------------
-- The window
--
-- No buttons and no icons: the only interaction is dragging it to a corner the
-- player prefers, and that place is remembered as a fraction of the UI area
-- beside the other windows' places, so a resolution change keeps it relative.
------------------------------------------------------------------------------

local frame
local label
local holdElapsed = 0

local function buildFrame()
    if frame then return frame end
    if Toasts:CombatLocked() then return nil end

    local ui = LT.UI
    if type(ui) ~= "table" or type(ui.MakeLabel) ~= "function" then return nil end

    -- Unnamed on purpose: a named frame is a new global, and this file adds
    -- only LT.Toasts. The window is moved and read through this upvalue.
    local ok, created = pcall(CreateFrame, "Frame", nil, UIParent)
    if not ok or not created then return nil end

    local window = created
    if window.SetFrameStrata then pcall(window.SetFrameStrata, window, "HIGH") end
    pcall(window.SetClampedToScreen, window, true)

    -- Movable, so the player can put it where it does not cover anything.
    pcall(window.SetMovable, window, true)
    pcall(window.EnableMouse, window, true)
    pcall(window.RegisterForDrag, window, "LeftButton")

    window:SetScript("OnDragStart", function(self)
        holdElapsed = 0
        pcall(self.StartMoving, self)
    end)

    window:SetScript("OnDragStop", function(self)
        pcall(self.StopMovingOrSizing, self)
        Toasts:SavePlace()
    end)

    -- The auto-hide. A hidden frame does not tick, so a toast that has gone
    -- costs nothing until the next one.
    window:SetScript("OnUpdate", function(self, delta)
        holdElapsed = holdElapsed + (tonumber(delta) or 0)
        if holdElapsed >= Toasts.HOLD_SECONDS then
            holdElapsed = 0
            self:Hide()
        end
    end)

    -- The main window's edge, drawn by the module that owns chrome. The tone is
    -- applied to the outer edge on each show (Show calls Chrome.Tint), so the
    -- toast still says "upgrade" or "reminder" in colour, not only in words.
    if LT.Chrome and LT.Chrome.Window then
        pcall(LT.Chrome.Window, window)
    end

    label = ui:MakeLabel(window, "", "GameFontNormal", rgb("text"))
    label:SetPoint("LEFT", Toasts.PADDING, 0)
    label:SetJustifyH("LEFT")
    if label.SetJustifyV then pcall(label.SetJustifyV, label, "MIDDLE") end
    -- One line, whatever the item is called.
    if label.SetWordWrap then pcall(label.SetWordWrap, label, false) end
    if label.SetNonSpaceWrap then pcall(label.SetNonSpaceWrap, label, false) end

    window:Hide()
    frame = window
    return window
end

-- Content-dependent sizing: the text is put in the font string first, its own
-- measured width and height decide the frame, and the result is clamped to the
-- UI area. Nothing is calculated from a guessed character count.
local function resize(text)
    local pad = Toasts.PADDING

    label:SetWidth(0)
    label:SetText(text)

    -- A hidden font string does not report a height on every client, so the
    -- frame is shown for the measurement. Sizing and anchoring finish inside
    -- the same event, before the client draws, so no unsized toast is seen.
    frame:Show()

    local measuredWidth = 0
    if type(label.GetStringWidth) == "function" then
        local ok, width = pcall(label.GetStringWidth, label)
        if ok and type(width) == "number" and width > 0 then measuredWidth = width end
    end

    local measuredHeight = 0
    if type(label.GetStringHeight) == "function" then
        local ok, height = pcall(label.GetStringHeight, label)
        if ok and type(height) == "number" and height > 0 then measuredHeight = height end
    end
    if measuredHeight <= 0 then measuredHeight = 12 end

    local uiWidth = screenSize()
    local maxWidth = Toasts.MAX_WIDTH
    if uiWidth > 0 then maxWidth = math.min(maxWidth, uiWidth - 40) end
    if maxWidth < 120 then maxWidth = 120 end

    local inner = measuredWidth
    if inner <= 0 then inner = math.min(maxWidth, 220) - pad * 2 end
    inner = math.min(inner, maxWidth - pad * 2)
    if inner < 40 then inner = 40 end

    label:SetWidth(inner)
    frame:SetSize(inner + pad * 2, measuredHeight + pad * 2)
end

-- Remembered place, as a fraction of the UI area. The default is the top
-- middle, low enough to clear the minimap and the buffs.
function Toasts:Place()
    if not frame then return end

    local uiWidth, uiHeight = screenSize()
    local width = frame:GetWidth() or 240
    local height = frame:GetHeight() or 24

    local record = windowRecord()
    local x, y

    if record and type(record.toastX) == "number" and type(record.toastY) == "number" then
        x = record.toastX * uiWidth
        y = record.toastY * uiHeight
    else
        x = (uiWidth - width) / 2
        y = 140
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

function Toasts:SavePlace()
    if not frame then return end

    local record = windowRecord()
    if not record then return end

    local uiWidth, uiHeight = screenSize()
    if uiWidth <= 0 or uiHeight <= 0 then return end

    local scale = frame:GetEffectiveScale() or 1
    local left, top = frame:GetLeft(), frame:GetTop()
    if not left or not top then return end

    if not UIParent or type(UIParent.GetLeft) ~= "function" then return end
    local okLeft, uiLeft = pcall(UIParent.GetLeft, UIParent)
    local okTop, uiTop = pcall(UIParent.GetTop, UIParent)
    if not okLeft or not okTop or not uiLeft or not uiTop then return end

    record.toastX = ((left - uiLeft) / scale) / uiWidth
    record.toastY = ((uiTop - top) / scale) / uiHeight
end

function Toasts:IsShown()
    return frame ~= nil and frame:IsShown() and true or false
end

-- The one line on screen, or nil. Exposed so a check can read what the player
-- would read without reaching into the frame.
function Toasts:CurrentText()
    if not self:IsShown() or not label then return nil end
    return label:GetText()
end

function Toasts:Hide()
    if frame then frame:Hide() end
end

-- One queued line at a time, and a captured upgrade is never replaced: a bag
-- warning can be read again after the fight, but the links of a loot window
-- cannot be recovered once the window is gone. `pending.links` non-nil is what
-- marks an entry as an upgrade.
function Toasts:QueuePending(entry)
    local pending = self.pending
    if type(pending) == "table" and pending.links ~= nil then return false end

    self.pending = entry
    return true
end

-- Show one line. Newest wins: a second answer replaces the text in the same
-- frame, so two toasts can never be on screen at once. In combat nothing is
-- built and the line is queued for PLAYER_REGEN_ENABLED.
function Toasts:Show(kind, text)
    if type(text) ~= "string" or text == "" then return false end

    if self:CombatLocked() then
        self:QueuePending({ kind = kind or "text", text = text })
        return false
    end

    local window = buildFrame()
    if not window then return false end

    resize(text)

    -- Purple for an upgrade (the palette's "yes"), green for a reminder that
    -- asks for an action. Both meanings are the legend's, not a new one, and
    -- both are carried by the frame's outer edge as well as by its text.
    local tone = (kind == "upgrade") and "go" or "caution"
    local colour = rgb(tone)
    label:SetTextColor(colour.r, colour.g, colour.b)

    if LT.Chrome and LT.Chrome.Tint then
        pcall(LT.Chrome.Tint, window, colourOf(tone))
    end

    self:Place()
    holdElapsed = 0
    window:Show()

    self.pending = nil
    self.currentKind = kind
    return true
end

------------------------------------------------------------------------------
-- The two events
------------------------------------------------------------------------------

-- LOOT_OPENED: the slots are read once, here. Each distinct link is scored once
-- with Compare's equipped comparison, the same route GearCheck uses. CHAT_MSG_LOOT
-- is not registered at all, so a stack split or a pickup notice cannot reach
-- this code however often the chat reports one.
--
-- In combat the links are captured here and scored at PLAYER_REGEN_ENABLED: the
-- loot window may be gone by then, but the links are already in hand, and a
-- score that reads equipped gear is not asked for during a fight.
function Toasts:OnLootOpened()
    if not self:Option("toastUpgrades") then return false end

    local links = self:LootLinks()
    if #links == 0 then return false end

    if self:CombatLocked() then
        self.pending = { kind = "upgrade", links = links }
        return false
    end

    local text = self:BestUpgrade(links)
    if not text then return false end

    return self:Show("upgrade", text)
end

-- BAG_UPDATE_DELAYED: the settled bag state. At or below the threshold the line
-- is said once per state; above it the state is forgotten and a warning still
-- on screen is taken down, because the reason for it is gone.
function Toasts:OnBagUpdateDelayed()
    if not self:Option("bagSpaceWarning") then
        self.warningShown = false
        self.warningFree = nil
        if self.currentKind == "bags" and self:IsShown() then self:Hide() end
        return false
    end

    -- Never in combat: the line waits for the regen event and the bag state is
    -- read again then, so a stale count is never shown. A queued upgrade is
    -- left alone: the bag warning is re-derived next update, the loot is not.
    if self:CombatLocked() then
        self:QueuePending({ kind = "bags" })
        return false
    end

    local free = self:FreeBagSlots()
    if type(free) ~= "number" then return false end

    local text = self:BagWarningText(free)
    if not text then
        self.warningShown = false
        self.warningFree = nil
        if self.currentKind == "bags" and self:IsShown() then self:Hide() end
        return false
    end

    -- Once per bag state. A count that changes while still low updates the one
    -- visible line; it does not stack a second toast.
    if self.warningShown and self.warningFree == free then return false end

    local shown = self:Show("bags", text)
    if shown then
        self.warningShown = true
        self.warningFree = free
    end

    return shown
end

function Toasts:OnRegenEnabled()
    local pending = self.pending
    if not pending then return false end
    self.pending = nil

    if pending.kind == "bags" and not pending.text then
        return self:OnBagUpdateDelayed()
    end

    if type(pending.links) == "table" then
        local text = self:BestUpgrade(pending.links)
        if not text then return false end
        return self:Show("upgrade", text)
    end

    return self:Show(pending.kind, pending.text)
end

-- QUEST_TURNED_IN: a reward has just gone into the bags. Wait one tick for the
-- bag to settle, then score it and toast the best upgrade to equip.
function Toasts:ScanUpgradeNow()
    if not self:Option("toastUpgrades") then return false end
    if self:CombatLocked() then return false end

    local gear = LT.GearCheck
    if type(gear) ~= "table" or type(gear.Scan) ~= "function" then return false end

    local ok, result = pcall(gear.Scan, gear, { fresh = true })
    if not ok or type(result) ~= "table" then return false end

    local best
    for _, row in ipairs(result.now or {}) do
        local delta = tonumber(row and row.delta)
        if delta and delta > 0 and (not best or delta > tonumber(best.delta or 0)) then
            best = row
        end
    end
    if not best then return false end

    return self:Show("upgrade", "Upgrade: " .. tostring(best.name) .. " — equip it")
end

function Toasts:OnQuestTurnedIn()
    if not self:Option("toastUpgrades") then return false end
    -- The bag scan after a turn-in walks GearCheck over every slot, so it is a
    -- separate opt-in (questTurnInScan, default false): a turn-in does not scan
    -- unless the player asked for it, even though upgrade toasts stay on.
    if not self:Option("questTurnInScan") then return false end
    if self:CombatLocked() then return false end

    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        C_Timer.After(0.5, function() Toasts:ScanUpgradeNow() end)
        return true
    end

    return self:ScanUpgradeNow()
end

------------------------------------------------------------------------------
-- Campfire (L-15, T-134)
--
-- A fire gives a buff, so the buff is what is read: the guide names the fires
-- (Mana Well, Camp Tent, Lodestone, Fish Bowl, Incense Candle) and that list of
-- words is the whole detection rule. No spell id is carried, because none was
-- read off this client and a guessed id either never matches or matches the
-- wrong spell. Any helpful aura whose name contains one of the words - or
-- "campfire"/"bonfire" - counts as a fire.
--
-- Three lines per fire, one each, in order, never per tick:
--
--   1. on the buff's first sight - the Spirit buff, and the experience-food
--      reminder; this is the only place that sentence is printed (L-8 moved it
--      here so nothing says it twice);
--   2. one toast-hold later - the buff's own time left, so line 1 is read
--      instead of being replaced before anyone sees it;
--   3. once, with CAMPFIRE_EXPIRY_WARNING left - find another fire.
--
-- Off by default (campfireToasts): the names are the guide's, not this client's,
-- so the switch is the player confirming the words. A line 2 or 3 that cannot be
-- scheduled (no C_Timer) waits for the next aura pass rather than inventing a
-- clock, and an unreadable time left drops line 3 instead of guessing.
------------------------------------------------------------------------------

Toasts.CAMPFIRE_NAMES = {
    "campfire", "camp fire", "bonfire",
    "mana well", "camp tent", "lodestone", "fish bowl", "incense candle",
}

Toasts.CAMPFIRE_EXPIRY_WARNING = 2 * 60 * 1000   -- "nearly up": under two minutes

Toasts.CAMPFIRE_TEXT = {
    -- The client's own aura (probe, 2026-11-05): "Welcoming Campfire", id
    -- 1289723, 60 seconds. The Cozy Sleeping Bag claim is the launch client's own
    -- tip, still unconfirmed by an aura read, so it is named as the bag's rule and
    -- not as the fire's.
    fire     = "Fire: Welcoming Campfire, 60 s. Cozy Sleeping Bag: 3 min for +3% XP, 2 h",
    received = "Buff received",
    expires  = "Fire buff expires - find another",
}

local function matchesCampfire(name)
    if type(name) ~= "string" or name == "" or isSecret(name) then return false end
    local text = name:lower()
    for _, word in ipairs(Toasts.CAMPFIRE_NAMES) do
        if text:find(word, 1, true) then return true end
    end
    return false
end

local function clockNow()
    if type(GetTime) ~= "function" then return nil end
    local ok, value = pcall(GetTime)
    return ok and LT:Number(value) or nil
end

-- The fire buff the player is wearing, as { timeLeft = ms or nil }, or nil when
-- no fire aura is present. "not at a fire" and "no aura API answers" are
-- deliberately the same answer: neither is worth a word on screen, and this is
-- off by default anyway.
function Toasts:CampfireBuff()
    local now = clockNow()

    local function record(duration, expiry)
        local timeLeft
        local expires = LT:Number(expiry)
        if now and expires and expires > 0 then
            timeLeft = math.max(0, expires - now) * 1000
        else
            local lasts = LT:Number(duration)
            if lasts and lasts > 0 then timeLeft = lasts * 1000 end
        end
        return { timeLeft = timeLeft }
    end

    if type(C_UnitAuras) == "table" and type(C_UnitAuras.GetAuraDataByIndex) == "function" then
        for index = 1, 40 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, "HELPFUL")
            if not ok or type(aura) ~= "table" then break end
            if matchesCampfire(aura.name) then
                return record(aura.duration, aura.expirationTime)
            end
        end
        return nil
    end

    if type(UnitAura) == "function" then
        for index = 1, 40 do
            local ok, name, _, _, duration, expiry = pcall(UnitAura, "player", index, "HELPFUL")
            if not ok or name == nil then break end
            if matchesCampfire(name) then
                return record(duration, expiry)
            end
        end
        return nil
    end

    if type(UnitBuff) == "function" then
        for index = 1, 40 do
            local ok, name, _, _, duration, expiry = pcall(UnitBuff, "player", index)
            if not ok or name == nil then break end
            if matchesCampfire(name) then
                return record(duration, expiry)
            end
        end
    end

    return nil
end

-- Line 2. The minutes are the buff's own time left, rounded to the nearest
-- minute; with no readable time the line still says the buff landed, because
-- that part is not in doubt.
function Toasts:CampfireReceivedText(buff)
    local timeLeft = type(buff) == "table" and buff.timeLeft or nil
    if not timeLeft then return self.CAMPFIRE_TEXT.received end
    local minutes = math.floor(timeLeft / 60000 + 0.5)
    if minutes < 1 then minutes = 1 end
    return string.format("%s - %d min", self.CAMPFIRE_TEXT.received, minutes)
end

-- Per-fire state. `generation` is stamped on every scheduled step: a fire that
-- ends mid-chain, or a second fire at a different one, drops the stale callback
-- instead of speaking over the new fire's line 1.
local campfire = {
    on         = false,   -- a fire buff is being tracked
    line1At    = nil,     -- GetTime() of line 1, so line 2 waits for the hold
    received   = false,
    expiring   = false,
    generation = 0,
}

local function resetCampfire()
    campfire.on = false
    campfire.line1At = nil
    campfire.received = false
    campfire.expiring = false
    campfire.generation = campfire.generation + 1
end

-- One delayed re-check, guarded like every other client read here. Without
-- C_Timer nothing is scheduled and the next aura pass carries the state on.
function Toasts:CampfireLater(delay, generation)
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return false end
    local seconds = LT:Number(delay) or 1
    if seconds < 1 then seconds = 1 end

    local scheduled = pcall(C_Timer.After, seconds, function()
        if campfire.generation ~= generation then return end
        local ok, err = pcall(function() Toasts:CampfireCheck() end)
        if not ok then LT:Error("The campfire toast failed: " .. tostring(err)) end
    end)

    return scheduled
end

-- One pass over the player's fire buff: say the next line that is due, or
-- nothing. Safe to call on every aura event; the flags are what keep it to one
-- line each.
function Toasts:CampfireCheck()
    if not self:Option("campfireToasts") then
        if campfire.on then resetCampfire() end
        return false
    end

    local buff = self:CampfireBuff()
    if not buff then
        if campfire.on then resetCampfire() end
        return false
    end

    local now = clockNow()

    if not campfire.on then
        campfire.on = true
        campfire.line1At = now
        campfire.received = false
        campfire.expiring = false
        local generation = campfire.generation
        self:Show("campfire", self.CAMPFIRE_TEXT.fire)
        self:CampfireLater(self.HOLD_SECONDS + 1, generation)
        return true
    end

    if not campfire.received then
        -- Line 2 waits for the toast hold so line 1 is read, not replaced. The
        -- timer above normally arrives here; with no timer the next aura pass
        -- does, once the hold has passed.
        if now and campfire.line1At and (now - campfire.line1At) < self.HOLD_SECONDS then
            return false
        end

        campfire.received = true
        self:Show("campfire", self:CampfireReceivedText(buff))

        if buff.timeLeft then
            local delay = (buff.timeLeft - self.CAMPFIRE_EXPIRY_WARNING) / 1000
            self:CampfireLater(delay, campfire.generation)
        end
        return true
    end

    if not campfire.expiring and buff.timeLeft
        and buff.timeLeft <= self.CAMPFIRE_EXPIRY_WARNING then
        campfire.expiring = true
        self:Show("campfire", self.CAMPFIRE_TEXT.expires)
        return true
    end

    return false
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
            "LOOT_OPENED",
            "BAG_UPDATE_DELAYED",
            "PLAYER_REGEN_ENABLED",
            "QUEST_TURNED_IN",
            -- The campfire lines (L-15): the buff arrives as an aura, and a
            -- login with the buff already on has no aura event to fire.
            "UNIT_AURA",
            "PLAYER_ENTERING_WORLD",
        }

        for _, event in ipairs(watched) do
            pcall(listener.RegisterEvent, listener, event)
        end

        listener:SetScript("OnEvent", function(_, event, arg1)
            local okEvent, err = pcall(function()
                if event == "LOOT_OPENED" then
                    Toasts:OnLootOpened()
                elseif event == "BAG_UPDATE_DELAYED" then
                    Toasts:OnBagUpdateDelayed()
                elseif event == "PLAYER_REGEN_ENABLED" then
                    Toasts:OnRegenEnabled()
                elseif event == "QUEST_TURNED_IN" then
                    Toasts:OnQuestTurnedIn()
                elseif event == "UNIT_AURA" then
                    -- Registered without a filter (RegisterUnitEvent is not on
                    -- every supported client), so every other unit is dropped
                    -- here, the same way ShamanHUD does it.
                    if arg1 == "player" then Toasts:CampfireCheck() end
                elseif event == "PLAYER_ENTERING_WORLD" then
                    Toasts:CampfireCheck()
                end
            end)

            if not okEvent then
                LT:Error("The toast failed on " .. tostring(event) .. ": " .. tostring(err))
            end
        end)
    else
        -- Without the listener every toast is silent. Say so once at load
        -- instead of leaving the switches doing nothing.
        LT:Error("The toast could not listen for loot, bags or fires on this client.")
    end
end
