--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Skins
    Runtime colour themes over cline's shell. Layout stays cline (rail); a theme
    mutates Palette.chrome in place, so all future paints use the new colours.
    A reload repaints frames already on screen. /lt skin (no arg) opens a picker.
--------------------------------------------------------------------------]]

if not LunchboxToolkit then return end
local LT = LunchboxToolkit

local Skins = {}
LT.Skins = Skins
LT.Modules.Skins = Skins

Skins.ORDER = { "cline", "cline-v1", "original", "omp" }
Skins.LABELS = { cline = "cline v2", ["cline-v1"] = "cline v1", original = "original", omp = "omp" }

Skins.THEMES = {
    cline = {},

    ["cline-v1"] = {
        brand     = { 0.33, 0.88, 0.82, 1.00 },
        muted     = { 0.55, 0.60, 0.65, 1.00 },
        text      = { 0.94, 0.95, 0.97, 1.00 },
        panelBg   = { 0.08, 0.10, 0.12, 1.00 },
        windowBg  = { 0.05, 0.06, 0.08, 1.00 },
        buttonBg  = { 0.13, 0.16, 0.19, 1.00 },
        buttonHot = { 0.18, 0.21, 0.25, 1.00 },
        warningBg = { 0.15, 0.07, 0.04, 1.00 },
        border     = { 0.22, 0.27, 0.33, 1.00 },
        borderDark = { 0.02, 0.03, 0.04, 1.00 },
        cardEdge   = { 0.15, 0.18, 0.22, 1.00 },
        fill       = { 0.04, 0.05, 0.06, 1.00 },
        railBg     = { 0.03, 0.04, 0.05, 1.00 },
        headerBg   = { 0.07, 0.09, 0.11, 1.00 },
        accent     = { 0.30, 0.55, 0.90, 1.00 },
        accentDim  = { 0.15, 0.30, 0.50, 1.00 },
    },

    original = {
        brand     = { 0.92, 0.76, 0.30, 1.00 },
        muted     = { 0.55, 0.55, 0.55, 1.00 },
        text      = { 1.00, 1.00, 1.00, 1.00 },
        panelBg   = { 0.05, 0.05, 0.05, 1.00 },
        windowBg  = { 0.04, 0.04, 0.04, 1.00 },
        buttonBg  = { 0.16, 0.16, 0.16, 1.00 },
        buttonHot = { 0.26, 0.26, 0.26, 1.00 },
        warningBg = { 0.20, 0.04, 0.04, 1.00 },
        border     = { 0.85, 0.70, 0.25, 1.00 },
        borderDark = { 0.00, 0.00, 0.00, 1.00 },
        cardEdge   = { 0.12, 0.12, 0.12, 1.00 },
        fill       = { 0.00, 0.00, 0.00, 1.00 },
        railBg     = { 0.02, 0.02, 0.02, 1.00 },
        headerBg   = { 0.06, 0.06, 0.06, 1.00 },
        accent     = { 0.85, 0.20, 0.20, 1.00 },
        accentDim  = { 0.45, 0.10, 0.10, 1.00 },
    },

    omp = {
        brand     = { 0.94, 0.78, 0.44, 1.00 },
        muted     = { 0.72, 0.64, 0.50, 1.00 },
        text      = { 1.00, 0.96, 0.88, 1.00 },
        panelBg   = { 0.13, 0.10, 0.08, 1.00 },
        windowBg  = { 0.08, 0.06, 0.05, 1.00 },
        buttonBg  = { 0.19, 0.15, 0.10, 1.00 },
        buttonHot = { 0.26, 0.20, 0.14, 1.00 },
        warningBg = { 0.26, 0.12, 0.05, 1.00 },
        border     = { 0.74, 0.60, 0.38, 1.00 },
        borderDark = { 0.05, 0.04, 0.03, 1.00 },
        cardEdge   = { 0.42, 0.34, 0.22, 1.00 },
        fill       = { 0.06, 0.05, 0.04, 1.00 },
        accent     = { 0.92, 0.76, 0.42, 1.00 },
        accentDim  = { 0.50, 0.40, 0.22, 1.00 },
    },
}

