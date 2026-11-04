--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Trackers
    One small movable frame for the two things a melee player watches during a
    fight, and nothing else:

      * combo points — Rogue, and Druid only while Cat Form is active. Read from
        GetComboPoints when the client has it, otherwise UnitPower with
        Enum.PowerType.ComboPoints. Zero points is a real answer and is drawn;
        no points API at all hides the frame rather than showing a stale number.

      * aura procs — helpful aura names registered by a class plugin through
        RegisterProcAuras. The table starts empty on purpose: no proc name is
        guessed here. A plugin that confirms a name in game can add it.

    The frame is built only outside combat, and only when one of the two options
    is on. It is hidden whenever the option is off, there is no target, or the
    class/form combination cannot generate combo points. A hidden frame does not
    tick, so the 0.25 s refresh only exists while the frame is actually shown.

    The combat-log probe is a diagnostic, not a counter: /lt probe log on asks
    the client for COMBAT_LOG_EVENT_UNFILTERED, prints the shape and names of the
    first ten events, then stops and switches itself off. It never promises a
    damage total, because until those events are seen nobody knows whether this
    client supplies them.

    Nothing here scores anything, changes a weight or touches a saved profile.
    The place is the only thing written, as a fraction of the UI area in the
    account-wide saved store, so every character sees the same small frame.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Trackers = {}
LT.Trackers = Trackers
LT.Modules.Trackers = Trackers

-- Refresh cadence while the frame is shown.
Trackers.UPDATE_INTERVAL = 0.25

-- Last-resort reader only. The preferred answer is GetShapeshiftFormID (Cat
-- is 1), then the Cat Form aura. In the old GetShapeshiftForm numbering the
-- Cat Form button is 3; 1 there is Bear, so it is never treated as cat.
Trackers.CAT_FORM_INDEX = 3

-- Registered proc names, by class token. Empty until a class plugin confirms a
-- name in game; no name is invented here.
local procAuras = {}
Trackers.procAuras = procAuras

local frame
local windfuryFrames = {}
local ALERT_POOL = 6
local comboText, procText

-- Windfury proc detection via swing timing (Forever has no readable combat log).
-- A main-hand swing that lands well before the timer is due is an extra attack,
-- which is what a Windfury proc is. Mirrors HanharEnhancementHUD's Swing.lua.
local SWING_MAIN = 0
local EXTRA_ATTACK_WINDOW = 0.5 -- fraction of weapon speed
local WINDFURY_FLASH = 1.5      -- seconds the WINDFURY! line stays up
local STORMSTRIKE_ID = 17364     -- the addon's own Stormstrike spell id
local ssAt = nil                -- last Stormstrike cast time
local swingState = { lastAt = nil, speed = nil }

-- Windfury on a white swing has no cast, so the only trustworthy attribution
-- is the player's own swing. PLAYER_SWING opens a short window; UNIT_COMBAT
-- damage that lands inside it is ours. Another player's hit cannot open it.
-- Declared here so the swing handlers below never see a nil global.
local SWING_WINDOW = 0.8
local MIN_HIT_DAMAGE = 50 -- below this is a shield/shock tick, not a swing
local swingProcAt = nil
local swingProcSum = 0
local swingProcCrit = false
local swingProcSS = false

local dots = {}
local tickElapsed = 0
local deferredScheduled = false

------------------------------------------------------------------------------
-- Small pure helpers
------------------------------------------------------------------------------

local function clamp01(value)
    local number = tonumber(value)
    if not number then return nil end
    -- Reject NaN without doing arithmetic on a secret: this is only ever called
    -- with numbers read from saved variables or frame geometry.
    if number ~= number then return nil end
    if number < 0 then return 0 end
    if number > 1 then return 1 end
    return number
end

-- Keeps a pixel offset inside the UI area. A frame wider or taller than the
-- area is pinned to the top-left corner rather than pushed off-screen.
function Trackers:ClampOffset(x, y, uiWidth, uiHeight, width, height)
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    uiWidth = tonumber(uiWidth) or 0
    uiHeight = tonumber(uiHeight) or 0
    width = tonumber(width) or 0
    height = tonumber(height) or 0

    local maxX = uiWidth - width
    local maxY = uiHeight - height
    if maxX < 0 then maxX = 0 end
    if maxY < 0 then maxY = 0 end

    if x < 0 then x = 0 elseif x > maxX then x = maxX end
    if y < 0 then y = 0 elseif y > maxY then y = maxY end
    return x, y
end

function Trackers:NormalizeFraction(value)
    return clamp01(value)
end

-- Prefer the legacy reader, fall back to UnitPower. A nil is "no answer", not
-- zero: the caller hides rather than drawing a made-up number.
function Trackers:PickPoints(legacy, power)
    if type(legacy) == "number" then return legacy, "GetComboPoints" end
    if type(power) == "number" then return power, "UnitPower" end
    return nil, "unavailable"
end

-- Cat Form is decided by the form ID or the aura when those answer; the old
-- form index (index 3, never 1) is the last resort.
function Trackers:IsCat(catAura, formIndex)
    if catAura == true then return true end
    if catAura == false then return false end
    return formIndex == self.CAT_FORM_INDEX
end

function Trackers:ShouldShow(enabled, classToken, hasTarget, catAura, formIndex)
    if enabled ~= true then return false end
    if hasTarget ~= true then return false end
    if classToken == "ROGUE" then return true end
    if classToken == "DRUID" then return self:IsCat(catAura, formIndex) end
    return false
end

function Trackers:FormatPoints(points)
    local number = tonumber(points)
    if not number then return "n/a" end
    if number < 0 then number = 0 elseif number > 5 then number = 5 end
    return tostring(math.floor(number)) .. "/5"
end

------------------------------------------------------------------------------
-- Guarded client reads
------------------------------------------------------------------------------

function Trackers:CombatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

function Trackers:ClassToken()
    local player = LT.player
    local classToken = player and player.class
    if type(classToken) ~= "string" or classToken == "" then return "UNKNOWN" end
    return classToken
end

function Trackers:Options()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return nil
    end
    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then return nil end
    return options
end

local function setOption(key, value)
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return false
    end
    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then return false end
    options[key] = value
    return true
end

function Trackers:IsEnabled()
    local options = self:Options()
    return options ~= nil and options.comboTracker == true
end

function Trackers:ProbeWanted()
    local options = self:Options()
    return options ~= nil and options.combatLogProbe == true
end

function Trackers:UnitHasTarget()
    if type(UnitExists) ~= "function" then return false end
    local ok, exists = pcall(UnitExists, "target")
    if not ok then return false end
    return exists == true or exists == 1
end

local function numericSafe(value)
    if type(value) ~= "number" then return nil end
    if LT:IsSecret(value) then return nil end
    return value
end

