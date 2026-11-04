--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Legend
    The window that explains the palette: what each colour asserts, where it
    appears, and a line of the kind the player will see in it.

    Where it opens from: the Colours button in the window header, and
    /lt colours. Deliberately not a tab of its own — the tab strip is the list of
    jobs the add-on does (Builds, Profiles, Caps...), and a legend is reference
    material, read once and then occasionally. The header is the right home for
    it because the colours it explains appear on every page, not only Settings.

    Everything shown comes from LT.Palette.legend, the same list /lt colours
    prints and the self test checks, so the window cannot describe a colour the
    add-on does not use (or miss one it does).

    Nothing is saved: the window opens beside the main window — over it when the
    screen is too narrow for both — and can be dragged for the session. A saved
    position would add a key to saved variables for a window most players open
    twice.

    The widgets here are the window's own. UI.lua keeps its builders local to
    that file, and a reference window has no business taking a dependency on the
    main window's control pool to draw seven short lines.
--------------------------------------------------------------------------]]
local LT = LunchboxToolkit
local Palette = LT.Palette

local Legend = {}
LT.Legend = Legend
LT.Modules.Legend = Legend

local WIDTH = 470
local PADDING = 16
local SWATCH = 14
local TEXT_LEFT = PADDING + SWATCH + 12

-- One line of GameFontNormalSmall. Only used to turn a measured width into a
-- height, on the clients that cannot report the height itself.
local LINE_HEIGHT = 12

local frame
local moved

------------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------------

local function label(parent, text, font, colour)
    local ok, created = pcall(parent.CreateFontString, parent, nil, "OVERLAY", font)

    if ok and created then
        created:SetText(tostring(text))
        if colour then created:SetTextColor(colour[1], colour[2], colour[3]) end
        return created
    end

    return nil
end

local function button(parent, text, width, height, onClick)
    local ok, created = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")

    if ok and created and created.SetText then
        created:SetSize(width, height)
        created:SetText(tostring(text))
        created:SetScript("OnClick", onClick)
        return created
    end

    -- Fallback for a client without the panel button template.
    local flat = CreateFrame("Button", nil, parent)
    flat:SetSize(width, height)

    local idle = Palette.chrome.buttonBg
    local hot = Palette.chrome.buttonHot

    local background = flat:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(true)
    background:SetColorTexture(idle[1], idle[2], idle[3], idle[4])

    local caption = flat:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caption:SetPoint("CENTER")
    caption:SetText(tostring(text))
    flat.label = caption

    flat:SetScript("OnClick", onClick)
    flat:SetScript("OnEnter", function()
        background:SetColorTexture(hot[1], hot[2], hot[3], hot[4])
    end)
    flat:SetScript("OnLeave", function()
        background:SetColorTexture(idle[1], idle[2], idle[3], idle[4])
    end)

    return flat
end

-- Font strings report their wrapped height on this client, but not on every
-- client, so a fallback keeps the layout sane when the call is missing. Where
-- only the single-line width is available it is turned into a line count, which
-- is the difference between "a row is one line tall" and "a row is as tall as the
-- text it holds" -- and the second is what stops the next row landing on top of
-- the last one's words.
local function measure(fontString, fallback)
    if fontString and fontString.GetStringHeight then
        local ok, height = pcall(fontString.GetStringHeight, fontString)
        if ok and type(height) == "number" and height > 0 then return height end
    end

    if fontString and fontString.GetStringWidth and fontString.GetWidth then
        local okWidth, textWidth = pcall(fontString.GetStringWidth, fontString,
            fontString:GetText() or "")
        local okBox, boxWidth = pcall(fontString.GetWidth, fontString)

        if okWidth and okBox and type(textWidth) == "number" and type(boxWidth) == "number"
            and textWidth > 0 and boxWidth > 0 then
            local lines = math.ceil(textWidth / boxWidth)
            if lines < 1 then lines = 1 end
            -- Word wrapping can need one line more than the plain ratio does, so a
            -- paragraph that spans lines is given that line. Extra space under a
            -- row is harmless; text landing on the next row's text is not.
            if lines > 1 then lines = lines + 1 end
            return lines * LINE_HEIGHT
        end
    end

    return fallback