function Skins:ApplyTheme(name)
    local theme = self.THEMES[name]
    if type(theme) ~= "table" then return false end

    local palette = LT.Palette
    if type(palette) ~= "table" then return false end
    local chrome = palette.chrome
    if type(chrome) ~= "table" then return false end

    for key, colour in pairs(theme) do
        if type(chrome[key]) == "table" and type(colour) == "table" then
            local c = { colour[1], colour[2], colour[3], colour[4] or 1 }
            chrome[key] = c
            if type(palette.named) == "table" then
                palette.named[key] = { r = c[1], g = c[2], b = c[3] }
            end
            local hex = string.format("%02x%02x%02x",
                math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
            if type(palette.hex) == "table" then palette.hex[key] = hex end
            if type(palette.code) == "table" then palette.code[key] = "|cff" .. hex end
        end
    end
    return true
end

function Skins:SavedName()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return "cline"
    end

    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then return "cline" end
    return options.uiTheme or "cline"
end

function Skins:Choose(name)
    if not self.THEMES[name] then return false end

    local database = LT.Database
    if type(database) == "table" and type(database.GetOptions) == "function" then
        local ok, options = pcall(database.GetOptions, database)
        if ok and type(options) == "table" then options.uiTheme = name end
    end

    self:ApplyTheme(name)

    StaticPopupDialogs["LUNCHBOX_SKIN_CHANGE"] = StaticPopupDialogs["LUNCHBOX_SKIN_CHANGE"] or {
        preferredIndex = 3,
        text = "Skin will change to %s. A reload applies it.",
        button1 = "Apply + reload",
        button2 = "Cancel",
        OnAccept = function() ReloadUI() end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("LUNCHBOX_SKIN_CHANGE", self.LABELS[name] or name)
    return true
end

function Skins:OpenPicker()
    local window = CreateFrame("Frame", "LunchboxToolkitSkinPicker", UIParent)
    window:SetSize(220, 48 + #self.ORDER * 30 + 34)
    window:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    window:SetFrameStrata("DIALOG")
    window:SetToplevel(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)

    if LT.Chrome and type(LT.Chrome.Window) == "function" then
        pcall(LT.Chrome.Window, window)
    end

    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("Skin — current: " .. (self.LABELS[self:SavedName()] or self:SavedName()))

    local y = -36
    for _, name in ipairs(self.ORDER) do
        local label = self.LABELS[name] or name
        local b
        if LT.UI and type(LT.UI.MakeButton) == "function" then
            local ok, made = pcall(LT.UI.MakeButton, LT.UI, window, label, 180, 22, function()
                Skins:Choose(name)
                window:Hide()
            end)
            if ok and type(made) == "table" then b = made end
        end
        if not b then
            b = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
            b:SetSize(180, 22)
            b:SetText(label)
            b:SetScript("OnClick", function() Skins:Choose(name); window:Hide() end)
        end
        b:SetPoint("TOPLEFT", 14, y)
        y = y - 28
    end

    -- A way out without choosing. The picker used to be closeable only by
    -- picking a skin or reloading; Escape works too because the frame is named.
    local cancel
    if LT.UI and type(LT.UI.MakeButton) == "function" then
        local ok, made = pcall(LT.UI.MakeButton, LT.UI, window, "Cancel", 90, 22, function()
            window:Hide()
        end)
        if ok and type(made) == "table" then cancel = made end
    end
    if not cancel then
        cancel = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        cancel:SetSize(90, 22)
        cancel:SetText("Cancel")
        cancel:SetScript("OnClick", function() window:Hide() end)
    end
    cancel:SetPoint("BOTTOMLEFT", 14, 14)

    if type(UISpecialFrames) == "table" then
        local listed = false
        for _, name in ipairs(UISpecialFrames) do
            if name == "LunchboxToolkitSkinPicker" then listed = true break end
        end
        if not listed then table.insert(UISpecialFrames, "LunchboxToolkitSkinPicker") end
    end

    window:Show()
    return window
end

local function applySaved()
    local name = Skins:SavedName()
    Skins:ApplyTheme(name)
end

local listener = CreateFrame("Frame")
listener:RegisterEvent("PLAYER_LOGIN")
listener:SetScript("OnEvent", applySaved)