-- Both readers are separated so the probe can show what each one returned.
function Trackers:ReadLegacyPoints()
    if type(GetComboPoints) ~= "function" then return nil end
    local ok, value = pcall(GetComboPoints, "player", "target")
    if not ok then return nil end
    return numericSafe(value)
end

function Trackers:ReadPowerPoints()
    if type(UnitPower) ~= "function" then return nil end
    if type(Enum) ~= "table" or type(Enum.PowerType) ~= "table" then return nil end
    local index = Enum.PowerType.ComboPoints
    if type(index) ~= "number" then return nil end
    local ok, value = pcall(UnitPower, "player", index)
    if not ok then return nil end
    return numericSafe(value)
end

function Trackers:ReadPoints()
    return self:PickPoints(self:ReadLegacyPoints(), self:ReadPowerPoints())
end

function Trackers:ReadFormIndex()
    if type(GetShapeshiftForm) ~= "function" then return nil end
    local ok, value = pcall(GetShapeshiftForm)
    if not ok then return nil end
    return numericSafe(value)
end

-- Preferred reader: the shapeshift form ID, where Cat Form is 1. Missing on
-- older clients, which fall back to the aura and finally to the index.
function Trackers:ReadFormID()
    if type(GetShapeshiftFormID) ~= "function" then return nil end
    local ok, value = pcall(GetShapeshiftFormID)
    if not ok then return nil end
    return numericSafe(value)
end

-- Returns a set of helpful aura names, or nil when no aura API can answer.
function Trackers:CollectHelpfulAuras()
    local names = {}
    local usable = false

    if type(C_UnitAuras) == "table" and type(C_UnitAuras.GetAuraDataByIndex) == "function" then
        for index = 1, 40 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, "HELPFUL")
            if not ok then break end
            usable = true
            if type(aura) ~= "table" then break end
            local name = aura.name
            if type(name) == "string" and not LT:IsSecret(name) then names[name] = true end
        end
        if usable then return names end
    end

    if type(UnitAura) == "function" then
        for index = 1, 40 do
            local ok, name = pcall(UnitAura, "player", index, "HELPFUL")
            if not ok then break end
            usable = true
            if name == nil then break end
            if type(name) == "string" and not LT:IsSecret(name) then names[name] = true end
        end
        if usable then return names end
    end

    if type(UnitBuff) == "function" then
        for index = 1, 40 do
            local ok, name = pcall(UnitBuff, "player", index)
            if not ok then break end
            usable = true
            if name == nil then break end
            if type(name) == "string" and not LT:IsSecret(name) then names[name] = true end
        end
        if usable then return names end
    end

    return nil
end

-- The form ID answers first (Cat is 1), the Cat Form aura second, and the old
-- shapeshift index only when neither exists. The third return names the route
-- that answered, so /lt probe can show which one this client uses.
-- Returns catAura, formIndex, route.
function Trackers:FormState()
    local formID = self:ReadFormID()
    if formID ~= nil then
        return formID == 1, nil, "GetShapeshiftFormID"
    end

    local auras = self:CollectHelpfulAuras()
    if auras then
        return auras["Cat Form"] == true, nil, "aura"
    end

    local formIndex = self:ReadFormIndex()
    if formIndex ~= nil then
        return nil, formIndex, "GetShapeshiftForm"
    end

    return nil, nil, "none"
end

------------------------------------------------------------------------------
-- Proc registration and scan
------------------------------------------------------------------------------

