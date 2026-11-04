--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — ImbueGlow (X05)

    Shaman-only. When the main hand has no weapon imbue, the four weapon-imbue
    spell buttons on the action bars glow (the client's own overlay glow, or a
    small corner texture when that helper is absent) so the player sees at a
    glance what is available; the moment an imbue is applied the glow clears.
    The glow has its own switch (default on) and never desaturates a button.
    This replaces the popup half of the old reminder: the chat line stays, the
    popup goes.

    Every client read is pcall'd and secret-guarded. The glow is toggled only out
    of combat (a weapon enchant cannot change in combat), so the protected glow
    call is safe. The spell list is read from ClassData (one fact in one place);
    the buttons are matched by spell name, never a hardcoded id.
--------------------------------------------------------------------------]]

if not LunchboxToolkit then return end
local LT = LunchboxToolkit

local ImbueGlow = {}
LT.ImbueGlow = ImbueGlow

ImbueGlow.VERSION = "0.1.0"

local enabled = true

-- The glow has its own switch, default on. It is stored on the character
-- record so turning it off survives a reload; a record that has never touched
-- it reads as on.
local OPTION_KEY = "shamanImbueGlow"

------------------------------------------------------------------------------
-- Reads
------------------------------------------------------------------------------

local function isSecret(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(issecretvalue, value)
    return ok and secret == true
end

local function inCombat()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

local function isShaman()
    if type(UnitClassBase) == "function" then
        local ok, class = pcall(UnitClassBase, "player")
        if ok and class == "SHAMAN" then return true end
    end
    if type(UnitClass) == "function" then
        local ok, class = pcall(UnitClass, "player")
        if ok and class == "SHAMAN" then return true end
    end
    return false
end

local function optionOn()
    local db = LT.Database
    if type(db) == "table" and type(db.GetOptions) == "function" then
        local ok, options = pcall(db.GetOptions, db)
        if ok and type(options) == "table" then
            return options[OPTION_KEY] ~= false
        end
    end
    return enabled
end

local function imbueSpellNames()
    local cd = LT.ClassData
    if type(cd) == "table" and type(cd.ImbueSpellNames) == "table" then
        return cd.ImbueSpellNames
    end
    return { "Rockbiter Weapon", "Flametongue Weapon", "Frostbrand Weapon", "Windfury Weapon" }
end

local function hasImbue()
    local cd = LT.ClassData
    if type(cd) ~= "table" or type(cd.MainHandImbueCheck) ~= "function" then return true end
    local ok, info = pcall(cd.MainHandImbueCheck)
    if not ok or type(info) ~= "table" then return true end
    return info.active == true
end

------------------------------------------------------------------------------
-- Action bar scan
------------------------------------------------------------------------------

local ACTION_PREFIXES = {
    "ActionButton",
    "MultiBarBottomLeftButton",
    "MultiBarBottomRightButton",
    "MultiBarRightButton",
    "MultiBarLeftButton",
    "MultiBar5Button",
    "MultiBar6Button",
    "MultiBar7Button",
}

local function actionButtons()
    local out = {}
    for _, prefix in ipairs(ACTION_PREFIXES) do
        for i = 1, 12 do
            local b = _G[prefix .. i]
            if type(b) == "table" then out[#out + 1] = b end
        end
    end
    return out
end

local function buttonActionSlot(button)
    if type(button) ~= "table" or type(button.GetAttribute) ~= "function" then return nil end
    local ok, action = pcall(button.GetAttribute, button, "action")
    if ok and type(action) == "number" and action > 0 then return action end
    return nil
end

local function spellName(spellID)
    local getInfo = (type(C_Spell) == "table" and C_Spell.GetSpellInfo) or GetSpellInfo
    if type(getInfo) ~= "function" then return nil end

    local ok, info = pcall(getInfo, spellID)
    if not ok then return nil end

    local name = info
    if type(info) == "table" then name = info.name end
    if type(name) ~= "string" or name == "" or isSecret(name) then return nil end

    return name
end

local function buttonSpellName(button)
    local slot = buttonActionSlot(button)
    if not slot or type(GetActionInfo) ~= "function" then return nil end

    local ok, actionType, actionID = pcall(GetActionInfo, slot)
    if not ok or actionType ~= "spell" or type(actionID) ~= "number" then return nil end

    return spellName(actionID)
end

-- Only the buttons this module lit are tracked, so clearing never removes a
-- glow another feature (a proc, a different addon) put on the same button.
local glowing = setmetatable({}, { __mode = "k" })

-- Fallback when the client has no overlay-glow helper: a small coloured square
-- in the button's top-right corner. Never desaturates the button.
local function cornerTexture(button)
    local tex = button.LunchboxImbueGlowTexture
    if type(tex) == "table" then return tex end
    if type(button.CreateTexture) ~= "function" then return nil end

    local ok, created = pcall(button.CreateTexture, button)
    if not ok or type(created) ~= "table" then return nil end
    tex = created

    if type(tex.SetSize) == "function" then pcall(tex.SetSize, tex, 12, 12) end
    if type(tex.SetPoint) == "function" then
        -- Top-left: the top-right corner carries the client's hotkey text.
        pcall(tex.SetPoint, tex, "TOPLEFT", button, "TOPLEFT", 2, -2)
    end
    if type(tex.SetColorTexture) == "function" then
        pcall(tex.SetColorTexture, tex, 1, 0.72, 0.15)
    elseif type(tex.SetTexture) == "function" then
        pcall(tex.SetTexture, tex, "Interface\\Buttons\\WHITE8X8")
        if type(tex.SetVertexColor) == "function" then
            pcall(tex.SetVertexColor, tex, 1, 0.72, 0.15)
        end
    end

    button.LunchboxImbueGlowTexture = tex
    return tex
end

local function setGlow(button, on)
    if type(button) ~= "table" then return end

    if on then
        glowing[button] = true
        if type(ActionButton_ShowOverlayGlow) == "function" then
            pcall(ActionButton_ShowOverlayGlow, button)
            return
        end
        local tex = cornerTexture(button)
        if tex and type(tex.Show) == "function" then pcall(tex.Show, tex) end
        return
    end

    if not glowing[button] then return end
    glowing[button] = nil

    if type(ActionButton_HideOverlayGlow) == "function" then
        pcall(ActionButton_HideOverlayGlow, button)
    end
    local tex = button.LunchboxImbueGlowTexture
    if type(tex) == "table" and type(tex.Hide) == "function" then
        pcall(tex.Hide, tex)
    end
end

-- Clear only what this module lit; a snapshot avoids mutating `glowing` while
-- iterating it.
local function clearGlows()
    local buttons = {}
    for button in pairs(glowing) do buttons[#buttons + 1] = button end
    for _, button in ipairs(buttons) do setGlow(button, false) end
end

------------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------------

function ImbueGlow:Refresh()
    if not optionOn() or not isShaman() then
        -- Other classes never glow: clear anything this module lit before the
        -- class changed (a test character switch) and stop.
        clearGlows()
        return
    end
    if inCombat() then return end

    local wantGlow = not hasImbue()
    local names = {}
    for _, n in ipairs(imbueSpellNames()) do names[n] = true end

    for _, button in ipairs(actionButtons()) do
        local spell = buttonSpellName(button)
        if spell and names[spell] then
            setGlow(button, wantGlow)
        elseif glowing[button] then
            setGlow(button, false)
        end
    end
end

function ImbueGlow:SetEnabled(on)
    enabled = (on ~= false)

    -- One switch, two doors: the slash command and the stored option agree, so
    -- the next reload keeps what the player chose.
    local db = LT.Database
    if type(db) == "table" and type(db.GetOptions) == "function" then
        local ok, options = pcall(db.GetOptions, db)
        if ok and type(options) == "table" then options[OPTION_KEY] = enabled end
    end

    if not enabled then clearGlows() end
    self:Refresh()
end

------------------------------------------------------------------------------
-- Driver: one refresh a second + login/equip/bar events
------------------------------------------------------------------------------

-- Defined with the slash command below; declared here so a login event can
-- register it once the class is known.
local registerCommand

local eventFrame = CreateFrame("Frame")
local elapsed = 0

eventFrame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (tonumber(dt) or 0)
    if elapsed < 1 then return end
    elapsed = 0
    if ImbueGlow then ImbueGlow:Refresh() end
end)

eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD"
        or event == "PLAYER_REGEN_ENABLED" or event == "ACTIONBAR_SLOT_CHANGED"
        or event == "PLAYER_EQUIPMENT_CHANGED" then
        -- Shaman-only surface: the slash word appears only for a Shaman.
        if isShaman() and registerCommand then registerCommand() end
        if ImbueGlow then ImbueGlow:Refresh() end
    end
end)

for _, event in ipairs({
    "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED",
    "ACTIONBAR_SLOT_CHANGED", "PLAYER_EQUIPMENT_CHANGED",
}) do
    pcall(eventFrame.RegisterEvent, eventFrame, event)
end

------------------------------------------------------------------------------
-- Slash: /lt imbueglow [on|off]
------------------------------------------------------------------------------

local commandRegistered = false

registerCommand = function()
    if commandRegistered then return true end
    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then return false end
    local ok, added = pcall(slash.RegisterCommand, slash, "imbueglow",
        function(words) ImbueGlow:Command(words) end,
        "/lt imbueglow — glow the weapon-imbue buttons when no imbue is applied")
    if ok and added == true then
        commandRegistered = true
        return true
    end
    return false
end

function ImbueGlow:Report()
    local message = optionOn() and "Imbue glow is on (Shaman weapon imbues)." or "Imbue glow is off."
    if type(LT.Print) == "function" then
        pcall(LT.Print, LT, message)
    else
        pcall(print, message)
    end
end

function ImbueGlow:Command(words)
    local action = tostring(words and words[2] or ""):lower()
    if action == "" or action == "status" then
        self:Report()
        return true
    end
    if action == "on" then
        self:SetEnabled(true)
        self:Report()
        return true
    end
    if action == "off" then
        self:SetEnabled(false)
        self:Report()
        return true
    end
    self:Report()
    return true
end

-- Shaman only: a Rogue never learns this word exists.
if isShaman() then registerCommand() end
