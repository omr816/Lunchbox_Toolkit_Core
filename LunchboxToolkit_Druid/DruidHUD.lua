--[[--------------------------------------------------------------------------
    LunchboxToolkit_Druid — DruidHUD

    A small form and resource strip for a Druid, off by default. It answers the
    one question the rest of the addon leaves open in a shapeshift class: which
    shape am I in, and what is my bar right now. A Druid's resource changes with
    the shape — mana as a caster, rage as a bear, energy as a cat — and the
    default client bars do not say which one is live.

    What it deliberately does NOT do:
      * it does not draw combo points as a bar. The core's tracker already owns
        the cat's combo points (Trackers), and a second copy on screen would be
        the same number in two places. One short "combo: 2/5" line is drawn only
        while a cat has points, so the two never disagree;
      * it does not draw buffs, timers or icons. That is BuffMonitor's job.

    Every client read goes through the plugin's own guarded readers in Druid.lua
    (FormLine, PowerLine, PointsLine), so the secret and nil handling exists in one
    place. A read that fails says why ("Mana: hidden in combat") instead of drawing
    a made-up number.

    The strip is invisible until `/lt druid hud on`, and it starts locked: a
    locked strip takes no mouse at all, so a stray click in combat passes straight
    through it. The cog in its top-right corner is the lock — press it to unlock,
    drag the strip, press it again to lock — and the panel that appears underneath
    while unlocked carries the rest of the controls:

      * Size and Opacity sliders;
      * a Combo switch (the "combo: 2/5" tail on the power line);
      * a Colour switch (paint the form line in the shape's colour);
      * Reset, which puts the strip back in the middle of the screen;
      * Off, which is the same as `/lt druid hud off`.

    Every control writes one key in LunchboxToolkitDruidDB.hud and every draw
    reads it back, so the cog, the panel and `/lt druid hud` cannot disagree after
    a reload. The cog is reachable while locked on purpose: without it there would
    be no way back to an unlocked strip in game.
--------------------------------------------------------------------------]]

if not LunchboxToolkit then return end
local LT = LunchboxToolkit

-- The whole file is inert on every other class: no table, no frame, no events.
local function isDruid()
    if type(UnitClassBase) == "function" then
        local ok, class = pcall(UnitClassBase, "player")
        if ok and class == "DRUID" then return true end
    end
    if type(UnitClass) == "function" then
        local ok, class = pcall(UnitClass, "player")
        if ok and class == "DRUID" then return true end
    end
    return false
end

if not isDruid() then return end
if type(LT.DruidHUD) == "table" then return end

local DruidHUD = {}
LT.DruidHUD = DruidHUD

DruidHUD.VERSION = "0.1.0"

local FRAME_NAME       = "LunchboxToolkitDruidHUD"
local UPDATE_INTERVAL  = 0.2
local DEFAULT_POINT    = { point = "CENTER", relativePoint = "CENTER", x = 0, y = -180 }

local PANEL_WIDTH = 200
-- The two numbers the sliders move, and the range each one refuses to leave.
-- Both keep a fallback, because a saved table from an older build has neither.
local SIZE_RANGE  = { low = 0.5, high = 1.6, fallback = 1 }
local ALPHA_RANGE = { low = 0.1, high = 1,   fallback = 0.9 }

local frame
local elapsed = 0
-- The texture behind the strip, whichever route made it: the chrome's fill or the
-- plain background. Kept here rather than read back off the frame, so the look
-- never depends on a field that may not exist.
local frameFill
-- The setters below call this, and it is written with the rest of the frame code
-- further down, so it is declared here rather than there.
local applyLook

------------------------------------------------------------------------------
-- Logging and guards
------------------------------------------------------------------------------

local function report(message)
    if type(LT.Print) == "function" then
        if pcall(LT.Print, LT, message) then return end
    end
    pcall(print, message)
end

local function debug(message)
    if type(LT.Debug) == "function" then
        pcall(LT.Debug, LT, message)
    end
end

local function combatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

-- The plugin's own store. Until Druid.lua has run there is no store to write to,
-- so the HUD simply stays off rather than creating a second table.
local function store()
    local module = LT.Druid
    if type(module) ~= "table" or type(module.Store) ~= "function" then return nil end
    local ok, saved = pcall(module.Store)
    if not ok or type(saved) ~= "table" then return nil end
    if type(saved.hud) ~= "table" then saved.hud = {} end
    return saved
end

function DruidHUD:IsEnabled()
    local saved = store()
    return saved ~= nil and saved.hud.enabled == true
end

function DruidHUD:IsLocked()
    local saved = store()
    if saved == nil then return true end
    -- Locked unless the player has explicitly unlocked it.
    return saved.hud.locked ~= false
end

function DruidHUD:IsUnlocked()
    return not self:IsLocked()
end

-----------------------------------------------------------------------------
-- Settings: the cog, the panel and the slash command all end here
-----------------------------------------------------------------------------

-- One key per control, all in saved.hud. A key that is absent is the default, so
-- a table written by an older build (which had enabled, locked and the place
-- only) draws the full strip rather than a blank one.
local function hudSetting(key)
    local saved = store()
    if saved == nil then return nil end
    return saved.hud[key]
end

local function setHudSetting(key, value)
    local saved = store()
    if saved == nil then return false end
    saved.hud[key] = value
    return true
end

local function numberSetting(range, key)
    local value = tonumber(hudSetting(key))
    if not value then value = range.fallback end
    if value < range.low then value = range.low end
    if value > range.high then value = range.high end
    return value
end

function DruidHUD:GetScale() return numberSetting(SIZE_RANGE, "scale") end
function DruidHUD:GetAlpha() return numberSetting(ALPHA_RANGE, "alpha") end

-- Both switches are on unless switched off: the combo tail is the only place the
-- strip says how many points a cat holds, and the shape colour is the fastest
-- read on the bar, so neither is something to lose by default.
function DruidHUD:ShowsPoints() return hudSetting("showPoints") ~= false end
function DruidHUD:ColoursByForm() return hudSetting("colourByForm") ~= false end

function DruidHUD:SetScale(value)
    local number = tonumber(value)
    if not number then return false end
    if number < SIZE_RANGE.low then number = SIZE_RANGE.low end
    if number > SIZE_RANGE.high then number = SIZE_RANGE.high end
    setHudSetting("scale", number)
    applyLook()
    return true
end

function DruidHUD:SetAlpha(value)
    local number = tonumber(value)
    if not number then return false end
    if number < ALPHA_RANGE.low then number = ALPHA_RANGE.low end
    if number > ALPHA_RANGE.high then number = ALPHA_RANGE.high end
    setHudSetting("alpha", number)
    applyLook()
    return true
end

-----------------------------------------------------------------------------
-- The lock
--
-- Locked is the fighting state: no mouse, no drag, no panel. EnableMouse(false)
-- is what makes a click pass through a frame instead of being eaten by it, and
-- the cog is a child button, so it keeps taking clicks while the strip under it
-- does not. That asymmetry is the whole lock.
-----------------------------------------------------------------------------

function DruidHUD:ApplyUnlock()
    local target = frame
    if not target then return end
    local unlocked = not self:IsLocked()

    pcall(target.EnableMouse, target, unlocked)
    local panel = target.settingsPanel
    if panel then
        if unlocked then
            pcall(panel.Show, panel)
        else
            pcall(panel.Hide, panel)
        end
    end
end

function DruidHUD:ToggleUnlock()
    local saved = store()
    if saved == nil then return false end
    saved.hud.locked = not (saved.hud.locked ~= false)
    self:ApplyUnlock()
    if saved.hud.locked == false then
        report("Druid HUD unlocked: drag it, and the panel below it is live.")
    else
        report("Druid HUD locked: it takes no clicks now.")
    end
    return true
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

-- The colour is the shape, so the strip says "bear" before the word is read.
local FORM_COLOURS = {
    Cat     = { r = 1.00, g = 0.82, b = 0.10 },
    Bear    = { r = 0.25, g = 0.62, b = 1.00 },
    Travel  = { r = 0.20, g = 1.00, b = 0.20 },
    Aquatic = { r = 0.20, g = 0.80, b = 1.00 },
    Moonkin = { r = 0.75, g = 0.48, b = 1.00 },
    Tree    = { r = 0.20, g = 1.00, b = 0.20 },
    Flight  = { r = 0.20, g = 1.00, b = 0.20 },
}

local CASTER_COLOUR = { r = 0.70, g = 0.70, b = 0.70 }

local function colourFor(key)
    if type(key) == "string" and FORM_COLOURS[key] then return FORM_COLOURS[key] end
    return CASTER_COLOUR
end

local function update()
    if not frame then return end

    local module = LT.Druid
    if type(module) ~= "table" then
        frame.form:SetText("form: no answer")
        frame.power:SetText("")
        return
    end

    local okForm, formLine = pcall(module.FormLine, module)
    frame.form:SetText(okForm and tostring(formLine) or "form: no answer")

    local okPower, powerLine = pcall(module.PowerLine, module)
    local okPoints, pointsLine = pcall(module.PointsLine, module)
    local text = okPower and tostring(powerLine) or "power: no answer"
    -- The combo tail is a switch: off means the power line stands alone, which is
    -- what a player who already reads the core's combo tracker wants.
    if okPoints and type(pointsLine) == "string" and DruidHUD:ShowsPoints() then
        text = text .. "   " .. pointsLine
    end
    frame.power:SetText(text)

    if DruidHUD:ColoursByForm() then
        local okState, state = pcall(module.FormState, module)
        local colour = colourFor(okState and type(state) == "table" and state.auraKey or nil)
        frame.form:SetTextColor(colour.r, colour.g, colour.b)
    else
        frame.form:SetTextColor(0.85, 0.85, 0.85)
    end
end

DruidHUD.Update = update

-- The switch buttons carry the text they should read while their switch is in a
-- given state; this asks each one again. One function for both the press and the
-- slash command, so the panel and the command can never disagree.
function DruidHUD:Reflect()
    local target = frame
    if not target then return end
    for _, button in ipairs(target.switchButtons or {}) do
        if type(button.ltLabel) == "function" then
            local text = button.ltLabel()
            button.text = text
            if type(button.SetText) == "function" then pcall(button.SetText, button, text) end
        end
    end
end

function DruidHUD:SetSwitch(key, on)
    if key ~= "showPoints" and key ~= "colourByForm" then return false end
    setHudSetting(key, on == true)
    self:Reflect()
    update()
    return true
end

------------------------------------------------------------------------------
-- The frame
------------------------------------------------------------------------------

local function applyPlace(target)
    local point, relativePoint, x, y = nil, nil, 0, 0

    local saved = store()
    local stored = saved and saved.hud or nil
    if type(stored) == "table" then
        if type(stored.point) == "string" and stored.point ~= "" then point = stored.point end
        if type(stored.relativePoint) == "string" and stored.relativePoint ~= "" then
            relativePoint = stored.relativePoint
        end
        x = tonumber(stored.x) or 0
        y = tonumber(stored.y) or 0
    end

    if not point then
        point = DEFAULT_POINT.point
        relativePoint = DEFAULT_POINT.relativePoint
        x = DEFAULT_POINT.x
        y = DEFAULT_POINT.y
    end

    target:ClearAllPoints()
    target:SetPoint(point, UIParent, relativePoint or point, x, y)
end

local function savePlace(target)
    local saved = store()
    if not saved then return end

    local ok, point, _, relativePoint, x, y = pcall(target.GetPoint, target, 1)
    if not ok or type(point) ~= "string" or type(relativePoint) ~= "string" then return end

    saved.hud.point = point
    saved.hud.relativePoint = relativePoint
    saved.hud.x = tonumber(x) or 0
    saved.hud.y = tonumber(y) or 0
end

-----------------------------------------------------------------------------
-- Look and the control panel
--
-- The panel hangs under the strip and is shown only while unlocked, so a locked
-- strip is two lines of text and a cog. Every control writes one key in
-- saved.hud and then asks the strip to redraw, so nothing here holds state that
-- a reload would lose.
-----------------------------------------------------------------------------

applyLook = function()
    local target = frame
    if not target then return end

    pcall(target.SetScale, target, DruidHUD:GetScale())

    -- The fill is the texture the chrome put behind the strip (or the plain one
    -- this file made when the chrome declined). Only it fades: the labels and the
    -- border stay at full strength, so a low opacity never costs legibility.
    local fill = frameFill
    if fill and type(fill.SetAlpha) == "function" then
        pcall(fill.SetAlpha, fill, DruidHUD:GetAlpha())
    end
end

-- LT.UI:MakeButton is the addon's own button, so the panel speaks the same
-- vocabulary as the toolkit window. A client without UI gets no button rather
-- than an error: the slash command still reaches the same setting.
local function addButton(panel, offsetX, offsetY, text, width, onClick)
    local ui = LT.UI
    if type(ui) ~= "table" or type(ui.MakeButton) ~= "function" then return nil end
    local ok, button = pcall(ui.MakeButton, ui, panel, text, width or 96, 18, onClick)
    if not ok or type(button) ~= "table" then return nil end
    pcall(button.SetPoint, button, "TOPLEFT", offsetX or 8, offsetY)
    return button
end

-- Label, live value, slider: the same row three times, so Size and Opacity can
-- never drift apart in behaviour.
local function addSliderRow(panel, offsetY, text, range, key, format)
    local okLabel, label = pcall(panel.CreateFontString, panel, nil, "OVERLAY",
        "GameFontNormalSmall")
    if okLabel and label then
        pcall(label.SetPoint, label, "TOPLEFT", 8, offsetY)
        pcall(label.SetText, label, text)
    end

    local okValue, valueText = pcall(panel.CreateFontString, panel, nil, "OVERLAY",
        "GameFontNormalSmall")
    if okValue and valueText then
        pcall(valueText.SetPoint, valueText, "TOPRIGHT", -8, offsetY)
        pcall(valueText.SetText, valueText, string.format(format, numberSetting(range, key)))
    end

    local ui = LT.UI
    if type(ui) ~= "table" or type(ui.MakeSlider) ~= "function" then return nil end
    local ok, slider = pcall(ui.MakeSlider, ui, panel, range.low, range.high, 0.05,
        numberSetting(range, key), function(value)
            setHudSetting(key, value)
            if valueText then
                pcall(valueText.SetText, valueText, string.format(format, value))
            end
            applyLook()
        end)
    if not ok or type(slider) ~= "table" then return nil end
    pcall(slider.SetPoint, slider, "TOPLEFT", 8, offsetY - 16)
    -- MakeSlider is built for a full-width page; the strip's panel is narrow, so
    -- the bar is shortened to fit rather than left to spill out of the box.
    pcall(slider.SetWidth, slider, 116)
    return slider
end

-- Each switch button answers its own label, so Reflect() can re-read the state
-- from the store instead of the panel keeping a copy of it.
local function addSwitch(panel, offsetY, text, key, getter)
    local function label()
        return text .. ": " .. (getter() and "On" or "Off")
    end
    local button = addButton(panel, 8, offsetY, label(), 96, function()
        DruidHUD:SetSwitch(key, not getter())
    end)
    if not button then return nil end
    -- Reflect() asks this again after a press, a slash command or a reload, so the
    -- panel never holds a copy of a state the store owns.
    button.ltLabel = label
    return button
end

local function buildPanel(parent)
    local createFrame = rawget(_G, "CreateFrame")
    if type(createFrame) ~= "function" then return nil end
    local ok, panel = pcall(createFrame, "Frame", nil, parent)
    if not ok or not panel then return nil end

    pcall(panel.SetPoint, panel, "TOPLEFT", parent, "BOTTOMLEFT", 0, -6)
    pcall(panel.SetSize, panel, PANEL_WIDTH, 150)

    local okBg, background = pcall(panel.CreateTexture, panel, nil, "BACKGROUND")
    if okBg and background then
        pcall(background.SetAllPoints, background)
        pcall(background.SetColorTexture, background, 0.02, 0.02, 0.02, 0.92)
    end

    addSliderRow(panel, -8, "Size", SIZE_RANGE, "scale", "%.2f")
    addSliderRow(panel, -44, "Opacity", ALPHA_RANGE, "alpha", "%.2f")

    -- The switches are listed on the panel as well as the frame, so Reflect() has
    -- one place to walk however the panel was built.
    panel.switchButtons = {}
    local comboSwitch = addSwitch(panel, -76, "Combo", "showPoints",
        function() return DruidHUD:ShowsPoints() end)
    if comboSwitch then panel.switchButtons[#panel.switchButtons + 1] = comboSwitch end

    local colourSwitch = addSwitch(panel, -98, "Colour", "colourByForm",
        function() return DruidHUD:ColoursByForm() end)
    if colourSwitch then panel.switchButtons[#panel.switchButtons + 1] = colourSwitch end

    -- Kept on the panel as well as drawn, so the tests and a future keybind can
    -- reach the two buttons without walking the toolkit's widget list.
    panel.resetButton = addButton(panel, 8, -122, "Reset", 82, function()
        DruidHUD:ResetPlace()
        report("Druid HUD back in the middle of the screen.")
    end)
    panel.offButton = addButton(panel, 96, -122, "Off", 52, function()
        DruidHUD:SetEnabled(false)
        report("Druid HUD off.")
    end)

    return panel
end

local function ensureFrame()
    if frame then return frame end

    local createFrame = rawget(_G, "CreateFrame")
    if type(createFrame) ~= "function" then return nil end

    local ok, created = pcall(createFrame, "Frame", FRAME_NAME, UIParent)
    if not ok or not created then return nil end

    frame = created
    -- Wider than the two lines need: the cog lives in the top-right corner and the
    -- longest power line ("Mana: 100%   combo: 5/5") has to clear it.
    pcall(frame.SetSize, frame, 200, 46)
    pcall(frame.SetFrameStrata, frame, "MEDIUM")
    pcall(frame.SetClampedToScreen, frame, true)
    pcall(frame.SetMovable, frame, true)

    -- The core's own window chrome, so the strip belongs to the addon rather than
    -- looking like a third-party frame parked over the game. The record it returns
    -- carries the fill texture, which is what the Opacity slider fades; a client
    -- where the chrome declines gets a plain background instead.
    frameFill = nil
    if type(LT.Chrome) == "table" and type(LT.Chrome.Window) == "function" then
        local okChrome, chrome = pcall(LT.Chrome.Window, frame, {})
        if okChrome and type(chrome) == "table" and chrome.fill then
            frameFill = chrome.fill
        end
    end
    if not frameFill then
        local okBg, background = pcall(frame.CreateTexture, frame, nil, "BACKGROUND")
        if okBg and background then
            pcall(background.SetAllPoints, background)
            pcall(background.SetColorTexture, background, 0.04, 0.04, 0.04, 0.9)
            frameFill = background
        end
    end
    -- Named on the frame as well, so a player's bug report can point at it and the
    -- tests can check what the Opacity slider did.
    frame.fill = frameFill

    local okForm, formText = pcall(frame.CreateFontString, frame, nil, "OVERLAY",
        "GameFontNormalSmall")
    local okPower, powerText = pcall(frame.CreateFontString, frame, nil, "OVERLAY",
        "GameFontNormalSmall")
    if not okForm or not formText or not okPower or not powerText then
        -- A client that will not make font strings cannot draw this strip; drop the
        -- frame rather than leave an empty box on screen.
        pcall(frame.Hide, frame)
        frame = nil
        return nil
    end

    frame.form = formText
    frame.form:SetPoint("TOPLEFT", 8, -7)
    frame.form:SetWidth(168)
    frame.form:SetJustifyH("LEFT")

    frame.power = powerText
    frame.power:SetPoint("TOPLEFT", 8, -23)
    frame.power:SetWidth(184)
    frame.power:SetJustifyH("LEFT")
    frame.power:SetTextColor(0.85, 0.85, 0.85)

    -- Dragging is allowed only while unlocked and out of combat. Both are checked
    -- again here, because the state can change between the click and the drag.
    pcall(frame.RegisterForDrag, frame, "LeftButton")
    pcall(frame.SetScript, frame, "OnDragStart", function(self)
        if DruidHUD:IsLocked() or combatLocked() then return end
        pcall(self.StartMoving, self)
    end)
    pcall(frame.SetScript, frame, "OnDragStop", function(self)
        pcall(self.StopMovingOrSizing, self)
        savePlace(self)
    end)

    -- One cheap tick while shown and nothing at all while hidden.
    pcall(frame.SetScript, frame, "OnUpdate", function(_, delta)
        elapsed = elapsed + (tonumber(delta) or 0)
        if elapsed < UPDATE_INTERVAL then return end
        elapsed = 0
        update()
    end)

    -- The cog is the lock. It is a child button, so it keeps taking clicks while
    -- the strip under it has its mouse switched off — which is the only way back
    -- to an unlocked strip in game.
    local createButton = rawget(_G, "CreateFrame")
    if type(createButton) == "function" then
        local okCog, cog = pcall(createButton, "Button", nil, frame)
        if okCog and cog then
            pcall(cog.SetSize, cog, 16, 16)
            pcall(cog.SetPoint, cog, "TOPRIGHT", -6, -5)
            local okIcon, icon = pcall(cog.CreateTexture, cog, nil, "ARTWORK")
            if okIcon and icon then
                pcall(icon.SetAllPoints, icon)
                pcall(icon.SetTexture, icon, "Interface\\Icons\\INV_Misc_Gear_01")
            end
            pcall(cog.SetScript, cog, "OnClick", function() DruidHUD:ToggleUnlock() end)
            frame.cog = cog
        end
    end

    -- The switches are kept in a list so Reflect() can re-label them from the
    -- store after a press, a slash command or a login.
    frame.settingsPanel = buildPanel(frame)
    frame.switchButtons = frame.settingsPanel and frame.settingsPanel.switchButtons or {}

    applyLook()
    DruidHUD:ApplyUnlock()

    frame:Hide()
    debug("DruidHUD: frame built.")
    return frame
end

function DruidHUD:Refresh()
    local target = ensureFrame()
    if not target then return false end

    if not self:IsEnabled() then
        target:Hide()
        return false
    end

    applyPlace(target)
    -- Size and opacity are reapplied here as well as from the sliders: on login the
    -- frame is built before the panel exists, and a saved look has to reach it.
    applyLook()
    self:ApplyUnlock()
    self:Reflect()
    target:Show()
    update()
    return true
end

function DruidHUD:SetEnabled(on)
    local saved = store()
    if not saved then return false end
    saved.hud.enabled = on == true
    self:Refresh()
    return true
end

function DruidHUD:SetLocked(locked)
    local saved = store()
    if not saved then return false end
    saved.hud.locked = locked == true
    self:ApplyUnlock()
    return true
end

function DruidHUD:ResetPlace()
    local saved = store()
    if not saved then return false end
    saved.hud.point = nil
    saved.hud.relativePoint = nil
    saved.hud.x = nil
    saved.hud.y = nil
    if self:IsEnabled() then self:Refresh() end
    return true
end

------------------------------------------------------------------------------
-- Status and the /lt druid hud surface
------------------------------------------------------------------------------

function DruidHUD:Report()
    local module = LT.Druid
    local formLine = "form: no answer"
    local powerLine = "power: no answer"
    if type(module) == "table" then
        if type(module.FormLine) == "function" then
            local ok, value = pcall(module.FormLine, module)
            if ok and type(value) == "string" then formLine = value end
        end
        if type(module.PowerLine) == "function" then
            local ok, value = pcall(module.PowerLine, module)
            if ok and type(value) == "string" then powerLine = value end
        end
    end

    report("Druid form and power HUD: " .. (self:IsEnabled() and "on" or "off")
        .. ", " .. (self:IsLocked() and "locked" or "unlocked") .. ".")
    report("  " .. formLine .. "   " .. powerLine)
    report("  size " .. string.format("%.2f", self:GetScale())
        .. ", opacity " .. string.format("%.2f", self:GetAlpha())
        .. ", combo " .. (self:ShowsPoints() and "on" or "off")
        .. ", colour by shape " .. (self:ColoursByForm() and "on" or "off") .. ".")
    report("  /lt druid hud on|off|lock|unlock|scale <n>|alpha <n>|combo on|off|"
        .. "colour on|off|reset")
    report("  the cog in the strip's corner is the same lock; the panel under the "
        .. "strip holds the sliders and the switches while it is unlocked.")
end

-- words[1] is "druid", words[2] is "hud", words[3] is the action.
function DruidHUD:Command(words)
    local action = string.lower(tostring(words and words[3] or ""))

    if action == "" or action == "status" then
        self:Report()
        return true
    end

    -- The two numbers the panel's sliders move, reachable from the keyboard for a
    -- player who has locked the strip and does not want to unlock it to nudge it.
    if action == "scale" or action == "alpha" then
        local range = (action == "scale") and SIZE_RANGE or ALPHA_RANGE
        local key = (action == "scale") and "scale" or "alpha"
        local value = tonumber(words and words[4])
        if not value then
            report("Druid HUD " .. action .. " is "
                .. string.format("%.2f", numberSetting(range, key))
                .. " (" .. tostring(range.low) .. "-" .. tostring(range.high) .. ")")
            return true
        end
        if action == "scale" then self:SetScale(value) else self:SetAlpha(value) end
        report("Druid HUD " .. action .. ": "
            .. string.format("%.2f", numberSetting(range, key)))
        return true
    end

    -- Same two switches as the panel's buttons, so the panel is never the only door.
    if action == "combo" or action == "colour" then
        local key = (action == "combo") and "showPoints" or "colourByForm"
        local wanted = string.lower(tostring(words and words[4] or ""))
        local on
        if wanted == "on" then
            on = true
        elseif wanted == "off" then
            on = false
        else
            local current = (key == "showPoints") and self:ShowsPoints() or self:ColoursByForm()
            report("Druid HUD " .. action .. " is " .. (current and "on" or "off")
                .. " (/lt druid hud " .. action .. " on|off)")
            return true
        end
        self:SetSwitch(key, on)
        report("Druid HUD " .. action .. ": " .. (on and "on" or "off") .. ".")
        return true
    end

    if action == "on" then
        if not self:SetEnabled(true) then
            report("The HUD could not be enabled: its saved table is not available.")
            return true
        end
        report("Druid HUD on." .. (self:IsLocked() and " The cog in its corner unlocks it." or ""))
        return true
    end

    if action == "off" then
        self:SetEnabled(false)
        report("Druid HUD off.")
        return true
    end

    if action == "lock" then
        self:SetLocked(true)
        report("Druid HUD locked: it takes no clicks, and the panel is hidden.")
        return true
    end

    if action == "unlock" then
        self:SetLocked(false)
        report("Druid HUD unlocked: drag it by its left mouse button, and the panel "
            .. "under it holds the sliders and the switches.")
        return true
    end

    if action == "reset" then
        self:ResetPlace()
        report("Druid HUD place reset to the middle of the screen.")
        return true
    end

    report("usage: /lt druid hud [on|off|lock|unlock|scale <n>|alpha <n>|"
        .. "combo on|off|colour on|off|reset|status]")
    return true
end

function DruidHUD:OnLogin()
    -- Only the shape of the saved table is touched here; the frame is built on the
    -- first Refresh, so a player who never turns the HUD on never pays for it.
    local saved = store()
    if not saved then return false end

    local shown = self:Refresh()
    if shown then
        debug("DruidHUD: shown.")
    end
    return shown
end