-- A class plugin calls this once it has confirmed the aura names in game.
-- Duplicates are ignored; an empty list changes nothing.
function Trackers:RegisterProcAuras(classToken, names)
    if type(classToken) ~= "string" or classToken == "" then return 0 end
    if type(names) ~= "table" then return 0 end

    local list = procAuras[classToken]
    if not list then
        list = {}
        procAuras[classToken] = list
    end

    local known = {}
    for _, name in ipairs(list) do known[name] = true end

    local added = 0
    for _, name in ipairs(names) do
        if type(name) == "string" and name ~= "" and not LT:IsSecret(name) and not known[name] then
            list[#list + 1] = name
            known[name] = true
            added = added + 1
        end
    end
    return added
end

function Trackers:ActiveProcs()
    local list = procAuras[self:ClassToken()]
    if type(list) ~= "table" or #list == 0 then return {} end

    local present = self:CollectHelpfulAuras()
    if not present then return {} end

    local active = {}
    for _, name in ipairs(list) do
        if present[name] then active[#active + 1] = name end
    end
    return active
end

------------------------------------------------------------------------------
-- Saved place (account-wide)
------------------------------------------------------------------------------

local function readPlacement()
    local store = LunchboxToolkitDB
    if type(store) ~= "table" then return nil end
    local record = store.trackers
    if type(record) ~= "table" then return nil end
    return record
end

local function writePlacement()
    LunchboxToolkitDB = LunchboxToolkitDB or {}
    local record = LunchboxToolkitDB.trackers
    if type(record) ~= "table" then
        record = {}
        LunchboxToolkitDB.trackers = record
    end
    return record
end

local function screenSize()
    if not UIParent then return 0, 0 end
    if type(UIParent.GetWidth) ~= "function" or type(UIParent.GetHeight) ~= "function" then
        return 0, 0
    end
    local okWidth, width = pcall(UIParent.GetWidth, UIParent)
    local okHeight, height = pcall(UIParent.GetHeight, UIParent)
    if not okWidth or not okHeight then return 0, 0 end
    return tonumber(width) or 0, tonumber(height) or 0
end

function Trackers:Place()
    if not frame then return end

    local uiWidth, uiHeight = screenSize()
    if uiWidth <= 0 or uiHeight <= 0 then return end

    local okWidth, width = pcall(frame.GetWidth, frame)
    local okHeight, height = pcall(frame.GetHeight, frame)
    width = okWidth and tonumber(width) or 116
    height = okHeight and tonumber(height) or 30

    local record = readPlacement()
    local fractionX, fractionY = nil, nil
    if record then
        fractionX = self:NormalizeFraction(record.x)
        fractionY = self:NormalizeFraction(record.y)
    end

    local x, y
    if fractionX then x = fractionX * uiWidth else x = (uiWidth - width) / 2 end
    if fractionY then y = fractionY * uiHeight else y = uiHeight * 0.62 end

    x, y = self:ClampOffset(x, y, uiWidth, uiHeight, width, height)

    local anchor = UIParent
    if not anchor then return end
    pcall(frame.ClearAllPoints, frame)
    pcall(frame.SetPoint, frame, "TOPLEFT", anchor, "TOPLEFT", x, -y)
end

function Trackers:SavePlace()
    if not frame then return end

    local record = writePlacement()
    local uiWidth, uiHeight = screenSize()
    if uiWidth <= 0 or uiHeight <= 0 then return end

    local okScale, scale = pcall(frame.GetEffectiveScale, frame)
    scale = okScale and tonumber(scale) or nil
    if not scale or scale <= 0 then return end

    local okLeft, left = pcall(frame.GetLeft, frame)
    local okTop, top = pcall(frame.GetTop, frame)
    left = okLeft and tonumber(left) or nil
    top = okTop and tonumber(top) or nil
    if not left or not top then return end

    if not UIParent then return end
    if type(UIParent.GetLeft) ~= "function" or type(UIParent.GetTop) ~= "function" then return end
    local okUiLeft, uiLeft = pcall(UIParent.GetLeft, UIParent)
    local okUiTop, uiTop = pcall(UIParent.GetTop, UIParent)
    uiLeft = okUiLeft and tonumber(uiLeft) or nil
    uiTop = okUiTop and tonumber(uiTop) or nil
    if not uiLeft or not uiTop then return end

    record.x = clamp01(((left - uiLeft) / scale) / uiWidth) or 0
    record.y = clamp01(((uiTop - top) / scale) / uiHeight) or 0
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

local function colourOf(key, fallback)
    local palette = LT.Palette
    if type(palette) == "table" and type(palette.RGB) == "function" then
        local ok, value = pcall(palette.RGB, palette, key)
        if ok and type(value) == "table" then return value end
    end
    return fallback
end

local function paint(texture, r, g, b, alpha)
    if not texture then return end
    if type(texture.SetColorTexture) == "function" then
        pcall(texture.SetColorTexture, texture, r, g, b, alpha)
    elseif type(texture.SetTexture) == "function" then
        pcall(texture.SetTexture, texture, r, g, b, alpha)
    end
end

function Trackers:DrawPoints(points)
    local number = tonumber(points)
    if not number then return end
    if number < 0 then number = 0 elseif number > 5 then number = 5 end
    number = math.floor(number)

    if comboText and type(comboText.SetText) == "function" then
        pcall(comboText.SetText, comboText, self:FormatPoints(number))
    end

    local filledColour = colourOf("go", { r = 0.75, g = 0.48, b = 1.00 })
    local emptyColour = colourOf("stop", { r = 0.55, g = 0.55, b = 0.55 })
    for index, dot in ipairs(dots) do
        local filled = index <= number
        local colour = filled and filledColour or emptyColour
        paint(dot, colour.r or 1, colour.g or 1, colour.b or 1, filled and 1 or 0.4)
    end
end

function Trackers:DrawProcs()
    local active = self:ActiveProcs()
    if not procText then return end

    local visible = #active > 0
    if visible then
        if type(procText.SetText) == "function" then
            pcall(procText.SetText, procText, table.concat(active, ", "))
        end
        if type(procText.Show) == "function" then pcall(procText.Show, procText) end
        if frame and type(frame.SetHeight) == "function" then pcall(frame.SetHeight, frame, 44) end
    else
        if type(procText.Hide) == "function" then pcall(procText.Hide, procText) end
        if frame and type(frame.SetHeight) == "function" then pcall(frame.SetHeight, frame, 30) end
    end

    -- The frame is taller while a proc line is shown, so an edge-adjacent frame
    -- is re-clamped at the moment the line appears or goes away.
    if visible ~= self.procLineShown then
        self.procLineShown = visible
        if self:IsShown() then self:Place() end
    end
end

------------------------------------------------------------------------------
-- Frame lifecycle
------------------------------------------------------------------------------

local function buildFrame()
    if frame then return frame end
    if Trackers:CombatLocked() then return nil end
    if type(CreateFrame) ~= "function" then return nil end

    -- A previous failed attempt must not leave half-built widgets behind.
    dots = {}
    comboText, procText = nil, nil

    local ok, window = pcall(CreateFrame, "Frame", nil, UIParent)
    if not ok or not window then
        ok, window = pcall(CreateFrame, "Frame")
        if not ok or not window then return nil end
    end

    if type(window.SetFrameStrata) == "function" then pcall(window.SetFrameStrata, window, "MEDIUM") end
    if type(window.SetClampedToScreen) == "function" then pcall(window.SetClampedToScreen, window, true) end
    if type(window.SetMovable) == "function" then pcall(window.SetMovable, window, true) end
    if type(window.EnableMouse) == "function" then pcall(window.EnableMouse, window, true) end
    if type(window.RegisterForDrag) == "function" then
        pcall(window.RegisterForDrag, window, "LeftButton")
    end
    if type(window.SetSize) == "function" then pcall(window.SetSize, window, 116, 30) end

    if type(window.CreateTexture) == "function" then
        local okBackground, texture = pcall(window.CreateTexture, window, nil, "BACKGROUND")
        if okBackground and texture then
            if type(texture.SetAllPoints) == "function" then pcall(texture.SetAllPoints, texture, window) end
            paint(texture, 0, 0, 0, 0.55)
        end
    end

    if type(window.CreateFontString) == "function" then
        local okText, text = pcall(window.CreateFontString, window, nil, "OVERLAY", "GameFontNormalSmall")
        if okText and text then
            comboText = text
            if type(text.SetPoint) == "function" then
                pcall(text.SetPoint, text, "TOPLEFT", window, "TOPLEFT", 8, -5)
            end
            if type(text.SetTextColor) == "function" then
                local colour = colourOf("text", { r = 0.95, g = 0.95, b = 0.95 })
                pcall(text.SetTextColor, text, colour.r or 1, colour.g or 1, colour.b or 1)
            end
        end

        local okProc, proc = pcall(window.CreateFontString, window, nil, "OVERLAY", "GameFontNormalSmall")
        if okProc and proc then
            procText = proc
            if type(proc.SetPoint) == "function" then
                pcall(proc.SetPoint, proc, "BOTTOMLEFT", window, "BOTTOMLEFT", 8, 20)
            end
            if type(proc.SetWidth) == "function" then pcall(proc.SetWidth, proc, 100) end
            if type(proc.SetTextColor) == "function" then
                local colour = colourOf("caution", { r = 0.20, g = 1.00, b = 0.20 })
                pcall(proc.SetTextColor, proc, colour.r or 1, colour.g or 1, colour.b or 1)
            end
            if type(proc.Hide) == "function" then pcall(proc.Hide, proc) end
        end
    end

    local dotColour = { 0.75, 0.48, 1.00 }
    for index = 1, 5 do
        if type(window.CreateTexture) ~= "function" then break end
        local okDot, dot = pcall(window.CreateTexture, window, nil, "ARTWORK")
        if not okDot or not dot then break end
        if type(dot.SetSize) == "function" then pcall(dot.SetSize, dot, 10, 10) end
        if type(dot.SetPoint) == "function" then
            pcall(dot.SetPoint, dot, "BOTTOMLEFT", window, "BOTTOMLEFT", 10 + (index - 1) * 16, 6)
        end
        paint(dot, dotColour[1], dotColour[2], dotColour[3], 0.4)
        dots[#dots + 1] = dot
    end

    if type(window.SetScript) == "function" then
        window:SetScript("OnEvent", function(_, event, arg1, arg2)
            pcall(Trackers.OnEvent, Trackers, event, arg1, arg2)
        end)

        window:SetScript("OnUpdate", function(_, delta)
            tickElapsed = tickElapsed + (tonumber(delta) or 0)
            if tickElapsed < Trackers.UPDATE_INTERVAL then return end
            tickElapsed = 0
            Trackers:Refresh()
        end)

        window:SetScript("OnDragStart", function(self)
            if type(self.StartMoving) == "function" then pcall(self.StartMoving, self) end
        end)

        window:SetScript("OnDragStop", function(self)
            if type(self.StopMovingOrSizing) == "function" then
                pcall(self.StopMovingOrSizing, self)
            end
            Trackers:SavePlace()
        end)
    end

    -- Every event is registered with pcall: this client may not know a name.
    -- PLAYER_SWING, UNIT_ATTACK_SPEED and PLAYER_ENTERING_WORLD belong to the
    -- windfury listener frame; registering them here too ran the swing handler
    -- twice per swing.
    for _, eventName in ipairs({
        "PLAYER_TARGET_CHANGED",
        "PLAYER_REGEN_ENABLED",
        "UPDATE_SHAPESHIFT_FORM",
        "UPDATE_SHAPESHIFT_FORMS",
    }) do
        if type(window.RegisterEvent) == "function" then
            pcall(window.RegisterEvent, window, eventName)
        end
    end

    frame = window
    Trackers:Place()
    if type(window.Hide) == "function" then pcall(window.Hide, window) end
    return window
end

function Trackers:CanDefer()
    return type(C_Timer) == "table" and type(C_Timer.After) == "function"
end

local function scheduleDeferred()
    if deferredScheduled then return end
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return end

    deferredScheduled = true
    local ok = pcall(C_Timer.After, 2, function()
        deferredScheduled = false
        Trackers:AttemptDeferred()
    end)
    if not ok then deferredScheduled = false end
end

function Trackers:Refresh()
    if not frame then return false end

    if not self:IsEnabled() then
        if type(frame.Hide) == "function" then pcall(frame.Hide, frame) end
        return false
    end

    local classToken = self:ClassToken()
    local hasTarget = self:UnitHasTarget()

    local catAura, formIndex = nil, nil
    if classToken == "DRUID" then
        catAura, formIndex = self:FormState()
    end

    if not self:ShouldShow(true, classToken, hasTarget, catAura, formIndex) then
        if type(frame.Hide) == "function" then pcall(frame.Hide, frame) end
        return false
    end

    local points = self:ReadPoints()
    if points == nil then
        if type(frame.Hide) == "function" then pcall(frame.Hide, frame) end
        return false
    end

    self.lastPoints = points
    self:DrawPoints(points)
    self:DrawProcs()

    if type(frame.IsShown) ~= "function" or not frame:IsShown() then
        self:Place()
        if type(frame.Show) == "function" then pcall(frame.Show, frame) end
    end
    return true
end

function Trackers:Tick()
    if frame then self:Refresh() end
end

-- Data accessor for the server state, so a caller never reaches into the frame.
function Trackers:IsShown()
    if not frame then return false end
    if type(frame.IsShown) ~= "function" then return false end
    return frame:IsShown() and true or false
end

-- Colour and dwell follow the label: plain proc is blue and brief, a record is
-- yellow and lingers, a crit is red. The frame is draggable and remembers
-- where it was dropped.
local ALERT_COLOUR = {
    plain  = { 0.45, 0.85, 1.00 },
    record = { 1.00, 0.85, 0.20 },
    crit   = { 1.00, 0.30, 0.15 },
}

local function alertKind(text)
    if type(text) ~= "string" then return "plain" end
    local lower = text:lower()
    if lower:find("record", 1, true) then return "record" end
    if lower:find("crit", 1, true) then return "crit" end
    return "plain"
end

local function createAlertFrame(index)
    local ok, f = pcall(CreateFrame, "Frame", "LunchboxToolkitWindfuryAlert" .. index, UIParent)
    if not ok or not f then return nil end
    f:SetSize(260, 34)
    f:SetFrameStrata("TOOLTIP")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        self.basePoint, self.baseRel, self.baseX, self.baseY = point, relPoint, x, y
        local store = LunchboxToolkitDB
        if store then
            store.windfuryAlertPos = {
                point = point, relPoint = relPoint, x = x, y = y,
            }
        end
    end)
    local fs = f:CreateFontString(nil, "OVERLAY")
    if STANDARD_TEXT_FONT then
        pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, 22, "OUTLINE")
    end
    if type(fs.SetPoint) == "function" then
        pcall(fs.SetPoint, fs, "CENTER", f, "CENTER", 0, 0)
    end
    f.text = fs
    if type(f.Hide) == "function" then pcall(f.Hide, f) end

    local store = LunchboxToolkitDB
    local pos = store and store.windfuryAlertPos
    if type(pos) == "table" and type(pos.point) == "string" then
        f.basePoint = pos.point
        f.baseRel = pos.relPoint or pos.point
        f.baseX = tonumber(pos.x) or 0
        f.baseY = tonumber(pos.y) or 0
    else
        f.basePoint, f.baseRel, f.baseX, f.baseY = "CENTER", "CENTER", 0, 160
    end
    f.basePoint = f.basePoint or "CENTER"
    f.baseRel = f.baseRel or "CENTER"
    f.baseX = f.baseX or 0
    f.baseY = f.baseY or 160
    return f
end

local function freeAlertFrame()
    for _, f in ipairs(windfuryFrames) do
        if not f.animating then return f end
    end
    if #windfuryFrames < ALERT_POOL then
        local f = createAlertFrame(#windfuryFrames + 1)
        if f then table.insert(windfuryFrames, f) end
        return f
    end
    return windfuryFrames[1]
end

function Trackers:FlashWindfury(text, dwellOverride, static)
    -- Windfury is a Shaman mechanic: the alert is never drawn for another class.
    if not LT:IsClass("SHAMAN") then return end
    local db = LunchboxToolkitDB
    if db and db.windfuryAlertOn == false and not static then return end

    text = text or "Windfury!"
    local kind = alertKind(text)
    local colour = ALERT_COLOUR[kind]
    local dwell = dwellOverride or 2.5
    if not dwellOverride then
        if kind == "record" then dwell = 4.0 elseif kind == "crit" then dwell = 3.5 end
    end

    local f = freeAlertFrame()
    if not f then return end
    f.animating = true

    if f.text then
        if type(f.text.SetText) == "function" then pcall(f.text.SetText, f.text, text) end
        if type(f.text.SetTextColor) == "function" then
            pcall(f.text.SetTextColor, f.text, colour[1], colour[2], colour[3])
        end
    end
    pcall(f.ClearAllPoints, f)
    pcall(f.SetPoint, f, f.basePoint, UIParent, f.baseRel, f.baseX, f.baseY)
    if type(f.SetAlpha) == "function" then pcall(f.SetAlpha, f, 1) end
    if type(f.SetScript) == "function" then pcall(f.SetScript, f, "OnUpdate", nil) end
    if type(f.Show) == "function" then pcall(f.Show, f) end

    if static then
        -- Hold still so it can be dragged; no animation to fight the drag.
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            pcall(C_Timer.After, dwell, function()
                f.animating = false
                if type(f.Hide) == "function" then pcall(f.Hide, f) end
            end)
        end
        return
    end

    -- Scroll up while fading out, like a scrolling combat text line.
    if type(f.SetScript) == "function" then
        local elapsed = 0
        f:SetScript("OnUpdate", function(self, delta)
            elapsed = elapsed + (tonumber(delta) or 0)
            local frac = elapsed / dwell
            if frac >= 1 then
                self:SetScript("OnUpdate", nil)
                self:Hide()
                self.animating = false
                return
            end
            self:ClearAllPoints()
            self:SetPoint(self.basePoint, UIParent, self.baseRel, self.baseX,
                self.baseY + frac * 70)
            if frac > 0.55 then
                self:SetAlpha(math.max(0, 1 - (frac - 0.55) / 0.45))
            else
                self:SetAlpha(1)
            end
        end)
    end
end

-- Windfury detection: a main-hand swing that lands well before the timer is
-- due is an extra attack (a proc). This is how Forever-aware Shaman HUDs find
-- it without a combat log. Duration is the swing's length; swingType 0 = MH.
local function armSwingFlush(mark)
    if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then return end
    pcall(C_Timer.After, SWING_WINDOW + 0.15, function()
        if swingProcAt ~= mark then return end
        local total = swingProcSum
        local crit = swingProcCrit
        local fromSS = swingProcSS
        swingProcAt = nil
        swingProcSum = 0
        if total > 0 then
            Trackers:RecordWindfury(total, crit, fromSS)
        end
    end)
end

function Trackers:OnSwing(duration, swingType)
    if self.wfProbe then
        LT:Print(string.format("wf swing: dur=%s type=%s last=%s speed=%s",
            tostring(duration), tostring(swingType),
            swingState.lastAt and string.format("%.2f", GetTime() - swingState.lastAt) or "none",
            tostring(swingState.speed)))
    end
    if numericSafe(swingType) ~= SWING_MAIN then return end
    local d = numericSafe(duration)
    local speed = (d and d > 0) and d or swingState.speed
    if not speed then return end

    local now = GetTime()
    if swingState.lastAt and swingState.speed
        and (now - swingState.lastAt) < swingState.speed * EXTRA_ATTACK_WINDOW then
        -- An early swing is the Windfury extra attack. Open the window so the
        -- damage that follows is attributed to us.
        swingProcAt = now
        swingProcSum = 0
        swingProcCrit = false
        swingProcSS = ssAt ~= nil and (now - ssAt) <= SWING_WINDOW
        armSwingFlush(now)
        return
    end
    swingState.lastAt = now
    swingState.speed = speed
end

function Trackers:OnSpeedChange()
    if type(UnitAttackSpeed) ~= "function" then return end
    local ok, speed = pcall(UnitAttackSpeed, "player")
    if not ok then return end
    local s = numericSafe(speed)
    if s and s > 0 then swingState.speed = s end
end

-- Two separate lists: one for a two-hander, one for dual-wield. The old single
-- list folds into the 2H list on first read.
local function windfuryStore(setup)
    LunchboxToolkitDB = LunchboxToolkitDB or {}
    local store = LunchboxToolkitDB
    if type(store.windfuryRecords2H) ~= "table" then
        store.windfuryRecords2H = type(store.windfuryRecords) == "table"
            and store.windfuryRecords or {}
    end
    if type(store.windfuryRecordsDW) ~= "table" then store.windfuryRecordsDW = {} end
    if setup == "DW" then return store.windfuryRecordsDW end
    return store.windfuryRecords2H
end

function Trackers:WeaponSetup()
    if type(GetInventoryItemLink) ~= "function" then return "2H" end
    local ok, link = pcall(GetInventoryItemLink, "player", 17)
    if not ok or type(link) ~= "string" or link == "" then return "2H" end
    if type(C_Item) ~= "table" or type(C_Item.GetItemInfoInstant) ~= "function" then
        return "2H"
    end
    local okInfo, _, _, _, equipLoc = pcall(C_Item.GetItemInfoInstant, link)
    if okInfo and (equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONOFFHAND") then
        return "DW"
    end
    return "2H"
end

function Trackers:OnCombat(unit, action, flag, amount)
    if self.wfProbe then
        local secret = "?"
        if type(LT.IsSecret) == "function" then
            local ok, s = pcall(LT.IsSecret, LT, amount)
            secret = ok and tostring(s) or "?"
        end
        LT:Print(string.format("wf: unit=%s act=%s flag=%s amt=%s secret=%s proc=%s",
            tostring(unit), tostring(action), tostring(flag), tostring(amount), secret,
            tostring(swingProcAt ~= nil)))
    end
    local token = tostring(unit)
    -- The target's own events are the only ones that carry our damage to it.
    -- nameplate is the twin of the same event, so it is ignored.
    if token ~= "target" then return end
    local act = type(action) == "string" and action:upper() or ""
    if act ~= "WOUND" and act ~= "CRITICAL" then return end
    local amt = numericSafe(amount)
    if not amt or amt <= MIN_HIT_DAMAGE then return end

    local now = GetTime()
    -- Only damage inside a window opened by our own swing counts as Windfury.
    -- Another player's hit cannot open or extend it.
    if not swingProcAt or (now - swingProcAt) > SWING_WINDOW then return end
    swingProcSum = swingProcSum + amt
    if type(flag) == "string" and flag:upper() == "CRITICAL" then swingProcCrit = true end
end

function Trackers:OnSpellcast(unit, spellID)
    if tostring(unit) ~= "player" then return end
    local id = numericSafe(spellID)
    if self.wfProbe then
        local name = "?"
        if type(GetSpellInfo) == "function" and id then
            local ok, n = pcall(GetSpellInfo, id)
            if ok and type(n) == "string" then name = n end
        end
        LT:Print(string.format("wf cast: spell=%s name=%s", tostring(spellID), name))
    end
    if id == STORMSTRIKE_ID then ssAt = GetTime() end
end

function Trackers:RecordWindfury(total, crit, ss)
    if self:ClassToken() ~= "SHAMAN" then return end
    local setup = self:WeaponSetup()
    local store = windfuryStore(setup)
    local target = UnitName("target")
    if type(target) ~= "string" or LT:IsSecret(target) then target = "unknown" end
    local entry = {
        amount = total,
        level = numericSafe(UnitLevel("player")) or 0,
        targetLevel = numericSafe(UnitLevel("target")) or 0,
        target = target,
        crit = crit == true,
        ss = ss == true,
    }
    table.insert(store, entry)
    table.sort(store, function(a, b)
        return (tonumber(a.amount) or 0) > (tonumber(b.amount) or 0)
    end)
    while #store > 5 do table.remove(store) end

    local kept = false
    for _, item in ipairs(store) do
        if item == entry then kept = true break end
    end

    -- A new top-5 entry is announced in chat too, so it can be seen even with
    -- the popup open.
    if kept then
        local name = UnitName("player")
        if type(name) ~= "string" or LT:IsSecret(name) then name = "Player" end
        local shownTarget = entry.target
        if type(shownTarget) ~= "string" or LT:IsSecret(shownTarget) then
            shownTarget = "unknown"
        end
        local critTag = entry.crit and " |cffff3030CRIT|r" or ""
        LT:Print(string.format("New WF (%s) record: %s (%d) landed a WF on %s of %d!%s",
            setup, name, tonumber(entry.level) or 0,
            shownTarget, math.floor(tonumber(entry.amount) or 0), critTag))
    end

    -- Show the damage total on the alert, and mark a new record.
    local amount = math.floor(tonumber(total) or 0)
    local kindName = entry.ss and "SS-WF" or "WF"
    local base = entry.crit and ("Critical " .. kindName .. "!!") or (kindName .. "!")
    local label = base .. " (" .. amount .. ")"
    if kept then label = label .. " New Record!" end
    self:FlashWindfury(label)
end

function Trackers:WindfuryRecords(setup)
    return windfuryStore(setup)
end

function Trackers:ResetWindfuryRecords()
    local db = LunchboxToolkitDB
    if not db then return false end
    db.windfuryRecords = nil
    db.windfuryRecords2H = {}
    db.windfuryRecordsDW = {}
    return true
end

function Trackers:OnEvent(event, arg1, arg2)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        self:OnCombatLogEvent()
        return
    end

    if event == "PLAYER_TARGET_CHANGED"
        or event == "UPDATE_SHAPESHIFT_FORM"
        or event == "UPDATE_SHAPESHIFT_FORMS" then
        self:Refresh()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if self.pendingCombo or self.pendingLog or self.pendingCombatFrame
            or ((self:IsEnabled() or self:ProbeWanted()) and not frame) then
            self:AttemptDeferred()
        elseif frame then
            self:Refresh()
        end
    end
end

------------------------------------------------------------------------------
-- Options and deferred start
------------------------------------------------------------------------------

function Trackers:AttemptDeferred()
    if self.deferring then return end
    self.deferring = true

    if self:CombatLocked() then
        self.deferring = false
        if self.pendingCombo or self.pendingLog or self.pendingCombatFrame then
            scheduleDeferred()
        end
        return
    end

    local wanted = self:IsEnabled() or self:ProbeWanted()
        or self.pendingCombo or self.pendingLog or self.pendingCombatFrame

    if not wanted then
        self.deferring = false
        return
    end

    if not frame then
        if not buildFrame() then
            self.deferring = false
            return
        end
    end

    if self.pendingLog or (self:ProbeWanted() and not self.logArmed) then
        self.pendingLog = false
        self:ArmLog()
    end

    self.pendingCombo = false
    self.pendingCombatFrame = false
    self.deferring = false
    self:Refresh()
end

-- Returns "on", "off", "deferred" or "failed".
function Trackers:SetEnabled(on)
    on = on == true
    setOption("comboTracker", on)

    if not on then
        self.pendingCombo = false
        if frame and type(frame.Hide) == "function" then pcall(frame.Hide, frame) end
        return "off"
    end

    if self:CombatLocked() then
        self.pendingCombo = true
        self.pendingCombatFrame = true
        scheduleDeferred()
        return "deferred"
    end

    if not buildFrame() then
        self.pendingCombo = true
        return "failed"
    end

    self.pendingCombo = false
    self:Refresh()
    return "on"
end

-- The Windfury source is its own frame: it runs whether or not the
-- combo-point frame is enabled, since a Shaman does not show that frame.
local windfuryEvents
-- nil until the listener is built, then true/false for "the client accepted
-- PLAYER_SWING". The client can refuse that event outright (measured 2026-11-03), and
-- without it a proc cannot be told from a normal swing, so the addon must say so
-- instead of recording nothing.
local swingRegistered = nil

function Trackers:WindfuryAvailable()
    return swingRegistered
end

local function ensureWindfuryEvents()
    if windfuryEvents then return end
    -- Windfury is a Shaman-only mechanic: no frame, no events, no listener.
    if not LT:IsClass("SHAMAN") then return end
    local ok, f = pcall(CreateFrame, "Frame")
    if not ok or not f then return end
    windfuryEvents = f
    swingRegistered = false
    for _, event in ipairs({
        "PLAYER_SWING",
        "UNIT_ATTACK_SPEED",
        "UNIT_COMBAT",
        "UNIT_SPELLCAST_SUCCEEDED",
        "PLAYER_ENTERING_WORLD",
        "PLAYER_EQUIPMENT_CHANGED",
    }) do
        if type(f.RegisterEvent) == "function" then
            local registered = pcall(f.RegisterEvent, f, event)
            if event == "PLAYER_SWING" then swingRegistered = registered == true end
            if not registered and type(LT.Print) == "function" then
                pcall(LT.Print, LT, "Windfury: this client refused the " .. event .. " event.")
            end
        end
    end
    if type(f.SetScript) == "function" then
        f:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
            if event == "PLAYER_SWING" then
                pcall(Trackers.OnSwing, Trackers, a1, a2)
            elseif event == "UNIT_COMBAT" then
                pcall(Trackers.OnCombat, Trackers, a1, a2, a3, a4)
            elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
                pcall(Trackers.OnSpellcast, Trackers, a1, a3)
            else
                pcall(Trackers.OnSpeedChange, Trackers)
            end
        end)
    end
    Trackers:OnSpeedChange()
    local options = Trackers:Options()
    local quiet = type(options) == "table" and options.loginMessage == false
    if type(LT.Print) == "function" and not quiet and LT:IsClass("SHAMAN") then
        if swingRegistered then
            pcall(LT.Print, LT, "Windfury listener on for " .. tostring(Trackers:ClassToken())
                .. " — /lt trackers wfprobe on to watch UNIT_COMBAT.")
        else
            pcall(LT.Print, LT, "Windfury proc tracking is off on this client: it refuses the "
                .. "PLAYER_SWING event, so a proc cannot be told from a normal swing. "
                .. "Nothing else is affected.")
        end
    end
end

function Trackers:Initialize()
    if self.initialized then return end
    self.initialized = true

    ensureWindfuryEvents()

    local enabled = self:IsEnabled()
    local probe = self:ProbeWanted()
    if not enabled and not probe then return end

    if self:CombatLocked() then
        self.pendingCombo = enabled
        self.pendingLog = probe
        self.pendingCombatFrame = true
        scheduleDeferred()
        return
    end

    if not buildFrame() then return end

    if probe then self:ArmLog() end
    self:Refresh()
end

function Trackers:OnEnterWorld()
    if self:CombatLocked() then
        if self.pendingCombo or self.pendingLog or self.pendingCombatFrame
            or self:IsEnabled() or self:ProbeWanted() then
            scheduleDeferred()
        end
        return
    end

    if (self:IsEnabled() or self:ProbeWanted()) and not frame then
        buildFrame()
    end
    if self:ProbeWanted() and not self.logArmed then self:ArmLog() end

    if frame then
        self:Place()
        self:Refresh()
    end
end

------------------------------------------------------------------------------
-- Combat-log probe
------------------------------------------------------------------------------

local function pack(...)
    return { n = select("#", ...), ... }
end

local function safeText(value)
    if value == nil then return "nil" end
    if LT:IsSecret(value) then return "<secret>" end
    return tostring(value)
end

local function currentEventInfo()
    if type(CombatLogGetCurrentEventInfo) ~= "function" then return nil end
    local ok, info = pcall(function()
        return pack(CombatLogGetCurrentEventInfo())
    end)
    if not ok or type(info) ~= "table" then return nil end
    return info
end

-- The documented COMBAT_LOG_EVENT_UNFILTERED prefix: subevent at 2, source name
-- at 5, destination name at 9, spell name at 13. Only the shape is printed, not
-- a damage total, because the payload beyond those names differs by event.
function Trackers:EventShape(info)
    if type(info) ~= "table" then return nil end

    local subevent = info[2]
    local count = info.n or #info
    return string.format("%s | source=%s | dest=%s | spell=%s | %d field(s)",
        safeText(subevent), safeText(info[5]), safeText(info[9]), safeText(info[13]), count)
end

function Trackers:OnCombatLogEvent()
    if not self.logArmed then return end

    self.logCount = (self.logCount or 0) + 1
    local shape = self:EventShape(currentEventInfo())
    if shape then
        LT:Print("probe " .. tostring(self.logCount) .. ": " .. shape)
    else
        LT:Print("probe " .. tostring(self.logCount)
            .. ": event fired but CombatLogGetCurrentEventInfo is missing")
    end

    if self.logCount >= 10 then
        self:StopLog(true)
    end
end

function Trackers:StopLog(announce)
    self.logArmed = false
    self.pendingLog = false
    if frame and type(frame.UnregisterEvent) == "function" then
        pcall(frame.UnregisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED")
    end
    setOption("combatLogProbe", false)
    if announce then
        LT:Print("Combat-log probe stopped after 10 events. /lt probe log on runs it again.")
    end
end

-- Returns "armed", "deferred", "failed" or "off".
function Trackers:SetLogProbe(on)
    on = on == true
    setOption("combatLogProbe", on)

    if not on then
        self:StopLog(false)
        return "off"
    end

    if self:CombatLocked() then
        self.pendingLog = true
        self.pendingCombatFrame = true
        scheduleDeferred()
        return "deferred"
    end

    if not buildFrame() then
        self.pendingLog = true
        return "failed"
    end

    return self:ArmLog()
end

-- Registers the event without changing the option. Returns "armed" or "failed".
function Trackers:ArmLog()
    if self:CombatLocked() then
        self.pendingLog = true
        scheduleDeferred()
        return "deferred"
    end
    if not frame and not buildFrame() then return "failed" end
    if not frame or type(frame.RegisterEvent) ~= "function" then return "failed" end

    local ok = pcall(frame.RegisterEvent, frame, "COMBAT_LOG_EVENT_UNFILTERED")
    if not ok then
        self.logArmed = false
        setOption("combatLogProbe", false)
        LT:Warn("This client does not report COMBAT_LOG_EVENT_UNFILTERED; the probe is off.")
        return "failed"
    end

    self.logArmed = true
    self.pendingLog = false
    self.logCount = 0
    return "armed"
end

------------------------------------------------------------------------------
-- Probe report
------------------------------------------------------------------------------

local function functionState(value)
    return type(value) == "function" and "available" or "missing"
end

function Trackers:Availability()
    local entries = {}

    local function add(name, state, detail)
        entries[#entries + 1] = { name = name, state = state, detail = detail }
    end

    add("GetComboPoints", functionState(GetComboPoints))
    add("UnitPower", functionState(UnitPower))

    if type(Enum) == "table" and type(Enum.PowerType) == "table"
        and type(Enum.PowerType.ComboPoints) == "number" then
        local value = Enum.PowerType.ComboPoints
        local detail = LT:IsSecret(value) and "<secret>" or tostring(value)
        add("Enum.PowerType.ComboPoints", "available", "value " .. detail)
    else
        add("Enum.PowerType.ComboPoints", "missing")
    end

    add("GetShapeshiftForm", functionState(GetShapeshiftForm))
    add("GetShapeshiftFormID", functionState(GetShapeshiftFormID))
    add("CombatLogGetCurrentEventInfo", functionState(CombatLogGetCurrentEventInfo))

    local eventState, eventDetail = "unknown", "not queryable on this client"
    if type(C_EventUtils) == "table" and type(C_EventUtils.IsEventValid) == "function" then
        local ok, valid = pcall(C_EventUtils.IsEventValid, "COMBAT_LOG_EVENT_UNFILTERED")
        if ok then
            eventState = valid and "available" or "missing"
            eventDetail = nil
        end
    else
        eventDetail = "not queryable; /lt probe log on tests it"
    end
    add("COMBAT_LOG_EVENT_UNFILTERED", eventState, eventDetail)

    add("UnitAura", functionState(UnitAura))
    add("UnitBuff", functionState(UnitBuff))

    return entries
end

function Trackers:ProbeLines()
    local lines = {}
    local function add(text) lines[#lines + 1] = text end

    add("Trackers probe — client APIs and current values.")

    local classToken = self:ClassToken()
    add("Class: " .. classToken)
    add("Target: " .. (self:UnitHasTarget() and "yes" or "no"))

    local catAura, formIndex, formRoute = self:FormState()
    add("Form route: " .. safeText(formRoute)
        .. " | form ID: " .. safeText(self:ReadFormID())
        .. " | Form index: " .. safeText(formIndex)
        .. " | Cat Form aura: " .. safeText(catAura))

    local points, source = self:ReadPoints()
    if points then
        add("Combo points: " .. safeText(points) .. " (" .. source .. ")")
    else
        add("Combo points: unavailable")
    end
    add("Reader detail: GetComboPoints=" .. safeText(self:ReadLegacyPoints())
        .. " | UnitPower=" .. safeText(self:ReadPowerPoints()))

    add("APIs:")
    for _, entry in ipairs(self:Availability()) do
        local line = "  " .. entry.name .. ": " .. entry.state
        if entry.detail then line = line .. " (" .. entry.detail .. ")" end
        add(line)
    end

    local registered = procAuras[classToken]
    local count = type(registered) == "table" and #registered or 0
    add("Registered proc auras for " .. classToken .. ": " .. tostring(count))

    local active = self:ActiveProcs()
    add("Active procs: " .. (#active > 0 and table.concat(active, ", ") or "none"))

    if self.logArmed then
        add("Combat-log probe: armed, " .. tostring(self.logCount or 0) .. "/10 events")
    else
        add("Combat-log probe: off")
    end

    return lines
end

------------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------------

function Trackers:PrintStatus()
    local enabled = self:IsEnabled()
    local shown = self:IsShown()

    LT:Print("Combo tracker: " .. (enabled and "on" or "off"))
    if not frame then
        LT:Print("  Frame: not created yet")
    else
        LT:Print("  Frame: " .. (shown and "shown" or "hidden"))
    end

    LT:Print("  Class: " .. self:ClassToken()
        .. " | Target: " .. (self:UnitHasTarget() and "yes" or "no"))

    local points, source = self:ReadPoints()
    if points then
        LT:Print("  Combo points: " .. self:FormatPoints(points) .. " (" .. source .. ")")
    else
        LT:Print("  Combo points: unavailable on this client")
    end

    -- A proc is detected from swing timing, so a client that refuses
    -- PLAYER_SWING cannot record one. Say which of the three states it is.
    -- Another class has no windfury at all, so it is not mentioned.
    if LT:IsClass("SHAMAN") then
        local wf = self:WindfuryAvailable()
        if wf == nil then
            LT:Print("  Windfury procs: listener not started yet")
        elseif wf then
            LT:Print("  Windfury procs: tracking (PLAYER_SWING accepted)")
        else
            LT:Print("  Windfury procs: off - this client refuses PLAYER_SWING, so a proc "
                .. "cannot be told from a normal swing")
        end
    end

    local record = readPlacement()
    local fractionX = record and self:NormalizeFraction(record.x)
    local fractionY = record and self:NormalizeFraction(record.y)
    if fractionX and fractionY then
        LT:Print(string.format("  Position: %.3f, %.3f of the UI area", fractionX, fractionY))
    else
        LT:Print("  Position: default (drag the frame to move it)")
    end

    if self.logArmed then
        LT:Print("  Combat-log probe: armed, " .. tostring(self.logCount or 0) .. "/10 events")
    else
        LT:Print("  Combat-log probe: off")
    end
end

local function printOneSet(store, setup)
    LT:Print("Windfury (" .. setup .. ") — top " .. #store .. " by damage:")
    for index, entry in ipairs(store) do
        local crit = entry.crit and " |cffff3030CRIT|r" or ""
        local target = entry.target
        if type(target) ~= "string" or LT:IsSecret(target) then target = "?" end
        LT:Print(string.format("%d. Lvl %d vs %d %s — %s %d!%s",
            index, tonumber(entry.level) or 0, tonumber(entry.targetLevel) or 0,
            target, entry.ss and "SS-WF" or "WF",
            math.floor(tonumber(entry.amount) or 0), crit))
    end
end

function Trackers:PrintWindfuryRecords()
    -- Records are Shaman data; never printed for, or to, another class.
    if not LT:IsClass("SHAMAN") then
        LT:Print("Windfury records are Shaman only.")
        return
    end
    local any = false
    for _, setup in ipairs({ "2H", "DW" }) do
        local store = self:WindfuryRecords(setup)
        if #store > 0 then
            any = true
            printOneSet(store, setup)
        end
    end
    if not any then
        LT:Print("No Windfury records yet. Hit something as a Shaman with a Windfury imbue.")
    end
end

function Trackers:Command(words)
    local action = words and words[2]

    if action == "on" then
        local result = self:SetEnabled(true)
        if result == "on" then
            LT:Print("Combo tracker on. Drag the small frame to move it; /lt trackers off hides it.")
        elseif result == "deferred" then
            if self:CanDefer() then
                LT:Print("Combo tracker on; the frame appears when you leave combat.")
            else
                LT:Print("Combo tracker on; this client cannot create it during combat."
                    .. " Run /lt trackers on again after the fight.")
            end
        else
            LT:Warn("The client did not allow the tracker frame to be created; try again out of combat.")
        end
        return
    end

    if action == "off" then
        self:SetEnabled(false)
        LT:Print("Combo tracker off.")
        return
    end

    if action == "wf" or action == "windfury" then
        if not LT:IsClass("SHAMAN") then
            LT:Print("Windfury tracking is Shaman only.")
            return
        end
        local mode = words and words[3]
        if mode == "move" then
            self:FlashWindfury("Windfury! (drag me)", 60, true)
            LT:Print("Drag the alert where you want it; the spot is saved.")
            return
        end
        if mode == "reset" then
            self:ResetWindfuryRecords()
            LT:Print("Windfury records cleared.")
            return
        end
        self:PrintWindfuryRecords()
        return
    end

    if action == "wfprobe" then
        if not LT:IsClass("SHAMAN") then
            LT:Print("The Windfury probe is Shaman only.")
            return
        end
        local mode = words and words[3]
        if mode == "on" then
            self.wfProbe = true
            LT:Print("Windfury probe on: each UNIT_COMBAT prints unit/action/amount.")
            if self:WindfuryAvailable() == false then
                LT:Print("  note: this client refuses PLAYER_SWING, so no swing window "
                    .. "will open and every line will read proc=false.")
            end
        elseif mode == "off" then
            self.wfProbe = false
            LT:Print("Windfury probe off.")
        else
            LT:Print("Usage: /lt trackers wfprobe on|off")
        end
        return
    end

    if action == nil or action == "status" then
        self:PrintStatus()
        return
    end

    LT:Print("Usage: /lt trackers [on|off|status|wf]")
end

function Trackers:CommandProbe(words)
    local sub = words and words[2]

    if sub == nil then
        for _, line in ipairs(self:ProbeLines()) do LT:Print(line) end
        return
    end

    if sub == "log" then
        local action = words[3]
        if action == "on" then
            local result = self:SetLogProbe(true)
            if result == "armed" then
                LT:Print("Combat-log probe on: the first 10 events will be printed, then it stops.")
            elseif result == "deferred" then
                if self:CanDefer() then
                    LT:Print("Combat-log probe on; it starts when you leave combat.")
                else
                    LT:Print("Combat-log probe on; this client cannot start it during combat."
                        .. " Run /lt probe log on again after the fight.")
                end
            else
                LT:Warn("The combat-log probe could not start on this client.")
            end
        elseif action == "off" then
            self:SetLogProbe(false)
            LT:Print("Combat-log probe off.")
        else
            LT:Print("Usage: /lt probe log on|off")
        end
        return
    end

    LT:Print("Usage: /lt probe [log on|off]")
end