end

------------------------------------------------------------------------------
-- Rows
------------------------------------------------------------------------------

-- One row: the colour itself, its name in that colour, what it means, and where
-- it shows up. Returns the y the next row starts at.
local function addRow(parent, entry, y)
    local colour = Palette:Colour(entry.key) or Palette.chrome.text
    local textWidth = WIDTH - TEXT_LEFT - PADDING

    local swatch = parent:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(SWATCH, SWATCH)
    swatch:SetPoint("TOPLEFT", PADDING, y - 2)
    swatch:SetColorTexture(colour[1], colour[2], colour[3], 1)

    -- The money row carries the coin, because that is what makes gold read as
    -- currency on a reward border rather than as a judgement on the item. It sits
    -- on the swatch's trailing edge as a badge, clear of the name column.
    if entry.key == "money" then
        local coinOk, coin = pcall(parent.CreateTexture, parent, nil, "ARTWORK")
        if coinOk and coin then
            if coin.SetTexture then pcall(coin.SetTexture, coin, Palette.coinTexture) end
            coin:SetSize(SWATCH, SWATCH)
            coin:SetPoint("TOPLEFT", PADDING + SWATCH - 4, y - 2)
        end
    end

    local name = label(parent, entry.name, "GameFontNormal", Palette:Colour(entry.key))
    if name then name:SetPoint("TOPLEFT", TEXT_LEFT, y) end

    local meaning = label(parent, entry.meaning, "GameFontNormalSmall",
        Palette:Colour("text"))
    if meaning then
        meaning:SetWidth(textWidth)
        meaning:SetJustifyH("LEFT")
        meaning:SetPoint("TOPLEFT", TEXT_LEFT, y - 15)
    end

    local where = label(parent,
        entry.where .. "  e.g. " .. entry.example, "GameFontNormalSmall",
        Palette:Colour("muted"))
    if where then
        where:SetWidth(textWidth)
        where:SetJustifyH("LEFT")
        where:SetPoint("TOPLEFT", TEXT_LEFT, y - 15 - measure(meaning, 12))
    end

    return y - 15 - measure(meaning, 12) - measure(where, 12) - 10
end

------------------------------------------------------------------------------
-- Window
------------------------------------------------------------------------------

local function build()
    local ok, created = pcall(CreateFrame, "Frame", "LunchboxToolkitColoursFrame", UIParent)
    if not ok or not created then
        LT:Error("The colours window could not be created on this client.")
        return nil
    end

    local window = created
    window:SetWidth(WIDTH)
    window:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    if window.SetFrameStrata then window:SetFrameStrata("DIALOG") end

    -- The same edge as the main window: one shared draw, so the Colours window
    -- cannot look like a different add-on from the window that opened it.
    LT.Chrome.Window(window)

    window:EnableMouse(true)
    window:SetMovable(true)
    pcall(window.RegisterForDrag, window, "LeftButton")
    window:SetScript("OnDragStart", function(self) self:StartMoving() end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        moved = true
    end)
    window:Hide()

    local title = label(window, "What the colours mean", "GameFontNormal",
        Palette:Colour("brand"))
    if title then title:SetPoint("TOPLEFT", PADDING, -PADDING) end

    local subtitle = label(window,
        "The same palette everywhere: tooltips, quest rewards, caps and checks.",
        "GameFontNormalSmall", Palette:Colour("muted"))
    if subtitle then subtitle:SetPoint("TOPLEFT", PADDING, -PADDING - 18) end

    local y = -PADDING - 42

    for _, entry in ipairs(Palette.legend) do
        y = addRow(window, entry, y)
    end

    y = y - 2

    local footer = label(window,
        "An equal score (\"Even\") is dimmed text, not a verdict.",
        "GameFontNormalSmall", Palette:Colour("muted"))
    if footer then footer:SetPoint("TOPLEFT", PADDING, y) end

    local close = button(window, "Close", 70, 20, function() window:Hide() end)
    close:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)

    -- Height follows the rows, so a longer legend never spills past the frame.
    window:SetHeight(PADDING + 42 - y + 48)

    -- Escape closes it like any other dialog. The name is the global the frame
    -- was created with, so this stays correct if the frame is ever recreated.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "LunchboxToolkitColoursFrame")
    end

    frame = window
    return frame
