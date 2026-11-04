--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — CharMarks
    Marks the character-pane slot whose best bag item beats what is worn.

    GearCheck:Scan().now already answers the whole question: one row per bag
    item that is usable now and beats the worn item, with the slot it would
    replace. This file only groups those rows by slot (the largest delta wins),
    finds that slot's pane button and hangs one small texture on it. The
    texture takes no mouse; hovering the button names the item, the slot and
    the gain in the tooltip the button already shows.

    Nothing here equips, sells, moves or destroys. A mark is a texture with no
    mouse and no script; the pane button underneath still belongs to the
    client.

    Slot buttons are named after their slot: "Character" .. SLOT_NAMES[slot] ..
    "Slot", e.g. CharacterHeadSlot. The two id-based spellings
    (CharacterSlot<id>, CharacterFrameSlot<id>) are kept as fallbacks. Whichever
    spelling resolves is printed once through LT:Diag; an absent frame means no
    mark.

    Marks are cleared on the pane closing, on BAG_UPDATE_DELAYED, on equipment
    and on build/profile changes. Clearing never scans: the next opening of the
    pane asks GearCheck once more. In combat nothing is scanned and no frame is
    created; an opening during a fight is remembered and retried when the fight
    ends.

    No new global is created: the module is LT.CharMarks and the textures it
    makes are unnamed children of the pane buttons.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local CharMarks = {}
LT.CharMarks = CharMarks
LT.Modules = LT.Modules or {}
LT.Modules.CharMarks = CharMarks

CharMarks.MARK_SIZE = 10
CharMarks.dirty = true

-- The client's own inventory-slot names, keyed by the addon's slot numbers
-- (LT.InventorySlots / ItemStats.equipSlots). The paper-doll button is named
-- after them ("Character" .. name .. "Slot"), and they are also the argument
-- GetInventorySlotInfo needs for the id-based fallbacks.
local SLOT_NAMES = {
    [1]  = "HeadSlot",
    [2]  = "NeckSlot",
    [3]  = "ShoulderSlot",
    [4]  = "ShirtSlot",
    [5]  = "ChestSlot",
    [6]  = "WaistSlot",
    [7]  = "LegsSlot",
    [8]  = "FeetSlot",
    [9]  = "WristSlot",
    [10] = "HandsSlot",
    [11] = "Finger0Slot",
    [12] = "Finger1Slot",
    [13] = "Trinket0Slot",
    [14] = "Trinket1Slot",
    [15] = "BackSlot",
    [16] = "MainHandSlot",
    [17] = "SecondaryHandSlot",
    [18] = "RangedSlot",
    [19] = "TabardSlot",
}

-- Legacy spellings, kept only as fallbacks: they key the button by the id
-- GetInventorySlotInfo returns. On this client family the slot-name spelling
-- above is the one that answers.
local LEGACY_PREFIXES = { "CharacterSlot", "CharacterFrameSlot" }

-- The frame the character pane is drawn in. Hooking its show/hide is the only
-- signal this client gives for the pane opening and closing.
local PANE_NAMES = { "CharacterFrame", "PaperDollFrame" }

local active = {}       -- slot -> row currently marked
local markFrames = {}   -- slot -> { texture, button } reused across opens
local hookedPanes = {}

------------------------------------------------------------------------------
-- Small guarded readers
------------------------------------------------------------------------------

local function isFrame(value)
    local kind = type(value)
    if kind ~= "table" and kind ~= "userdata" then return false end
    return type(value.IsShown) == "function"
        or type(value.HookScript) == "function"
        or type(value.CreateTexture) == "function"
end

local function isSecret(value)
    if type(LT.IsSecret) ~= "function" then return false end
    local ok, result = pcall(LT.IsSecret, LT, value)
    return ok and result == true
end

-- IsShown only reports the frame's own flag; a shown child of a hidden
-- CharacterFrame would answer true. IsVisible accounts for the parents when the
-- client has it, which is the question "is the pane on screen".
local function frameVisible(frame)
    local kind = type(frame)
    if kind ~= "table" and kind ~= "userdata" then return false end

    local fn = frame.IsVisible or frame.IsShown
    if type(fn) ~= "function" then return false end

    local ok, visible = pcall(fn, frame)
    return ok and visible == true
