--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — BuffMonitor
    Generic buff/imbue/seal/aspect reminder framework.
    Replaces ClassTools.lua. Core owns warning frame, timer, event hooks.
    Per-class definitions register via BuffMonitor:Register(classToken, def).

    Definition table fields:
        id                  string   unique stable identifier
        label               string   shown in warning messages
        optionKey           string   Database options key (bool); nil = always on
        checkFn             func()   returns { active, timeLeft(ms), precise }
        messages            table    { missing=string, expiring=string }
                                     "expiring" may contain {minutes} literal
        expiringThreshold   number   ms before expiry to warn (default 300000)
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local BuffMonitor = {}
LT.BuffMonitor = BuffMonitor
LT.Modules.BuffMonitor = BuffMonitor

local registry  = {}   -- { [classToken] = { definition, ... } }
local checker
local elapsed   = 0
local lastStates = {}  -- { [definitionId] = state }
local warningFrame

local EXPIRING_DEFAULT_MS = 5 * 60 * 1000

------------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------------

function BuffMonitor:Register(classToken, definition)
    if type(classToken) ~= "string" or classToken == "" then
        LT:Warn("BuffMonitor:Register — classToken must be a non-empty string.") ; return false
    end
    if type(definition) ~= "table"
        or type(definition.id) ~= "string" or definition.id == ""
        or type(definition.checkFn) ~= "function" then
        LT:Warn("BuffMonitor:Register — definition requires id (string) and checkFn (function).") ; return false
    end

    registry[classToken] = registry[classToken] or {}
    for _, existing in ipairs(registry[classToken]) do
        if existing.id == definition.id then
            LT:Warn("BuffMonitor:Register — id \"" .. definition.id .. "\" already registered for " .. classToken)
            return false
        end
    end

    table.insert(registry[classToken], definition)
    LT:Debug("BuffMonitor: registered \"" .. definition.id .. "\" for " .. classToken)
    return true
end

function BuffMonitor:GetRegistry() return registry end

------------------------------------------------------------------------------
-- Warning frame
------------------------------------------------------------------------------

local function ensureWarningFrame()
    if warningFrame then return end

    -- No BackdropTemplate: the same four-texture edge as every other window,
    -- with the reminder bar's own warm fill kept so it still reads as a warning
    -- rather than as a dialog.
    warningFrame = CreateFrame("Frame", "LunchboxToolkitBuffWarning", UIParent)
    warningFrame:SetSize(430, 48)
    warningFrame:SetPoint("TOP", UIParent, "TOP", 0, -145)
    warningFrame:SetFrameStrata("HIGH")
    warningFrame:SetClampedToScreen(true)

    LT.Chrome.Window(warningFrame, { fill = LT.Palette.chrome.warningBg })

    warningFrame.text = warningFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    warningFrame.text:SetPoint("CENTER", warningFrame, "CENTER", 0, 0)
    warningFrame.text:SetWidth(380)
    warningFrame.text:SetJustifyH("CENTER")

    -- Dismiss button: hides the popup. It does not come back until the buff
    -- state actually changes (the check only re-announces on a transition).
    local okClose, closeButton = pcall(CreateFrame, "Button", nil, warningFrame, "UIPanelCloseButton")
    if okClose and closeButton then
        closeButton:SetPoint("TOPRIGHT", warningFrame, "TOPRIGHT", 2, 2)
        closeButton:SetScript("OnClick", function() warningFrame:Hide() end)
    end

    warningFrame:Hide()
end

local warningOwner   -- id of the definition whose message is currently shown

local function showWarning(message, urgent, ownerId)
    ensureWarningFrame()
    warningOwner = ownerId
    warningFrame.text:SetText(message)
    -- Urgent is a "no" and a reminder is a "yes, but": the same red and yellow
    -- the rest of the add-on uses, so the bar cannot look like a third state.
    local colour = urgent and LT.Palette.verdict.stop or LT.Palette.verdict.caution
    warningFrame.text:SetTextColor(colour[1], colour[2], colour[3])
    warningFrame:Show()
end