end

-- Where the window sits: fully inside the UI area on every open, until the player
-- drags it. Beside the main window when the screen is wide enough for both — right
-- first, then left — and over the main window when it is not, because a 470-pixel
-- legend next to a 660-pixel main window does not fit on a 1024-wide UI at all.
--
-- Why the third case changed (player report 2026-10-27: "it opens up but is mostly
-- off screen"): it used to anchor the legend's BOTTOMLEFT to the main window's
-- TOPLEFT, so a tall wrapped legend — roughly 570 pixels — grew upward from the main
-- window's top edge and most of it sat above the screen. Overlapping the main window
-- is the honest answer on a narrow UI; off the screen never is.
--
-- Every branch ends in the same clamp, so no path can place the frame partly outside
-- the UI. If the window is taller than the whole UI area the clamp keeps its bottom
-- and top-left corner visible rather than its middle.
local function place(window)
    window:ClearAllPoints()

    local uiWidth = UIParent:GetWidth() or 0
    local uiHeight = UIParent:GetHeight() or 0
    local width = window:GetWidth() or WIDTH
    local height = window:GetHeight() or 0
    local margin = 8
    local gap = 10

    local main = _G.LunchboxToolkitFrame
    local left, right, top, bottom

    if main and main.IsShown and main:IsShown() and main.GetLeft then
        left = main:GetLeft()
        right = main:GetRight()
        top = main.GetTop and main:GetTop() or nil
        bottom = main.GetBottom and main:GetBottom() or nil
    end

    local x, y

    if left and right and top then
        if (right + gap + width) <= (uiWidth - margin) then
            -- Beside it on the right, tops aligned.
            x = right + gap
            y = top - height
        elseif (left - gap - width) >= margin then
            -- Beside it on the left, tops aligned.
            x = left - gap - width
            y = top - height
        else
            -- No room beside it: centred over the main window.
            x = left + ((right - left) - width) / 2
            y = (bottom or 0) + ((top - (bottom or 0)) - height) / 2
        end
    else
        -- No main window on screen (login, or /lt colours before it was ever
        -- opened): centre on the UI.
        x = (uiWidth - width) / 2
        y = (uiHeight - height) / 2
    end

    -- Clamp into the UI area, margins included.
    if uiWidth > 0 then
        if x < margin then x = margin end
        if x + width > uiWidth - margin then x = uiWidth - margin - width end
        if x < 0 then x = 0 end
    end

    if uiHeight > 0 then
        if y < margin then y = margin end
        if y + height > uiHeight - margin then y = uiHeight - margin - height end
        if y < 0 then y = 0 end
    end

    window:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
end

function Legend:Show()
    local window = frame or build()
    if not window then return false end

    -- Placed fully inside the UI area on every open until the player drags it; after
    -- that the position they chose wins, even if they have put it somewhere it
    -- overlaps the main window.
    if not moved then place(window) end
    window:Show()
    if window.Raise then window:Raise() end
    return true
end

function Legend:Hide()
    if frame then frame:Hide() end
end

function Legend:IsShown()
    return frame ~= nil and frame:IsShown()
end

function Legend:Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
        return false
    end

    return self:Show()
end