end

local function formatDelta(value)
    local number = tonumber(value)
    if not number then return nil end
    if number >= 0 then return string.format("+%.2f", number) end
    return string.format("%.2f", number)
end

function CharMarks:InCombat()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

function CharMarks:PaneShown()
    if type(_G) ~= "table" then return false end

    for _, name in ipairs(PANE_NAMES) do
        local pane = _G[name]

        if isFrame(pane) and frameVisible(pane) then return true end
    end

    return false
end

------------------------------------------------------------------------------
-- Slot buttons
--
-- The paper-doll button is named after its slot: "Character" .. name .. "Slot".
-- When that global is absent, the id GetInventorySlotInfo returns is tried
-- under both legacy prefixes. A client that does not know the name, or a pane
-- that has no such button, answers nil and the slot is simply not marked.
------------------------------------------------------------------------------

function CharMarks:InventorySlotId(slot)
    if isSecret(slot) then return nil end

    local name = SLOT_NAMES[tonumber(slot) or -1]
    if not name then return nil end
    if type(GetInventorySlotInfo) ~= "function" then return nil end

    local ok, id = pcall(GetInventorySlotInfo, name)
    if not ok then return nil end

    id = tonumber(id)
    if not id or id <= 0 then return nil end
    return id
end

function CharMarks:SlotButton(slot)
    if isSecret(slot) then return nil end

    local index = tonumber(slot)
    if not index then return nil end
    if type(_G) ~= "table" then return nil end

    local name = SLOT_NAMES[index]
    if name then
        local global = "Character" .. name .. "Slot"
        local frame = _G[global]

        if isFrame(frame) and type(frame.CreateTexture) == "function" then
            self:NoteSpelling("slot name", global)
            return frame
        end
    end

    local id = self:InventorySlotId(index)
    if not id then return nil end

    local suffix = tostring(id)
    for _, prefix in ipairs(LEGACY_PREFIXES) do
        local frame = _G[prefix .. suffix]

        if isFrame(frame) and type(frame.CreateTexture) == "function" then
            self:NoteSpelling("legacy id", prefix .. suffix)
            return frame
        end
    end

    return nil
end

-- Which spelling resolves is a once-per-client fact, and a silent guess is what
-- left the marks invisible before. The first hit prints the name that answered;
-- a different spelling later (a replaced button) prints again, so a debug run
-- answers the question instead of leaving the feature quietly dead.
function CharMarks:NoteSpelling(kind, globalName)
    if self.spelling == kind then return end
    self.spelling = kind

    LT:Diag("charmarks: slot buttons resolve as " .. globalName
        .. " (" .. kind .. " spelling).")
end

------------------------------------------------------------------------------
-- The pure part: one winner per slot
------------------------------------------------------------------------------

-- rows is GearCheck's `now` list. A later row only replaces an earlier one when
-- its delta is larger, so exactly one row survives per slot. Losing rows and
-- soon rows are not accepted at all; double-checking the delta here means a
-- caller that hands over the wrong list still cannot paint a downgrade.
function CharMarks:BestBySlot(rows)
    local best = {}
    if type(rows) ~= "table" then return best end

    for index = 1, #rows do
        local row = rows[index]

        if type(row) == "table" and not isSecret(row.slot) and not isSecret(row.delta) then
            local slot = tonumber(row.slot)
            local delta = tonumber(row.delta)

            if slot and delta and delta > 0 then
                local current = best[slot]

                if not current or delta > current.delta then
                    -- A shallow copy keeps the caller's rows untouched and gives
                    -- the comparisons a number even when a caller passed a
                    -- numeric string.
                    local candidate = {}
                    for key, value in pairs(row) do candidate[key] = value end
                    candidate.slot = slot
                    candidate.delta = delta
                    best[slot] = candidate
                end
            end
        end
    end

    return best
end