-- Only the definition that owns the popup may hide it, so one definition going
-- "ok" cannot wipe another definition's warning.
local function hideWarning(ownerId)
    if not warningFrame then return end
    if ownerId and warningOwner and warningOwner ~= ownerId then return end
    warningOwner = nil
    warningFrame:Hide()
end

------------------------------------------------------------------------------
-- Per-definition check
------------------------------------------------------------------------------

local function isEnabled(definition)
    if definition.optionKey then
        if not LT.Database then return false end
        local options = LT.Database:GetOptions()
        return options[definition.optionKey] == true
    end
    return true
end

local function checkDefinition(definition)
    if not isEnabled(definition) then return "disabled" end

    -- Optional gate: a definition can say "this does not apply to the character
    -- yet" (for example the spell is not learned). Only an explicit false counts;
    -- an error or a missing answer never suppresses the reminder.
    if type(definition.isAvailable) == "function" then
        local okAvail, available = pcall(definition.isAvailable)
        if okAvail and available == false then return "unavailable" end
    end

    local ok, info = pcall(definition.checkFn)
    if not ok or type(info) ~= "table" then
        LT:Debug("BuffMonitor: checkFn error for " .. tostring(definition.id) .. ": " .. tostring(info))
        return "unknown"
    end

    if not info.active then return "missing" end

    local threshold = definition.expiringThreshold or EXPIRING_DEFAULT_MS
    if info.timeLeft and info.timeLeft > 0 and info.timeLeft <= threshold then
        local minutes = math.max(1, math.ceil(info.timeLeft / 60000))
        return "expiring", minutes, info.precise
    end

    return "ok"
end

local function announceDefinition(definition, state, minutes, precise)
    local last = lastStates[definition.id]
    if state == last then return end
    lastStates[definition.id] = state

    local messages = definition.messages or {}

    if state == "ok" then
        hideWarning(definition.id)
        LT:Debug(tostring(definition.label) .. " status is OK.")
    elseif state == "disabled" or state == "unknown" or state == "unavailable" then
        hideWarning(definition.id)
    elseif state == "missing" then
        local msg = tostring(messages.missing or (definition.label .. " is missing."))
        showWarning(msg, true, definition.id) ; LT:Warn(msg)
    elseif state == "expiring" then
        local raw = tostring(messages.expiring or (definition.label .. " is expiring in about {minutes} minute(s)."))
        local msg = raw:gsub("{minutes}", tostring(minutes or 1))
        if not precise then msg = msg .. " (legacy API)" end
        showWarning(msg, false, definition.id) ; LT:Warn(msg)
    end
end

------------------------------------------------------------------------------
-- Check all definitions for the current class
------------------------------------------------------------------------------

function BuffMonitor:CheckAll()
    if not LT.player then return end
    local defs = registry[LT.player.class]
    if not defs or #defs == 0 then return end

    for _, definition in ipairs(defs) do
        local state, minutes, precise = checkDefinition(definition)
        announceDefinition(definition, state, minutes, precise)
    end
end

------------------------------------------------------------------------------
-- Module lifecycle
------------------------------------------------------------------------------

function BuffMonitor:OnPlayerLogin()  self:CheckAll() end
function BuffMonitor:OnEnterWorld()   self:CheckAll() end

function BuffMonitor:Initialize()
    if checker then return end
    ensureWarningFrame()

    checker = CreateFrame("Frame")
    checker:RegisterEvent("UNIT_INVENTORY_CHANGED")
    checker:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    checker:RegisterEvent("PLAYER_ENTERING_WORLD")
    checker:RegisterEvent("PLAYER_LOGIN")
    pcall(checker.RegisterEvent, checker, "SPELLS_CHANGED")

    checker:SetScript("OnEvent", function(_, event, unit)
        if event == "UNIT_INVENTORY_CHANGED" and unit ~= "player" then return end
        elapsed = 5
        BuffMonitor:CheckAll()
    end)

    checker:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + (delta or 0)
        if elapsed < 5 then return end
        elapsed = 0
        BuffMonitor:CheckAll()
    end)
end