-- The wording a hover shows. Returns item name, slot label and the delta, or nil
-- when the row cannot describe an upgrade.
function CharMarks:MarkText(row)
    if type(row) ~= "table" then return nil end
    if isSecret(row.delta) then return nil end

    local delta = tonumber(row.delta)
    if not delta or delta <= 0 then return nil end

    local name
    if type(row.name) == "string" and row.name ~= "" then
        name = row.name
    elseif type(row.link) == "string" and row.link ~= "" then
        name = row.link:match("%[(.-)%]") or row.link
    end

    if type(name) ~= "string" or name == "" then return nil end

    local slot = tonumber(row.slot)
    local label

    local itemStats = LT.ItemStats
    if slot and type(itemStats) == "table"
        and type(itemStats.GetSlotLabel) == "function" then
        local ok, value = pcall(itemStats.GetSlotLabel, itemStats, slot)
        if ok and type(value) == "string" and value ~= "" then
            label = value
        end
    end

    if not label then
        label = slot and ("Slot " .. tostring(slot)) or "Unknown slot"
    end

    return name, label, delta
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

local function markColour()
    local palette = LT.Palette
    local colour = palette and palette.named and palette.named.go

    if colour then
        return colour.r, colour.g, colour.b, 1
    end

    return 0.75, 0.48, 1.00, 1
end

-- The explanation goes into the tooltip the slot button already opens: the
-- button owns the mouse, so one hooked OnEnter appends two lines and nothing
-- new ever sits in the button's click path.
local hookedButtons = {}

local function appendHint(slot)
    local row = active[slot]
    if not row then return end

    local tooltip = _G.GameTooltip
    if type(tooltip) ~= "table" or type(tooltip.AddLine) ~= "function" then return end

    -- Only add to a tooltip the client has already opened for this hover.
    if type(tooltip.IsShown) ~= "function" then return end

    local okShown, shown = pcall(tooltip.IsShown, tooltip)
    if not okShown or not shown then return end

    local name, label, delta = CharMarks:MarkText(row)
    local proven = formatDelta(delta)
    if not name or not proven then return end

    local shownName = name
    local palette = LT.Palette
    if type(palette) == "table" and type(palette.Wrap) == "function" then
        local ok, wrapped = pcall(palette.Wrap, palette, "go", name)
        if ok and type(wrapped) == "string" then shownName = wrapped end
    end

    pcall(tooltip.AddLine, tooltip, shownName)
    pcall(tooltip.AddLine, tooltip, tostring(label) .. "   " .. proven)
end

local function hookHint(slot, button)
    if hookedButtons[button] then return end
    if type(button.HookScript) ~= "function" then return end

    local ok = pcall(button.HookScript, button, "OnEnter", function()
        appendHint(slot)
    end)

    if ok then hookedButtons[button] = true end
end

local function anchorMark(mark)
    if not mark or not mark.texture or not mark.button then return end

    pcall(mark.texture.ClearAllPoints, mark.texture)
    pcall(mark.texture.SetPoint, mark.texture, "TOPRIGHT", mark.button,
        "TOPRIGHT", -2, -2)
end

-- One texture on the client's own button: a texture takes no mouse, holds no
-- script and cannot sit between the player and the slot.
local function buildMark(slot, button)
    if CharMarks:InCombat() then return nil end
    if type(button.CreateTexture) ~= "function" then return nil end

    local ok, texture = pcall(button.CreateTexture, button, nil, "OVERLAY")
    if not ok or not texture then return nil end

    local size = CharMarks.MARK_SIZE
    pcall(texture.SetWidth, texture, size)
    pcall(texture.SetHeight, texture, size)

    local mark = { texture = texture, button = button }
    anchorMark(mark)
    pcall(texture.Hide, texture)
    hookHint(slot, button)
    return mark
end

-- The mark is built once per slot and reused. A texture cannot be reparented, so
-- a button the client replaced drops the old hidden texture and the next
-- out-of-combat draw builds a new one on the new button.
function CharMarks:EnsureMark(slot)
    local button = self:SlotButton(slot)
    if not button then return nil end

    local mark = markFrames[slot]

    if mark and mark.button ~= button then
        if mark.texture then pcall(mark.texture.Hide, mark.texture) end
        mark = nil
    end

    if not mark then
        mark = buildMark(slot, button)
        if not mark then return nil end
        markFrames[slot] = mark
    end

    local r, g, b, a = markColour()
    if type(mark.texture.SetColorTexture) == "function" then
        pcall(mark.texture.SetColorTexture, mark.texture, r, g, b, a)
    elseif type(mark.texture.SetTexture) == "function" then
        pcall(mark.texture.SetTexture, mark.texture, r, g, b, a)
    end

    return mark
end

------------------------------------------------------------------------------
-- Clearing and drawing the current answer
------------------------------------------------------------------------------

function CharMarks:ClearMarks()
    for _, mark in pairs(markFrames) do
        if mark.texture then pcall(mark.texture.Hide, mark.texture) end
    end

    active = {}
end

function CharMarks:MarkedCount()
    local count = 0
    for _ in pairs(active) do count = count + 1 end
    return count
end

function CharMarks:ActiveRow(slot)
    if isSecret(slot) then return nil end
    return active[tonumber(slot) or -1]
end

function CharMarks:Apply(best)
    self:ClearMarks()
    if type(best) ~= "table" then return end

    local slots = {}
    for slot in pairs(best) do
        if type(slot) == "number" then table.insert(slots, slot) end
    end
    table.sort(slots)

    for _, slot in ipairs(slots) do
        local row = best[slot]
        local mark = self:EnsureMark(slot)

        if mark then
            active[slot] = row
            pcall(mark.texture.Show, mark.texture)
        end
    end
end

------------------------------------------------------------------------------
-- Opening, closing and invalidating
------------------------------------------------------------------------------

-- One scan per opening. `dirty` only means the answer is no longer trusted; it
-- never starts a scan by itself, because a bag event must not turn into work
-- while the window stays open.
function CharMarks:Resolve()
    if self.resolving then return false end

    if self:InCombat() then
        self.dirty = true
        self.pendingOpen = true
        self:ClearMarks()
        return false
    end

    if not self:PaneShown() then
        self.dirty = true
        return false
    end

    local gearCheck = LT.GearCheck
    if type(gearCheck) ~= "table" or type(gearCheck.Scan) ~= "function" then
        self.dirty = true
        self:ClearMarks()
        return false
    end

    self.resolving = true
    local ok, result = pcall(gearCheck.Scan, gearCheck)
    self.resolving = false

    if not ok or type(result) ~= "table" then
        self.dirty = true
        self:ClearMarks()
        return false
    end

    if result.reason == "combat" then
        self.dirty = true
        self.pendingOpen = true
        self:ClearMarks()
        return false
    end

    if result.reason or type(result.now) ~= "table" then
        -- A module is missing or the client cannot read the bags. No marks is
        -- the honest answer; the next opening asks again.
        self.dirty = true
        self:ClearMarks()
        return false
    end

    local best = self:BestBySlot(result.now)
    self:Apply(best)
    self.dirty = false
    self.pendingOpen = false
    return true
end

function CharMarks:OnPaneShown()
    if not self:PaneShown() then return end

    -- Both CharacterFrame and PaperDollFrame can announce the same opening on a
    -- client that has both. The second signal finds a resolved pane and returns.
    if not self.dirty then return end

    if self:InCombat() then
        -- No scan and no frame creation in a fight. The flag is what the regen
        -- handler retries.
        self.dirty = true
        self.pendingOpen = true
        self:ClearMarks()
        return
    end

    self.pendingOpen = false
    self:Resolve()
end

function CharMarks:OnPaneHidden()
    self.pendingOpen = false
    self.dirty = true
    self:ClearMarks()
end

function CharMarks:Invalidate()
    self.dirty = true
    self:ClearMarks()
end

function CharMarks:EnsureHooked()
    if type(_G) ~= "table" then return false end

    local hooked = false
    local shown = false

    for _, name in ipairs(PANE_NAMES) do
        local pane = _G[name]

        if isFrame(pane) then
            if not hookedPanes[pane] and type(pane.HookScript) == "function" then
                local okShow = pcall(pane.HookScript, pane, "OnShow", function()
                    CharMarks:OnPaneShown()
                end)
                local okHide = pcall(pane.HookScript, pane, "OnHide", function()
                    CharMarks:OnPaneHidden()
                end)

                if okShow or okHide then hookedPanes[pane] = true end
            end

            if hookedPanes[pane] then
                hooked = true
                if frameVisible(pane) then shown = true end
            end
        end
    end

    if shown then self:OnPaneShown() end
    return hooked
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

function CharMarks:OnRegenEnabled()
    self:EnsureHooked()

    if self:InCombat() then return end

    if not self:PaneShown() then
        self.pendingOpen = false
        return
    end

    if self.pendingOpen then
        self.pendingOpen = false
        self:Resolve()
    end
end

function CharMarks:HandleEvent(event, arg1)
    if event == "BAG_UPDATE_DELAYED" then
        self:Invalidate()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        self:OnRegenEnabled()
        return
    end

    -- ADDON_LOADED fires once for every addon, so only this addon's own load is
    -- a signal that the character pane may exist now.
    if event == "ADDON_LOADED" then
        if arg1 ~= LT.name then return end
        self:EnsureHooked()
        return
    end

    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        self:EnsureHooked()
    end
end

local ownFrame

local function moduleFrame()
    local frame = LT.frame
    if type(frame) == "table" or type(frame) == "userdata" then
        if type(frame.RegisterEvent) == "function"
            and type(frame.HookScript) == "function" then
            return frame
        end
    end

    if ownFrame then return ownFrame end
    if CharMarks:InCombat() or type(CreateFrame) ~= "function" then return nil end

    local ok, created = pcall(CreateFrame, "Frame")
    if ok and created then
        ownFrame = created
        return created
    end

    return nil
end

-- One line, once, when the pane gives this file nothing to hang a mark on.
-- LT:Debug rather than a warning: a client with no paper-doll buttons is a
-- degraded case the player cannot act on, but a silent module would leave "no
-- marks" indistinguishable from "no upgrades". The slot-name spelling and the
-- two id spellings are the whole contract, so the message names all of them.
function CharMarks:ReportMissingButtons()
    for slot in pairs(SLOT_NAMES) do
        if self:SlotButton(slot) then return end
    end

    local tried = { "Character" .. (SLOT_NAMES[1] or "HeadSlot") .. "Slot" }
    for _, prefix in ipairs(LEGACY_PREFIXES) do
        table.insert(tried, prefix .. "<id>")
    end

    LT:Debug("charmarks: no character-pane slot button resolved (tried "
        .. table.concat(tried, ", ") .. ").")
end

function CharMarks:Initialize()
    if self.initialized then return true end

    local frame = moduleFrame()
    if not frame then return false end

    self.frame = frame

    for _, event in ipairs({
        "PLAYER_LOGIN",
        "PLAYER_ENTERING_WORLD",
        "ADDON_LOADED",
        "PLAYER_REGEN_ENABLED",
        "BAG_UPDATE_DELAYED",
    }) do
        pcall(frame.RegisterEvent, frame, event)
    end

    local ok = pcall(frame.HookScript, frame, "OnEvent", function(_, event, arg1)
        CharMarks:HandleEvent(event, arg1)
    end)

    if not ok then return false end

    self.initialized = true
    self:EnsureHooked()
    self:ReportMissingButtons()
    return true
end

------------------------------------------------------------------------------
-- Wiring
--
-- The same changes GearCheck invalidates on. Clearing is all this does: the
-- next opening calls Scan once more, so no scan is triggered by a bag event.
-- EVENT_WEIGHTS is deliberately absent: GetEffective fires it while a tooltip
-- is being evaluated, and clearing marks on every tooltip would make them blink.
------------------------------------------------------------------------------

for _, event in ipairs({
    LT.EVENT_BUILDS,
    LT.EVENT_PROFILE,
    LT.EVENT_GEARSET,
    LT.EVENT_LEVEL,
    "EQUIPMENT_CHANGED",
}) do
    if type(event) == "string" and type(LT.On) == "function" then
        pcall(LT.On, LT, event, function()
            CharMarks:Invalidate()
        end, "CharMarks")
    end
end

CharMarks:Initialize()
