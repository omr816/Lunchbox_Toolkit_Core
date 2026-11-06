--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — UI
    One window, one page per job. Deliberately plain: buttons cycle values and
    edit boxes commit on Enter, so the window keeps working on a client whose
    dropdown and template support is still moving.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local UI = {}
LT.UI = UI

-- The one line the Windfury row can add without a second list: the recorded
-- averages, straight from Trackers. Empty when nothing is recorded.
function UI:WindfuryLabel()
    local trackers = LT.Trackers
    if type(trackers) ~= "table" or type(trackers.WindfurySummary) ~= "function" then return "" end
    local ok, summary = pcall(trackers.WindfurySummary, trackers)
    if ok and type(summary) == "string" and summary ~= "" then return " — " .. summary end
    return ""
end
LT.Modules.UI = UI

local PAGES = {
    { key = "builds",   label = "Builds" },
    { key = "profiles", label = "Profiles" },
    { key = "gear",     label = "Equipment" },
    { key = "setup",    label = "Best setup" },
    { key = "plugins",  label = "Plugins" },
    { key = "settings", label = "Settings" },
    -- Debug is a popup opened from Settings now, not a page of its own: it is the
    -- one screen a player mostly does not need. The key stays in this list so a
    -- saved page from 1.5.6 is still recognised (and redirected, see
    -- ensureFrame) and so the page registry keeps the order the self test
    -- asserts; `hidden` is what keeps it off the rail.
    { key = "debug",    label = "Debug", hidden = true },
    { key = "actions",  label = "Actions" },
    { key = "ranks",    label = "Ranks" },
}

-- The ordered page list is readable by an optional local addon, but only
-- UI:AddPage may change it. Nothing in this file depends on the list being
-- fixed, so a page contributed from outside gets its own row on the rail and
-- behaves like a bundled one.
UI.pages = PAGES

-- Pages contributed through UI:AddPage: key -> draw(cursor, content).
local externalDrawers = {}

local currentPage = "builds"
local selectedProfileKey = nil

------------------------------------------------------------------------------
-- Surfaces
--
-- Every edge in this file comes from Chrome and every colour from Palette; the
-- helpers below are the only places that decide what one of our window surfaces
-- looks like, so the main window, its popups and the character-panel card cannot
-- drift apart.
--
-- The look since the 2026-10-31 client-skin brief is the client's own: a warm
-- brown-black slab under a gold rim, panels inset into it, controls raised out of
-- it, parchment text. Still no texture file anywhere, so the window reads the
-- same at every UI scale. Depth comes from the bevel Chrome draws - lit on the
-- top-left of what you press, shaded on the top-left of what you look into -
-- plus fill value, window to panel to button to rail, and the single cold mark
-- that says which page is up.
--
-- Every fill below is forced to alpha 1 in opaqueFill, whatever the palette
-- says: the defect this rework exists to remove is a background the world shows
-- through, and one colour edit must not be able to bring it back.
------------------------------------------------------------------------------

-- Three fills, one rule: opaque, always. The fourth channel is written here as
-- 1 so no later palette edit can put the game world back behind the window.
local function opaqueFill(colour, fallback)
    local tone = (type(colour) == "table") and colour or fallback
    if type(tone) ~= "table" then return { 0.09, 0.07, 0.05, 1 } end
    return { tone[1], tone[2], tone[3], 1 }
end

-- The slab behind the content: the darkest plane in the window, so every panel
-- and button placed on it reads as raised.
local function windowSurface()
    return opaqueFill(LT.Palette.chrome.windowBg, { 0.09, 0.07, 0.05, 1 })
end

-- A panel sitting on the slab: the tooltip, a popup body, a card. One step
-- lighter than the window, never a hole in it.
local function panelSurface()
    return opaqueFill(LT.Palette.chrome.panelBg, { 0.14, 0.11, 0.08, 1 })
end

-- The line just inside a window's rule. Near-black and one pixel: it is what
-- makes a popup read as a separate slab from the page behind it when both fills
-- are graphite and only a few values apart.
local function windowHighlight()
    local dark = LT.Palette.chrome.borderDark
    if type(dark) ~= "table" then return { 0.03, 0.02, 0.01, 1 } end
    return { dark[1], dark[2], dark[3], 1 }
end

-- The one call that makes a frame look like one of our windows. `opts` goes
-- straight to Chrome.Window, so a caller can still ask for another fill or edge;
-- omitted, it gets the opaque slab and the window's hairline rim.
local function windowChrome(target, opts)
    if not target then return nil end

    local settings = (type(opts) == "table") and opts or {}
    if settings.fill == nil then settings.fill = windowSurface() end
    if settings.inner == nil then settings.inner = windowHighlight() end

    return LT.Chrome.Window(target, settings)
end

-- A card inside a window: the quieter hairline, and by default the same opaque
-- slab so a panel never becomes a hole in the window.
local function cardChrome(target, opts)
    if not target then return nil end

    local settings = (type(opts) == "table") and opts or {}
    if settings.fill == nil then settings.fill = panelSurface() end

    return LT.Chrome.Card(target, settings)
end

------------------------------------------------------------------------------
-- Widget helpers
------------------------------------------------------------------------------

-- A button's edge is fixed when it is drawn; a hover moves its face and its
-- label and nothing else.
--
-- That is the rule the 2026-10-31 client-skin brief asks for, and the reason is a
-- defect the player reproduced on the other arm: a hover handed the edge the
-- FACE colour, so the border was painted off, and nothing put it back until a
-- click redrew the page. `buttonTone` is the whole of what a hover may change,
-- `buttonEdge` is the one key every control's edge comes from, and the self test
-- asserts that neither returned tone is an edge key - so a later edit cannot
-- bring the vanishing border back by accident.
UI.buttonEdge = "cardEdge"

local function buttonTone(enabled, hovered)
    if not enabled then return "fill", "muted" end
    if hovered then return "buttonHot", "text" end
    return "buttonBg", "text"
end
UI.buttonTone = buttonTone

-- One button for the whole add-on, drawn rather than templated.
--
-- The template button (UIPanelButtonTemplate) brings the client's own stone
-- bevel with it, which is why the previous build showed two vocabularies at
-- once: flat add-on panels with Blizzard's buttons sitting on them. This draws a
-- button the same way every other surface is drawn - one opaque fill, one
-- hairline, a centred label - so it is visibly part of this window. Height and
-- width still come from the caller, because pages reserve exact vertical space
-- for a button; everything else is fixed, so every button on every page is one
-- object with a different label.
local function MakeButton(parent, text, width, height, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(tonumber(width) or 120, tonumber(height) or 22)

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", 0, 0)
    label:SetJustifyH("CENTER")
    button.label = label
    button.ltEnabled = true
    button.ltHover = false

    local function paint(self)
        local chrome = LT.Palette.chrome
        local fillKey, labelKey = buttonTone(self.ltEnabled, self.ltHover)
        local tone = LT.Palette:RGB(labelKey)

        -- The edge is always buttonEdge, so a hover repaints the same border the
        -- draw painted: only the face and the label differ.
        LT.Chrome.Card(self, {
            edge = chrome[UI.buttonEdge],
            fill = chrome[fillKey],
            bevelMode = "raised",
        })
        if self.label then self.label:SetTextColor(tone.r, tone.g, tone.b) end
    end
    button.ltPaint = paint

    -- Pages keep asking a cycle button for its new text ("Spec: Beast Mastery"),
    -- so the drawn label answers the same method the template one did.
    button.SetText = function(self, value)
        self.ltText = tostring(value)
        if self.label then self.label:SetText(self.ltText) end
    end
    button.GetText = function(self) return self.ltText end
    -- The character-sheet card measures a button's text to size it, so the drawn
    -- label answers GetFontString the way a templated button's did.
    button.GetFontString = function(self) return self.label end
    button:SetText(text)

    -- Disable() is what the Profiles page and the Ranks popup use to grey a
    -- control they will not let the player touch yet; SetEnabled is the same
    -- thing said the other way. A disabled button keeps its shape, loses its
    -- hover and refuses the click.
    button.SetEnabled = function(self, value)
        self.ltEnabled = (value ~= false)
        self.ltHover = false
        paint(self)
    end
    button.Enable = function(self) self:SetEnabled(true) end
    button.Disable = function(self) self:SetEnabled(false) end

    button:SetScript("OnClick", function(self)
        if not self.ltEnabled then return end
        if type(onClick) == "function" then onClick(self) end
    end)
    button:SetScript("OnEnter", function(self)
        if not self.ltEnabled then return end
        self.ltHover = true
        paint(self)
    end)
    button:SetScript("OnLeave", function(self)
        self.ltHover = false
        paint(self)
    end)

    paint(button)
    return button
end

-- Labels are FontStrings (regions), not child frames, so frame:GetChildren()
-- never returns them and they cannot be reparented away. Labels created directly
-- on the page's content frame are therefore pooled: clearContent() hides and
-- returns them to parent.lunchboxLabelPool, and MakeLabel reuses them.
local function MakeLabel(parent, text, size, colour)
    local fontName = size or "GameFontNormalSmall"
    local pool = parent.lunchboxLabelPool
    local label

    if pool and #pool > 0 then
        label = table.remove(pool)
        label.lunchboxFree = false
        label:ClearAllPoints()
        label:SetFontObject(_G[fontName] or fontName)
        label:SetWidth(0)
        label:SetJustifyH("CENTER")
        label:Show()

        -- A reused label must not inherit a previous custom colour.
        local r, g, b = 1, 1, 1
        local fontObject = _G[fontName]
        if fontObject and fontObject.GetTextColor then
            local okColour, fr, fg, fb = pcall(fontObject.GetTextColor, fontObject)
            if okColour and fr then r, g, b = fr, fg, fb end
        end
        label:SetTextColor(r, g, b)
    else
        label = parent:CreateFontString(nil, "OVERLAY", fontName)
    end

    label:SetText(tostring(text))

    if colour then
        label:SetTextColor(colour.r, colour.g, colour.b)
    end

    return label
end

local function MakeEditBox(parent, width, height, value, onCommit)
    local ok, box = pcall(CreateFrame, "EditBox", nil, parent, "InputBoxTemplate")

    if not ok or not box then
        box = CreateFrame("EditBox", nil, parent)
        box:SetAutoFocus(false)
        box:SetFontObject("ChatFontNormal")
    end

    box:SetSize(width or 140, height or 20)
    box:SetText(tostring(value or ""))
    box:SetAutoFocus(false)

    -- Text is committed on Enter and also when focus is lost (clicking another
    -- control or page), so a typed value is not silently discarded by the next
    -- page rebuild. Escape cancels and must not commit.
    local cancelled = false
    local committed = tostring(value or "")

    local function commit(self)
        local text = self:GetText()
        if text == committed then return end
        committed = text
        onCommit(text)
    end

    box:SetScript("OnEnterPressed", function(self)
        commit(self)
        self:ClearFocus()
    end)

    box:SetScript("OnEscapePressed", function(self)
        cancelled = true
        self:SetText(committed)
        self:ClearFocus()
    end)

    box:SetScript("OnEditFocusLost", function(self)
        if cancelled then
            cancelled = false
            return
        end
        commit(self)
    end)

    return box
end

-- One on/off control for the whole add-on, drawn like every other control.
--
-- The previous version used the client's own tick box, which is a third
-- vocabulary again: a round gold stud beside a flat panel. This is a square -
-- one hairline, an opaque fill, and a drawn mark when it is on. The mark is what
-- carries the state, never the fill colour, because the player rejected filled
-- green/red squares for exactly that reason: colour alone cannot say "on".
local function MakeCheck(parent, checked, onClick)
    local box = CreateFrame("Button", nil, parent)
    box:SetSize(20, 20)

    local glyph = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    glyph:SetAllPoints(true)
    glyph:SetJustifyH("CENTER")
    glyph:SetJustifyV("MIDDLE")
    box.ltGlyph = glyph
    box.ltEnabled = true

    local function paint(self, on)
        self.ltOn = (on == true)

        local chrome = LT.Palette.chrome
        local edge = self.ltOn and chrome.border or chrome.cardEdge
        local fill = self.ltEnabled and chrome.buttonBg or chrome.fill
        LT.Chrome.Card(self, { edge = edge, fill = fill })

        local colour = self.ltOn and LT.Palette:RGB("accent") or LT.Palette:RGB("muted")
        glyph:SetText(self.ltOn and "X" or "")
        glyph:SetTextColor(colour.r, colour.g, colour.b)
    end

    box.SetChecked = function(self, value) paint(self, value) end
    box.GetChecked = function(self) return self.ltOn == true end
    box.SetEnabled = function(self, value)
        self.ltEnabled = (value ~= false)
        paint(self, self.ltOn)
    end
    box.Enable = function(self) self:SetEnabled(true) end
    box.Disable = function(self) self:SetEnabled(false) end
    box.ltPaint = paint

    box:SetScript("OnClick", function(self)
        if not self.ltEnabled then return end
        local value = not self.ltOn
        paint(self, value)
        if type(onClick) == "function" then onClick(value) end
    end)

    paint(box, checked == true)
    return box
end

-- A horizontal slider for a numeric option. The thumb is a plain texture and the
-- track a thin line, so it needs no template the client might not ship. The value
-- is written by the row's `apply`, never held here. It lives on UI rather than in
-- a chunk local because UI.lua is at Lua's 200-local limit.
function UI:MakeSlider(parent, min, max, step, value, onValue)
    local slider = CreateFrame("Slider", nil, parent)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(150, 16)
    slider:SetMinMaxValues(min, max)
    slider:SetValueStep(step)
    if type(slider.SetObeyStepOnDrag) == "function" then
        pcall(slider.SetObeyStepOnDrag, slider, true)
    end

    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetHeight(2)
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetColorTexture(0.35, 0.32, 0.22, 0.9)

    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetSize(10, 16)
    thumb:SetColorTexture(0.85, 0.80, 0.55, 1)
    slider:SetThumbTexture(thumb)

    if type(slider.SetValue) == "function" then
        local okValue = pcall(slider.SetValue, slider, tonumber(value) or min)
        if not okValue then pcall(slider.SetValue, slider, min) end
    end

    slider:SetScript("OnValueChanged", function(self, newValue)
        local number = tonumber(newValue)
        if not number then return end
        if type(onValue) == "function" then onValue(number) end
    end)

    return slider
end

-- The one combat test every popup and the Ranks page share. Creating a frame is
-- the operation the client refuses in combat; showing one that exists is not.
local function combatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

------------------------------------------------------------------------------
-- Hover help
------------------------------------------------------------------------------

-- Explanatory text lives on a "?" next to the heading or option it describes,
-- not on the page. The page then reads as a list of controls, and the detail is
-- one hover away in the game's own tooltip, which also wraps long paragraphs
-- without widening the window. Nothing here is invented: the strings are the
-- ones the pages used to print.
local function showInfo(frame, title, text)
    if not GameTooltip or type(GameTooltip.SetOwner) ~= "function" then return end

    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:AddLine(tostring(title or "Lunchbox Toolkit"),
        LT.Palette.named.brand.r, LT.Palette.named.brand.g, LT.Palette.named.brand.b, true)
    GameTooltip:AddLine(tostring(text), 1, 1, 1, true)
    GameTooltip:Show()
end

-- Returns nil when there is nothing to explain, so a caller can pass the text
-- straight through and a heading without a paragraph simply has no marker.
local function MakeInfo(parent, title, text)
    if type(text) ~= "string" or text == "" then return nil end

    local button = CreateFrame("Button", nil, parent)
    button:SetSize(16, 16)

    local glyph = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    glyph:SetAllPoints(true)
    glyph:SetJustifyH("CENTER")
    glyph:SetText("?")
    -- Brand, not gold: gold now means money at the reward window, so a heading
    -- marker that shared it would say the wrong thing.
    local brand = LT.Palette.named.brand
    glyph:SetTextColor(brand.r, brand.g, brand.b)

    button:SetScript("OnEnter", function(self)
        local hover = LT.Palette.named.text
        glyph:SetTextColor(hover.r, hover.g, hover.b)
        showInfo(self, title, text)
    end)

    button:SetScript("OnLeave", function()
        glyph:SetTextColor(brand.r, brand.g, brand.b)
        if GameTooltip then GameTooltip:Hide() end
    end)

    -- Clicking repeats the tooltip, which is also the only way to read it on a
    -- client where hover is awkward (touchpad, or a pointer that keeps moving).
    button:SetScript("OnClick", function(self)
        showInfo(self, title, text)
    end)

    return button
end

-- An invisible mouse target over a label: hovering the option name shows the
-- same text as its "?" without adding another visible control. It starts at the
-- label's left edge, so a checkbox beside the label keeps its own clicks.
local function MakeHoverTarget(parent, title, text, anchorLabel)
    if type(text) ~= "string" or text == "" then return nil end

    local button = CreateFrame("Button", nil, parent)
    button:SetPoint("LEFT", anchorLabel, "LEFT", -4, 0)
    button:SetPoint("RIGHT", anchorLabel, "RIGHT", 8, 0)
    button:SetHeight(18)

    button:SetScript("OnEnter", function(self)
        showInfo(self, title, text)
    end)

    button:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    button:SetScript("OnClick", function(self)
        showInfo(self, title, text)
    end)

    return button
end

-- A simple scrolling area. Rows are created and destroyed on refresh.
local scrollOffsets = {}

-- The scroll area the page on screen is using, and the callback that redraws
-- the scrollbar. One page draws one scroll area, so a single bar serves every
-- page; clearContent clears the first, and the bar is defined with the window.
local activeScroll = nil
local scrollChanged = nil

-- True only while a page drawer is running. A scroll area made by a popup is a
-- page of its own and must never take the window's bar, so only the scroll a
-- page creates during its own draw claims it.
local inPageDraw = false

local function maxScrollOffset(scroll)
    if not scroll or type(scroll.GetContentExtent) ~= "function" then return 0 end
    local extent = scroll:GetContentExtent() or 0
    local view = scroll:GetHeight() or 0
    return math.max(0, extent - view + 8)
end

-- Moves a scroll area to an offset, clamped to what it actually holds. The
-- mouse wheel, the two arrows and the thumb all go through here, so they can
-- never disagree about where the end of the page is.
local function scrollToOffset(scroll, value)
    if not scroll then return end

    local offset = math.max(0, math.min(maxScrollOffset(scroll), tonumber(value) or 0))
    scroll.offset = offset
    if scroll.ltKey then scrollOffsets[scroll.ltKey] = offset end
    if scroll.content then scroll.content:SetPoint("TOPLEFT", 0, offset) end

    if scrollChanged then scrollChanged() end
end

local function MakeScroll(parent, key)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)

    -- A keyed scroll remembers its position, because every edit rebuilds the page.
    scroll.ltKey = key
    scroll.offset = (key and scrollOffsets[key]) or 0
    content:SetPoint("TOPLEFT", 0, scroll.offset)

    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        -- Offsets are positive and move the content up; scrollToOffset measures
        -- the range from the lowest child so the whole list can be reached.
        scrollToOffset(self, self.offset - (delta * 28))
    end)

    -- Height of everything placed inside the scroll child.
    function scroll:GetContentExtent()
        local top = content:GetTop()
        if not top then return 0 end

        local lowest = top
        local function consider(object)
            local bottom = object and object.GetBottom and object:GetBottom()
            if bottom and bottom < lowest then lowest = bottom end
        end

        for _, child in ipairs({ content:GetChildren() }) do consider(child) end
        for _, region in ipairs({ content:GetRegions() }) do consider(region) end

        -- One trailing row of air: a tall last line must be able to scroll
        -- clear of the clip edge instead of being cut through its glyphs.
        return top - lowest + 12
    end

    scroll.content = content

    -- The page being drawn owns the bar until clearContent takes it away.
    if inPageDraw then activeScroll = scroll end
    return scroll
end

------------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------------

local frame, contentFrame, titleText, pageButtons, contextText, rail, footerText, specToggle

-- Where the shell's body starts, measured down from the window's top edge and
-- set in ensureFrame once the title band has reported its height. The rail and
-- the page host both hang from this one number, so a taller client font moves
-- the whole body down instead of overlapping the band, and nothing is measured
-- twice.
local shellTopY = -60

-- The footer strip: one line at the bottom of the window, the same tone as the
-- title band. `pad` is the gap between it and the content above.
local FOOTER = { band = 22, pad = 8 }

-- The tab table belongs to the tabs that live inside a page now - the gear slots
-- and the ranks panel - which are still a horizontal row inside their page. The
-- window's own navigation is the rail below and shares none of this.
local TAB = {
    gap            = 2,
    margin         = 14,
    heightSelected = 25,   -- taller: the selected tab rises above the row
    heightIdle     = 21,
}

-- The rail down the left of the window: the window's navigation, one row per
-- page, in the order the pages were registered. A rail rather than a tab row
-- because the page count only grows - plugins add pages - and a horizontal row
-- runs out of width while a column runs out of height, which this window has to
-- spare. Every row is one size, so eight pages, twelve pages and a plugin's new
-- page all look like the same window; a page is never a squeezed tab.
local RAIL = {
    margin = 8,     -- between the window rim and the column
    width  = 128,   -- the column, hairline to hairline
    gutter = 10,    -- between the column and the page host
    gap    = 2,     -- between two rows
    pad    = 6,     -- between the column's top edge and the first row
    rowH   = 26,
    textAt = 11,    -- label inset from the row's left edge
    marker = 3,     -- width of the accent bar on the current page's row
}

-- The tabs that live inside a page - the Ranks views, the gear slots - are their
-- own widget, not a UIPanelButton: the selected one is drawn as part of the strip
-- (lighter fill, the window's hairline, three pixels taller) and the rest sit
-- lower and dimmer. The window's own navigation is the rail above, which shares
-- the drawing but none of this geometry.
--
-- SetSelected says plainly that a tab is the current view. SetEnabled(true) also
-- means selected here, keeping the call the old window tabs used, because the
-- inverted name was already in the pages.
local function styleTab(tab, selected)
    tab.ltSelected = (selected == true)

    local chrome = LT.Palette.chrome

    -- The edge key is kept on the tab so the hover path repaints the SAME edge
    -- instead of picking one of its own; that is what keeps a border from being
    -- painted off by a mouse pass (see UI.buttonTone).
    tab.ltEdgeKey = tab.ltSelected and "border" or "cardEdge"

    local label = tab.label
    if label then
        local colour = tab.ltSelected and LT.Palette:RGB("text") or LT.Palette:RGB("muted")
        label:SetTextColor(colour.r, colour.g, colour.b)
    end

    if tab.ltSelected then
        tab:SetHeight(TAB.heightSelected)
    else
        tab:SetHeight(TAB.heightIdle)
    end

    -- The selected tab sits in the same raised idiom as the page below it, so it
    -- reads as attached to what it opened rather than as a second slab.
    LT.Chrome.Card(tab, {
        edge = chrome[tab.ltEdgeKey],
        fill = chrome[tab.ltSelected and "buttonBg" or "fill"],
        bevelMode = "raised",
    })
end

local function MakePageTab(parent, text, onClick)
    local tab = CreateFrame("Button", nil, parent)
    tab:SetSize(80, TAB.heightIdle)

    tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tab.label:SetPoint("CENTER", 0, -1)
    tab.label:SetText(tostring(text))
    tab.label:SetJustifyH("CENTER")

    tab:SetScript("OnClick", function(self)
        if type(onClick) == "function" then onClick(self) end
    end)

    -- Hovering an unselected tab says what clicking it would do; the selected
    -- one has nowhere to go, so it keeps its own look. Only the face and the
    -- label move - the edge stays the key styleTab chose.
    tab:SetScript("OnEnter", function(self)
        if self.ltSelected then return end
        local chrome = LT.Palette.chrome
        local colour = LT.Palette:RGB("text")
        self.label:SetTextColor(colour.r, colour.g, colour.b)
        LT.Chrome.Card(self, {
            edge = chrome[self.ltEdgeKey or UI.buttonEdge],
            fill = chrome.buttonBg,
            bevelMode = "raised",
        })
    end)

    tab:SetScript("OnLeave", function(self)
        if self.ltSelected then return end
        local chrome = LT.Palette.chrome
        local colour = LT.Palette:RGB("muted")
        self.label:SetTextColor(colour.r, colour.g, colour.b)
        LT.Chrome.Card(self, {
            edge = chrome[self.ltEdgeKey or UI.buttonEdge],
            fill = chrome.fill,
            bevelMode = "raised",
        })
    end)

    tab.SetSelected = function(self, value) styleTab(self, value) end
    -- Kept so a page that asks with the old name still lands on the right look,
    -- but not inverted: true means selected, like SetSelected.
    tab.SetEnabled = function(self, value) styleTab(self, value == true) end

    styleTab(tab, false)
    return tab
end

-- One row of the rail. Drawn like every other control: an opaque fill, a
-- hairline, a left-aligned label and - on the page being looked at - a three
-- pixel accent bar against the row's left edge. That bar is the only mark in the
-- window that moves when the player navigates, which is what makes "you are
-- here" readable without reading the labels: one teal mark on screen means one
-- thing.
--
-- SetSelected is the call that means "this is the current page". There is no
-- SetEnabled: a navigation row is never disabled, and the old tab row's
-- "disabled means selected" inversion is exactly the sort of thing that reads as
-- a bug later.
local function styleRailItem(item, selected)
    item.ltSelected = (selected == true)

    local chrome = LT.Palette.chrome
    -- Same rule as the tab and the button: the edge key is chosen here and kept
    -- on the row, so a hover can only move the face and the label.
    item.ltEdgeKey = item.ltSelected and "border" or "cardEdge"

    LT.Chrome.Card(item, {
        edge = chrome[item.ltEdgeKey],
        fill = chrome[item.ltSelected and "buttonBg" or "fill"],
        bevelMode = "raised",
    })

    local tone = item.ltSelected and LT.Palette:RGB("text") or LT.Palette:RGB("muted")
    if item.label then item.label:SetTextColor(tone.r, tone.g, tone.b) end

    if item.marker then
        if item.ltSelected then item.marker:Show() else item.marker:Hide() end
    end
end

local function MakeRailItem(parent, text, onClick)
    local item = CreateFrame("Button", nil, parent)
    item:SetSize(RAIL.width, RAIL.rowH)

    -- The accent bar, inset three pixels top and bottom so it reads as a mark
    -- against the row rather than as the row's own edge.
    local accent = LT.Palette.chrome.accent
    local marker = item:CreateTexture(nil, "ARTWORK")
    marker:SetColorTexture(accent[1], accent[2], accent[3], 1)
    marker:SetPoint("TOPLEFT", item, "TOPLEFT", 0, -3)
    marker:SetPoint("BOTTOMLEFT", item, "BOTTOMLEFT", 0, 3)
    marker:SetWidth(RAIL.marker)
    marker:Hide()
    item.marker = marker

    local label = item:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", item, "LEFT", RAIL.textAt, 0)
    label:SetPoint("RIGHT", item, "RIGHT", -6, 0)
    label:SetJustifyH("LEFT")
    label:SetText(tostring(text))
    item.label = label

    item:SetScript("OnClick", function(self)
        if type(onClick) == "function" then onClick(self) end
    end)

    -- Hover lifts the label to body text and lightens the face. It never shows
    -- the accent bar (that belongs to the current page, not the cursor) and it
    -- never repaints the edge: the border a row was drawn with stays its border.
    item:SetScript("OnEnter", function(self)
        if self.ltSelected then return end
        local chrome = LT.Palette.chrome
        local tone = LT.Palette:RGB("text")
        self.label:SetTextColor(tone.r, tone.g, tone.b)
        LT.Chrome.Card(self, {
            edge = chrome[self.ltEdgeKey or UI.buttonEdge],
            fill = chrome.buttonBg,
            bevelMode = "raised",
        })
    end)
    item:SetScript("OnLeave", function(self)
        if self.ltSelected then return end
        local chrome = LT.Palette.chrome
        local tone = LT.Palette:RGB("muted")
        self.label:SetTextColor(tone.r, tone.g, tone.b)
        LT.Chrome.Card(self, {
            edge = chrome[self.ltEdgeKey or UI.buttonEdge],
            fill = chrome.fill,
            bevelMode = "raised",
        })
    end)

    item.SetSelected = function(self, value) styleRailItem(self, value) end

    styleRailItem(item, false)
    return item
end

-- The rail is navigation, not the registry: every page stays reachable through
-- its /lt command even while its row is hidden. Only one entry waits:
--   * Plugins has nothing to list until a plugin has registered.
-- Ranks is shown at every level by the player's 2026-11-05 decision; what waits
-- for level 10 is the talent advisor (/lbs), not the board.
--
-- One home for the gates, on the RAIL table that already holds the column's
-- geometry: the main chunk sits at the Lua 5.1 200-local ceiling, so fields
-- cost no extra local.

function RAIL.pluginsLoaded()
    local api = LT.PluginAPI
    if type(api) ~= "table" or type(api.plugins) ~= "table" then return false end

    for _ in pairs(api.plugins) do return true end
    return false
end

function RAIL.pageOnRail(page)
    if type(page) ~= "table" or page.hidden then return false end
    -- Ranks is visible from level 1 by the player's decision (2026-11-05): it is
    -- a new release and the leaderboard is part of the first impression, not a
    -- reward for levelling. Only Plugins waits, because it has nothing to list
    -- until a plugin registers.
    if page.key == "plugins" then return RAIL.pluginsLoaded() end
    return true
end

function RAIL.firstPageKey()
    for _, page in ipairs(PAGES) do
        if RAIL.pageOnRail(page) then return page.key end
    end

    return nil
end

-- One row per visible page, top to bottom, in registration order. Existing rows
-- are relabelled and repositioned rather than recreated, so a layout pass never
-- leaks a frame and a page added at run time only ever appends a row. A page
-- whose row is no longer offered is hidden in place, which is what lets level
-- and plugin changes re-evaluate without ever dropping a page from the registry.
local function layoutRail()
    if not rail or not pageButtons then return end

    local y = RAIL.pad

    for _, page in ipairs(PAGES) do
        if RAIL.pageOnRail(page) then
            local item = pageButtons[page.key]

            if not item then
                item = MakeRailItem(rail, page.label, function()
                    UI:ShowPage(page.key)
                end)
                pageButtons[page.key] = item
            end

            if item.label then item.label:SetText(tostring(page.label)) end

            item:ClearAllPoints()
            item:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -y)
            item:SetPoint("TOPRIGHT", rail, "TOPRIGHT", 0, -y)
            item:SetHeight(RAIL.rowH)
            item:Show()
            y = y + RAIL.rowH + RAIL.gap
        else
            local item = pageButtons[page.key]
            if item then item:Hide() end
        end
    end
end

------------------------------------------------------------------------------
-- The page scrollbar
--
-- A thin track in the window's right margin, with an arrow at each end, drawn
-- only while the page on screen is taller than the space it is given. It is one
-- frame for the whole window rather than one per page: every page draws into its
-- own scroll area, but only one of them is on screen at a time.
--
-- It sits outside the content frame, in the fourteen pixels the window keeps
-- free on its right, so making room for it never narrows a page and never moves
-- a control. The wheel over the page and the two arrows both go through
-- scrollToOffset, so they share one idea of where the end is.
------------------------------------------------------------------------------

local SCROLLBAR = { width = 10, arrow = 11 }

local scrollBar = nil

local function scrollArrow(parent, glyph, delta)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(SCROLLBAR.width, SCROLLBAR.arrow)

    LT.Chrome.Card(button, {
        edge = LT.Palette.chrome[UI.buttonEdge],
        fill = LT.Palette.chrome.buttonBg,
        bevelMode = "raised",
    })

    local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", 0, 0)
    label:SetText(glyph)
    local brand = LT.Palette:RGB("brand")
    label:SetTextColor(brand.r, brand.g, brand.b)
    button.label = label

    button:SetScript("OnClick", function()
        if activeScroll then
            scrollToOffset(activeScroll, activeScroll.offset + delta)
        end
    end)

    -- The arrows are the smallest controls in the window, so they move the least:
    -- the face lightens and the glyph comes up to body text, and the edge stays
    -- the one they were drawn with.
    button:SetScript("OnEnter", function(self)
        local chrome = LT.Palette.chrome
        local hover = LT.Palette:RGB("text")
        self.label:SetTextColor(hover.r, hover.g, hover.b)
        LT.Chrome.Card(self, {
            edge = chrome[UI.buttonEdge],
            fill = chrome.buttonHot,
            bevelMode = "raised",
        })
    end)
    button:SetScript("OnLeave", function(self)
        local chrome = LT.Palette.chrome
        self.label:SetTextColor(brand.r, brand.g, brand.b)
        LT.Chrome.Card(self, {
            edge = chrome[UI.buttonEdge],
            fill = chrome.buttonBg,
            bevelMode = "raised",
        })
    end)

    return button
end

local function buildScrollBar()
    if scrollBar or not frame then return end

    local bar = CreateFrame("Frame", nil, frame)
    bar:SetWidth(SCROLLBAR.width)
    bar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, shellTopY)
    bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4,
        3 + FOOTER.band + FOOTER.pad)

    LT.Chrome.Card(bar, {
        edge = LT.Palette.chrome.cardEdge,
        fill = LT.Palette.chrome.fill,
    })

    bar.up = scrollArrow(bar, "^", -24)
    bar.up:SetPoint("TOP", bar, "TOP", 0, 0)

    bar.down = scrollArrow(bar, "v", 24)
    bar.down:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)

    -- The thumb is a region, not a control: dragging is not offered, because a
    -- click that grabs nothing is worse than one that is not there.
    bar.thumb = CreateFrame("Frame", nil, bar)
    bar.thumb:SetWidth(SCROLLBAR.width - 2)
    LT.Chrome.Card(bar.thumb, {
        edge = LT.Palette.chrome.border,
        fill = LT.Palette.chrome.buttonHot,
    })

    bar:Hide()
    scrollBar = bar
end

local function refreshScrollBar()
    local bar = scrollBar
    if not bar then return end

    local scroll = activeScroll
    if not scroll or not frame or not frame:IsShown() then
        bar:Hide()
        return
    end

    local extent = scroll:GetContentExtent() or 0
    local view = scroll:GetHeight() or 0

    -- Two pixels of slack: a page that fits must not grow a bar for rounding.
    if view <= 0 or extent <= view + 2 then
        bar:Hide()

        -- A page that fits starts at the top, whatever an earlier visit left
        -- behind: a remembered offset from a longer list would otherwise leave
        -- its first rows above the visible area with no bar to bring them back.
        if (scroll.offset or 0) ~= 0 then
            scroll.offset = 0
            if scroll.ltKey then scrollOffsets[scroll.ltKey] = 0 end
            if scroll.content then scroll.content:SetPoint("TOPLEFT", 0, 0) end
        end

        return
    end

    bar:Show()

    local trackHeight = bar:GetHeight() or 0
    local travel = trackHeight - (SCROLLBAR.arrow * 2)
    if travel < 1 then travel = 1 end

    local maxOffset = maxScrollOffset(scroll)
    local ratio = 0
    if maxOffset > 0 then ratio = (scroll.offset or 0) / maxOffset end
    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end

    local thumbHeight = travel * (view / extent)
    if thumbHeight < 12 then thumbHeight = 12 end
    if thumbHeight > travel then thumbHeight = travel end

    bar.thumb:SetSize(SCROLLBAR.width - 2, thumbHeight)
    bar.thumb:ClearAllPoints()
    bar.thumb:SetPoint("TOPLEFT", bar, "TOPLEFT", 1,
        -(SCROLLBAR.arrow + (ratio * (travel - thumbHeight))))
end

scrollChanged = refreshScrollBar

------------------------------------------------------------------------------
-- Remembered place and page
--
-- Both live in the character record, so they survive /reload with the rest of
-- the character's data. The place is stored as a fraction of the UI area rather
-- than a pixel offset: after a resolution or UI-scale change the same fraction
-- lands in the same relative spot, and the clamp below still keeps the window
-- fully reachable if the fraction was stored on a much larger screen.
------------------------------------------------------------------------------

local function windowRecord()
    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return nil end

    if type(character.window) ~= "table" then
        character.window = {}
    end

    return character.window
end

local function pageExists(key)
    if type(key) ~= "string" or key == "" then return false end

    for _, page in ipairs(PAGES) do
        if page.key == key then return true end
    end

    return externalDrawers[key] ~= nil
end

function RAIL.pageAllowed(key)
    for _, page in ipairs(PAGES) do
        if page.key == key then return RAIL.pageOnRail(page) end
    end

    return externalDrawers[key] ~= nil
end

-- A saved or current page whose rail row is no longer offered falls back to the
-- first row that is still there. This is only called where the rail is being
-- re-evaluated (window open, login, level-up, plugin change), never by
-- ShowPage, so a /lt command can still reach a page the rail is hiding. It
-- changes the selection only; the caller owns the redraw.
function RAIL.revalidatePage()
    if RAIL.pageAllowed(currentPage) then return false end

    local fallback = RAIL.firstPageKey()
    if not fallback or fallback == currentPage then return false end

    currentPage = fallback
    local record = windowRecord()
    if record then record.page = fallback end
    return true
end

-- Clamp a top-left offset into the UI area. A window wider or taller than the UI
-- is centred rather than pinned to a corner where it could not be dragged back.
-- Shared by the main window and the Weights window so both land the same way.
local function clampTopLeft(x, y, width, height, uiWidth, uiHeight)
    -- A scaled caller passes the UI area already converted into the frame's
    -- own units; the Weights window has no scale of its own and passes nil.
    uiWidth = uiWidth or UIParent:GetWidth() or 0
    uiHeight = uiHeight or UIParent:GetHeight() or 0

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

    return x, y
end

------------------------------------------------------------------------------
-- Popup frames
--
-- One small window per question, created on its first open and only outside
-- combat. Each remembers where the player dragged it, as the same fraction of
-- the UI area the main window stores, so a resolution or UI-scale change lands
-- it in the same relative spot and the clamp below keeps it reachable.
------------------------------------------------------------------------------

local function popupRecord(key)
    local record = windowRecord()
    if not record then return nil end
    if type(record[key]) ~= "table" then record[key] = {} end
    return record[key]
end

-- Places a popup at its remembered fraction, centred the first time, then
-- clamped into the UI area. `width`/`height` are the design sizes used before
-- the frame has been sized.
local function placePopupFrame(target, key, width, height)
    if not target then return end

    local uiWidth = UIParent:GetWidth() or 0
    local uiHeight = UIParent:GetHeight() or 0
    local actualWidth = target:GetWidth() or width or 0
    local actualHeight = target:GetHeight() or height or 0
    local record = popupRecord(key)
    local x, y

    if record and type(record.x) == "number" and type(record.y) == "number" then
        x = record.x * uiWidth
        y = record.y * uiHeight
    else
        x = (uiWidth - actualWidth) / 2
        y = (uiHeight - actualHeight) / 2
    end

    x, y = clampTopLeft(x, y, actualWidth, actualHeight)

    target:ClearAllPoints()
    target:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, -y)
end

local function savePopupPlacement(target, key)
    if not target then return end

    local record = popupRecord(key)
    if not record then return end

    local uiWidth = UIParent:GetWidth() or 0
    local uiHeight = UIParent:GetHeight() or 0
    if uiWidth <= 0 or uiHeight <= 0 then return end

    local scale = target:GetEffectiveScale() or 1
    local left, top = target:GetLeft(), target:GetTop()
    local uiLeft, uiTop = UIParent:GetLeft(), UIParent:GetTop()
    if not left or not top or not uiLeft or not uiTop then return end

    record.x = ((left - uiLeft) / scale) / uiWidth
    record.y = ((uiTop - top) / scale) / uiHeight
end

-- Creates a popup with the main window's own chrome: same backdrop, same drag
-- behaviour, same remembered place and the same Escape list. Returns nil in
-- combat, because creating the frame is the operation the client refuses.
-- A named frame is the only thing UISpecialFrames accepts, so every popup here
-- carries one and is closed by Escape like the main window.
local function MakePopupFrame(name, width, height, recordKey, onHide)
    if combatLocked() then return nil end

    local ok, created = pcall(CreateFrame, "Frame", name, UIParent)
    if not ok or not created then return nil end

    local window = created
    window:SetSize(width, height)
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    if window.SetFrameStrata then window:SetFrameStrata("DIALOG") end
    pcall(window.RegisterForDrag, window, "LeftButton")
    window:SetScript("OnDragStart", function(self) self:StartMoving() end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        savePopupPlacement(self, recordKey)
    end)

    -- The main window's own chrome, not a second look: the same opaque slab and
    -- hairline rim every window draws, so one call covers this popup and every
    -- popup built through this function.
    windowChrome(window)

    if type(UISpecialFrames) == "table" then
        pcall(table.insert, UISpecialFrames, name)
    end

    if onHide then window:HookScript("OnHide", onHide) end

    window:Hide()
    return window
end

-- Window scale. The list is the one the Settings row cycles through; a saved
-- value that is not on the list falls back to 100%, so a hand-edited record
-- cannot leave the window unreadably small or large. The value lives in the
-- same character record as the place, so /reload and a resolution change keep
-- it.
local WINDOW_SCALES = { 0.8, 0.9, 1.0, 1.1, 1.25 }

local function windowScale()
    local record = windowRecord()
    local saved = record and tonumber(record.scale)

    if saved then
        for _, candidate in ipairs(WINDOW_SCALES) do
            if math.abs(candidate - saved) < 0.001 then return candidate end
        end
    end

    return WINDOW_SCALES[3]
end

-- Where the top-left corner sits, as a fraction of the UI area measured from
-- the top-left corner of UIParent. A frame's SetPoint offsets are in its own
-- scaled units, so the fraction is converted into frame units before the
-- clamp: the UI area shrinks by the window scale and the rendered size of the
-- window is its own width times that scale. Without this, a 125% window near
-- an edge would run off it while the numbers still looked "clamped".
local function applyWindowPlacement()
    if not frame then return end

    local scale = windowScale()
    local uiWidth = (UIParent:GetWidth() or 0) / scale
    local uiHeight = (UIParent:GetHeight() or 0) / scale
    local width = frame:GetWidth() or 800
    local height = frame:GetHeight() or 560

    if frame.SetScale then frame:SetScale(scale) end

    local record = windowRecord()
    local x, y

    if record and type(record.x) == "number" and type(record.y) == "number" then
        x = record.x * uiWidth
        y = record.y * uiHeight
    else
        x = (uiWidth - width) / 2
        y = (uiHeight - height) / 2
    end

    x, y = clampTopLeft(x, y, width, height, uiWidth, uiHeight)

    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", x, -y)
end

-- Cycles the main window through WINDOW_SCALES. The scale is written into the
-- character record, then placement is re-applied, so the clamp accounts for the
-- new rendered size before the player sees it.
function UI:SetScale(value)
    local chosen = tonumber(value) or WINDOW_SCALES[3]
    local matched = false

    for _, candidate in ipairs(WINDOW_SCALES) do
        if math.abs(candidate - chosen) < 0.001 then
            chosen = candidate
            matched = true
            break
        end
    end

    if not matched then chosen = WINDOW_SCALES[3] end

    local record = windowRecord()
    if record then
        record.scale = chosen
    end

    applyWindowPlacement()

    if LT.Database and type(LT.Database.Save) == "function" then
        pcall(LT.Database.Save, LT.Database, "window:scale")
    end

    UI:Refresh()
    return chosen
end

function UI:GetScale()
    return windowScale()
end

-- The Settings row uses these so the label and the actual next value cannot
-- disagree about the list.
function UI:ScaleValues()
    return WINDOW_SCALES
end

function UI:NextScale(value)
    local current = tonumber(value) or windowScale()

    for index, candidate in ipairs(WINDOW_SCALES) do
        if math.abs(candidate - current) < 0.001 then
            return WINDOW_SCALES[(index % #WINDOW_SCALES) + 1]
        end
    end

    return WINDOW_SCALES[3]
end

-- Opening the Ranks page is one of the two moments the leaderboard is allowed
-- to share a row. The UI never sends the packet itself: it tells the module the
-- page is open, and the module applies its own opt-in and once-a-minute rule.
local function notifyRanksOpened()
    if currentPage ~= "ranks" then return end

    local module = LT.Leaderboard
    if type(module) == "table" and type(module.PageOpened) == "function" then
        pcall(module.PageOpened, module)
    end
end

------------------------------------------------------------------------------
-- Ranks redraw requests
--
-- A row arriving fires RANKS_CHANGED once per packet, and a busy channel sends
-- them in bursts. Only the Ranks page draws that data, and one rebuild per
-- frame is all it needs, so a packet raises a flag and the window's OnUpdate
-- clears it. The script is removed as soon as the redraw has run, so a window
-- with nothing waiting does not tick.
------------------------------------------------------------------------------

local ranksRefreshPending = false
local ranksRefreshArmed = false

local function clearRanksRefresh()
    ranksRefreshPending = false
    if ranksRefreshArmed and frame and frame.SetScript then
        pcall(frame.SetScript, frame, "OnUpdate", nil)
    end
    ranksRefreshArmed = false
end

local function flushRanksRefresh()
    local queued = ranksRefreshPending
    clearRanksRefresh()
    if queued then UI:Refresh() end
end

local function queueRanksRefresh()
    if currentPage ~= "ranks" then return end
    if not frame or not frame:IsShown() then return end

    ranksRefreshPending = true
    if ranksRefreshArmed then return end

    local ok = pcall(frame.SetScript, frame, "OnUpdate", flushRanksRefresh)
    ranksRefreshArmed = ok
    if not ok then clearRanksRefresh(); UI:Refresh() end
end

-- A Ranks page first opened during a fight has no widgets at all: the client
-- refuses to create them there, and drawing the page leaves it empty rather
-- than half built. Watching for the fight's end is what fills it in, because
-- nothing else would redraw a page the player has already opened.
local regenWatched = false

local function watchRegen()
    if regenWatched or not frame then return end

    local ok = pcall(frame.RegisterEvent, frame, "PLAYER_REGEN_ENABLED")
    regenWatched = ok
end

-- Called on drag release. GetLeft/GetTop are screen pixels; the effective
-- scale turns that distance back into the units SetPoint takes. Nothing is
-- fired from here: the fields are written into the live record, which is what
-- the client saves on logout and on /reload.
local function saveWindowPlacement()
    if not frame then return end

    local record = windowRecord()
    if not record then return end

    local uiWidth = UIParent:GetWidth() or 0
    local uiHeight = UIParent:GetHeight() or 0
    if uiWidth <= 0 or uiHeight <= 0 then return end

    -- The fraction is measured in UIParent's units. Dividing by the frame's
    -- own effective scale would subtract the window scale as well and store a
    -- different place at 125% than at 100%.
    local scale = UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or nil
    local left, top = frame:GetLeft(), frame:GetTop()
    local uiLeft, uiTop = UIParent:GetLeft(), UIParent:GetTop()

    if type(scale) ~= "number" or scale <= 0 then
        local effective = frame:GetEffectiveScale() or 1
        scale = effective / windowScale()
    end

    if not left or not top or not uiLeft or not uiTop then return end

    record.x = ((left - uiLeft) / scale) / uiWidth
    record.y = ((uiTop - top) / scale) / uiHeight
    record.page = currentPage
end

-- The vocabulary a build slot stores its context in is ClassData's ("PVE" is
-- read as "PvE"), so the band and the wizard cannot spell the same answer two
-- ways. A core that exports no such list falls back to the stored key.
local function contextWord(key)
    if type(key) ~= "string" or key == "" then return nil end
    if type(LT.Contexts) == "table" then
        for _, entry in ipairs(LT.Contexts) do
            if type(entry) == "table" and entry.key == key then
                return entry.label or entry.key
            end
        end
    end
    return key
end

-- One line, read at draw time from the profile the active slot resolves to, the
-- build's own name and the level the scores are calculated at, so pointing a
-- slot at another profile, switching build or dinging updates it.
--
-- Profile first, by the player's choice on 2026-10-31: it is what every score on
-- every page is made from. The "Slot N" prefix is gone with it, and so is the
-- flat "level N" tail whenever the context word can be said instead. The word is
-- dropped again when the profile or the build's name already carries it — the old
-- line printed "PVE" twice, spelled two ways ("Slot 2 ·
-- Enhancement DW - PVE · level 60" beside a second profile line).
local function describeContext()
    local index = (LT.Builds and LT.Builds:GetActiveIndex()) or 1
    local build = LT.Builds and LT.Builds:GetActive()
    local level = (LT.Levels and LT.Levels:GetScoringLevel())
        or (LT.player and tonumber(LT.player.level)) or 1

    local parts = {}
    local profileName

    if LT.Profiles and type(LT.Profiles.ResolveSlot) == "function" then
        local resolved = LT.Profiles:ResolveSlot(index)
        local profile = type(resolved) == "table" and resolved or nil
        profileName = profile and (profile.name
            or (type(profile.profile) == "table" and profile.profile.name))
        if profileName then table.insert(parts, tostring(profileName)) end
    end

    local name = build and build.name
    if name then
        -- A build named after the profile it uses — T-79 makes that the default —
        -- would otherwise print the same name twice in one line.
        if tostring(profileName or ""):lower() ~= tostring(name):lower() then
            table.insert(parts, tostring(name))
        end
    else
        table.insert(parts, "Build " .. tostring(index))
    end

    local context = build and build.context
    local word = contextWord(context)

    -- The word is dropped when the line already carries it, whichever half says
    -- it: a build named "… - PVE" and a profile named "… PVP" both do, and the
    -- player's complaint was the same word printed twice in two spellings.
    local repeats = false
    if word and type(context) == "string" then
        for _, text in ipairs(parts) do
            if tostring(text):upper():find(context:upper(), 1, true) then
                repeats = true
                break
            end
        end
    end

    if word and not repeats then
        table.insert(parts, word .. " " .. tostring(level))
    else
        table.insert(parts, "level " .. tostring(level))
    end

    return table.concat(parts, " · ")
end

-- One short name for the spec toggle: the resolved profile name when the slot
-- has one (the same token the header context line shows), else the build's own
-- name, else the spec and role. Falls back to "Build N" so a slot the wizard
-- never filled still has something to show.
local function activeBuildShortLabel()
    local index = (LT.Builds and LT.Builds:GetActiveIndex()) or 1
    local build = LT.Builds and LT.Builds:GetActive()

    if LT.Profiles and type(LT.Profiles.ResolveSlot) == "function" then
        local ok, resolved = pcall(LT.Profiles.ResolveSlot, LT.Profiles, index)
        if ok and type(resolved) == "table" and type(resolved.name) == "string"
            and resolved.name ~= "" then
            return resolved.name
        end
    end

    local name = build and build.name
    if type(name) == "string" and name ~= "" and name ~= ("Build " .. tostring(index)) then
        return name
    end

    local spec = build and build.spec
    local role = build and build.role
    if type(spec) == "string" and spec ~= "" and spec ~= "Any" then
        if type(role) == "string" and role ~= "" and role ~= "Damage" then
            return spec .. " " .. role
        end
        return spec
    end

    return "Build " .. tostring(index)
end

-- The popups are built further down. They are declared here so the main
-- frame's OnHide handler can ask whether one is up: that handler is what keeps
-- one Escape from closing both the popup and the window behind it.
local weightsPopup
local sharePopup
local recordsPopup
local profilePicker
-- The popups this ticket adds — the delete confirmation, the plugin command
-- list and the debug log. Each is built through MakePopupFrame at its first
-- open, never in combat, and takes part in the same one-Escape rule as the four
-- above. The debug log is a popup rather than a page: it is the one thing here a
-- player mostly does not need.
local deletePopup
local commandsPopup
local debugPopup

local function ensureFrame()
    if frame then return frame end

    frame = CreateFrame("Frame", "LunchboxToolkitFrame", UIParent)
    frame:SetSize(800, 560)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    applyWindowPlacement()
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        saveWindowPlacement()
    end)

    -- One unbroken hairline rim, with a near-black line a pixel inside it, over
    -- an opaque slab: the window the player asked for, drawn by the module every
    -- window shares. Textures, not a backdrop: no template and no texture file.
    windowChrome(frame)

    -- The title band: one strip across the top of the slab carrying the addon's
    -- mark, its name, the context line and the close cross. It is a card inside
    -- the window, so the only heavy edge on screen stays the window's own rim.
    local band = CreateFrame("Frame", nil, frame)
    band:SetPoint("TOPLEFT", 3, -3)
    band:SetPoint("TOPRIGHT", -3, -3)
    band:SetHeight(38)
    LT.Chrome.Card(band, {
        edge = LT.Palette.chrome.cardEdge,
        fill = LT.Palette.chrome.headerBg,
    })

    -- The add-on's mark: the player's own icon, in the corner the quest log puts
    -- its own. The art is a TGA in Media\ (this client cannot load the PNG it
    -- came from) and the TOC declares the same path as IconTexture, so the
    -- add-on list and this header show one piece of art. The frame keeps the
    -- size and the position it always had, so nothing around it re-flows; the
    -- texture is inset past the rim and the bevel so neither clips the art.
    local mark = CreateFrame("Frame", nil, band)
    mark:SetSize(28, 28)
    mark:SetPoint("TOPLEFT", 7, -5)
    LT.Chrome.Card(mark, {
        edge = LT.Palette.chrome.border,
        fill = LT.Palette.chrome.headerBg,
        bevelMode = "raised",
    })

    local logo
    if type(mark.CreateTexture) == "function" then
        local ok, texture = pcall(mark.CreateTexture, mark, nil, "ARTWORK")
        if ok and texture then logo = texture end
    end

    if logo then
        logo:SetPoint("TOPLEFT", mark, "TOPLEFT", 2, -2)
        logo:SetPoint("BOTTOMRIGHT", mark, "BOTTOMRIGHT", -2, 2)
        pcall(logo.SetTexture, logo,
            "Interface\\AddOns\\LunchboxToolkit\\Media\\Inv_treasurechest_felfirecitadel_64")

        -- A client that refuses this texture must never leave a hole: the
        -- client's own question mark is the second choice and the drawn initials
        -- below are the third. What the API can see is worth stating plainly:
        -- GetTexture answers with the path it was handed, not with whether the
        -- file exists on disk, so a missing file cannot be detected from here.
        -- The TOC's IconTexture line and the shipped Media\ file are what make
        -- the art present; this only guards a client that refuses the call.
        local loaded = true
        if type(logo.GetTexture) == "function" then
            local okGet, texture = pcall(logo.GetTexture, logo)
            loaded = (okGet and texture ~= nil)
        end
        if not loaded then
            pcall(logo.SetTexture, logo, "Interface\\Icons\\INV_Misc_QuestionMark")
        end
        mark.logo = logo
    end

    -- Last fallback: the drawn mark this header wore before the player supplied
    -- art. Hidden whenever the texture exists.
    local initials = mark:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    initials:SetPoint("CENTER", 0, 0)
    initials:SetText("LB")
    local accent = LT.Palette:RGB("accent")
    initials:SetTextColor(accent.r, accent.g, accent.b)
    if logo then initials:Hide() end

    -- The name, in body text, at the left where the quest log puts "Quest Log".
    -- It used to take the rim colour, which in this palette is a slate two steps
    -- away from the band behind it: a title nobody can read is not a title.
    titleText = MakeLabel(band, "Lunchbox Toolkit", "GameFontNormal")
    titleText:SetPoint("TOPLEFT", mark, "TOPRIGHT", 7, -3)
    local heading = LT.Palette:RGB("text")
    titleText:SetTextColor(heading.r, heading.g, heading.b)

    -- What the window is currently acting on: the profile the active slot scores
    -- with, the build's own name and the level. One line, always present, so the
    -- player does not have to go to Profiles or Builds to find out what a page is
    -- talking about.
    contextText = MakeLabel(band, describeContext(), "GameFontNormalSmall",
        LT.Palette:RGB("muted"))
    contextText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -2)
    if contextText.SetWordWrap then
        pcall(contextText.SetWordWrap, contextText, false)
    end

    -- Measured after both font strings exist: the band is as tall as the mark or
    -- the two text lines, whichever needs more, so a taller client font makes a
    -- taller band instead of stacking the title on the context line.
    local titleHeight = titleText:GetStringHeight()
    if not titleHeight or titleHeight < 1 then titleHeight = 16 end

    local contextHeight = contextText:GetStringHeight()
    if not contextHeight or contextHeight < 1 then contextHeight = 12 end

    local textHeight = 3 + titleHeight + 2 + contextHeight + 4
    local bandHeight = math.max(28 + 10, textHeight)
    band:SetHeight(bandHeight)

    -- Where the body starts: the rim above the band, the band, and the gap under
    -- it. The rail and the page host both hang from this one number, so a taller
    -- client font moves the whole body down instead of overlapping the band.
    shellTopY = -(3 + bandHeight + 10)

    -- The rail: the navigation column, down the left under the band. It is the
    -- darkest plane in the window, so the pages beside it read as the content and
    -- the rail reads as furniture. One hairline down its right edge is all that
    -- separates the two; it does not need a second frame to be a column.
    rail = CreateFrame("Frame", nil, frame)
    rail:SetWidth(RAIL.width)
    rail:SetPoint("TOPLEFT", frame, "TOPLEFT", RAIL.margin, shellTopY)
    rail:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", RAIL.margin,
        3 + FOOTER.band + FOOTER.pad)
    LT.Chrome.Card(rail, {
        edge = LT.Palette.chrome.cardEdge,
        fill = LT.Palette.chrome.railBg,
    })

    -- The close control, in the game's own close-corner: one neutral cross, the
    -- same control the Testing tools panel already wears. Red is a verdict in
    -- this add-on - "no answer about this item" - so it is not worn by anything
    -- that closes a window; the glyph is `muted` at rest and `text` under the
    -- cursor, and neither the face nor the edge moves at all.
    local closeButton = CreateFrame("Button", nil, band)
    closeButton:SetSize(22, 22)
    closeButton:SetPoint("TOPRIGHT", -6, -6)
    LT.Chrome.Card(closeButton, {
        edge = LT.Palette.chrome[UI.buttonEdge],
        fill = LT.Palette.chrome.buttonBg,
        bevelMode = "raised",
    })

    local cross = closeButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    cross:SetPoint("CENTER", 0, 0)
    cross:SetText("X")
    local restGlyph = LT.Palette:RGB("muted")
    cross:SetTextColor(restGlyph.r, restGlyph.g, restGlyph.b)
    closeButton:SetScript("OnClick", function() UI:Hide() end)
    closeButton:SetScript("OnEnter", function()
        local lit = LT.Palette:RGB("text")
        cross:SetTextColor(lit.r, lit.g, lit.b)
    end)
    closeButton:SetScript("OnLeave", function()
        cross:SetTextColor(restGlyph.r, restGlyph.g, restGlyph.b)
    end)

    -- The legend sits in the header, not on one page: the colours it explains are
    -- drawn by every page (tooltips, rewards, caps, checks), so the explanation
    -- belongs beside the rail that reaches them all. Legend.lua loads after this
    -- file, so the handler looks Legend up when it is clicked, not now.
    local colours = MakeButton(band, "Colours", 70, 20, function()
        if LT.Legend then LT.Legend:Toggle() end
    end)
    colours:SetPoint("TOPRIGHT", -32, -6)

    -- Re-runs the scan and shows the list. Nothing is built here: the gear
    -- check window builds itself on the first open, and refuses to open in
    -- combat for the same reason a scan refuses there.
    local gearCheck = MakeButton(band, "Gear check", 84, 20, function()
        local popup = LT.GearPopup
        if type(popup) ~= "table" or type(popup.Open) ~= "function" then
            LT:Error("The gear check module is not loaded.")
            return
        end

        local shown, reason = popup:Open()
        if reason then LT:Print(reason) end
    end)
    gearCheck:SetPoint("TOPRIGHT", -108, -6)

    -- Opens the skin picker. Skins.lua loads after this file, so the handler
    -- looks Skins up when clicked, not now.
    local skinButton = MakeButton(band, "Skin", 52, 20, function()
        if LT.Skins and type(LT.Skins.OpenPicker) == "function" then
            LT.Skins:OpenPicker()
        else
            LT:Error("The skin module is not loaded.")
        end
    end)
    skinButton:SetPoint("TOPRIGHT", -198, -6)

    -- The quick spec switch: flips the active build slot and re-ranks the bags,
    -- so the upgrade arrow follows whichever spec is being played right now.
    specToggle = MakeButton(band, "Spec: " .. activeBuildShortLabel(), 150, 20, function()
        local builds = LT.Builds
        if type(builds) ~= "table" or type(builds.GetActiveIndex) ~= "function"
            or type(builds.SetActive) ~= "function" then
            return
        end

        local current = builds:GetActiveIndex()
        local next = (current % builds.SLOT_COUNT) + 1
        builds:SetActive(next)

        -- The bag upgrade arrow was gathered for the previous spec; drop it so
        -- the next bag opening rescans against the newly active build.
        if LT.DropHint and type(LT.DropHint.InvalidateUpgrades) == "function" then
            pcall(LT.DropHint.InvalidateUpgrades, LT.DropHint)
        end
    end)
    specToggle:SetPoint("TOPRIGHT", -354, -6)

    -- The toggle's label is a profile name ("Lunchbox 2H WF PvP"), not a fixed
    -- word, so its width is measured instead of guessed: the player reported the
    -- text spilling off both sides of a 150 px button.
    local function fitSpecToggle()
        if not specToggle or type(specToggle.GetFontString) ~= "function" then return end
        local label = specToggle:GetFontString()
        local width = 150
        if label and type(label.GetStringWidth) == "function" then
            local ok, measured = pcall(label.GetStringWidth, label)
            if ok and type(measured) == "number" and measured > 0 then
                width = math.min(260, math.max(120, math.floor(measured + 28)))
            end
        end
        specToggle:SetWidth(width)
    end
    specToggle.fit = fitSpecToggle
    fitSpecToggle()

    -- The page host: everything right of the rail and above the footer. A page
    -- is written against this box alone, so a change to the chrome cannot move a
    -- control inside a page.
    contentFrame = CreateFrame("Frame", nil, frame)
    contentFrame.lunchboxLabelPool = {}
    contentFrame:SetPoint("TOPLEFT", rail, "TOPRIGHT", RAIL.gutter, 0)
    contentFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14,
        3 + FOOTER.band + FOOTER.pad)

    -- The footer strip: the title band's tone again, one static line. How to
    -- drive the window is said once here instead of costing every page a line of
    -- instructions, and nothing on it changes with the page, so it cannot go
    -- stale.
    local footer = CreateFrame("Frame", nil, frame)
    footer:SetHeight(FOOTER.band)
    footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 3, 3)
    footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)
    LT.Chrome.Card(footer, {
        edge = LT.Palette.chrome.cardEdge,
        fill = LT.Palette.chrome.headerBg,
    })

    footerText = MakeLabel(footer, "Drag to move  |  Esc closes  |  hover a ? for what it does",
        "GameFontNormalSmall", LT.Palette:RGB("muted"))
    footerText:SetPoint("LEFT", 10, 0)

    -- The page the window was closed on. Checked against the live page list so
    -- a saved key from an uninstalled local addon falls back to Builds. Debug is
    -- a popup now, so a window closed on that page reopens on Settings with the
    -- log up, and the saved key is rewritten for the next open.
    local record = windowRecord()
    if record then
        if record.page == "debug" then
            currentPage = "settings"
            record.page = "settings"
            if debugPopup and not combatLocked() then debugPopup:Open() end
        elseif pageExists(record.page) then
            currentPage = record.page
        else
            record.page = "builds"
        end
    end

    pageButtons = {}
    layoutRail()
    -- A page saved from a character that has since dropped below the Ranks
    -- gate, or that has no plugins, falls back instead of reopening on a page
    -- the rail no longer offers.
    RAIL.revalidatePage()
    buildScrollBar()

    -- One pass for every gate that can change while the window exists: the
    -- level (Ranks) and the registered plugin list (Plugins). The rail is
    -- re-stacked, the current page is checked against it, and a shown window
    -- redraws with the new navigation.
    local function refreshRailGating()
        if not pageButtons then return end
        layoutRail()
        RAIL.revalidatePage()
        UI:Refresh()
    end

    pcall(function()
        table.insert(UISpecialFrames, "LunchboxToolkitFrame")
    end)

    -- Escape closes the shown frames named in UISpecialFrames and the list
    -- order is not a contract, so the window cannot rely on being looked at
    -- last. Instead it stays in the list and repairs the case that matters:
    -- when this window hides while the Weights window is up, it shows itself
    -- again and closes the Weights window. Escape then closes only the popup,
    -- and a second Escape (popup already gone) closes this window. The flag
    -- stops the repair from being repaired if the client hides the frame twice.
    local escapeRepair = false
    frame:HookScript("OnHide", function()
        if escapeRepair then return end

        -- Whichever popup is up, it is the window Escape meant to close: the
        -- main window shows itself again and closes only that popup. A second
        -- Escape then closes the window. The new popups take part in the same
        -- repair as the Weights window, so one Escape never takes both.
        local open = nil
        for _, candidate in ipairs({ weightsPopup, sharePopup, recordsPopup, profilePicker,
            deletePopup, commandsPopup, debugPopup }) do
            if candidate and candidate.IsShown and candidate:IsShown() then
                open = candidate
                break
            end
        end

        -- The two hosted popups (Caps, Slash commands) are created lazily from
        -- the Actions page, so they cannot be in the fixed list above. Without
        -- this, Escape closed the whole window while their popup was up.
        if not open and type(UI.hostedPopups) == "table" then
            for _, record in pairs(UI.hostedPopups) do
                local window = type(record) == "table" and record.window or nil
                if window and window.IsShown and window:IsShown() then
                    open = window
                    break
                end
            end
        end
        if not open then return end

        escapeRepair = true
        frame:Show()
        open:Hide()
        escapeRepair = false
    end)

    -- The Ranks and Equipment pages ask for PLAYER_REGEN_ENABLED only when they
    -- are drawn (see watchRegen); this is the handler they will use. A fight
    -- that started while either page was blank is the case this exists for: the
    -- redraw fills in the widgets the client refused to create during it.
    --
    -- PLAYER_LEVEL_UP and PLAYER_LOGIN are here for the rail gates: the Ranks
    -- row appears at level 10 and a level gained while the window is open must
    -- not wait for the next unrelated refresh. Both are pcall'd for the same
    -- reason as every other registration in this addon.
    pcall(frame.RegisterEvent, frame, "PLAYER_LEVEL_UP")
    pcall(frame.RegisterEvent, frame, "PLAYER_LOGIN")

    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_LEVEL_UP" or event == "PLAYER_LOGIN" then
            refreshRailGating()
            return
        end
        if event ~= "PLAYER_REGEN_ENABLED" then return end
        if currentPage == "ranks" or currentPage == "gear" then UI:Refresh() end
    end)

    -- Saved data changes elsewhere should keep the visible page honest. A
    -- plugin registering or leaving also changes whether the Plugins row is
    -- offered, so that event re-stacks the rail before it redraws.
    LT:On(LT.EVENT_BUILDS, function() UI:Refresh() end)
    LT:On(LT.EVENT_GEARSET, function() UI:Refresh() end)
    LT:On(LT.EVENT_PLUGINS, function() refreshRailGating() end)
    LT:On(LT.EVENT_PROFILE, function() UI:Refresh() end)
    LT:On(LT.EVENT_LEVEL, function() UI:Refresh() end)

    -- Leaderboard.lua loads after this file, so the event name is read when the
    -- window is built; the literal is the fallback for a build without it.
    -- A burst of rows is one packet each, so the handler queues one rebuild for
    -- the next frame instead of redrawing per packet, and it only queues while
    -- the Ranks page is the one on screen.
    local ranksEvent = (LT.Leaderboard and LT.Leaderboard.EVENT) or "RANKS_CHANGED"
    LT:On(ranksEvent, function() queueRanksRefresh() end)

    -- A resolution or UI-scale change resizes UIParent. Re-applying the stored
    -- fraction keeps the window on screen even if it was closed at the time.
    pcall(UIParent.HookScript, UIParent, "OnSizeChanged", function()
        if frame then applyWindowPlacement() end
    end)

    -- CreateFrame returns a shown frame. Without this, the first Toggle() sees
    -- IsShown() == true and hides it, so a bare "/lt" appeared to do nothing.
    frame:Hide()

    return frame
end

function UI:Show()
    ensureFrame()
    -- A window closed on a page the rail no longer offers opens on the first
    -- row that is still there, the same rule ensureFrame applies on first build.
    RAIL.revalidatePage()
    applyWindowPlacement()
    frame:Show()
    self:Refresh()
    notifyRanksOpened()
end

function UI:Hide()
    -- A queued Ranks rebuild has nothing to redraw once the window is hidden,
    -- and Show refreshes on its way back, so the queue is dropped here.
    clearRanksRefresh()
    if frame then frame:Hide() end
end

-- Used by anything that wants to redraw only when the window is actually open:
-- RefreshNow touches the content frame, which does not exist until ensureFrame.
function UI:IsShown()
    return frame ~= nil and frame:IsShown() and true or false
end

function UI:Toggle()
    ensureFrame()

    if frame:IsShown() then
        frame:Hide()
    else
        RAIL.revalidatePage()
        applyWindowPlacement()
        frame:Show()
        self:Refresh()
        notifyRanksOpened()
    end
end

function UI:ShowPage(key)
    currentPage = key

    local record = windowRecord()
    if record then record.page = key end

    self:Refresh()
    notifyRanksOpened()
end

-- Lets an optional local addon contribute a page. Nothing in this addon calls
-- it, so a normal install has exactly the nine pages above and no code path
-- that could draw a page nobody registered. The drawer receives the page cursor
-- and the content frame; parent widgets to the content frame so the existing
-- clear-and-pool pass tidies them up like any bundled page.
function UI:AddPage(key, label, draw)
    if type(key) ~= "string" or key == "" then
        return false, "A page needs a string key."
    end

    if type(draw) ~= "function" then
        return false, "A page needs a draw function."
    end

    for _, page in ipairs(PAGES) do
        if page.key == key then
            return false, "Page \"" .. tostring(key) .. "\" already exists."
        end
    end

    table.insert(PAGES, {
        key = key,
        label = tostring(label or key),
        external = true,
    })

    externalDrawers[key] = draw

    -- If the window is already built, the new page gets its own row on the rail
    -- and the column is re-stacked, so nothing is ever crowded off the bottom.
    if pageButtons then layoutRail() end
    if currentPage == key then self:Refresh() end

    return true
end

-- Widget constructors for pages contributed through UI:AddPage, so a local
-- addon builds controls that match the bundled pages instead of its own.
function UI:MakeButton(parent, text, width, height, onClick)
    return MakeButton(parent, text, width, height, onClick)
end

-- A contributed page that grows taller than the window needs its own scroll:
-- without one its rows are laid out below the window and, because the page host
-- is not clipped, draw straight over the footer and the rest of the UI. That is
-- what the Dev page did on 2026-11-04. The bar is the window's single one and
-- appears only when the content is taller than the view.
function UI:MakeScroll(parent, key)
    return MakeScroll(parent, key)
end

function UI:MakeLabel(parent, text, size, colour)
    return MakeLabel(parent, text, size, colour)
end

function UI:GetHoveredItemLink()
    if GameTooltip and GameTooltip.GetItem then
        local name, link = GameTooltip:GetItem()
        if link and not LT:IsSecret(link) then return link end
    end

    return nil
end

------------------------------------------------------------------------------
-- Layout helper for the current page
------------------------------------------------------------------------------

-- Empties a host frame and returns its labels to the pool. One function for the
-- page content and for a popup body, so a redrawn popup reuses labels exactly
-- as a redrawn page does and neither leaks a font string per draw.
local function recycleHost(host)
    if not host then return end

    -- Decision 4 fix: use select('#',...) so nil gaps in the child table do not
    -- stop the loop, and reparent to UIParent instead of nil (nil is unsafe on
    -- Forever's client and can leave frames rendered but untracked).
    local children = { host:GetChildren() }
    -- WoW Lua uses the global unpack(); avoid table.unpack which may not exist.
    for i = 1, select("#", unpack(children)) do
        local child = children[i]
        if child then
            child:Hide()
            child:SetParent(UIParent)
        end
    end

    -- Labels directly on the host are regions, not children: hide them and
    -- return them to the pool so the next draw starts clean.
    local pool = host.lunchboxLabelPool
    if pool then
        local regions = { host:GetRegions() }
        for i = 1, select("#", unpack(regions)) do
            local region = regions[i]
            if region and region.GetObjectType and region:GetObjectType() == "FontString"
                and not region.lunchboxFree then
                region:Hide()
                region:ClearAllPoints()
                region:SetText("")
                region.lunchboxFree = true
                table.insert(pool, region)
            end
        end
    end
end

-- A popup that hosts a page drawer needs the same clean slate the page host gets,
-- or every open would leave a second copy of the labels behind it.
function UI:Recycle(host)
    recycleHost(host)
end

local function clearContent()
    recycleHost(contentFrame)

    -- The page being cleared owned the scrollbar; the next page claims it if it
    -- has a scroll area of its own.
    activeScroll = nil
    if refreshScrollBar then refreshScrollBar() end

    local cursor = { x = 0, y = 0 }
    return cursor
end

------------------------------------------------------------------------------
-- Shared wording and measurements
------------------------------------------------------------------------------

-- A label that must stay on one line. Clients that cannot turn wrapping off
-- keep their default, which is why every caller also sets a width that the
-- longest expected string fits.
local function oneLine(label)
    if label and label.SetWordWrap then
        pcall(label.SetWordWrap, label, false)
    end
    return label
end

local function trimmed(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

------------------------------------------------------------------------------
-- Weights popup
--
-- One window, shared by every slot row on the Profiles page. It answers one
-- question: which weights is this slot scoring from, and where did that
-- profile come from?
--
-- It opens read-only. "Customise" starts a draft from the resolved profile's
-- weights and "Save as profile" stores that draft under a new key and points
-- the slot at it. The profile the window was opened on is never written to, so
-- a bundled or private profile cannot be changed by accident, and the weights
-- look the same as they do in the profile editor below: same group headings,
-- same stat names, same three decimal places.
--
-- The frame is created on the first open and only outside combat. Once it
-- exists it is shown, hidden and rewritten, so a fight that starts while it is
-- open cannot ask the client to create anything. It needs a name because
-- Escape only closes a frame listed in UISpecialFrames, and Escape discarding
-- the draft is the decided behaviour. The main window stays in that list as
-- well and repairs the result in its own OnHide handler (see ensureFrame): an
-- Escape pressed with this window up closes only this window, and the next
-- Escape then closes the main window.
------------------------------------------------------------------------------

local WEIGHTS_WIDTH     = 460
local WEIGHTS_HEIGHT    = 460
local WEIGHTS_PAD       = 14
local WEIGHTS_FOOTER    = 100
local WEIGHTS_VALUE_X   = 232
local WEIGHTS_LABEL_W   = 216

weightsPopup = {
    frame = nil,
    slotIndex = nil,
    mode = "read",      -- "read" | "edit" | "confirm"
    draft = nil,        -- { sourceKey, sourceName, name, weights }
    baseline = nil,     -- the weights the draft started from
    defaultName = nil,
    error = nil,
    groups = {},
}

function weightsPopup:CombatLocked()
    return combatLocked()
end

function weightsPopup:IsShown()
    return self.frame ~= nil and self.frame:IsShown() and true or false
end

-- The Weights window shares the popup place/remember helpers above; only the
-- record key and the two design sizes are its own.
local function placeWeightsFrame()
    placePopupFrame(weightsPopup.frame, "weights", WEIGHTS_WIDTH, WEIGHTS_HEIGHT)
end

local function saveWeightsPlace()
    savePopupPlacement(weightsPopup.frame, "weights")
end

function weightsPopup:EnsureFrame()
    if self.frame then return self.frame end

    -- Escape closes this window through the client's special-frame list, and
    -- closing discards the draft. The shared builder registers the name and
    -- refuses in combat, because creating the frame is what the client refuses
    -- there. Shown or hidden, the popup only manages its own state; the main
    -- window's OnHide handler keeps one Escape from taking both windows.
    local window = MakePopupFrame("LunchboxToolkitWeightsFrame",
        WEIGHTS_WIDTH, WEIGHTS_HEIGHT, "weights", function()
            weightsPopup:Reset()
        end)
    if not window then return nil end

    local headerY = -WEIGHTS_PAD

    local title = MakeLabel(window, "Weights", "GameFontNormal", LT.Palette:RGB("brand"))
    title:SetPoint("TOPLEFT", WEIGHTS_PAD, headerY)
    headerY = headerY - (title:GetStringHeight() or 16) - 2

    local context = MakeLabel(window, "X", "GameFontNormalSmall", LT.Palette:RGB("muted"))
    context:SetPoint("TOPLEFT", WEIGHTS_PAD, headerY)
    context:SetWidth(WEIGHTS_WIDTH - (WEIGHTS_PAD * 2))
    context:SetJustifyH("LEFT")
    oneLine(context)
    headerY = headerY - (context:GetStringHeight() or 12) - 2
    self.contextLabel = context

    local profileLine = MakeLabel(window, "X", "GameFontNormalSmall")
    profileLine:SetPoint("TOPLEFT", WEIGHTS_PAD, headerY)
    profileLine:SetWidth(WEIGHTS_WIDTH - (WEIGHTS_PAD * 2))
    profileLine:SetJustifyH("LEFT")
    oneLine(profileLine)
    headerY = headerY - (profileLine:GetStringHeight() or 12) - 2
    self.profileLabel = profileLine

    local note = MakeLabel(window, "Weights (rating points are shown per unit of each stat)",
        "GameFontNormalSmall", LT.Palette:RGB("muted"))
    note:SetPoint("TOPLEFT", WEIGHTS_PAD, headerY)
    note:SetWidth(WEIGHTS_WIDTH - (WEIGHTS_PAD * 2))
    note:SetJustifyH("LEFT")
    oneLine(note)
    headerY = headerY - (note:GetStringHeight() or 12) - 6

    local body = MakeScroll(window, "weights.popup")
    body:SetPoint("TOPLEFT", WEIGHTS_PAD, headerY)
    body:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -WEIGHTS_PAD, WEIGHTS_FOOTER)

    local content = body.content
    local rowsY = 0

    for _, group in ipairs((LT.ItemStats and LT.ItemStats.statGroups) or {}) do
        local heading = MakeLabel(content, tostring(group.label), "GameFontNormalSmall",
            LT.Palette:RGB("text"))
        heading:SetPoint("TOPLEFT", 4, rowsY)
        rowsY = rowsY - ((heading:GetStringHeight() or 12) + 4)

        local set = { heading = heading, rows = {} }

        for _, stat in ipairs(group.stats) do
            -- A block-local copy, so the commit callback always writes the stat
            -- of its own row whatever the client's loop-variable scoping does.
            local statKey = stat

            local label = MakeLabel(content, LT:Label(stat), "GameFontNormalSmall")
            label:SetPoint("TOPLEFT", 8, rowsY)
            label:SetWidth(WEIGHTS_LABEL_W)
            label:SetJustifyH("LEFT")
            oneLine(label)

            local value = MakeLabel(content, "0", "GameFontNormalSmall")
            value:SetPoint("TOPLEFT", WEIGHTS_VALUE_X, rowsY)
            value:SetWidth(90)
            value:SetJustifyH("LEFT")

            local box
            box = MakeEditBox(content, 74, 20, "0", function(text)
                weightsPopup:SetDraftWeight(statKey, text, box)
            end)
            box:SetPoint("TOPLEFT", WEIGHTS_VALUE_X - 4, rowsY - 3)
            box:Hide()

            table.insert(set.rows, { stat = stat, label = label, value = value, box = box })
            rowsY = rowsY - 20
        end

        rowsY = rowsY - 6
        table.insert(self.groups, set)
    end

    local message = MakeLabel(window, "X", "GameFontNormalSmall", LT.Palette:RGB("caution"))
    message:SetPoint("BOTTOMLEFT", WEIGHTS_PAD, 74)
    message:SetWidth(WEIGHTS_WIDTH - (WEIGHTS_PAD * 2))
    message:SetJustifyH("LEFT")
    oneLine(message)
    self.messageLabel = message

    local nameLabel = MakeLabel(window, "Name:", "GameFontNormalSmall",
        LT.Palette:RGB("muted"))
    nameLabel:SetPoint("BOTTOMLEFT", WEIGHTS_PAD, 48)
    self.nameFieldLabel = nameLabel

    local nameBox = MakeEditBox(window, 190, 20, "", function(text)
        if not weightsPopup.draft then return end
        weightsPopup.draft.name = text
        -- A corrected name must not leave the previous refusal on screen.
        weightsPopup.error = nil
        weightsPopup:Render()
    end)
    nameBox:SetPoint("BOTTOMLEFT", WEIGHTS_PAD + 44, 44)
    self.nameBox = nameBox

    self.customiseButton = MakeButton(window, "Customise", 96, 20, function()
        weightsPopup:Customise()
    end)
    self.customiseButton:SetPoint("BOTTOMLEFT", WEIGHTS_PAD, 12)

    self.closeButton = MakeButton(window, "Close", 70, 20, function()
        weightsPopup:Close()
    end)
    self.closeButton:SetPoint("BOTTOMLEFT", WEIGHTS_PAD + 104, 12)

    self.saveButton = MakeButton(window, "Save as profile", 124, 20, function()
        weightsPopup:SaveDraft()
    end)
    self.saveButton:SetPoint("BOTTOMLEFT", WEIGHTS_PAD + 238, 44)

    self.discardButton = MakeButton(window, "Discard", 80, 20, function()
        weightsPopup:Hide()
    end)
    self.discardButton:SetPoint("BOTTOMLEFT", WEIGHTS_PAD + 96, 12)

    window:Hide()
    self.frame = window
    return window
end

-- Back to the read-only view. Called on every open and whenever the window is
-- hidden, so a discarded draft cannot leak into the next visit.
function weightsPopup:Reset()
    self.mode = "read"
    self.draft = nil
    self.baseline = nil
    self.defaultName = nil
    self.error = nil
end

function weightsPopup:Hide()
    if self.frame then self.frame:Hide() end
end

function weightsPopup:Open(slotIndex)
    local requested = tonumber(slotIndex) or LT.Builds:GetActiveIndex()

    -- Opening another slot would throw the draft away without asking; say so
    -- instead. The same slot just re-reads it.
    if self:IsShown() and self.mode == "edit" and self:IsDirty()
        and requested ~= self.slotIndex then
        LT:Print("The weights window has unsaved changes. Close it first.")
        return false
    end

    -- A second open on the same slot while editing keeps the draft.
    if self:IsShown() and requested == self.slotIndex then
        self:Render()
        return true
    end

    local window = self:EnsureFrame()
    if not window then
        LT:Print("The weights window cannot be built in combat. Open it again after the fight.")
        return false
    end

    self:Reset()
    self.slotIndex = requested
    placeWeightsFrame()
    self:Render()
    window:Show()
    return true
end

function weightsPopup:SetDraftWeight(stat, text, box)
    if not self.draft then return end

    local number = tonumber(text)
    if not number then
        box:SetText(LT:FormatNumber(self.draft.weights[stat] or 0, 3))
        return
    end

    self.draft.weights[stat] = number
end

function weightsPopup:IsDirty()
    if self.mode ~= "edit" or not self.draft then return false end
    if trimmed(self.draft.name) ~= trimmed(self.defaultName) then return true end

    local function number(map, stat)
        return tonumber(map and map[stat]) or 0
    end

    for _, group in ipairs((LT.ItemStats and LT.ItemStats.statGroups) or {}) do
        for _, stat in ipairs(group.stats) do
            if number(self.draft.weights, stat) ~= number(self.baseline, stat) then
                return true
            end
        end
    end

    return false
end

function weightsPopup:Customise()
    local resolved = self.slotIndex and LT.Profiles:ResolveSlot(self.slotIndex) or nil
    local profile = resolved and resolved.profile

    if not profile then
        self.error = "This slot has no profile to customise."
        self:Render()
        return
    end

    local weights = LT:Copy(profile.weights or {})
    local defaultName = tostring(profile.name) .. " (custom)"

    -- The draft is a copy from the first keystroke: nothing below writes to the
    -- profile it was taken from.
    self.draft = {
        sourceKey = resolved.key,
        sourceName = resolved.name,
        name = defaultName,
        weights = weights,
    }
    self.baseline = LT:Copy(weights)
    self.defaultName = defaultName
    self.mode = "edit"
    self.error = nil
    self:Render()
end

function weightsPopup:SaveDraft()
    local draft = self.draft
    if not draft then return end

    -- Read the name field itself. Clicking a button does not take focus off an
    -- edit box before the click runs, so a typed name never reached the draft
    -- and the profile was saved under the "(custom)" name Customise proposed.
    local typed = ""
    if self.nameBox and type(self.nameBox.GetText) == "function" then
        local okText, text = pcall(self.nameBox.GetText, self.nameBox)
        if okText and type(text) == "string" then typed = text end
    end

    -- Trimmed typed text, else the name Customise proposed, else whatever the
    -- draft already held. An empty field therefore still saves a named profile.
    local name = trimmed(typed)
    if name == "" then name = trimmed(self.defaultName) end
    if name == "" then name = trimmed(draft.name) end
    if name == "" then
        self.error = "A profile name is required."
        self:Render()
        return
    end

    -- The draft carries the name the profile is created with, so the key that
    -- Create derives, the label in the picker and the field all agree.
    draft.name = name
    if self.nameBox and type(self.nameBox.SetText) == "function" then
        pcall(self.nameBox.SetText, self.nameBox, name)
    end

    -- Create's own collision message quotes the whole name, which can outrun
    -- the one-line row; this case gets wording that always fits.
    for _, existing in pairs(LT.Profiles:GetCustomTable()) do
        if existing.name == name then
            self.error = "A custom profile already uses that name."
            self:Render()
            return
        end
    end

    -- A new key every time: the profile this window was opened on is a source,
    -- never a destination, which is what keeps bundled and private data intact.
    local key, err = LT.Profiles:Create(name, draft.sourceKey)
    if not key then
        self.error = tostring(err or "The profile could not be created.")
        self:Render()
        return
    end

    local stored, why = LT.Profiles:SetWeights(key, draft.weights)
    if not stored then
        -- The slot is still on the old profile, so remove the half-made one
        -- rather than leaving it in the picker.
        LT.Profiles:Delete(key)
        self.error = tostring(why or "The weights could not be stored.")
        self:Render()
        return
    end

    local slotIndex = self.slotIndex
    LT.Builds:SetProfile(slotIndex, key)
    LT.Profiles:Invalidate()

    local build = LT.Builds:Get(slotIndex)
    LT:Print("Saved \"" .. tostring((LT.Profiles:Get(key) or {}).name or name)
        .. "\" and selected it for " .. tostring(build and build.name or "this slot") .. ".")

    self:Reset()
    self:Hide()
end

function weightsPopup:Close()
    -- Closing is the only route that asks. Escape is the client's own close and
    -- discards without a question, which is the decided behaviour.
    if self.mode == "edit" and self:IsDirty() then
        self.mode = "confirm"
        self.error = nil
        self:Render()
        return
    end

    self:Hide()
end

function weightsPopup:Render()
    local window = self.frame
    if not window then return end

    local resolved = self.slotIndex and LT.Profiles:ResolveSlot(self.slotIndex) or nil
    local profile = resolved and resolved.profile
    local build = self.slotIndex and LT.Builds:Get(self.slotIndex) or nil

    self.contextLabel:SetText("Slot " .. tostring(self.slotIndex or 1) .. " · "
        .. tostring(build and build.name or "this build"))

    if profile then
        self.profileLabel:SetText(tostring(profile.name)
            .. (resolved.source
                and ("  " .. LT.Palette:Wrap("muted", "(" .. tostring(resolved.source) .. ")"))
                or ""))
    else
        self.profileLabel:SetText(LT.Palette:Wrap("muted", "no profile resolves for this slot"))
    end

    local editing = self.mode == "edit"
    local weights = (self.draft and self.draft.weights)
        or (profile and profile.weights) or {}

    for _, set in ipairs(self.groups) do
        for _, row in ipairs(set.rows) do
            local number = tonumber(weights[row.stat])
            row.value:SetText(number and LT:FormatNumber(number, 3) or "0")

            if editing then
                row.value:Hide()
                row.box:Show()
                if not (row.box.HasFocus and row.box:HasFocus()) then
                    row.box:SetText(LT:FormatNumber(number or 0, 3))
                end
            else
                row.box:Hide()
                row.value:Show()
            end
        end
    end

    local confirmMode = self.mode == "confirm"

    local function show(widget, flag)
        if not widget then return end
        if flag then widget:Show() else widget:Hide() end
    end

    show(self.customiseButton, self.mode == "read")
    show(self.closeButton, not confirmMode)
    show(self.nameFieldLabel, editing)
    show(self.nameBox, editing)
    show(self.saveButton, editing or confirmMode)
    show(self.discardButton, confirmMode)

    if confirmMode then
        self.saveButton:ClearAllPoints()
        self.saveButton:SetPoint("BOTTOMLEFT", WEIGHTS_PAD, 12)
        self.saveButton:SetText("Save")

        self.discardButton:ClearAllPoints()
        self.discardButton:SetPoint("BOTTOMLEFT", WEIGHTS_PAD + 96, 12)
    elseif editing then
        self.saveButton:ClearAllPoints()
        self.saveButton:SetPoint("BOTTOMLEFT", WEIGHTS_PAD + 238, 44)
        self.saveButton:SetText("Save as profile")
    end

    local message, colourKey
    if self.error then
        message, colourKey = tostring(self.error), "stop"
    elseif confirmMode then
        message = "Unsaved weight changes. Save them as a new profile, or discard them?"
        colourKey = "caution"
    end

    if message then
        local colour = LT.Palette:RGB(colourKey)
        self.messageLabel:SetText(message)
        self.messageLabel:SetTextColor(colour.r, colour.g, colour.b)
        self.messageLabel:Show()
    else
        self.messageLabel:Hide()
    end
end

------------------------------------------------------------------------------
-- Profile choice shared by the Builds page and the Profiles slot rows
------------------------------------------------------------------------------

-- The next key in the player's own suggestion list, starting after the profile
-- the slot currently resolves to, so both places cycle in the same order.
local function nextProfileKey(resolved)
    local suggestions = LT.Profiles:GetSuggested(LT.player and LT.player.class)
    if #suggestions == 0 then return nil end

    for position, candidate in ipairs(suggestions) do
        if candidate.key == (resolved and resolved.key) then
            local following = suggestions[(position % #suggestions) + 1]
            return following and following.key or suggestions[1].key
        end
    end

    return suggestions[1].key
end

------------------------------------------------------------------------------
-- Profile picker
--
-- One button per build slot opens this list, and choosing a profile is one
-- click on its name. The editor on the Profiles page below follows the chosen
-- profile, so the page no longer needs a second, always-visible library beside
-- it: a slot row and the editor are the whole page.
--
-- The frame is created on the first open and only outside combat; opening it
-- again rewrites the existing rows, so a fight cannot ask the client to create
-- anything.
------------------------------------------------------------------------------

local PICKER_WIDTH = 380
local PICKER_HEIGHT = 420
local PICKER_PAD = 14
local PICKER_ROW = 22

profilePicker = {
    frame = nil,
    slotIndex = nil,
    rows = {},
}

function profilePicker:IsShown()
    return self.frame ~= nil and self.frame:IsShown() and true or false
end

function profilePicker:Hide()
    if self.frame then self.frame:Hide() end
end

-- The profiles this character can choose: its own class plus the class-neutral
-- ones. The same rule the page's library used, so nothing becomes unreachable.
function profilePicker:List()
    local playerClass = LT.player and LT.player.class
    local list = {}

    for _, candidate in ipairs(LT.Profiles:GetAll()) do
        local profileClass = candidate.class
        if not playerClass or not profileClass or profileClass == "ANY"
            or profileClass == playerClass then
            list[#list + 1] = candidate
        end
    end

    return list
end

function profilePicker:EnsureFrame()
    if self.frame then return self.frame end

    local window = MakePopupFrame("LunchboxToolkitProfilePickerFrame",
        PICKER_WIDTH, PICKER_HEIGHT, "picker", function()
            profilePicker.slotIndex = nil
        end)
    if not window then return nil end

    local title = MakeLabel(window, "Profile", "GameFontNormal", LT.Palette:RGB("brand"))
    title:SetPoint("TOPLEFT", PICKER_PAD, -PICKER_PAD)
    self.titleLabel = title

    -- The context line hangs off the title and the list hangs off the context
    -- line, not off a measured offset: both labels are empty when this frame is
    -- built, and an empty label reports no height, so an offset measured here
    -- would put the first row on top of the sentence once it has its text.
    local context = MakeLabel(window, "", "GameFontNormalSmall", LT.Palette:RGB("muted"))
    context:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    context:SetWidth(PICKER_WIDTH - (PICKER_PAD * 2))
    context:SetJustifyH("LEFT")
    self.contextLabel = context

    local list = MakeScroll(window, "profiles.picker")
    list:SetPoint("TOPLEFT", context, "BOTTOMLEFT", 0, -6)
    list:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -PICKER_PAD, 42)
    self.list = list

    self.emptyLabel = MakeLabel(window, "", "GameFontNormalSmall", LT.Palette:RGB("muted"))
    self.emptyLabel:SetPoint("BOTTOMLEFT", PICKER_PAD, 26)
    self.emptyLabel:SetWidth(PICKER_WIDTH - (PICKER_PAD * 2))
    self.emptyLabel:SetJustifyH("LEFT")
    oneLine(self.emptyLabel)

    local close = MakeButton(window, "Close", 70, 20, function()
        profilePicker:Hide()
    end)
    close:SetPoint("BOTTOMLEFT", PICKER_PAD, 12)

    window:Hide()
    self.frame = window
    return window
end

-- One click, and the slot is pointed at that profile. The editor follows it, so
-- what the page shows below the slots is the profile the click chose.
function profilePicker:Choose(key)
    if type(key) ~= "string" or key == "" then return end

    local slot = self.slotIndex or LT.Builds:GetActiveIndex()
    if LT.Builds:SetProfile(slot, key) == false then
        LT:Error("That profile could not be given to the slot.")
        return
    end

    LT.Profiles:Invalidate()
    selectedProfileKey = key
    self:Hide()
    UI:Refresh()
end

function profilePicker:Render()
    local slot = self.slotIndex or LT.Builds:GetActiveIndex()
    local build = LT.Builds:Get(slot)
    local slotName = tostring(build and build.name or ("Build " .. tostring(slot)))
    local resolved = LT.Profiles:ResolveSlot(slot)

    if self.titleLabel then self.titleLabel:SetText("Profile for " .. slotName) end
    if self.contextLabel then
        self.contextLabel:SetText("Now scoring from "
            .. tostring(resolved and resolved.name or "no profile")
            .. ". Choosing one writes it to this slot.")
    end

    local list = self:List()
    local content = self.list and self.list.content
    if not content then return end

    local selectedKey = resolved and resolved.key
    local y = 0

    for index, candidate in ipairs(list) do
        local button = self.rows[index]

        if not button then
            -- A profile added while the window is open during a fight would need
            -- a new button, and creating one is exactly what the client refuses
            -- there. The rows that exist are still re-texted; the new profile
            -- appears on the next open out of combat.
            if combatLocked() then break end

            -- `button` is captured after it exists, so the click always reads
            -- the row's own key and never the last one the loop looked at.
            button = MakeButton(content, "", PICKER_WIDTH - (PICKER_PAD * 2) - 20,
                PICKER_ROW - 2, function()
                profilePicker:Choose(button.profileKey)
            end)
            self.rows[index] = button
        end

        local isCurrent = candidate.key == selectedKey
        button.profileKey = candidate.key
        button:SetText((isCurrent and "> " or "  ") .. tostring(candidate.name))
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", 0, y)
        button:Show()

        y = y - PICKER_ROW
    end

    for index = #list + 1, #self.rows do
        self.rows[index]:Hide()
    end

    if self.emptyLabel then
        if #list == 0 then
            self.emptyLabel:SetText("No profile is available for this class.")
            self.emptyLabel:Show()
        else
            self.emptyLabel:SetText("")
            self.emptyLabel:Hide()
        end
    end
end

function profilePicker:Open(slotIndex)
    local window = self:EnsureFrame()
    if not window then
        LT:Print("The profile list cannot be built in combat. Open it again after the fight.")
        return false
    end

    self.slotIndex = tonumber(slotIndex) or LT.Builds:GetActiveIndex()
    placePopupFrame(window, "picker", PICKER_WIDTH, PICKER_HEIGHT)
    self:Render()
    window:Show()
    return true
end

------------------------------------------------------------------------------
-- Profile delete confirmation
--
-- A build may still be pointed at the profile being deleted. Deleting it then
-- would either silently move every score that build produces or leave the slot
-- dangling, so the question is asked first and answered once: Delete clears the
-- slot and then removes the profile; Cancel writes nothing.
--
-- A base profile is not deletable at all (the page gives it a Copy button
-- instead), and a locked custom profile refuses here as well as in Profiles, so
-- "delete only when unlocked" holds on both paths. After a used profile is
-- deleted the same small window asks "Run the build wizard now?" — Yes opens the
-- wizard, No only redraws.
--
-- The frame is created on first open and only outside combat; once it exists,
-- text and size are rewritten in place. Every height below is measured from the
-- labels after their text is set.
------------------------------------------------------------------------------

local DELETE_WIDTH      = 400
local DELETE_MIN_HEIGHT = 140

deletePopup = {
    frame = nil,
    mode = nil,      -- "confirm" or "wizard"
    key = nil,
    uses = {},
}

-- The builds whose stored profileKey is this profile. Read from the live table,
-- not from a copy: the confirmation must name the slot the player will clear.
local function profileUses(key)
    local uses = {}
    local builds = LT.Builds
    if type(builds) ~= "table" or type(builds.Get) ~= "function" then return uses end

    local count = tonumber(builds.SLOT_COUNT) or 2
    for index = 1, count do
        local ok, build = pcall(builds.Get, builds, index)
        if ok and type(build) == "table" and build.profileKey == key then
            uses[#uses + 1] = {
                index = index,
                name = tostring(build.name or ("Build " .. tostring(index))),
            }
        end
    end

    return uses
end

local function profileUseSentence(uses)
    local parts = {}

    for _, use in ipairs(uses) do
        parts[#parts + 1] = "Build " .. tostring(use.index) .. " (" .. use.name .. ")"
    end

    return table.concat(parts, " and ") .. (#uses == 1 and " uses" or " use")
end

function deletePopup:IsShown()
    return self.frame ~= nil and self.frame:IsShown() and true or false
end

function deletePopup:Hide()
    if self.frame then self.frame:Hide() end
end

function deletePopup:EnsureFrame()
    if self.frame then return self.frame end

    local window = MakePopupFrame("LunchboxToolkitDeleteProfileFrame",
        DELETE_WIDTH, DELETE_MIN_HEIGHT, "deleteProfile")
    if not window then return nil end

    self.title = MakeLabel(window, "Delete profile", "GameFontNormal",
        LT.Palette:RGB("brand"))
    self.title:SetPoint("TOPLEFT", 14, -12)

    -- The consequences are one hover away, not behind a second click.
    self.titleInfo = MakeInfo(window, "Delete profile",
        "A custom profile can be deleted only while it is unlocked. If a build still "
        .. "uses it, the confirmation names that build; Delete clears the slot and "
        .. "then removes the profile. If the delete fails, the slot is put back. A "
        .. "base profile is never deletable.")
    if self.titleInfo then self.titleInfo:SetPoint("LEFT", self.title, "RIGHT", 6, 0) end

    self.message = MakeLabel(window, "", "GameFontNormalSmall")
    self.message:SetJustifyH("LEFT")
    oneLine(self.message)

    self.detail = MakeLabel(window, "", "GameFontNormalSmall", LT.Palette:RGB("muted"))
    self.detail:SetJustifyH("LEFT")
    oneLine(self.detail)

    self.noButton = MakeButton(window, "Cancel", 76, 20, function()
        if deletePopup.mode == "wizard" then
            deletePopup:Hide()
            UI:Refresh()
        else
            deletePopup:Hide()
        end
    end)
    self.noButton:SetPoint("BOTTOMRIGHT", -100, 12)

    self.yesButton = MakeButton(window, "Delete", 76, 20, function()
        if deletePopup.mode == "wizard" then
            deletePopup:FinishWizard()
        else
            deletePopup:Confirm()
        end
    end)
    self.yesButton:SetPoint("BOTTOMRIGHT", -14, 12)

    window:Hide()
    self.frame = window
    return window
end

-- Sizes the small window from the strings it just wrote, then re-clamps its
-- remembered place. A long build name or a taller client font makes the window
-- taller instead of putting the buttons over the sentence.
function deletePopup:Render()
    if not self.frame then return end

    local title, message, detail = self.title, self.message, self.detail
    if not title or not message or not detail then return end

    if self.mode == "wizard" then
        title:SetText("Run the build wizard now?")
        message:SetText("The slot is empty. Run the build wizard now?")
        detail:SetText("Yes opens the wizard. No leaves the slot empty.")
        self.yesButton:SetText("Yes")
        self.noButton:SetText("No")
    else
        title:SetText("Delete profile")

        if #self.uses > 0 then
            message:SetText(profileUseSentence(self.uses)
                .. " this; delete and clear the "
                .. (#self.uses > 1 and "slots" or "slot") .. "?")
        else
            local profile
            if self.key then
                local okGet, value = pcall(LT.Profiles.Get, LT.Profiles, self.key)
                if okGet then profile = value end
            end
            message:SetText("Delete \"" .. tostring(profile and profile.name or "this profile")
                .. "\"?")
        end

        detail:SetText("This cannot be undone.")
        self.yesButton:SetText("Delete")
        self.noButton:SetText("Cancel")
    end

    message:SetWidth(DELETE_WIDTH - 28)
    detail:SetWidth(DELETE_WIDTH - 28)

    title:ClearAllPoints()
    title:SetPoint("TOPLEFT", 14, -12)
    if self.titleInfo then
        self.titleInfo:ClearAllPoints()
        self.titleInfo:SetPoint("LEFT", title, "RIGHT", 6, 0)
    end

    message:ClearAllPoints()
    message:SetPoint("TOPLEFT", 14, -12 - (title:GetStringHeight() or 16) - 6)

    detail:ClearAllPoints()
    detail:SetPoint("TOPLEFT", message, "BOTTOMLEFT", 0, -4)

    local height = 12 + (title:GetStringHeight() or 16) + 6
        + (message:GetStringHeight() or 12) + 4
        + (detail:GetStringHeight() or 12) + 14 + 20 + 12
    if height < DELETE_MIN_HEIGHT then height = DELETE_MIN_HEIGHT end

    self.frame:SetHeight(height)
    placePopupFrame(self.frame, "deleteProfile", DELETE_WIDTH, height)
end

function deletePopup:OpenConfirm(key)
    if combatLocked() then
        LT:Print("The delete confirmation cannot be built in combat. "
            .. "Try again after the fight.")
        return false
    end

    local window = self:EnsureFrame()
    if not window then
        LT:Print("The delete confirmation could not be built. Try again.")
        return false
    end

    self.mode = "confirm"
    self.key = key
    self.uses = profileUses(key)
    self:Render()
    window:Show()
    return true
end

-- Yes on the confirmation. The slot is cleared first because Profiles:Delete
-- refuses while a build points at the profile; if the delete then fails, every
-- cleared slot is put back, so a failed delete leaves the build untouched.
function deletePopup:Confirm()
    local key = self.key
    if type(key) ~= "string" or key == "" then return end

    local okProfile, profile = pcall(LT.Profiles.Get, LT.Profiles, key)
    if not okProfile or type(profile) ~= "table" then
        LT:Error("That profile no longer exists.")
        self:Hide()
        UI:Refresh()
        return
    end
    if profile.kind ~= "custom" then
        LT:Error("Base profiles cannot be deleted.")
        self:Hide()
        UI:Refresh()
        return
    end
    if profile.locked == true then
        LT:Error("This profile is locked. Unlock it to delete it.")
        self:Hide()
        UI:Refresh()
        return
    end

    local uses = self.uses or {}
    local cleared = {}

    for _, use in ipairs(uses) do
        local okSet, set = pcall(LT.Builds.SetProfile, LT.Builds, use.index, nil)
        if not okSet or set == false then
            for _, done in ipairs(cleared) do
                pcall(LT.Builds.SetProfile, LT.Builds, done.index, key)
            end
            LT:Error("Build " .. tostring(use.index)
                .. " could not be cleared; the profile was not deleted.")
            self:Hide()
            UI:Refresh()
            return
        end
        cleared[#cleared + 1] = use
    end

    local okDelete, deleted, err = pcall(LT.Profiles.Delete, LT.Profiles, key)
    if not okDelete or deleted ~= true then
        for _, done in ipairs(cleared) do
            pcall(LT.Builds.SetProfile, LT.Builds, done.index, key)
        end
        LT:Error(okDelete and tostring(err or "The profile could not be deleted.")
            or tostring(deleted))
        self:Hide()
        UI:Refresh()
        return
    end

    selectedProfileKey = nil
    LT:Print("Deleted the custom profile.")

    -- Only a delete that cleared a slot leaves a question worth asking.
    if #cleared > 0 then
        self.mode = "wizard"
        self.key = nil
        self.uses = {}
        self:Render()
        self.frame:Show()
    else
        self:Hide()
    end

    UI:Refresh()
end

-- Yes on the wizard question. A missing wizard is said plainly instead of
-- leaving the player on a popup that appears to have done nothing.
function deletePopup:FinishWizard()
    self:Hide()

    local wizard = LT.Wizard
    if type(wizard) ~= "table" or type(wizard.Show) ~= "function" then
        LT:Error("The build wizard is not available.")
        UI:Refresh()
        return
    end

    local ok, err = pcall(wizard.Show, wizard)
    if not ok then
        LT:Error("The build wizard could not open: " .. tostring(err))
        UI:Refresh()
    end
end

------------------------------------------------------------------------------
-- Page: Builds
------------------------------------------------------------------------------

local function drawBuilds(cursor)
    local classDefinition = LT.ClassData:GetClass(LT.player.class)
    local specChoices = (classDefinition and classDefinition.specs) or { "Any" }

    -- Two slots plus their imbue rows and any plugin toggles can be taller than
    -- the window, so the page scrolls like Settings rather than clipping the
    -- last slot. `contentFrame` shadows the page frame for the rest of the
    -- function; the page framework still clears the scroll itself.
    local contentFrame = MakeScroll(contentFrame, "builds").content

    local function addLabel(text, indent, size, colour)
        local label = MakeLabel(contentFrame, text, size, colour)
        label:SetPoint("TOPLEFT", indent or 4, cursor.y)
        cursor.y = cursor.y - 18
        return label
    end

    for index = 1, LT.Builds.SLOT_COUNT do
        local build = LT.Builds:Get(index)
        local isActive = index == LT.Builds:GetActiveIndex()

        local slotY = cursor.y
        addLabel((isActive and "> " or "  ") .. "Slot " .. tostring(index),
            0, "GameFontNormal")

        -- The wizard owns the starter records and the untouched-slot rule, so
        -- this page only opens it. Slot 1 runs the two-phase flow (build 1,
        -- then the optional second build); slot 2 runs its questionnaire alone
        -- and never writes slot 1. Neither button closes this window.
        local wizardButton = MakeButton(contentFrame,
            "Setup build " .. tostring(index), 130, 20, function()
                local wizard = LT.Wizard
                if type(wizard) ~= "table" or type(wizard.Show) ~= "function" then
                    LT:Error("The build wizard module is not loaded.")
                    return
                end

                local shown, reason = wizard:Show(index)
                if not shown and reason then LT:Warn(reason) end
            end)
        wizardButton:SetPoint("TOPLEFT", 300, slotY)

        local nameBox = MakeEditBox(contentFrame, 200, 20, build and build.name, function(text)
            LT.Builds:SetName(index, text)
        end)
        nameBox:SetPoint("TOPLEFT", 4, cursor.y)
        cursor.y = cursor.y - 24

        local specCycle = MakeButton(contentFrame, "Spec: " .. tostring(build and build.spec),
            150, 20, function()
                local current = build and build.spec
                local nextSpec = specChoices[1]

                for _, spec in ipairs(specChoices) do
                    if spec == current then
                        for position, candidate in ipairs(specChoices) do
                            if candidate == current then
                                nextSpec = specChoices[(position % #specChoices) + 1]
                            end
                        end
                    end
                end

                LT.Builds:SetSpec(index, nextSpec)
                UI:Refresh()
            end)
        specCycle:SetPoint("TOPLEFT", 4, cursor.y)

        local roleCycle = MakeButton(contentFrame, "Role: " .. tostring(build and build.role),
            140, 20, function()
                local roles = LT.Roles
                local nextRole = roles[1]

                for position, role in ipairs(roles) do
                    if role == (build and build.role) then
                        nextRole = roles[(position % #roles) + 1]
                    end
                end

                LT.Builds:SetRole(index, nextRole)
                UI:Refresh()
            end)
        roleCycle:SetPoint("TOPLEFT", 160, cursor.y)

        local contextCycle = MakeButton(contentFrame, "Context: " .. tostring(build and build.context),
            120, 20, function()
                local nextContext = (build and build.context) == "PVE" and "PVP" or "PVE"
                LT.Builds:SetContext(index, nextContext)
                UI:Refresh()
            end)
        contextCycle:SetPoint("TOPLEFT", 306, cursor.y)
        cursor.y = cursor.y - 24

        local setupCycle = MakeButton(contentFrame, "Weapon: " .. tostring(build and build.weaponSetup),
            210, 20, function()
                local order = LT.WeaponSetupOrder
                local nextSetup = order[1]

                for position, key in ipairs(order) do
                    if key == (build and build.weaponSetup) then
                        nextSetup = order[(position % #order) + 1]
                    end
                end

                LT.Builds:SetWeaponSetup(index, nextSetup)
                UI:Refresh()
            end)
        setupCycle:SetPoint("TOPLEFT", 4, cursor.y)

        local profile = LT.Profiles:ResolveForBuild(index)
        local profileButton = MakeButton(contentFrame,
            "Profile: " .. tostring(profile and profile.name or "none"),
            320, 20, function()
                local nextKey = nextProfileKey(LT.Profiles:ResolveForBuild(index))

                if nextKey then
                    LT.Builds:SetProfile(index, nextKey)
                    LT.Profiles:Invalidate()
                    UI:Refresh()
                end
            end)
        profileButton:SetPoint("TOPLEFT", 220, cursor.y)
        cursor.y = cursor.y - 24

        -- Shaman only: the weapon imbue this slot is scored with, and whether
        -- this slot scores it. Both choices live on the slot, so the tanking
        -- build and the PvP build can disagree; the Settings switch is only the
        -- fallback for a slot that has not set its own.
        if LT.Imbues and LT.player and LT.player.class == "SHAMAN" then
            local key = LT.Builds:GetImbue(index)
                or (LT.Database:GetOptions().shamanDefaultImbue) or "none"

            local definition = LT.Imbues:GetDefinition(key) or LT.Imbues.definitions.none

            local imbueButton = MakeButton(contentFrame,
                "Imbue: " .. tostring(definition.label), 200, 20, function()
                    LT.Builds:SetImbue(index, LT.Imbues:Next(key))
                    UI:Refresh()
                end)
            imbueButton:SetPoint("TOPLEFT", 4, cursor.y)

            local scoring = LT.Imbues:ResolveScoring(index)

            local toggle = MakeCheck(contentFrame, scoring, function(value)
                -- Pins this slot's own switch. The Settings option is not touched.
                LT.Builds:SetScoreImbue(index, value and true or false)
                UI:Refresh()
            end)
            toggle:SetPoint("TOPLEFT", 212, cursor.y - 1)

            local toggleLabel = MakeLabel(contentFrame, LT.Imbues.SCORING_LABEL,
                "GameFontNormalSmall")
            toggleLabel:SetPoint("LEFT", toggle, "RIGHT", 6, 0)
            toggleLabel:SetWidth(280)
            toggleLabel:SetJustifyH("LEFT")

            -- Only a slot with its own switch needs a way back to the option.
            if LT.Builds:GetScoreImbue(index) ~= nil then
                local inheritButton = MakeButton(contentFrame, "Use setting", 96, 20, function()
                    LT.Builds:SetScoreImbue(index, nil)
                    UI:Refresh()
                end)
                inheritButton:SetPoint("TOPLEFT", 528, cursor.y)
            end

            local stateLabel = MakeLabel(contentFrame, LT.Imbues:DescribeScoring(index),
                "GameFontNormalSmall", LT.Palette:RGB("muted"))
            stateLabel:SetPoint("TOPLEFT", 24, cursor.y - 22)
            stateLabel:SetWidth(560)
            stateLabel:SetJustifyH("LEFT")

            cursor.y = cursor.y - 22 - ((stateLabel:GetStringHeight() or 12) + 2)
        end

        addLabel("Equipment set: " .. LT.GearSets:Describe(index), 8, "GameFontNormalSmall",
            LT.Palette:RGB("muted"))

        local saveButton = MakeButton(contentFrame, "Save equipped", 120, 20, function()
            local snapshot, err = LT.GearSets:Save(index, { reason = "UI" })
            if not snapshot then
                LT:Error(err or "Could not save the equipment set.")
            else
                LT:Print("Saved equipment set for " .. tostring(snapshot.buildName) .. ".")
            end
            UI:Refresh()
        end)
        saveButton:SetPoint("TOPLEFT", 8, cursor.y)

        local viewButton = MakeButton(contentFrame, "View", 70, 20, function()
            LT.Slash:Handle("gear " .. tostring(index))
        end)
        viewButton:SetPoint("TOPLEFT", 132, cursor.y)

        local clearButton = MakeButton(contentFrame, "Clear", 70, 20, function()
            LT.GearSets:Clear(index)
            UI:Refresh()
        end)
        clearButton:SetPoint("TOPLEFT", 206, cursor.y)
        cursor.y = cursor.y - 26

        -- Plugin toggles per slot: two builds of one class can want different
        -- adjustments, so the switch lives on the slot.
        for pluginId, plugin in pairs(LT.PluginAPI.plugins) do
            local enabled = LT.Builds:IsPluginEnabled(index, pluginId)
            local check = MakeCheck(contentFrame, enabled, function(value)
                LT.Builds:SetPluginEnabled(index, pluginId, value)
                UI:Refresh()
            end)
            check:SetPoint("TOPLEFT", 12, cursor.y)

            local label = MakeLabel(contentFrame, tostring(plugin.name), "GameFontNormalSmall")
            label:SetPoint("LEFT", check, "RIGHT", 6, 0)
            cursor.y = cursor.y - 20
        end

        cursor.y = cursor.y - 10
    end

    addLabel("Selecting a slot changes nothing in the game: no gear is swapped and "
        .. "no talent points are spent.", 4, "GameFontNormalSmall", LT.Palette:RGB("muted"))
end

------------------------------------------------------------------------------
-- Page: Profiles
------------------------------------------------------------------------------

local function drawProfiles(cursor)
    -- One row per build slot, and below it the editor for the profile the page
    -- is showing. The profile is chosen from the list behind the slot's own
    -- button (see profilePicker above), so the page is a slot list and one
    -- editor instead of a list, a library and an editor sharing the space.
    local activeIndex = LT.Builds:GetActiveIndex()

    -- With nothing chosen yet, the page opens on the active slot's profile, so
    -- the editor always has something to show and no click is needed to get
    -- there.
    if not selectedProfileKey or not LT.Profiles:Get(selectedProfileKey) then
        local resolvedActive = LT.Profiles:ResolveSlot(activeIndex)
        selectedProfileKey = resolvedActive and resolvedActive.key or nil
    end

    local slotHeading = MakeLabel(contentFrame, "Slots", "GameFontNormalSmall",
        LT.Palette:RGB("brand"))
    slotHeading:SetPoint("TOPLEFT", 4, cursor.y)

    local slotInfo = MakeInfo(contentFrame, "Slots",
        "Each row shows the profile the slot actually scores with. A slot that has "
        .. "never been pointed at a profile still resolves to the bundled one that "
        .. "matches its role and context, so this name can differ from the one stored "
        .. "on the Builds page. The button opens the list of profiles for this class; "
        .. "choosing one points the slot at it and the editor below follows it. The "
        .. "word after the name is where the profile comes from: bundled and private "
        .. "profiles are read-only, and Weights opens one for looking and customises "
        .. "a copy of it.")
    if slotInfo then slotInfo:SetPoint("LEFT", slotHeading, "RIGHT", 4, 0) end

    cursor.y = cursor.y - 18

    for index = 1, LT.Builds.SLOT_COUNT do
        -- Build 2 appears once it exists, so a character with one slot is not
        -- shown a second row for a slot it does not have.
        local build = LT.Builds:Get(index)
        if not build then break end

        local resolved = LT.Profiles:ResolveSlot(index)

        local slotLabel = MakeLabel(contentFrame,
            (index == activeIndex and "> " or "  ")
                .. tostring(build.name or ("Build " .. tostring(index))),
            "GameFontNormalSmall")
        slotLabel:SetPoint("TOPLEFT", 4, cursor.y)
        slotLabel:SetWidth(118)
        slotLabel:SetJustifyH("LEFT")
        oneLine(slotLabel)

        local change = MakeButton(contentFrame,
            "Profile: " .. tostring(resolved.name or "none"), 288, 20, function()
                profilePicker:Open(index)
            end)
        change:SetPoint("TOPLEFT", 128, cursor.y)

        local sourceLabel = MakeLabel(contentFrame, tostring(resolved.source or "none"),
            "GameFontNormalSmall", LT.Palette:RGB("muted"))
        sourceLabel:SetPoint("TOPLEFT", 424, cursor.y - 4)
        sourceLabel:SetWidth(76)
        sourceLabel:SetJustifyH("LEFT")
        oneLine(sourceLabel)

        local weights = MakeButton(contentFrame, "Weights", 84, 20, function()
            weightsPopup:Open(index)
        end)
        weights:SetPoint("TOPLEFT", 504, cursor.y)

        cursor.y = cursor.y - 24
    end

    local editorHeading = MakeLabel(contentFrame, "Editor", "GameFontNormalSmall",
        LT.Palette:RGB("brand"))
    editorHeading:SetPoint("TOPLEFT", 4, cursor.y)

    local editorInfo = MakeInfo(contentFrame, "Editor",
        "The weights and caps of the profile chosen for a slot. Base profiles ship "
        .. "with the addon and cannot be edited — copy one to make it yours. Every "
        .. "weight in a base profile is provisional and has not been validated "
        .. "against Forever. The list of profiles is behind each slot's own button.")
    if editorInfo then editorInfo:SetPoint("LEFT", editorHeading, "RIGHT", 4, 0) end

    cursor.y = cursor.y - 20

    -- The library column is gone, so the editor takes the whole width: one
    -- long-form panel is easier to read than a 390-pixel strip beside a list.
    local detail = MakeScroll(contentFrame, "profiles.editor")
    detail:SetPoint("TOPLEFT", 0, cursor.y)
    detail:SetPoint("BOTTOMRIGHT", contentFrame, "BOTTOMRIGHT", 0, 0)

    local panel = detail.content
    local panelY = 0

    local function panelLabel(text, size, colour)
        local label = MakeLabel(panel, text, size or "GameFontNormalSmall", colour)
        label:SetPoint("TOPLEFT", 0, panelY)
        label:SetWidth(600)
        label:SetJustifyH("LEFT")
        panelY = panelY - (label:GetStringHeight() or 14) - 6
        return label
    end

    local profile = selectedProfileKey and LT.Profiles:Get(selectedProfileKey) or nil

    if not profile then
        panelLabel("No profile is chosen yet.", "GameFontNormal")
        panelLabel("Open a slot's Profile button above to pick one. Base profiles "
            .. "ship with the addon and cannot be edited — copy one to make it "
            .. "yours.", "GameFontNormalSmall", LT.Palette:RGB("muted"))
        return
    end

    -- "Provisional" and "[Locked]" are yellow: they qualify an answer, they are
    -- not a refusal. On a base profile the note is muted rather than yellow,
    -- because nothing there can be changed anyway.
    local lockBadge = (profile.kind == "custom" and profile.locked == true)
        and (" " .. LT.Palette:Wrap("caution", "[Locked]")) or ""
    panelLabel(profile.name .. lockBadge, "GameFontNormal")
    panelLabel("(" .. tostring(profile.kind) .. ")"
        .. (profile.provisional and ("  " .. LT.Palette:Wrap("caution", "provisional")) or ""),
        "GameFontNormalSmall", LT.Palette:RGB("muted"))

    if profile.assumptions and profile.assumptions ~= "" then
        panelLabel(profile.assumptions, "GameFontNormalSmall", LT.Palette:RGB("muted"))
    end

    if profile.kind == "base" then
        local copyButton = MakeButton(panel, "Copy to a custom profile", 200, 22, function()
            local key, err = LT.Profiles:CopyProfile(profile.key, profile.name .. " (mine)")
            if key then
                selectedProfileKey = key
                LT:Print("Created \"" .. tostring(LT.Profiles:Get(key).name) .. "\".")
            else
                LT:Error(err)
            end
            UI:Refresh()
        end)
        copyButton:SetPoint("TOPLEFT", 0, panelY)
        panelY = panelY - 30
    else
        -- Locked profiles show a lock indicator and Lock/Unlock button.
        -- Edit boxes are disabled when locked; Delete refuses until Unlocked.
        -- A profile a build still uses asks first, then clears the slot.
        local isLocked = profile.locked == true

        local lockLabel = MakeLabel(panel,
            isLocked and LT.Palette:Wrap("caution", "[Locked]")
                or LT.Palette:Wrap("muted", "[Unlocked]"),
            "GameFontNormalSmall")
        lockLabel:SetPoint("TOPLEFT", 0, panelY)

        local lockButton = MakeButton(panel, isLocked and "Unlock" or "Lock", 70, 20, function()
            LT.Profiles:SetLocked(profile.key, not isLocked)
            UI:Refresh()
        end)
        lockButton:SetPoint("TOPLEFT", 82, panelY)
        panelY = panelY - 24

        local renameBox = MakeEditBox(panel, 200, 20, profile.name, function(text)
            LT.Profiles:Rename(profile.key, text)
            UI:Refresh()
        end)
        renameBox:SetPoint("TOPLEFT", 0, panelY)
        if isLocked then renameBox:Disable() end

        local deleteButton = MakeButton(panel, "Delete", 70, 20, function()
            if isLocked then
                LT:Error("This profile is locked. Unlock it to delete it.")
                return
            end

            if profile.kind ~= "custom" then
                LT:Error("Only custom profiles can be deleted.")
                return
            end

            if #profileUses(profile.key) > 0 then
                deletePopup:OpenConfirm(profile.key)
                return
            end

            local ok, err = LT.Profiles:Delete(profile.key)
            if not ok then
                LT:Error(err)
            else
                selectedProfileKey = nil
                LT:Print("Deleted the custom profile.")
            end
            UI:Refresh()
        end)
        deleteButton:SetPoint("TOPLEFT", 208, panelY)
        panelY = panelY - 28
    end

    -- Goal preset
    local goals = profile.goals or {}
    local isCustomLocked = profile.kind ~= "base" and profile.locked == true
    local presetButton = MakeButton(panel, "Goal preset: " .. tostring(goals.preset or "Custom"),
        220, 20, function()
            local order = LT.GoalOrder
            local nextPreset = order[1]

            for position, name in ipairs(order) do
                if name == (goals.preset or "Custom") then
                    nextPreset = order[(position % #order) + 1]
                end
            end

            local ok, err = LT.Profiles:SetGoalPreset(profile.key, nextPreset)
            if not ok then LT:Error(err) end
            UI:Refresh()
        end)
    presetButton:SetPoint("TOPLEFT", 0, panelY)
    if isCustomLocked then presetButton:Disable() end
    panelY = panelY - 28

    -- Weight rows
    panelLabel("Weights (rating points are shown per unit of each stat)",
        "GameFontNormalSmall", LT.Palette:RGB("muted"))

    for _, group in ipairs(LT.ItemStats.statGroups) do
        panelLabel(group.label, "GameFontNormalSmall", LT.Palette:RGB("text"))

        for _, stat in ipairs(group.stats) do
            local value = (profile.weights or {})[stat]

            local label = MakeLabel(panel, LT:Label(stat), "GameFontNormalSmall")
            label:SetPoint("TOPLEFT", 8, panelY)
            label:SetWidth(190)
            label:SetJustifyH("LEFT")

            local box = MakeEditBox(panel, 70, 20, value and LT:FormatNumber(value, 3) or "0",
                function(text)
                    local ok, err = LT.Profiles:SetWeight(profile.key, stat, text)
                    if not ok then LT:Error(err) end
                    UI:Refresh()
                end)
            box:SetPoint("TOPLEFT", 200, panelY)

            if profile.kind == "base" or profile.locked == true then
                box:Disable()
            end

            panelY = panelY - 22
        end
    end

    -- Caps
    panelLabel("Caps — targets only. A rating equivalent appears once the level's "
        .. "conversion has been measured or entered.", "GameFontNormalSmall",
        LT.Palette:RGB("muted"))

    local editDisabled = profile.kind == "base" or profile.locked == true

    for _, stat in ipairs(LT.Caps.order) do
        local definition = LT.Caps:GetDefinition(profile, stat)

        local check = MakeCheck(panel, definition.enabled, function(value)
            local ok, err = LT.Profiles:SetCap(profile.key, stat, "enabled", value)
            if not ok then LT:Error(err) end
            UI:Refresh()
        end)
        check:SetPoint("TOPLEFT", 8, panelY)

        if editDisabled then check:Disable() end

        local label = MakeLabel(panel, LT:Label(stat), "GameFontNormalSmall")
        label:SetPoint("LEFT", check, "RIGHT", 6, 0)
        label:SetWidth(110)
        label:SetJustifyH("LEFT")

        local targetBox = MakeEditBox(panel, 60, 20, LT:FormatNumber(definition.target or 0, 2),
            function(text)
                local ok, err = LT.Profiles:SetCap(profile.key, stat, "target", tonumber(text) or 0)
                if not ok then LT:Error(err) end
                UI:Refresh()
            end)
        targetBox:SetPoint("TOPLEFT", 150, panelY)

        if editDisabled then targetBox:Disable() end

        local boostText = tostring(definition.mode or "")
            .. " x" .. LT:FormatNumber(definition.boost or 0, 2)
        local boostLabel = MakeLabel(panel, boostText, "GameFontNormalSmall",
            LT.Palette:RGB("muted"))
        boostLabel:SetPoint("TOPLEFT", 216, panelY)
        boostLabel:SetWidth(90)
        boostLabel:SetJustifyH("LEFT")

        local kindLabel = MakeLabel(panel, tostring(definition.kind), "GameFontNormalSmall",
            LT.Palette:RGB("muted"))
        kindLabel:SetPoint("TOPLEFT", 272, panelY)

        panelY = panelY - 24
    end

    panelLabel("Columns: enabled, stat, target, mode boost. Every cap default is a "
        .. "starting point, not verified game data.", "GameFontNormalSmall",
        LT.Palette:RGB("muted"))
end

------------------------------------------------------------------------------
-- Page: Equipment
--
-- The player's layout (12.7): one tab per build slot across the top, the
-- character sheet's own 19-slot arrangement down the left (ten slots in its
-- first column, nine in its second), and every number on the right.
--
-- The slot grid and the tab strip are built once, outside combat, and only
-- moved and re-texted afterwards. Like the Ranks page, their widgets are
-- re-parented to contentFrame on every draw, so clearContent's sweep hides
-- them with the rest of the page and no redraw builds a second copy. Nothing
-- here is named, so no global survives the Lua state.
--
-- The row of data is `UI:EquipmentModel`: it is the one read of the worn items,
-- the scan and the projector, so the grid, the totals line and the per-slot
-- deltas can never disagree with GearPopup. An item that cannot be scored is
-- drawn as an em dash; a zero is never used for "unknown".
------------------------------------------------------------------------------

local GEAR = {
    -- The character sheet's arrangement: the first column takes slot numbers
    -- 1-10, the second 11-19. Numbers, not labels, so a renamed slot keeps its
    -- place.
    columns = {
        { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
        { 11, 12, 13, 14, 15, 16, 17, 18, 19 },
    },
    contentWidth     = 600,
    leftWidth        = 308,
    columnGap        = 16,
    cellWidth        = 150,
    cellGap          = 8,
    rowGap           = 2,
    buttonWidth      = 140,
    lineFallback     = 12,
    rowFallback      = 20,
    limitationLabels = 8,
    cache            = {},      -- key -> the expensive half of the model
    page             = nil,     -- built once, never during a fight
}

function GEAR.textHeight(label)
    if label and type(label.GetStringHeight) == "function" then
        local ok, height = pcall(label.GetStringHeight, label)
        if ok and type(height) == "number" and height > 0
            and not (LT.IsSecret and LT:IsSecret(height)) then
            return height
        end
    end

    return GEAR.lineFallback
end

function GEAR.textWidth(label, fallbackText)
    if label and type(label.GetStringWidth) == "function" then
        local ok, width = pcall(label.GetStringWidth, label)
        if ok and type(width) == "number" and width > 0
            and not (LT.IsSecret and LT:IsSecret(width)) then
            return width
        end
    end

    return #tostring(fallbackText or "") * 6
end

-- One slot's worn score through exactly the scorer GearPopup:WornTotal uses,
-- so the cells add up to the total the character panel shows.
function GEAR.wornScore(slot, buildIndex)
    local gearSets = LT.GearSets
    local score = LT.Score

    if type(gearSets) ~= "table" or type(gearSets.GetEquippedLink) ~= "function" then
        return nil
    end
    if type(score) ~= "table" then return nil end

    local scorer = score.ScoreItemWithImbue or score.ScoreItem
    if type(scorer) ~= "function" then return nil end

    local okLink, link = pcall(gearSets.GetEquippedLink, gearSets, slot)
    if not okLink or type(link) ~= "string" or link == "" then return nil end
    if LT.IsSecret and LT:IsSecret(link) then return nil end

    local okScore, result = pcall(scorer, score, link, buildIndex)
    if okScore and type(result) == "table" and result.ok and tonumber(result.score) then
        return tonumber(result.score)
    end

    return nil
end

-- One tab per build slot that exists. A character with one build gets one tab;
-- the wizard's second slot adds the second. The active slot's tab is the one
-- the page is showing, and it is the raised tab in the draw below.
function GEAR.tabs(builds, active)
    local tabs = {}
    local count = tonumber(builds and builds.SLOT_COUNT) or 2
    if count < 1 then count = 1 end

    for slot = 1, count do
        local build
        if type(builds) == "table" and type(builds.Get) == "function" then
            local ok, value = pcall(builds.Get, builds, slot)
            if ok then build = value end
        end

        if build then
            tabs[#tabs + 1] = {
                index  = slot,
                label  = (slot == 1) and "Primary build" or "Offspec",
                active = (slot == active),
            }
        end
    end

    if #tabs == 0 then
        tabs[1] = { index = 1, label = "Primary build", active = true }
    end

    return tabs
end

-- The page's read-only model. Everything is taken from GearPopup, GearSets and
-- Score; this function invents no number and writes nothing.
function UI:EquipmentModel(buildIndex)
    local builds = LT.Builds
    local index = tonumber(buildIndex)

    if not index and type(builds) == "table" and type(builds.GetActiveIndex) == "function" then
        local ok, active = pcall(builds.GetActiveIndex, builds)
        if ok then index = tonumber(active) end
    end
    index = index or 1

    local slots = LT.InventorySlots
    if type(slots) ~= "table" then slots = {} end

    -- A stored active slot can point at a slot the wizard never created (old
    -- data, or slot 2 emptied). The page shows an existing slot rather than a
    -- grid with no tab selected; this reads the saved state and never writes
    -- it, so which slot is stored active is not changed behind the player.
    local tabs = GEAR.tabs(builds, index)
    local hasActiveTab = false
    for _, tab in ipairs(tabs) do
        if tab.active then hasActiveTab = true end
    end
    if not hasActiveTab and tabs[1] then
        index = tabs[1].index
        tabs = GEAR.tabs(builds, index)
    end

    local model = {
        buildIndex = index,
        tabs       = tabs,
        cells      = {},
        deltas     = {},
    }

    -- GearCheck's revision is the same cache key SummaryLine uses, so a level,
    -- a gear change or a bag change makes a new key and a stale total cannot be
    -- served. With no revision source the sums are recomputed each draw.
    local level
    local levels = LT.Levels
    if type(levels) == "table" and type(levels.GetScoringLevel) == "function" then
        local ok, value = pcall(levels.GetScoringLevel, levels)
        if ok then level = tonumber(value) end
    end

    local popup = LT.GearPopup
    local revision
    if type(popup) == "table" and type(popup.SummaryRevision) == "function" then
        local ok, value = pcall(popup.SummaryRevision, popup, index, level)
        if ok and type(value) == "string" and value ~= "" then revision = value end
    end

    local key
    if revision then
        key = tostring(index) .. "|" .. tostring(level) .. "|" .. revision
            .. "|" .. tostring(#slots)
    end

    if key and GEAR.cache.key == key and type(GEAR.cache.data) == "table" then
        local cached = GEAR.cache.data
        model.worn        = cached.worn
        model.projected   = cached.projected
        model.upgrades    = cached.upgrades
        model.cells       = cached.cells
        model.deltas      = cached.deltas
        model.scoreText   = cached.scoreText
        model.totalText   = cached.totalText
        model.unavailable = cached.unavailable
        return model
    end

    -- One cell per slot, in the order the slot list declares. The label comes
    -- from the item table, the number from the same scorer the worn total uses;
    -- an empty or unreadable slot is an em dash, never 0.0.
    for _, slot in ipairs(slots) do
        local cell = {
            slot      = slot.slot,
            label     = tostring(slot.label or ("Slot " .. tostring(slot.slot))),
            text      = "—",
            available = false,
        }

        local score = GEAR.wornScore(slot.slot, index)
        if score then
            cell.score     = score
            cell.text      = LT:FormatNumber(score, 1)
            cell.available = true
        end

        model.cells[#model.cells + 1] = cell
    end

    -- Worn total straight from GearPopup. A nil (nothing scorable) and a
    -- non-positive total both read as "no answer": 0.0 would look like a scan
    -- result, which is exactly what the player asked never to see.
    local worn
    if type(popup) == "table" and type(popup.WornTotal) == "function" then
        local ok, value = pcall(popup.WornTotal, popup, index)
        if ok then worn = tonumber(value) end
    end
    if worn and worn <= 0 then worn = nil end

    -- The scan's own rows are the only source of deltas. ProjectedTotal is the
    -- same call GearPopup:BuildSummaryLine makes, so "with these" agrees with
    -- the character panel card to the tenth.
    local entries
    if type(popup) == "table" and type(popup.Scan) == "function" then
        local okScan, result = pcall(popup.Scan, popup, { buildIndex = index })
        if okScan and type(result) == "table" and type(popup.Classify) == "function" then
            local okClass, classified = pcall(popup.Classify, popup, result)
            if okClass and type(classified) == "table" then entries = classified end
        end
    end

    local projected, upgrades = nil, 0
    if entries and type(popup) == "table" and type(popup.ProjectedTotal) == "function" then
        local okTotal, total, count = pcall(popup.ProjectedTotal, popup, worn, entries)
        if okTotal then
            projected = tonumber(total)
            upgrades = tonumber(count) or 0
        end
    end

    -- One delta per slot: the best "now" row for that slot, exactly the rows
    -- ProjectedTotal counts, so the deltas add up to projected minus worn.
    local best = {}
    for _, entry in ipairs(entries or {}) do
        if type(entry) == "table" and entry.group == "now"
            and type(entry.row) == "table" then
            local delta = tonumber(entry.row.delta)
            local slot = entry.row.slot

            if delta and slot then
                local current = best[slot]
                if not current or delta > current.delta then
                    best[slot] = { delta = delta, row = entry.row }
                end
            end
        end
    end

    for _, slot in ipairs(slots) do
        local hit = best[slot.slot]
        if hit then
            local text
            if type(popup) == "table" and type(popup.DescribeRow) == "function" then
                local ok, described = pcall(popup.DescribeRow, popup, hit.row, "now")
                if ok and type(described) == "string" and described ~= "" then
                    text = described
                end
            end

            model.deltas[#model.deltas + 1] = {
                slot  = slot.slot,
                link  = hit.row.link,
                name  = hit.row.name,
                delta = hit.delta,
                text  = text or (tostring(slot.label) .. ": "
                    .. LT:FormatSigned(hit.delta, 1)),
            }
        end
    end

    model.projected = projected
    model.upgrades = upgrades or 0

    if worn then
        local wornText = LT:FormatNumber(worn, 1)
        model.worn = worn
        model.scoreText = "LBTK " .. wornText .. " as worn"

        if model.projected and model.upgrades > 0 then
            model.totalText = wornText .. " worn, " .. LT:FormatNumber(model.projected, 1)
                .. " with these " .. tostring(model.upgrades)
                .. (model.upgrades == 1 and " upgrade" or " upgrades")
        else
            model.totalText = wornText .. " worn"
        end

        model.unavailable = false
    else
        model.unavailable = true
        model.scoreText = "LBTK — as worn"
        model.totalText = "— worn"
    end

    if key then
        GEAR.cache.key = key
        GEAR.cache.data = {
            worn        = model.worn,
            projected   = model.projected,
            upgrades    = model.upgrades,
            cells       = model.cells,
            deltas      = model.deltas,
            scoreText   = model.scoreText,
            totalText   = model.totalText,
            unavailable = model.unavailable,
        }
    end

    return model
end

-- Builds the tab strip, the 19 cells, the four totals labels, the delta lines,
-- the two controls and the preserved saved-set rows. Called once, out of
-- combat; every later draw only moves and re-texts these widgets.
function GEAR.build()
    if GEAR.page then return GEAR.page end
    if combatLocked() then return nil end

    local scroll = MakeScroll(contentFrame, "gear")
    LT.Chrome.Card(scroll)

    local pageContent = scroll.content

    -- The page places only the rows it has. Hidden delta and limitation labels
    -- keep their old bottom edges, so the generic extent walk would reserve
    -- space for a longer list that is no longer there. The draw stores the
    -- measured extent instead.
    local baseExtent = scroll.GetContentExtent
    function scroll:GetContentExtent()
        local measured = self.gearExtent
        if type(measured) == "number" and measured > 0 then return measured end
        return baseExtent(self)
    end

    local built = {
        scroll           = scroll,
        tabs             = {},
        cells            = {},
        deltaRows        = {},
        limitationLabels = {},
        savedLabels      = {},
        rightWidth       = GEAR.contentWidth - GEAR.leftWidth - GEAR.columnGap,
    }

    local function bodyLabel(size, colour, width)
        local label = MakeLabel(pageContent, "", size or "GameFontNormalSmall", colour)
        label:SetJustifyH("LEFT")
        oneLine(label)
        label:SetWidth(width or GEAR.contentWidth)
        return label
    end

    -- The page's build descriptor sits above the scroll, in the tab row: the
    -- player asked for it out from under the border and at the tabs' own size.
    -- It is created on a child frame so clearContent's label pool can never
    -- recycle it.
    built.headerFrame = CreateFrame("Frame", nil, contentFrame)
    built.description = MakeLabel(built.headerFrame, "", "GameFontNormal",
        LT.Palette:RGB("muted"))
    built.description:SetJustifyH("LEFT")
    oneLine(built.description)
    built.scoreLine     = bodyLabel("GameFontNormal", LT.Palette:RGB("text"))
    built.totalLine     = bodyLabel(nil, LT.Palette:RGB("text"))
    built.emptyNote     = bodyLabel(nil, LT.Palette:RGB("muted"))
    built.upgradeHeading = bodyLabel(nil, LT.Palette:RGB("brand"))
    built.savedHeading  = bodyLabel(nil, LT.Palette:RGB("brand"))

    local slots = type(LT.InventorySlots) == "table" and LT.InventorySlots or {}

    -- The 19 cells: one frame each, with the slot name on the left and its worn
    -- score on the right. The height is measured from the real font strings, so
    -- a taller client font gets taller cells instead of overlapping text.
    for _, slot in ipairs(slots) do
        local cell = CreateFrame("Frame", nil, pageContent)
        cell:SetSize(GEAR.cellWidth, GEAR.rowFallback)
        cardChrome(cell, {
            edge = LT.Palette.chrome.cardEdge,
            fill = LT.Palette.chrome.buttonBg,
        })

        local name = MakeLabel(cell, "", "GameFontNormalSmall", LT.Palette:RGB("muted"))
        name:SetPoint("LEFT", 26, 0)
        name:SetJustifyH("LEFT")
        oneLine(name)
        name:SetWidth(GEAR.cellWidth - 70)

        -- The worn item's own art, with the client's tooltip on hover. The link
        -- is stored on the cell frame by the draw, so the hover never has to ask
        -- a question the page has already answered.
        local icon = cell.CreateTexture and cell:CreateTexture(nil, "ARTWORK")
        if icon then
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", 6, 0)
            icon:Hide()
        end

        if type(cell.EnableMouse) == "function" then pcall(cell.EnableMouse, cell, true) end
        if type(cell.SetScript) == "function" then
            pcall(cell.SetScript, cell, "OnEnter", function(self)
                local popup = LT.GearPopup
                if type(popup) == "table" and type(popup.ShowItemTooltip) == "function"
                    and type(self.__ltLink) == "string" then
                    pcall(popup.ShowItemTooltip, popup, self, self.__ltLink)
                end
            end)
            pcall(cell.SetScript, cell, "OnLeave", function()
                if GameTooltip and type(GameTooltip.Hide) == "function" then
                    pcall(GameTooltip.Hide, GameTooltip)
                end
            end)
        end

        local score = MakeLabel(cell, "", "GameFontNormalSmall", LT.Palette:RGB("text"))
        score:SetPoint("RIGHT", -6, 0)
        score:SetJustifyH("RIGHT")
        oneLine(score)
        score:SetWidth(40)

        built.cells[slot.slot] = { frame = cell, name = name, score = score, icon = icon }
    end

    local measured = GEAR.rowFallback
    for _, cell in pairs(built.cells) do
        cell.name:SetText("Ag")
        cell.score:SetText("0.0")
        measured = math.max(measured, GEAR.textHeight(cell.name), GEAR.textHeight(cell.score))
        cell.name:SetText("")
        cell.score:SetText("")
    end

    built.cellHeight = math.max(GEAR.rowFallback, math.floor(measured + 6))
    for _, cell in pairs(built.cells) do
        cell.frame:SetHeight(built.cellHeight)
    end

    -- One label per possible upgrade and per preserved saved row. They are
    -- hidden when the section has nothing to say, so an empty list draws no
    -- heading and no blank lines.
    -- One row per possible upgrade: the item's icon, its sentence, a tooltip on
    -- hover and a click that equips it. The row is a frame rather than a bare font
    -- string because a label cannot take a click.
    for index = 1, math.max(#slots, 1) do
        local row = CreateFrame("Frame", nil, pageContent)
        row:SetSize(built.rightWidth, 16)

        local icon = row.CreateTexture and row:CreateTexture(nil, "ARTWORK")
        if icon then
            icon:SetSize(14, 14)
            icon:SetPoint("LEFT", 0, 0)
            icon:Hide()
        end

        local label = MakeLabel(row, "", "GameFontNormalSmall", LT.Palette:RGB("text"))
        label:SetPoint("LEFT", 20, 0)
        label:SetJustifyH("LEFT")
        oneLine(label)
        label:SetWidth(built.rightWidth - 20)

        if type(row.EnableMouse) == "function" then pcall(row.EnableMouse, row, true) end
        if type(row.SetScript) == "function" then
            pcall(row.SetScript, row, "OnEnter", function(self)
                local popup = LT.GearPopup
                if type(popup) == "table" and type(popup.ShowItemTooltip) == "function"
                    and type(self.__ltLink) == "string" then
                    pcall(popup.ShowItemTooltip, popup, self, self.__ltLink)
                end
            end)
            pcall(row.SetScript, row, "OnLeave", function()
                if GameTooltip and type(GameTooltip.Hide) == "function" then
                    pcall(GameTooltip.Hide, GameTooltip)
                end
            end)
            pcall(row.SetScript, row, "OnMouseUp", function(self)
                local popup = LT.GearPopup
                if type(popup) ~= "table" or type(popup.Equip) ~= "function" then return end
                if type(self.__ltLink) ~= "string" then return end

                local ok, why = popup:Equip(self.__ltLink, self.__ltSlot)
                if ok then
                    LT:Print("Equipped " .. tostring(self.__ltName or "the item") .. ".")
                else
                    LT:Print("Could not equip: " .. tostring(why) .. ".")
                end
                UI:Refresh()
            end)
        end

        built.deltaRows[index] = { frame = row, icon = icon, label = label }
    end

    for index = 1, math.max(#slots, 1) do
        built.savedLabels[index] = bodyLabel(nil, LT.Palette:RGB("text"))
    end

    for index = 1, GEAR.limitationLabels do
        built.limitationLabels[index] = bodyLabel(nil, LT.Palette:RGB("caution"))
    end

    -- The page keeps its save control. The old "Switch active slot" button is
    -- gone: the same switch is the Spec toggle in the title band, and two
    -- controls for one action is what the player called redundant.
    built.saveButton = MakeButton(pageContent, "Save equipped set",
        GEAR.buttonWidth, 20, function()
            local index = LT.Builds:GetActiveIndex()
            local snapshot, err = LT.GearSets:Save(index, { reason = "UI" })
            if not snapshot then LT:Error(err) else LT:Print("Equipment set saved.") end
            UI:Refresh()
        end)

    -- One tab for every slot the build module can hold; a slot with no build is
    -- hidden by the draw, so a single-build character still sees one tab.
    local count = tonumber(LT.Builds and LT.Builds.SLOT_COUNT) or 2
    for slot = 1, math.max(1, count) do
        built.tabs[slot] = MakePageTab(contentFrame, "Slot " .. tostring(slot),
            function()
                if LT.Builds:GetActiveIndex() == slot then return end
                LT.Builds:SetActive(slot)
                UI:Refresh()
            end)
    end

    GEAR.page = built
    return built
end

local function drawGear(cursor)
    -- Ask for the end-of-fight redraw before anything else: a page opened for
    -- the first time during a fight has nothing to build, and this registration
    -- is what brings it back when the fight ends.
    watchRegen()

    local page = GEAR.page or GEAR.build()

    -- Never build a protected frame in combat. If the page already exists,
    -- drawing it again only moves and re-texts widgets that are already there.
    if not page then
        cursor.y = 0
        return
    end

    local model = UI:EquipmentModel()

    local textColour = LT.Palette:RGB("text")
    local mutedColour = LT.Palette:RGB("muted")
    local brandColour = LT.Palette:RGB("brand")
    local cautionColour = LT.Palette:RGB("caution")

    local function hide(widget)
        if widget then widget:Hide() end
    end

    -- Slot tabs. They use the window's own tab widget and selected style, so
    -- the viewed slot is the raised tab with the light edge and bright label.
    local tabX = 0
    local tabHeight = 0
    local shown = {}
    for _, tabInfo in ipairs(model.tabs) do shown[tabInfo.index] = tabInfo end

    for slot = 1, #page.tabs do
        local tab = page.tabs[slot]
        if tab then
            if shown[slot] then
                tab:SetParent(contentFrame)
                tab:SetSelected(shown[slot].active == true)

                local width = math.max(80,
                    math.floor(GEAR.textWidth(tab.label, "Slot " .. tostring(slot)) + 24))
                tab:SetWidth(width)
                tab:ClearAllPoints()
                tab:SetPoint("BOTTOMLEFT", contentFrame, "TOPLEFT", tabX,
                    cursor.y - TAB.heightSelected)
                tab:Show()

                tabX = tabX + width + TAB.gap

                local height = tab:GetHeight() or TAB.heightIdle
                if height > tabHeight then tabHeight = height end
            else
                hide(tab)
            end
        end
    end

    if tabHeight < 1 then tabHeight = TAB.heightIdle end
    -- The tab row's top edge, for anything that must sit in line with the tabs.
    local tabRowY = cursor.y - TAB.heightSelected + tabHeight
    cursor.y = cursor.y - tabHeight - 8

    local scroll = page.scroll
    scroll:SetParent(contentFrame)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", 0, cursor.y)
    scroll:SetPoint("BOTTOMRIGHT", 0, 0)
    scroll:Show()

    -- This page has claimed the window's single scrollbar for this draw.
    activeScroll = scroll

    local pageContent = scroll.content
    local leftX = 0
    local rightX = GEAR.leftWidth + GEAR.columnGap
    local rightWidth = page.rightWidth
    local cells = {}

    -- The left grid and the right column start on the same line, so the page
    -- really is two halves: the character-sheet slots on the left, all text and
    -- the score on the right.
    local gridTop = 0

    for _, cell in ipairs(model.cells) do cells[cell.slot] = cell end

    -- The left half, arranged like the character sheet: ten cells down the
    -- first column, nine down the second. Each cell shows its slot name and its
    -- worn score; an unavailable score is a muted em dash.
    local gridHeight = 0
    for column = 1, #GEAR.columns do
        local x = leftX + (column - 1) * (GEAR.cellWidth + GEAR.cellGap)
        local row = 0

        for _, slotNumber in ipairs(GEAR.columns[column]) do
            local widget = page.cells[slotNumber]
            local cell = cells[slotNumber]

            if widget then
                if cell then
                    widget.frame:SetParent(pageContent)
                    widget.frame:ClearAllPoints()
                    widget.frame:SetPoint("TOPLEFT", x,
                        gridTop - row * (page.cellHeight + GEAR.rowGap))

                    widget.name:SetText(cell.label)
                    widget.name:SetTextColor(mutedColour.r, mutedColour.g, mutedColour.b)
                    widget.score:SetText(cell.text)

                    -- The worn item's art and its link for the hover. Both are
                    -- read here, once per draw, and stay on the cell.
                    local link
                    if type(LT.GearSets) == "table"
                        and type(LT.GearSets.GetEquippedLink) == "function" then
                        local okLink, found = pcall(LT.GearSets.GetEquippedLink,
                            LT.GearSets, cell.slot)
                        if okLink and type(found) == "string" and found ~= "" then link = found end
                    end
                    widget.frame.__ltLink = link

                    if widget.icon then
                        local texture
                        if link and type(LT.ItemStats) == "table"
                            and type(LT.ItemStats.GetIdentity) == "function" then
                            local okId, identity = pcall(LT.ItemStats.GetIdentity, LT.ItemStats, link)
                            if okId and type(identity) == "table" then texture = identity.texture end
                        end
                        if texture then
                            pcall(widget.icon.SetTexture, widget.icon, texture)
                            widget.icon:Show()
                        else
                            widget.icon:Hide()
                        end
                    end

                    local colour = cell.available and textColour or mutedColour
                    widget.score:SetTextColor(colour.r, colour.g, colour.b)
                    widget.frame:Show()
                else
                    hide(widget.frame)
                end
            end

            row = row + 1
        end

        local height = row * (page.cellHeight + GEAR.rowGap)
        if height > gridHeight then gridHeight = height end
    end

    -- The right half: the overall LBTK score, the worn and projected totals,
    -- then the per-slot deltas the scan found.
    local rightY = gridTop

    local function rightLine(widget, text, colour, gap)
        if not widget then return end

        widget:SetText(text or "")
        if colour then widget:SetTextColor(colour.r, colour.g, colour.b) end
        widget:ClearAllPoints()
        widget:SetPoint("TOPLEFT", rightX, rightY)
        widget:SetWidth(rightWidth)
        widget:Show()
        rightY = rightY - GEAR.textHeight(widget) - (gap or 4)
    end

    -- The build this page is scoring, at the tab row and at the tabs' own size,
    -- above the scroll's border and clear of it.
    page.headerFrame:ClearAllPoints()
    page.headerFrame:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", tabX + 10, tabRowY)
    page.headerFrame:SetSize(math.max(160, (contentFrame:GetWidth() or 600) - tabX - 24),
        tabHeight)

    page.description:SetText(LT.Builds:Describe(model.buildIndex))
    page.description:SetTextColor(mutedColour.r, mutedColour.g, mutedColour.b)
    page.description:ClearAllPoints()
    page.description:SetPoint("LEFT", page.headerFrame, "LEFT", 0, 0)
    page.description:SetWidth(math.max(160, (contentFrame:GetWidth() or 600) - tabX - 24))
    page.description:Show()

    page.saveButton:SetParent(pageContent)
    page.saveButton:ClearAllPoints()
    page.saveButton:SetPoint("TOPLEFT", rightX, rightY)
    page.saveButton:Show()
    rightY = rightY - 26

    rightLine(page.scoreLine, model.scoreText, textColour, 6)
    rightLine(page.totalLine, model.totalText, textColour, 8)

    if model.unavailable then
        rightLine(page.emptyNote,
            "No worn item could be scored, so there is no total to report.",
            mutedColour, 6)
    else
        hide(page.emptyNote)
    end

    if #model.deltas > 0 then
        rightLine(page.upgradeHeading, "Upgrades found — click one to equip it",
            brandColour, 4)

        for index = 1, #page.deltaRows do
            local widget = page.deltaRows[index]
            local delta = model.deltas[index]

            if delta then
                widget.label:SetText(delta.text)
                widget.label:SetTextColor(textColour.r, textColour.g, textColour.b)

                widget.frame.__ltLink = delta.link
                widget.frame.__ltSlot = delta.slot
                widget.frame.__ltName = delta.name

                if widget.icon then
                    local texture
                    if delta.link and type(LT.ItemStats) == "table"
                        and type(LT.ItemStats.GetIdentity) == "function" then
                        local okId, identity = pcall(LT.ItemStats.GetIdentity,
                            LT.ItemStats, delta.link)
                        if okId and type(identity) == "table" then texture = identity.texture end
                    end
                    if texture then
                        pcall(widget.icon.SetTexture, widget.icon, texture)
                        widget.icon:Show()
                    else
                        widget.icon:Hide()
                    end
                end

                widget.frame:ClearAllPoints()
                widget.frame:SetPoint("TOPLEFT", rightX, rightY)
                widget.frame:SetWidth(rightWidth)
                widget.frame:SetHeight(math.max(16, GEAR.textHeight(widget.label) + 2))
                widget.frame:Show()
                rightY = rightY - (widget.frame:GetHeight() or 16) - 2
            else
                hide(widget.frame)
            end
        end
    else
        hide(page.upgradeHeading)
        for _, widget in ipairs(page.deltaRows) do hide(widget.frame) end
    end

    -- Anything below the two halves starts under the taller of them.
    local gridBottom = gridTop - gridHeight
    local bottom = math.min(gridBottom, rightY) - 12

    local status
    if type(LT.GearSets) == "table" and type(LT.GearSets.GetStatus) == "function" then
        local ok, value = pcall(LT.GearSets.GetStatus, LT.GearSets, model.buildIndex)
        if ok and type(value) == "table" then status = value end
    end

    local limitations = (status and type(status.limitations) == "table")
        and status.limitations or {}

    for index = 1, #page.limitationLabels do
        local label = page.limitationLabels[index]
        local text = limitations[index]

        if text then
            label:SetText(text)
            label:SetTextColor(cautionColour.r, cautionColour.g, cautionColour.b)
            label:ClearAllPoints()
            label:SetPoint("TOPLEFT", 0, bottom)
            label:Show()
            bottom = bottom - GEAR.textHeight(label) - 4
        else
            hide(label)
        end
    end

    -- The per-slot saved-set rows the page already had. They are kept, below the
    -- two halves, and drawn only when the slot really has a saved set, so the
    -- section is absent rather than a list of "none" before Save is pressed.
    local hasSnapshot = false
    if type(LT.GearSets) == "table" and type(LT.GearSets.HasSnapshot) == "function" then
        local ok, value = pcall(LT.GearSets.HasSnapshot, LT.GearSets, model.buildIndex)
        hasSnapshot = ok and value == true
    end

    if hasSnapshot then
        page.savedHeading:SetText("Saved set")
        page.savedHeading:SetTextColor(brandColour.r, brandColour.g, brandColour.b)
        page.savedHeading:ClearAllPoints()
        page.savedHeading:SetPoint("TOPLEFT", 0, bottom)
        page.savedHeading:Show()
        bottom = bottom - GEAR.textHeight(page.savedHeading) - 4

        local savedIndex = 0
        for _, slot in ipairs(LT.InventorySlots or {}) do
            if not slot.cosmetic and page.savedLabels[savedIndex + 1] then
                savedIndex = savedIndex + 1

                local row
                if type(LT.GearSets.GetRow) == "function" then
                    local ok, value = pcall(LT.GearSets.GetRow, LT.GearSets,
                        model.buildIndex, slot.slot)
                    if ok then row = value end
                end

                local current
                if type(LT.GearSets.GetEquippedLink) == "function" then
                    local ok, value = pcall(LT.GearSets.GetEquippedLink, LT.GearSets,
                        slot.slot)
                    if ok then current = value end
                end

                local text = tostring(slot.label) .. ": "

                if current then
                    local name = "equipped"
                    if type(LT.ItemStats) == "table"
                        and type(LT.ItemStats.GetIdentity) == "function" then
                        local ok, identity = pcall(LT.ItemStats.GetIdentity,
                            LT.ItemStats, current)
                        if ok and type(identity) == "table"
                            and type(identity.name) == "string" then
                            name = identity.name
                        end
                    end
                    text = text .. name
                else
                    text = text .. LT.Palette:Wrap("muted", "empty")
                end

                text = text .. "   " .. LT.Palette:Wrap("muted", "saved:") .. " "

                if row and row.link then
                    local name = "item"
                    if type(LT.ItemStats) == "table"
                        and type(LT.ItemStats.GetIdentity) == "function" then
                        local ok, identity = pcall(LT.ItemStats.GetIdentity,
                            LT.ItemStats, row.link)
                        if ok and type(identity) == "table"
                            and type(identity.name) == "string" then
                            name = identity.name
                        end
                    end
                    text = text .. name .. " ("
                        .. (row.score and LT:FormatNumber(row.score, 1) or "n/a") .. ")"
                elseif row and row.expectedEmpty then
                    text = text .. "not used by this weapon setup"
                else
                    text = text .. "none"
                end

                local label = page.savedLabels[savedIndex]
                label:SetText(text)
                label:SetTextColor(textColour.r, textColour.g, textColour.b)
                label:ClearAllPoints()
                label:SetPoint("TOPLEFT", 0, bottom)
                label:Show()
                bottom = bottom - GEAR.textHeight(label) - 2
            end
        end

        for index = savedIndex + 1, #page.savedLabels do
            hide(page.savedLabels[index])
        end
    else
        hide(page.savedHeading)
        for _, label in ipairs(page.savedLabels) do hide(label) end
    end

    -- The measured height of everything actually placed, so a section that is
    -- not drawn leaves no hole at the bottom of the scroll.
    scroll.gearExtent = math.max(1, -bottom + 8)
    cursor.y = bottom
end

------------------------------------------------------------------------------
-- Page: Caps
------------------------------------------------------------------------------

local function drawCaps(cursor, host)
    host = host or contentFrame
    local buildIndex = LT.Builds:GetActiveIndex()
    local profile = LT.Profiles:ResolveForBuild(buildIndex)

    local header = MakeLabel(host, LT.Builds:Describe(buildIndex) .. " — "
        .. LT.Levels:DescribeScoringLevel(), "GameFontNormal")
    header:SetPoint("TOPLEFT", 4, cursor.y)
    cursor.y = cursor.y - 24

    if not profile then
        local label = MakeLabel(host, "No profile for the active slot.", "GameFontNormal")
        label:SetPoint("TOPLEFT", 4, cursor.y)
        return
    end

    local capture = MakeButton(host, "Measure rating conversion now", 220, 20, function()
        LT.Levels:CaptureAndReport()
        UI:Refresh()
    end)
    capture:SetPoint("TOPLEFT", 4, cursor.y)
    cursor.y = cursor.y - 28

    -- A switch is only drawn where pressing it would do something. SetCap writes
    -- one field of a custom, unlocked profile and refuses everything else, so the
    -- page asks the same question first and shows the state as text instead of a
    -- button that would answer "only custom profiles can be edited".
    local editable = false
    if type(LT.Profiles.GetCustomTable) == "function" then
        local okTable, custom = pcall(LT.Profiles.GetCustomTable, LT.Profiles)
        local stored = okTable and type(custom) == "table" and custom[profile.key] or nil
        editable = type(stored) == "table" and stored.locked ~= true
    end

    if not editable then
        local note = MakeLabel(host,
            "This profile is read-only, so the switches below are shown as text. "
                .. "A custom profile unlocked on the Profiles page can be changed here.",
            "GameFontNormalSmall", LT.Palette:RGB("muted"))
        note:SetPoint("TOPLEFT", 4, cursor.y)
        note:SetWidth(600)
        note:SetJustifyH("LEFT")
        cursor.y = cursor.y - (note:GetStringHeight() or 12) - 6
    end

    local scroll = MakeScroll(host)
    scroll:SetPoint("TOPLEFT", 0, cursor.y)
    local content = scroll.content
    local y = 0

    for _, row in ipairs(LT.Caps:GetReport(profile, LT.Levels:GetScoringLevel())) do
        local definition = LT.Caps:GetDefinition(profile, row.stat)
        local importance = tonumber(definition and definition.importance) or 0

        local state
        if not row.enabled then
            state = "off"
        elseif row.measured == false then
            state = row.measuredLabel or "not measured yet"
        elseif row.known then
            state = row.capped and "met" or "not met"
        else
            state = "state unknown"
        end

        local text
        if row.enabled and row.measured == false then
            -- One collapsed state instead of a target nobody can measure yet.
            text = row.label .. " — " .. (row.measuredLabel or "not measured yet")
        else
            text = row.label .. " — target "
                .. LT:FormatNumber(row.target, 2) .. (row.kind == "percent" and "%" or "")

            if row.targetRating then
                text = text .. " = " .. LT:FormatNumber(row.targetRating, 1)
                    .. " rating at level " .. tostring(LT.Levels:GetScoringLevel())
            elseif row.ratingUnavailable then
                text = text .. " — rating equivalent unavailable"
            end

            if row.currentRating then
                text = text .. ", current " .. LT:FormatNumber(row.currentRating, 0) .. " rating"
            end
        end

        text = text .. "  [" .. state .. "]  priority " .. LT:FormatNumber(
            row.enabled and row.target and importance or 0, 2)

        -- The build's own recommendation, as a word rather than a slider: there
        -- is no per-stat reference line in the data, and a slider with no mark on
        -- it would be a fake. The priority number beside it is what the score
        -- multiplies by, so the two cannot disagree. Brand rather than green:
        -- green already means "cap met" on this page.
        if row.enabled and importance > 0 then
            text = text .. "  " .. LT.Palette:Wrap("brand", "[recommended by this build]")
        end

        -- Decision 5: show adjustment sources if any
        if row.adjustmentSources and #row.adjustmentSources > 0 then
            text = text .. " " .. LT.Palette:Wrap("muted",
                "(adjusted: " .. table.concat(row.adjustmentSources, "; ") .. ")")
        end

        local labelX = 4

        if editable then
            local toggle = MakeCheck(content, row.enabled == true, function(value)
                local okSet, err = LT.Profiles:SetCap(profile.key, row.stat, "enabled", value)
                if not okSet and err then LT:Warn(err) end
                UI:Refresh()
            end)
            toggle:SetPoint("TOPLEFT", 4, y - 1)
            labelX = 28
        end

        local label = MakeLabel(content, text, "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", labelX, y)
        label:SetWidth(600 - (labelX - 4))
        label:SetJustifyH("LEFT")
        y = y - ((label:GetStringHeight() or 12) + 4)

        for _, limitation in ipairs(row.limitations or {}) do
            local dim = MakeLabel(content, "    " .. limitation, "GameFontNormalSmall",
                LT.Palette:RGB("muted"))
            dim:SetPoint("TOPLEFT", labelX, y)
            dim:SetWidth(590 - (labelX - 4))
            dim:SetJustifyH("LEFT")
            y = y - (dim:GetStringHeight() or 12) - 2
        end

        if row.ratingUnavailable then
            local dim = MakeLabel(content, "    " .. tostring(row.ratingUnavailable),
                "GameFontNormalSmall", LT.Palette:RGB("muted"))
            dim:SetPoint("TOPLEFT", labelX, y)
            dim:SetWidth(590 - (labelX - 4))
            dim:SetJustifyH("LEFT")
            y = y - (dim:GetStringHeight() or 12) - 2
        end
    end

    local note = MakeLabel(content,
        "A score or rating difference is not a prediction of damage, healing or survival.",
        "GameFontNormalSmall", LT.Palette:RGB("muted"))
    note:SetPoint("TOPLEFT", 4, y)
    note:SetWidth(590)
    note:SetJustifyH("LEFT")
end

------------------------------------------------------------------------------
-- Plugin commands popup
--
-- One plugin at a time, one slash command per row, and the help for a row lives
-- on hover and on its "?" so the list stays one line per command. A plugin may
-- publish its own list by setting `plugin.commands` on the table
-- PluginAPI:RegisterPlugin returned; that list is read first. The map below is
-- the fallback for the bundled plugins, whose commands are already registered
-- through Slash:RegisterCommand. Nothing on this page runs a command.
--
-- The frame is created on the first open and only outside combat. Its height is
-- measured from the labels after their text exists and capped to the screen,
-- with the rows inside a scroll area when a future plugin declares long list.
------------------------------------------------------------------------------

local PLUGIN_COMMANDS_WIDTH  = 460
------------------------------------------------------------------------------
-- Best setup page
--
-- One row per weapon configuration this character could actually wear, each
-- showing the single best pair available right now: worn items and bags, never
-- the bank. All the choosing is BestSetup.lua's; this only draws its answer.
--
-- The proficiency table below the pairs is T-133: Usability:ListProficiency
-- answers "known / learnable / never" from the class pack and the client's own
-- proficiency check, and this page paints it. The colours are the ticket's:
-- green learnt, yellow learnable, red never. A red row names no city, so the
-- page can never send a player to a trainer who will refuse them.
------------------------------------------------------------------------------

local function drawSetup(cursor)
    local muted = LT.Palette:RGB("muted")
    local text = LT.Palette:RGB("text")
    local brand = LT.Palette:RGB("brand")
    local stop = LT.Palette:RGB("stop")

    -- The proficiency table (T-133), drawn at startY, returns the y below it.
    -- Every client-facing lookup sits behind Usability, where
    -- KnowsProficiency/ResolvesSpell are pcall'd; a missing module or a failed
    -- call simply draws no table. Kept inside the page drawer because the main
    -- chunk is already at the Lua 5.1 local-variable ceiling.
    local function drawProficiency(parent, startY)
        local usability = LT.Usability
        if type(usability) ~= "table" or type(usability.ListProficiency) ~= "function" then
            return startY
        end

        local ok, entries = pcall(usability.ListProficiency, usability)
        if not ok or type(entries) ~= "table" or #entries == 0 then
            return startY
        end

        local classToken = LT.player and LT.player.class
        local className = tostring(classToken or "class")

        if type(LT.ClassData) == "table" and type(LT.ClassData.GetClassName) == "function" then
            local okName, name = pcall(LT.ClassData.GetClassName, LT.ClassData, classToken)
            if okName and type(name) == "string" and name ~= "" then
                className = name
            end
        end

        local colourFor = {
            known     = LT.Palette:RGB("caution"), -- green: the skill is trained
            learnable = LT.Palette:RGB("special"), -- yellow: still to be learned
            never     = LT.Palette:RGB("unknown"), -- red: the class can never use it
        }

        local y = startY

        local heading = MakeLabel(parent,
            "Weapon proficiency — what this character can train", "GameFontNormal",
            LT.Palette:RGB("brand"))
        heading:SetPoint("TOPLEFT", 4, y)
        y = y - 22

        for _, entry in ipairs(entries) do
            local label = tostring(entry.label or entry.kind or "?")
            local state = entry.state
            local trainer = entry.trainer
            local line

            if state == "never" then
                line = label .. " — not a " .. className .. " weapon"
            elseif state == "known" then
                line = label .. " — known"
            elseif type(trainer) == "table" and type(trainer.name) == "string"
                and trainer.name ~= "" then
                line = label .. " — " .. trainer.name
                if type(trainer.zone) == "string" and trainer.zone ~= "" then
                    line = line .. ", " .. trainer.zone
                end
            else
                line = label .. " — not trained yet"
            end

            local colour = colourFor[state] or LT.Palette:RGB("text")
            local row = MakeLabel(parent, line, "GameFontNormalSmall", colour)
            row:SetPoint("TOPLEFT", 12, y)
            row:SetWidth(580)
            row:SetJustifyH("LEFT")
            y = y - ((row:GetStringHeight() or 12) + 3)
        end

        return y
    end

    local header = MakeLabel(contentFrame, "Best setup available to this character",
        "GameFontNormal")
    header:SetPoint("TOPLEFT", 4, cursor.y)
    cursor.y = cursor.y - 22

    local best = LT.BestSetup
    if type(best) ~= "table" or type(best.Compute) ~= "function" then
        local missing = MakeLabel(contentFrame, "The best-setup module is not loaded.",
            "GameFontNormalSmall", stop)
        missing:SetPoint("TOPLEFT", 4, cursor.y)
        drawProficiency(contentFrame, cursor.y - 16)
        return
    end

    local result, reason = best:Compute(LT.Builds:GetActiveIndex())
    if not result then
        local why = (reason == "combat")
            and "Not while you are in a fight: the client will not read items in combat. "
                .. "Open this page again after the fight."
            or ("Not available: " .. tostring(reason))
        local label = MakeLabel(contentFrame, why, "GameFontNormalSmall", muted)
        label:SetPoint("TOPLEFT", 4, cursor.y)
        label:SetWidth(600)
        label:SetJustifyH("LEFT")
        drawProficiency(contentFrame, cursor.y - (label:GetStringHeight() or 12) - 14)
        return
    end

    local intro = MakeLabel(contentFrame,
        LT.Builds:Describe(result.buildIndex) .. " — " .. tostring(result.candidates)
            .. " usable item(s) among what is worn and in the bags",
        "GameFontNormalSmall", muted)
    intro:SetPoint("TOPLEFT", 4, cursor.y)
    intro:SetWidth(600)
    intro:SetJustifyH("LEFT")
    cursor.y = cursor.y - 3 - (intro:GetStringHeight() or 12) - 6

    local scroll = MakeScroll(contentFrame)
    scroll:SetPoint("TOPLEFT", 0, cursor.y)
    local content = scroll.content
    local y = 0

    local ROW_HEIGHT = 30
    local SCORE_X, SCORE_W = 2, 54
    local LABEL_X, LABEL_W = 60, 150
    local ICON2_X, NAME2_X, NAME2_W = 214, 236, 118
    local SCORE2_X = 358
    local ICON3_X, NAME3_X, NAME3_W = 404, 426, 106
    local SCORE3_X = 536
    local DELTA_X, DELTA_W = 578, 40
    local stripes = 0

    local panelBg = LT.Palette.chrome and LT.Palette.chrome.panelBg
    local railBg = LT.Palette.chrome and LT.Palette.chrome.railBg

    -- One row: a striped background, the total on the left, then icon + name +
    -- score per hand, then the delta against what is equipped. Icons carry the
    -- client's own item tooltip, so nothing about an item is copied in here.
    local function rowLine(height)
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(620, height or ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 0, y)

        local colour = ((stripes % 2) == 0) and panelBg or railBg
        if colour and row.CreateTexture then
            local fill = row:CreateTexture(nil, "BACKGROUND")
            fill:SetAllPoints(row)
            pcall(fill.SetColorTexture, fill, colour[1], colour[2], colour[3], 0.55)
        end
        stripes = stripes + 1
        return row
    end

    local function iconAt(row, x, entry)
        if not entry or not entry.link then return end

        local holder = CreateFrame("Frame", nil, row)
        holder:SetSize(18, 18)
        holder:SetPoint("LEFT", row, "LEFT", x, 0)
        holder:EnableMouse(true)

        local texture = holder.CreateTexture and holder:CreateTexture(nil, "ARTWORK")
        if texture then
            texture:SetAllPoints(holder)
            if entry.icon and texture.SetTexture then pcall(texture.SetTexture, texture, entry.icon) end
        end

        holder:SetScript("OnEnter", function(self)
            local popup = LT.GearPopup
            if type(popup) == "table" and type(popup.ShowItemTooltip) == "function" then
                pcall(popup.ShowItemTooltip, popup, self, entry.link)
            end
        end)
        holder:SetScript("OnLeave", function()
            if GameTooltip and type(GameTooltip.Hide) == "function" then
                pcall(GameTooltip.Hide, GameTooltip)
            end
        end)
    end

    local function itemText(row, nameX, nameW, scoreX, entry)
        local name = MakeLabel(row, tostring(entry and entry.name or "—"),
            "GameFontNormalSmall", text)
        name:SetPoint("LEFT", row, "LEFT", nameX, 0)
        name:SetWidth(nameW)
        name:SetWordWrap(false)
        name:SetJustifyH("LEFT")

        if entry and entry.score then
            local score = MakeLabel(row, LT:FormatNumber(entry.score, 1),
                "GameFontNormalSmall", muted)
            score:SetPoint("LEFT", row, "LEFT", scoreX, 0)
            score:SetWidth(42)
            score:SetJustifyH("LEFT")
        end
    end

    -- Equipped now, above the sets, in the same columns as a card: the score on
    -- the left, the label, then the pair. Every card below is read against it.
    local worn = result.worn or {}
    do
        local row = rowLine()

        local value = MakeLabel(row, LT:FormatNumber(worn.total or 0, 1),
            "GameFontNormal", text)
        value:SetPoint("LEFT", row, "LEFT", SCORE_X, 0)
        value:SetWidth(SCORE_W)
        value:SetJustifyH("RIGHT")

        local label = MakeLabel(row, "Worn now", "GameFontNormalSmall", brand)
        label:SetPoint("LEFT", row, "LEFT", LABEL_X, 0)
        label:SetWidth(LABEL_W)

        if worn.main then
            iconAt(row, ICON2_X, worn.main)
            itemText(row, NAME2_X, NAME2_W, SCORE2_X, worn.main)
        else
            local empty = MakeLabel(row, "main hand empty", "GameFontNormalSmall", muted)
            empty:SetPoint("LEFT", row, "LEFT", ICON2_X, 0)
        end

        if worn.off then
            iconAt(row, ICON3_X, worn.off)
            itemText(row, NAME3_X, NAME3_W, SCORE3_X, worn.off)
        end

        y = y - (ROW_HEIGHT + 6)
    end

    for _, style in ipairs(result.styles) do
        local isBest = style.available and result.best == style.key
        local row = rowLine()

        local value = MakeLabel(row, style.available and LT:FormatNumber(style.total, 1) or "—",
            "GameFontNormal", style.available and (isBest and brand or text) or muted)
        value:SetPoint("LEFT", row, "LEFT", SCORE_X, 0)
        value:SetWidth(SCORE_W)
        value:SetJustifyH("RIGHT")

        local label = MakeLabel(row, tostring(style.label) .. (isBest and " · best" or ""),
            "GameFontNormalSmall", style.available and (isBest and brand or text) or muted)
        label:SetPoint("LEFT", row, "LEFT", LABEL_X, 0)
        label:SetWidth(LABEL_W)
        label:SetWordWrap(false)
        label:SetJustifyH("LEFT")

        if style.available then
            iconAt(row, ICON2_X, style.main)
            itemText(row, NAME2_X, NAME2_W, SCORE2_X, style.main)
            if style.off then
                iconAt(row, ICON3_X, style.off)
                itemText(row, NAME3_X, NAME3_W, SCORE3_X, style.off)
            end

            -- Click the row to wear that pair. The client does the equipping, the
            -- replaced item stays in the bags, and combat is refused by
            -- GearPopup:Equip rather than here.
            if type(row.EnableMouse) == "function" then pcall(row.EnableMouse, row, true) end
            if type(row.SetScript) == "function" then
                pcall(row.SetScript, row, "OnMouseUp", function()
                    local popup = LT.GearPopup
                    if type(popup) ~= "table" or type(popup.Equip) ~= "function" then return end

                    local okMain, whyMain = popup:Equip(style.main.link, 16)
                    if not okMain then
                        LT:Print("Could not equip: " .. tostring(whyMain) .. ".")
                        return
                    end

                    if style.off then
                        local okOff, whyOff = popup:Equip(style.off.link, 17)
                        if not okOff then
                            LT:Print("Main hand equipped; off hand failed: "
                                .. tostring(whyOff) .. ".")
                        end
                    end

                    LT:Print("Equipped " .. tostring(style.label) .. ".")
                    UI:Refresh()
                end)
            end
        else
            local why = MakeLabel(row, tostring(style.reason or "not available"),
                "GameFontNormalSmall", muted)
            why:SetPoint("LEFT", row, "LEFT", ICON2_X, 0)
            why:SetWidth(340)
            why:SetWordWrap(false)
        end

        if style.available and worn.total and worn.total > 0 then
            local delta = style.total - worn.total
            -- StatusColour returns a hex string for chat codes; a label needs the
            -- RGB table. Passing the string is what raised
            -- "bad argument #1 to SetTextColor" on 2026-11-04.
            local colour = muted
            if delta > 0 then colour = LT.Palette:RGB("caution") end
            local line = MakeLabel(row, LT:FormatSigned(delta, 1), "GameFontNormalSmall", colour)
            line:SetPoint("LEFT", row, "LEFT", DELTA_X, 0)
            line:SetWidth(DELTA_W)
            line:SetJustifyH("RIGHT")
        end

        y = y - (ROW_HEIGHT + 2)
    end

    local footer = MakeLabel(content,
        "Worn and bagged items only; the bank is never read. Hover an icon for the "
            .. "client's own tooltip. Click a row to wear that pair - the item it "
            .. "replaces stays in your bags, and equipping is refused in combat.",
        "GameFontNormalSmall", muted)
    footer:SetPoint("TOPLEFT", 4, y - 4)
    footer:SetWidth(610)
    footer:SetJustifyH("LEFT")

    -- The proficiency table sits below the pairs, inside the same scroll: this
    -- is the page that answers weapon questions, and a type the character can
    -- still train belongs beside the answer. It draws even when the packs leave
    -- the class unknown (every row says learnable, no row says never).
    drawProficiency(content, y - 4 - (footer:GetStringHeight() or 12) - 16)

    cursor.y = 0
end

local PLUGIN_COMMANDS_MIN    = 150
local PLUGIN_COMMANDS_MAX    = 420
local PLUGIN_COMMANDS_PAD    = 14
local PLUGIN_COMMANDS_FOOTER = 46

-- The bundled commands, by plugin id. Every string here is a command the plugin
-- documents; none is invented and none is run from the page.
local PLUGIN_COMMANDS = {
    lunchbox_vendor = {
        { cmd = "/lt vendor", help = "Shows the vendor helper's status: the marked item, "
            .. "auto-sell and surplus switches, and the command list." },
        { cmd = "/lbv", help = "Alias for /lt vendor, set at load so it also works when "
            .. "another addon already owns the word vendor." },
        { cmd = "/ltvendor", help = "Second alias for /lt vendor." },
        { cmd = "/lt vendor dryrun", help = "Lists every grey item that would be sold at a "
            .. "merchant and sells nothing. The same exclusions as a real sale apply." },
        { cmd = "/lt vendor sell on|off", help = "Arms or disarms grey auto-sell for this "
            .. "character only. Quality 0, priced, unbound, not a quest item, not ignored." },
        { cmd = "/lt vendor surplus on|off", help = "Turns the gold surplus framing on or "
            .. "off for this character. The best item per slot plus a spare is kept." },
        { cmd = "/lt vendor ignore [item]", help = "Adds an item to the account-wide ignore "
            .. "list. Takes a shift-clicked link, the item on the cursor, or the marked item." },
    },
    lunchbox_racials = {
        { cmd = "/lt racials", help = "Lists the racial adjustments this plugin registered "
            .. "and the ones it cannot value yet, with the reason for each." },
    },
    -- These two have no slash command of their own: their switches are Settings
    -- rows written by the plugin. The note is shown instead of an empty list.
    lunchbox_weaponbuffs = {
        note = "No slash commands. Its off-hand imbue and temporary-enhancement "
            .. "switches are in Settings → Buff watch.",
    },
    lunchbox_rogue = {
        note = "No slash commands. Its main-hand poison warning is in "
            .. "Settings → Buff watch.",
    },
}

local function commandTextHeight(label)
    if not label then return 12 end

    local ok, height = pcall(label.GetStringHeight, label)
    if ok and type(height) == "number" and height > 0 then return height end
    return 12
end

-- A declared list is the plugin's own words and wins. The fallback map answers
-- for the bundled ids; an unknown plugin with neither gets an honest note rather
-- than a guessed command.
local function pluginCommandRows(pluginId, plugin)
    local declared = type(plugin) == "table" and plugin.commands or nil
    local function collect(source)
        local rows = {}
        for _, entry in ipairs(source) do
            local cmd = type(entry) == "table" and (entry.cmd or entry.command) or entry
            if type(cmd) == "string" and cmd ~= "" then
                local help = type(entry) == "table" and entry.help or nil
                rows[#rows + 1] = {
                    cmd = cmd,
                    help = type(help) == "string" and help or "",
                }
            end
        end
        return rows
    end

    if type(declared) == "table" then
        local rows = collect(declared)
        if #rows > 0 then
            return rows, type(declared.note) == "string" and declared.note or nil
        end
    end

    local builtin = PLUGIN_COMMANDS[pluginId]
    if type(builtin) == "table" then
        return collect(builtin), type(builtin.note) == "string" and builtin.note or nil
    end

    return {}, "This plugin declares no slash commands."
end

commandsPopup = {
    frame = nil,
    rows = {},
}

function commandsPopup:IsShown()
    return self.frame ~= nil and self.frame:IsShown() and true or false
end

function commandsPopup:Hide()
    if self.frame then self.frame:Hide() end
end

function commandsPopup:EnsureFrame()
    if self.frame then return self.frame end

    local window = MakePopupFrame("LunchboxToolkitPluginCommandsFrame",
        PLUGIN_COMMANDS_WIDTH, PLUGIN_COMMANDS_MIN, "pluginCommands")
    if not window then return nil end

    self.title = MakeLabel(window, "Plugin commands", "GameFontNormal",
        LT.Palette:RGB("brand"))
    self.title:SetPoint("TOPLEFT", PLUGIN_COMMANDS_PAD, -12)

    self.titleInfo = MakeInfo(window, "Plugin commands",
        "One row per slash command the plugin declares. Hover a row's ? for what it "
        .. "does. Nothing here runs a command: type it in chat when you want it.")
    if self.titleInfo then
        self.titleInfo:SetPoint("LEFT", self.title, "RIGHT", 6, 0)
    end

    self.subtitle = MakeLabel(window, "", "GameFontNormalSmall", LT.Palette:RGB("muted"))
    self.subtitle:SetPoint("TOPLEFT", self.title, "BOTTOMLEFT", 0, -4)
    self.subtitle:SetWidth(PLUGIN_COMMANDS_WIDTH - (PLUGIN_COMMANDS_PAD * 2))
    self.subtitle:SetJustifyH("LEFT")
    oneLine(self.subtitle)

    -- The scroll body owns the rows, so a long declared list stays reachable
    -- without making a window taller than the screen.
    local body = CreateFrame("Frame", nil, window)
    body:SetPoint("TOPLEFT", self.subtitle, "BOTTOMLEFT", 0, -8)
    body:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT",
        -PLUGIN_COMMANDS_PAD, PLUGIN_COMMANDS_FOOTER)

    self.scroll = MakeScroll(body, "pluginCommands")
    self.noteLabel = MakeLabel(self.scroll.content, "", "GameFontNormalSmall",
        LT.Palette:RGB("muted"))
    self.noteLabel:SetWidth(PLUGIN_COMMANDS_WIDTH - (PLUGIN_COMMANDS_PAD * 2) - 8)
    self.noteLabel:SetJustifyH("LEFT")
    oneLine(self.noteLabel)

    self.closeButton = MakeButton(window, "Close", 70, 20, function()
        commandsPopup:Hide()
    end)
    self.closeButton:SetPoint("BOTTOMRIGHT", -PLUGIN_COMMANDS_PAD, 12)

    window:Hide()
    self.frame = window
    return window
end

function commandsPopup:Render(plugin, rows, note)
    if not self.frame then return end

    local name = type(plugin) == "table" and tostring(plugin.name or plugin.id) or "Plugin"
    self.title:SetText("Commands — " .. name)
    self.subtitle:SetText("One row per slash command. Hover a ? for what it does; "
        .. "nothing here runs it.")

    local content = self.scroll and self.scroll.content
    if not content then return end

    local textColour = LT.Palette:RGB("text")
    local y = 0

    for index, entry in ipairs(rows) do
        local row = self.rows[index]

        if not row then
            if combatLocked() then break end

            local label = MakeLabel(content, "", "GameFontNormalSmall", textColour)
            label:SetWidth(PLUGIN_COMMANDS_WIDTH - (PLUGIN_COMMANDS_PAD * 2) - 36)
            label:SetJustifyH("LEFT")
            oneLine(label)
            row = { label = label }
            self.rows[index] = row
        end

        row.label:SetText(entry.cmd)
        row.label:ClearAllPoints()

        -- Keep the "?" next to the command it explains: the width is the text's
        -- measured width, not a guessed row length, with the row cap for an
        -- unexpectedly long command.
        local maxLabelWidth = PLUGIN_COMMANDS_WIDTH - (PLUGIN_COMMANDS_PAD * 2) - 36
        local measured = 0
        local okWidth, width = pcall(row.label.GetStringWidth, row.label)
        if okWidth and type(width) == "number" and width > 0 then measured = width end
        row.label:SetWidth(math.min(maxLabelWidth, math.max(40, measured + 2)))
        row.label:SetPoint("TOPLEFT", 0, y)
        row.label:Show()

        if entry.help ~= "" then
            -- MakeInfo captures its text, so a row reused for another plugin's
            -- command replaces the marker instead of showing stale help.
            if not row.info or row.infoHelp ~= entry.help or row.infoTitle ~= entry.cmd then
                if row.info then
                    row.info:Hide()
                    row.info:SetParent(UIParent)
                end
                row.info = MakeInfo(content, entry.cmd, entry.help)
                row.infoHelp, row.infoTitle = entry.help, entry.cmd
            end
            if row.info then
                row.info:ClearAllPoints()
                row.info:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
                row.info:Show()
            end
        elseif row.info then
            row.info:Hide()
        end

        y = y - math.max(16, commandTextHeight(row.label)) - 3
    end

    for index = #rows + 1, #self.rows do
        local row = self.rows[index]
        if row then
            row.label:Hide()
            if row.info then row.info:Hide() end
        end
    end

    if type(note) == "string" and note ~= "" then
        self.noteLabel:SetText(note)
        self.noteLabel:ClearAllPoints()
        self.noteLabel:SetPoint("TOPLEFT", 0, y - (y < 0 and 2 or 0))
        self.noteLabel:Show()
        y = y - commandTextHeight(self.noteLabel) - 3
    else
        self.noteLabel:Hide()
    end

    -- Every open starts at the top, whatever the previous plugin left behind.
    self.scroll.offset = 0
    content:SetPoint("TOPLEFT", 0, 0)

    local extent = math.max(20, -y + 4)
    local headerHeight = 12 + (self.title:GetStringHeight() or 16) + 4
        + (self.subtitle:GetStringHeight() or 12) + 8

    local target = headerHeight + extent + PLUGIN_COMMANDS_FOOTER + 8
    local uiHeight = UIParent and UIParent.GetHeight and UIParent:GetHeight() or 0
    local maxHeight = PLUGIN_COMMANDS_MAX
    if type(uiHeight) == "number" and uiHeight > 0 then
        local screenCap = math.floor(uiHeight * 0.8)
        if screenCap < maxHeight then maxHeight = screenCap end
    end
    if maxHeight < PLUGIN_COMMANDS_MIN then maxHeight = PLUGIN_COMMANDS_MIN end
    if target > maxHeight then target = maxHeight end
    if target < PLUGIN_COMMANDS_MIN then target = PLUGIN_COMMANDS_MIN end

    self.frame:SetHeight(target)
    placePopupFrame(self.frame, "pluginCommands", PLUGIN_COMMANDS_WIDTH, target)
end

function commandsPopup:Open(pluginId, plugin)
    if combatLocked() then
        LT:Print("The command list cannot be built in combat. "
            .. "Open it again after the fight.")
        return false
    end

    local window = self:EnsureFrame()
    if not window then
        LT:Print("The command list could not be built. Try again.")
        return false
    end

    local rows, note = pluginCommandRows(pluginId, plugin)
    self:Render(plugin, rows, note)
    window:Show()
    return true
end

------------------------------------------------------------------------------
-- Page: Plugins
------------------------------------------------------------------------------

local function drawPlugins(cursor)
    local count = 0
    local y = cursor.y

    local pageWidth = contentFrame:GetWidth() or 632
    if type(pageWidth) ~= "number" or pageWidth < 80 then pageWidth = 632 end

    -- The order the player asked for: the "?" first, the button next, then the
    -- plugin's name, so the three sit together instead of a button parked at the
    -- far right and a name at the far left.
    local BUTTON_X = 26
    local BUTTON_W = 84
    local NAME_X = BUTTON_X + BUTTON_W + 8
    local nameWidth = math.max(120, pageWidth - NAME_X - 8)

    -- One line of description under each name. The first sentence of the
    -- plugin's own description is the line: it is written by the plugin, so it
    -- cannot be invented here, and a sentence fits one row. The whole paragraph
    -- is still on the "?" and on the name's hover.
    local function firstSentence(text)
        local whole = tostring(text or "")
        local sentence = whole:match("^[^%.]+%.")
        if sentence and sentence ~= "" then return sentence end
        return whole
    end

    -- Cuts the text to the room it has, with an ellipsis, rather than letting
    -- the client clip it mid-word. Measured before the width is pinned, so the
    -- answer is the text's own width and not the box it was given.
    local function fitOneLine(label, text, maxWidth)
        label:SetText(text)

        local ok, width = pcall(label.GetStringWidth, label)
        if not ok or type(width) ~= "number" or width <= maxWidth or width <= 0 then
            return label
        end

        local keep = math.max(8, math.floor(#text * (maxWidth / width)) - 3)
        label:SetText(text:sub(1, keep) .. "...")
        return label
    end

    for pluginId, plugin in pairs(LT.PluginAPI.plugins) do
        count = count + 1

        local info = MakeInfo(contentFrame, plugin.name, plugin.description)
        if info then info:SetPoint("TOPLEFT", 4, y - 1) end

        -- One button per plugin, on the plugin's own row. It opens a list of that
        -- plugin's commands; it never runs one. The popup is built outside combat
        -- only, so a click during a fight says so instead of creating a frame.
        local commands = MakeButton(contentFrame, "Commands", BUTTON_W, 20, function()
            commandsPopup:Open(pluginId, plugin)
        end)
        commands:SetPoint("TOPLEFT", BUTTON_X, y)

        local label = MakeLabel(contentFrame, plugin.name .. "  v" .. tostring(plugin.version)
            .. "  (api " .. tostring(plugin.apiVersion) .. ")", "GameFontNormal")
        label:SetPoint("TOPLEFT", NAME_X, y)
        label:SetWidth(nameWidth)
        label:SetJustifyH("LEFT")
        oneLine(label)

        MakeHoverTarget(contentFrame, plugin.name, plugin.description, label)

        y = y - 21

        local description = firstSentence(plugin.description)
        if description ~= "" then
            local line = MakeLabel(contentFrame, description, "GameFontNormalSmall",
                LT.Palette:RGB("muted"))
            line:SetPoint("TOPLEFT", NAME_X, y)
            line:SetJustifyH("LEFT")
            oneLine(line)
            fitOneLine(line, description, nameWidth)
            line:SetWidth(nameWidth)
            y = y - 15
        end

        local list = LT.PluginAPI.adjustments[pluginId] or {}
        local adjustments = MakeLabel(contentFrame,
            tostring(#list) .. " adjustment(s) registered", "GameFontNormalSmall",
            LT.Palette:RGB("muted"))
        adjustments:SetPoint("TOPLEFT", NAME_X, y)
        y = y - 15

        for _, problem in ipairs(LT.PluginAPI.errors[pluginId] or {}) do
            local errorLabel = MakeLabel(contentFrame, tostring(problem), "GameFontNormalSmall",
                LT.Palette:RGB("stop"))
            errorLabel:SetPoint("TOPLEFT", NAME_X, y)
            errorLabel:SetWidth(nameWidth)
            errorLabel:SetJustifyH("LEFT")
            y = y - (errorLabel:GetStringHeight() or 12) - 2
        end

        y = y - 8
    end

    if count == 0 then
        local explanation = "The core stands on its own: profiles, equipment sets, "
            .. "scoring, comparisons and tooltips all work without a single plugin. "
            .. "Plugins add class and talent knowledge through the documented "
            .. "interface — the first one will be the Shaman module."

        local info = MakeInfo(contentFrame, "No plugins are loaded.", explanation)
        if info then info:SetPoint("TOPLEFT", 4, y - 1) end

        local label = MakeLabel(contentFrame,
            "No plugins are loaded.", "GameFontNormal")
        label:SetPoint("TOPLEFT", NAME_X, y)

        MakeHoverTarget(contentFrame, "No plugins are loaded.", explanation, label)

        y = y - 20
    end

    for _, problem in ipairs(LT.PluginAPI.registrationProblems or {}) do
        local label = MakeLabel(contentFrame, tostring(problem), "GameFontNormalSmall",
            LT.Palette:RGB("caution"))
        label:SetPoint("TOPLEFT", 4, y)
        label:SetWidth(math.max(120, pageWidth - 8))
        label:SetJustifyH("LEFT")
        y = y - (label:GetStringHeight() or 12) - 4
    end

    cursor.y = y
end

------------------------------------------------------------------------------
-- Page: Commands
--
-- Every word /lt accepts, in one place, so the player does not have to remember
-- a chat mnemonic. The list is read from the slash module when the page is
-- drawn, which is also how a plugin's own words show up here without this file
-- knowing them. Nothing runs on open.
--
-- Run is offered only for the words in COMMANDS_SAFE_TO_RUN below: each one
-- prints or scans and changes nothing. A word that saves, imports, edits,
-- deletes or switches something keeps its row and gets no button, because a
-- mis-click on this page must not be able to change the player's data.
------------------------------------------------------------------------------

-- Where each bundled word belongs. A word that is not listed here did not come
-- from Slash.lua's own table — a module or plugin registered it through
-- Slash:RegisterCommand — so it is shown under Plugins with a plain label and
-- no button: this file cannot know that a contributed word is safe to run.
local COMMAND_AREAS = {
    { label = "Scoring", words = {
        "score", "weight", "weights", "divisor", "capture", "caps", "why", "unknown",
    } },
    { label = "Bags and gear", words = {
        "gear", "save", "scan", "weapon", "imbune", "imbue", "imbues", "quest", "drop", "trash",
    } },
    { label = "Profiles", words = {
        "builds", "use", "name", "spec", "role", "context",
        "profiles", "profile", "export", "exports", "import",
    } },
    { label = "Diagnostics", words = {
        "help", "?", "ui", "open", "test", "level", "played", "colours", "colors", "debug",
    } },
    { label = "Plugins", words = {
        "plugins",
    } },
}

-- Read-only words. Every one of these prints, lists or scans; none writes a
-- saved value, a profile, an equipment set or a build field.
local COMMANDS_SAFE_TO_RUN = {
    help = true,
    builds = true,
    profiles = true,
    caps = true,
    why = true,
    unknown = true,
    quest = true,
    drop = true,
    colours = true,
    imbues = true,
    -- /lt imbune is the same command and the button runs it with no argument,
    -- which only lists; a name still sets the imbue and needs typing.
    imbune = true,
    plugins = true,
    played = true,
    scan = true,
    racials = true,
    spells = true,
}

-- The page is three columns of short rows: forty words in one column needed a
-- scrollbar and put Run at the far right of a 632-pixel page, which is the gap
-- the player reported. Three columns put every Run button at the end of its own
-- word, and the whole list fits the default window.
--
-- A row is striped so the eye can follow a word to its button across the gap,
-- and each row's hover says the word, the area it belongs to and whether Run is
-- offered (and therefore whether pressing it can change anything).
local COMMAND_COLUMNS     = 3
local COMMAND_COLUMN_GAP  = 10
local COMMAND_ROW_HEIGHT  = 16
local COMMAND_ROW_GAP     = 1
local COMMAND_RUN_WIDTH   = 42
local COMMAND_RUN_HEIGHT  = 16
local COMMAND_AREA_GAP    = 6
local COMMAND_LINE_FALLBACK = 12

-- A client that cannot measure a font string gets a line height for its font
-- size rather than a zero that would stack every row on one pixel.
local function commandLineHeight(label)
    if not label then return COMMAND_LINE_FALLBACK end

    local ok, height = pcall(label.GetStringHeight, label)
    if ok and type(height) == "number" and height > 0 then
        if not (LT.IsSecret and LT:IsSecret(height)) then
            return height
        end
    end

    return COMMAND_LINE_FALLBACK
end

-- The registered words, or nil and a reason. Read at draw time only, and never
-- assumed to exist: a build with the slash module stripped out still draws this
-- page, it just has nothing to list.
local function registeredCommandWords()
    local slash = LT.Slash

    if type(slash) ~= "table" or type(slash.RegisteredCommands) ~= "function" then
        return nil, "The slash command module is not loaded, so no words are listed here."
    end

    local ok, list = pcall(slash.RegisteredCommands, slash)
    if not ok or type(list) ~= "table" then
        return nil, "The command list could not be read."
    end

    return list
end

-- What a Run button does. The word and nothing else, so the command receives an
-- empty argument list and falls back to its own default answer, exactly as a
-- bare "/lt word" in chat would. The window stays open and the answer arrives
-- in the chat frame.
local function runCommandWord(word)
    local slash = LT.Slash

    if type(slash) ~= "table" or type(slash.Handle) ~= "function" then
        LT:Error("/lt " .. tostring(word)
            .. " cannot be run from the window: the slash command module is not loaded.")
        return
    end

    local ok, err = pcall(slash.Handle, slash, word)
    if not ok then
        LT:Error("Command /lt " .. tostring(word) .. " failed: " .. tostring(err))
    end
end

local function drawCommands(cursor, host)
    -- The rows are laid out in three columns, which is what makes the whole list
    -- fit the default window. The scroll area is still here for a client with
    -- larger fonts or a plugin that registers many words: the bar appears by
    -- itself when the rows do not fit, and the page remembers where it was left.
    -- `host` is the main window's page host, or a popup's own content frame.
    host = host or contentFrame
    local scroll = MakeScroll(host, "commands")
    scroll:SetPoint("TOPLEFT", 0, cursor.y)
    local page = scroll.content
    local y = 0

    local intro = oneLine(MakeLabel(page, "Every /lt word this addon accepts.",
        "GameFontNormal"))
    intro:SetPoint("TOPLEFT", 4, y)
    intro:SetJustifyH("LEFT")

    local explanation = "Read from the addon as the page is drawn, so a plugin's own "
        .. "words appear here too. Nothing is run when the page opens. Run calls the "
        .. "command with no arguments and leaves the window open, so the answer arrives "
        .. "in the chat frame. Run is only offered for words that print, list or scan "
        .. "and change nothing: saving, importing, editing a weight or choosing a build "
        .. "have no button, because a mis-click there would change your data."

    local info = MakeInfo(page, "Commands", explanation)
    if info then info:SetPoint("LEFT", intro, "RIGHT", 6, 0) end

    y = y - commandLineHeight(intro) - COMMAND_AREA_GAP

    local words, reason = registeredCommandWords()

    if not words then
        local missing = MakeLabel(page, tostring(reason), "GameFontNormalSmall",
            LT.Palette:RGB("muted"))
        missing:SetPoint("TOPLEFT", 4, y)
        missing:SetWidth(560)
        missing:SetJustifyH("LEFT")
        cursor.y = y - commandLineHeight(missing) - 4
        return
    end

    -- word (lower case) -> area index, so a word added to the area table above
    -- is placed without a second list to keep in step.
    local areaOf = {}
    for index, area in ipairs(COMMAND_AREAS) do
        for _, word in ipairs(area.words) do
            areaOf[string.lower(word)] = index
        end
    end

    local pluginArea = #COMMAND_AREAS
    local buckets = {}
    for index = 1, #COMMAND_AREAS do buckets[index] = {} end

    -- A word that is empty, not a string, or listed twice cannot be a working
    -- command, so it is not drawn as a row. The slash module never lists a word
    -- twice; the guard is here so a contributed list cannot produce a duplicate
    -- line or a button that would run nothing.
    local seen = {}
    local placed = 0

    for _, entry in ipairs(words) do
        local word = type(entry) == "string" and entry or nil

        if word and word ~= "" and not seen[word] then
            seen[word] = true
            placed = placed + 1
            table.insert(buckets[areaOf[string.lower(word)] or pluginArea], word)
        end
    end

    if placed == 0 then
        local empty = MakeLabel(page, "No command words are registered.", "GameFontNormalSmall",
            LT.Palette:RGB("muted"))
        empty:SetPoint("TOPLEFT", 4, y)
        cursor.y = y - commandLineHeight(empty) - 4
        return
    end

    -- The visible page width decides the column width, so a page added at run
    -- time or a narrower client does not squeeze the Run button off the row.
    local pageWidth = scroll.GetWidth and scroll:GetWidth() or 0
    if type(pageWidth) ~= "number" or pageWidth < 180 then pageWidth = 632 end

    local columnWidth = math.floor((pageWidth
        - ((COMMAND_COLUMNS - 1) * COMMAND_COLUMN_GAP)) / COMMAND_COLUMNS)
    local wordWidth = math.max(40, columnWidth - COMMAND_RUN_WIDTH - 10)

    local function columnX(column)
        return (column - 1) * (columnWidth + COMMAND_COLUMN_GAP)
    end

    -- What a row's hover says. It states only what this file knows: the word,
    -- the area it belongs to, and the rule that decides whether Run is offered.
    -- Arguments are pointed at /lt help rather than invented here.
    local function rowHelp(area, word)
        local text = "Type it in chat as /lt " .. word .. ", listed under "
            .. area.label .. ". "

        if COMMANDS_SAFE_TO_RUN[string.lower(word)] then
            text = text .. "Run presses it with no argument; it prints, lists or scans "
                .. "and changes nothing."
        else
            text = text .. "No Run button: Run is only offered for words that print, "
                .. "list or scan with no argument."
        end

        return text .. " /lt help lists every word."
    end

    for index, area in ipairs(COMMAND_AREAS) do
        local list = buckets[index]

        -- A section with nothing in it is not drawn.
        if #list > 0 then
            local heading = oneLine(MakeLabel(page, area.label, "GameFontNormal",
                LT.Palette:RGB("brand")))
            heading:SetPoint("TOPLEFT", 4, y)
            heading:SetJustifyH("LEFT")
            y = y - math.max(COMMAND_ROW_HEIGHT, commandLineHeight(heading) + 2)

            -- Fill across the three columns, then down: a short area stays one
            -- band of rows instead of leaving a hole.
            local rowsPerColumn = math.ceil(#list / COMMAND_COLUMNS)

            for position, word in ipairs(list) do
                local column = math.floor((position - 1) / rowsPerColumn) + 1
                local rowIndex = (position - 1) % rowsPerColumn
                local rowY = y - (rowIndex * (COMMAND_ROW_HEIGHT + COMMAND_ROW_GAP))
                local x = columnX(column)

                -- The stripe is a child frame, so it is hidden and detached with
                -- the page; the word and its button sit above it.
                if rowIndex % 2 == 1 then
                    local stripe = CreateFrame("Frame", nil, page)
                    stripe:SetPoint("TOPLEFT", x, rowY)
                    stripe:SetSize(columnWidth, COMMAND_ROW_HEIGHT)

                    local fill = stripe:CreateTexture(nil, "BACKGROUND")
                    fill:SetAllPoints(stripe)

                    -- The window's own dark tone at half its weight: a band a
                    -- row can be followed along, not a second colour.
                    local shade = LT.Palette:Colour("fill")
                    fill:SetColorTexture(shade[1], shade[2], shade[3],
                        (shade[4] or 1) * 0.5)
                end

                local row = oneLine(MakeLabel(page, word, "GameFontNormalSmall",
                    LT.Palette:RGB("text")))
                row:SetPoint("TOPLEFT", x + 4, rowY + 1)
                row:SetWidth(wordWidth)
                row:SetJustifyH("LEFT")

                -- Hovering the word explains it; clicking does the same, so the
                -- usage is reachable without a steady pointer.
                MakeHoverTarget(page, word, rowHelp(area, word), row)

                -- Run sits at the end of its own row, not across the page.
                if COMMANDS_SAFE_TO_RUN[string.lower(word)] then
                    local run = MakeButton(page, "Run", COMMAND_RUN_WIDTH,
                        COMMAND_RUN_HEIGHT, function()
                            runCommandWord(word)
                        end)
                    run:SetPoint("TOPRIGHT", x + columnWidth, rowY)
                end
            end

            y = y - (rowsPerColumn * (COMMAND_ROW_HEIGHT + COMMAND_ROW_GAP)) - COMMAND_AREA_GAP
        end
    end

    cursor.y = y
end

------------------------------------------------------------------------------
-- Page: Actions, and the two reference popups
--
-- The player's ask (2026-11-04): everything an end user would type should be a
-- control, and the reference lists should stop taking a rail slot of their own.
-- Every button here runs the command it names through Slash:Handle, so chat and
-- the window can never disagree about what an action does; a word that needs an
-- argument keeps its command only.
------------------------------------------------------------------------------

-- A method rather than a chunk-level local: this file is already at Lua's 200
-- locals per chunk, and the page needs exactly one name.
function UI:DrawActions(cursor)
    -- Everything the page needs lives inside this one function: UI.lua is at
    -- Lua's 200-locals-per-chunk ceiling, so the page's data, its runner and its
    -- popups are function locals rather than six more chunk-level names.
    local ACTIONS = {
        { heading = "Bags", help = "Sorting uses the client's own sort and needs its "
            .. "switch on in Settings. Triage only names an item; it never destroys one.",
          buttons = {
            { label = "Sort bags", run = "sort bags", help = "Runs /lt sort bags." },
            { label = "Sort bank", run = "sort bank", help = "Runs /lt sort bank; the "
                .. "bank window must be open for the client to move anything." },
            { label = "Sort both", run = "sort all", help = "Runs /lt sort all." },
            { label = "What to drop first", run = "drop", help = "Names the cheapest "
                .. "sellable item: the first thing worth losing when the bags are full." },
            { label = "Ignored items", run = "drop list", help = "Lists the items you "
                .. "told the triage to never suggest." },
          } },
        { heading = "Vendor", help = "The vendor plugin. Nothing here sells unless grey "
            .. "auto-sell is on and a merchant is open; surplus only frames items.",
          buttons = {
            { label = "Vendor status", run = "vendor status", help = "Marked item, both "
                .. "switches and the command list." },
            { label = "Dry run", run = "vendor dryrun", help = "Lists what a sale would "
                .. "take and sells nothing." },
            { label = "Mark cheapest", run = "vendor mark", help = "Marks the single "
                .. "cheapest sellable item in the bags." },
            { label = "Auto-sell on", run = "vendor sell on", help = "Grey items sell "
                .. "when a merchant is open; quest, soulbound, ignored and upgrade items "
                .. "never do." },
            { label = "Auto-sell off", run = "vendor sell off", help = "Stops the grey "
                .. "sweep for this character." },
            { label = "Surplus on", run = "vendor surplus on", help = "Gold-frames spare "
                .. "gear beyond the best item per slot plus one spare; nothing is sold." },
            { label = "Surplus off", run = "vendor surplus off", help = "Removes the framing." },
          } },
        { heading = "Gear and trackers", help = "The same actions the header buttons and "
            .. "the popup offer, in one place.", buttons = {
            { label = "Scan the bags", run = "scan", help = "Lists the upgrades in the "
                .. "bags: wear now, and what a level unlocks." },
            { label = "Windfury records" .. UI:WindfuryLabel(), run = "wf",
              help = "Shaman only: the recorded Windfury procs." },
            { label = "Tracker status", run = "trackers status", help = "Combo tracker, "
                .. "windfury availability, and where the frame sits." },
          } },
    }

    local muted = LT.Palette:RGB("muted")
    local brand = LT.Palette:RGB("brand")

    local function runWord(word, label)
        local slash = LT.Slash
        if type(slash) ~= "table" or type(slash.Handle) ~= "function" then
            LT:Error("The slash command module is not loaded.")
            return
        end

        local ok, err = pcall(slash.Handle, slash, word)
        if not ok then
            LT:Error(tostring(label or word) .. " failed: " .. tostring(err))
        end
    end

    -- The two reference windows, each hosting an existing drawer so there is one
    -- implementation of the list and no second copy to keep in step.
    local function openHostedPopup(which)
        if combatLocked() then
            LT:Warn("Not while you are in combat: the window cannot be built.")
            return false
        end

        UI.hostedPopups = UI.hostedPopups or {}
        local record = UI.hostedPopups[which]

        if not record then
            local name = (which == "commands") and "LunchboxToolkitCommandsPopup"
                or "LunchboxToolkitCapsPopup"
            local window = MakePopupFrame(name, 660, 460, which .. "Popup")
            if not window then
                LT:Error("The " .. tostring(which) .. " window could not be built.")
                return false
            end

            local host = CreateFrame("Frame", nil, window)
            host.lunchboxLabelPool = {}
            host:SetPoint("TOPLEFT", 12, -12)
            -- Room for the Close control along the bottom edge.
            host:SetPoint("BOTTOMRIGHT", -12, 44)

            local close = MakeButton(window, "Close", 70, 20, function()
                window:Hide()
            end)
            close:SetPoint("BOTTOMRIGHT", -12, 12)

            record = { window = window, host = host, close = close }
            UI.hostedPopups[which] = record
        end

        pcall(recycleHost, record.host)

        local inner = { x = 0, y = 0 }
        local ok, err
        if which == "commands" then
            ok, err = pcall(drawCommands, inner, record.host)
        else
            ok, err = pcall(drawCaps, inner, record.host)
        end
        if not ok then
            LT:Error("The " .. tostring(which) .. " window failed to draw: " .. tostring(err))
            return false
        end

        -- Every other popup in this file calls this before showing. A frame built
        -- by MakePopupFrame has a size but no anchor, so without it the window
        -- opens at the UI origin and reads as "the button did nothing" - which is
        -- exactly what the player reported on 2026-11-04.
        pcall(placePopupFrame, record.window, which .. "Popup", 660, 460)

        record.window:Show()
        return true
    end

    local header = MakeLabel(contentFrame, "Actions", "GameFontNormal")
    header:SetPoint("TOPLEFT", 4, cursor.y)
    cursor.y = cursor.y - 22

    local intro = MakeLabel(contentFrame,
        "One button per thing you would otherwise type. Each button runs the command it "
            .. "names, so the window and chat can never disagree about what it does.",
        "GameFontNormalSmall", muted)
    intro:SetPoint("TOPLEFT", 4, cursor.y)
    intro:SetWidth(600)
    intro:SetJustifyH("LEFT")
    cursor.y = cursor.y - 3 - (intro:GetStringHeight() or 12) - 8

    local scroll = MakeScroll(contentFrame, "actions")
    scroll:SetPoint("TOPLEFT", 0, cursor.y)
    local content = scroll.content
    local y = 0

    local COLUMN_W, ROW_H, GAP, COLUMNS = 204, 20, 6, 3

    for _, area in ipairs(ACTIONS) do
        local heading = MakeLabel(content, area.heading, "GameFontNormalSmall", brand)
        heading:SetPoint("TOPLEFT", 4, y)

        local info = MakeInfo(content, area.heading, area.help)
        if info then info:SetPoint("LEFT", heading, "RIGHT", 4, 0) end

        y = y - 20

        local rows = 0
        for index, definition in ipairs(area.buttons) do
            local column = (index - 1) % COLUMNS
            local row = math.floor((index - 1) / COLUMNS)
            rows = row + 1

            local made = MakeButton(content, tostring(definition.label), COLUMN_W, 20,
                function() runWord(definition.run, definition.label) end)
            made:SetPoint("TOPLEFT", 4 + column * (COLUMN_W + GAP), y - row * (ROW_H + 4))

            MakeHoverTarget(content, definition.label,
                definition.help or ("Runs /lt " .. tostring(definition.run)), made)
        end

        y = y - rows * (ROW_H + 4) - 10
    end

    local openCommands = MakeButton(content, "Slash commands…", COLUMN_W, 20, function()
        openHostedPopup("commands")
    end)
    openCommands:SetPoint("TOPLEFT", 4, y)
    MakeHoverTarget(content, "Slash commands",
        "Every /lt word this addon accepts, in the same three columns the page used "
            .. "to draw, with a Run button for the words that only print.", openCommands)

    local openCaps = MakeButton(content, "Caps and conversion…", COLUMN_W, 20, function()
        openHostedPopup("caps")
    end)
    openCaps:SetPoint("TOPLEFT", 4 + COLUMN_W + GAP, y)
    MakeHoverTarget(content, "Caps and conversion",
        "Each cap's target, whether it is met, and the rating conversion at this level, "
            .. "for the active build.", openCaps)

    cursor.y = 0
end

------------------------------------------------------------------------------
-- Page: Ranks
--
-- A battleground scoreboard, not a settings form. One board fills the page with
-- four tabs along the bottom: Party, Guild, Friends and Fastest to 60. A row is
-- rank, class marker, name in its class colour, level and played time, with the
-- faction carried by a full-row tint and a visible hairline under every line.
-- The character's own row takes part in the list like any other, tinted gold, so
-- there is no separate "your row" block above it and no "(you)" suffix.
--
-- Clicking a heading sorts by that column and puts a triangle on it; the
-- explanation of a heading is still the "?" beside it. Sharing is a popup
-- behind one button, the record board behind another, and the channel controls
-- live in the sharing popup so they do not double the bottom chrome of the tab
-- strip.
--
-- Every widget is built once, out of combat, and reused on each redraw: the
-- client does not allow a protected frame to be created during a fight, and a
-- page that is merely shown and re-texted is safe there. If the page has never
-- been built and the player is in combat, nothing is drawn at all rather than a
-- half-built page.
--
-- The data is read through Leaderboard:Boards() each time the page is drawn.
-- An absent module is a plain sentence, not an error: the rest of the window
-- still works without Leaderboard.lua.
------------------------------------------------------------------------------

local RANKS_DEFAULT_CHANNEL = "LBTK"
-- The module owns the real limit; this is only the fallback for a build whose
-- leaderboard does not publish one.
local RANKS_CHANNEL_LIMIT_FALLBACK = 64
local RANKS_LEVEL_LIMIT = 20
local RANKS_RECORD_LIMIT = 10
local RANKS_CONTENT_WIDTH = 600
local RANKS_ROW_GAP = 2
local RANKS_AREA_GAP = 10
local RANKS_LINE_FALLBACK = 12
local RANKS_MARKER_SIZE = 8
-- Space between two scoreboard columns. Every column starts where the measured
-- text of the one before it ends, so alignment survives any client font.
local RANKS_COLUMN_GAP = 12
local RANKS_COLUMN_X = 4

-- The four boards the player asked for, in the order of the bottom strip. The
-- selected tab is the same widget the window's own strip uses, so it is obvious
-- without a second style: taller, brighter label, gold edge.
local RANKS = {}

RANKS.TABS = {
    { key = "server",  label = "Party" },
    { key = "guild",   label = "Guild" },
    { key = "friends", label = "Friends" },
    { key = "fastest", label = "Fastest to 60" },
}

RANKS.TITLES = {
    server = "Party board",
    guild = "Guild board",
    friends = "Friends ladder",
    fastest = "Fastest to 60",
}

-- One heading list for the board. `marker` is the class icon column: an
-- 8 x 8 class-coloured tile, because this build cannot rely on a class-icon
-- texture path existing on the client. `deaths` is drawn only when a row
-- actually carries a number, so an empty column is never printed.
RANKS.COLUMNS = {
    { key = "rank",   label = "Rank",   sortable = true, numeric = true },
    { key = "marker", label = "",       sortable = false },
    { key = "name",   label = "Name",   sortable = true },
    { key = "level",  label = "Level",  sortable = true, numeric = true },
    { key = "played", label = "Played", sortable = true, numeric = true },
    { key = "deaths", label = "Deaths", sortable = true, numeric = true, optional = true },
}

-- Which tab is up, which heading sorted it and which way, and the last search
-- text. Kept in the file, not in SavedVariables: it is a view, not a setting.
-- The default is the player's ask: fastest time to 60 first.
RANKS.state = {
    tab = "server",
    sortKey = "rank",
    ascending = true,
    search = "",
}

-- Used only when a row reports its race but not its faction. Pandaren can be
-- either side and is deliberately absent, so it reads as unknown rather than
-- being put on a side the row never claimed.
local RANKS_RACE_FACTION = {
    Human = "Alliance",
    Dwarf = "Alliance",
    NightElf = "Alliance",
    Gnome = "Alliance",
    SkyborneAlliance = "Alliance",
    Draenei = "Alliance",
    Worgen = "Alliance",
    Orc = "Horde",
    Scourge = "Horde",
    Undead = "Horde",
    Tauren = "Horde",
    Troll = "Horde",
    SkyborneHorde = "Horde",
    BloodElf = "Horde",
    Goblin = "Horde",
}

-- The client's own scoreboard colours. Palette holds no faction group, so these
-- two values are the one set the ticket allows outside it; both are the classic
-- Alliance blue and Horde red, dark enough to read on the window background.
local RANKS_FACTION_COLOURS = {
    Alliance = { 0.00, 0.44, 0.87 },
    Horde = { 0.83, 0.13, 0.13 },
}

-- Absent ranksServer/ranksGuild/ranksFriends read as ON in Leaderboard.lua, so
-- the page shows the same thing the module would do. The master switch is the
-- exception: absent means off, which is the opt-in rule.
local RANKS_TOGGLES = {
    {
        key = "ranksShare",
        label = "Share at all",
        default = false,
        help = "Off by default. While this is off nothing leaves this machine: no row "
            .. "is sent, and a row that arrives is not stored. While it is on, one "
            .. "packet carrying your name, class, race, faction, level and active time "
            .. "is sent at most once a minute, only when you level up or open this page.",
    },
    {
        key = "ranksServer",
        label = "Party board",
        default = true,
        help = "Include rows shared on the party channel. While Share is off, nothing "
            .. "leaves this machine and nothing new is stored, so this switch only "
            .. "decides what is shown once sharing is on.",
    },
    {
        key = "ranksGuild",
        label = "Guild board",
        default = true,
        help = "Include rows shared on the guild channel. While Share is off, nothing "
            .. "leaves this machine and nothing new is stored, so this switch only "
            .. "decides what is shown once sharing is on.",
    },
    {
        key = "ranksFriends",
        label = "Friends filter",
        default = true,
        help = "Show only rows whose name is on your friends list, when the leaderboard "
            .. "can read it. While Share is off, nothing leaves this machine and "
            .. "nothing new is stored.",
    },
}

local RANKS_SCOPE_READ = {
    ranksServer = "IsServerSharing",
    ranksGuild = "IsGuildSharing",
    ranksFriends = "IsFriendFilter",
}

local RANKS_SCOPE_WRITE = {
    ranksServer = "SetServerSharing",
    ranksGuild = "SetGuildSharing",
    ranksFriends = "SetFriendFilter",
}

local ranksPage

local function ranksLocked()
    return combatLocked()
end

local function ranksModule()
    local module = LT.Leaderboard
    if type(module) ~= "table" then return nil end
    return module
end

local function ranksHeight(label)
    if not label then return RANKS_LINE_FALLBACK end

    local ok, height = pcall(label.GetStringHeight, label)
    if ok and type(height) == "number" and height > 0 then
        if not (LT.IsSecret and LT:IsSecret(height)) then
            return height
        end
    end

    return RANKS_LINE_FALLBACK
end

-- "1h 02m", "12m 03s", "42s". A missing or negative number is not dressed up
-- as a time; it is said to be unknown.
local function ranksDuration(seconds)
    local total = tonumber(seconds)
    if not total or total < 0 then return "time unknown" end

    total = math.floor(total)
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local secs = total % 60

    if hours > 0 then return string.format("%dh %02dm", hours, minutes) end
    if minutes > 0 then return string.format("%dm %02ds", minutes, secs) end
    return string.format("%ds", secs)
end

-- The one line under the Ranks page for a character at the cap: lifetime time
-- played, the active/AFK split, and the time-to-60 record when the ledger has a
-- real moment for it. Every Played call is guarded and a ledger that cannot
-- answer means no line is drawn at all — never a row of zeroes standing in for
-- "unknown".
local function level60PlayedLine()
    local played = LT.Played
    if type(played) ~= "table" or type(played.GetPlayed) ~= "function" then return nil end

    local okRecord, record = pcall(played.GetPlayed, played, false)
    if not okRecord or type(record) ~= "table" then return nil end

    local totals = type(record.total) == "table" and record.total or nil
    if not totals then return nil end

    local active = tonumber(totals.active)
    local afk = tonumber(totals.afk)
    if not active or not afk then return nil end

    local lifetime = active + afk
    if type(played.LifetimeSeconds) == "function" then
        local okLife, value = pcall(played.LifetimeSeconds, played)
        if okLife and type(value) == "number" and value >= 0 then lifetime = value end
    end

    local atSixty = nil
    if type(played.Level60Seconds) == "function" then
        local okSixty, value = pcall(played.Level60Seconds, played)
        if okSixty and type(value) == "number" and value > 0 then atSixty = value end
    end

    local text = "Played " .. ranksDuration(lifetime) .. " total: "
        .. ranksDuration(active) .. " active, " .. ranksDuration(afk) .. " AFK"
    if atSixty then
        text = text .. "; level 60 at " .. ranksDuration(atSixty)
    end

    return text
end

local function ranksClassName(token)
    local classData = LT.ClassData

    if type(classData) == "table" and type(classData.GetClassName) == "function" then
        local ok, name = pcall(classData.GetClassName, classData, token)
        if ok and type(name) == "string" and name ~= "" then return name end
    end

    return tostring(token or "Unknown")
end

-- The row is a scoreboard line, so a marker is carried by colour and never by a
-- second word: the own row is found by its tint and its white name, not by
-- "(you)". A made-up demo row still says "demo" in the muted colour because its
-- numbers are not a report.
local function ranksNameText(row)
    local name = type(row.name) == "string" and row.name ~= "" and row.name or "Unknown"

    if row.synthetic then
        return name .. " " .. LT.Palette:Wrap("muted", "demo")
    end
    return name
end

-- The race token a row reports, or the player's own race for the own row when
-- the module sent none. nil means the row carried no race at all.
local function ranksRaceToken(row)
    if type(row) ~= "table" then return nil end

    if type(row.race) == "string" and row.race ~= "" and row.race ~= "UNKNOWN" then
        return row.race
    end

    if row.you then
        local player = LT.player
        if type(player) == "table" and type(player.race) == "string"
            and player.race ~= "" and player.race ~= "UNKNOWN" then
            return player.race
        end
    end

    return nil
end

-- "Alliance" / "Horde" / "Neutral", from the row when it reports one and from
-- the race table otherwise, so a v2 sender that carried no faction still gets
-- its side. nil means the side is genuinely unknown.
local function ranksFaction(row)
    if type(row) ~= "table" then return nil end

    local reported = row.faction
    if reported == "Alliance" or reported == "Horde" or reported == "Neutral" then
        return reported
    end

    local token = ranksRaceToken(row)

    -- ClassData is the authoritative race table (it has both Skyborne rows and
    -- their faction). The local table is only the fallback for a token this
    -- core does not know, so race knowledge has one source of truth.
    local races = LT.ClassData and LT.ClassData.races
    local definition = token and races and races[token]
    if definition and type(definition.faction) == "string" then
        return definition.faction
    end

    local known = token and RANKS_RACE_FACTION[token]
    if known then return known end

    if row.you then
        local player = LT.player
        if type(player) == "table"
            and (player.faction == "Alliance" or player.faction == "Horde") then
            return player.faction
        end
    end

    return nil
end

-- The class colour the client already publishes, guarded twice: a client
-- without RAID_CLASS_COLORS and a token it does not know both fall back to the
-- palette's plain text, so a name is never drawn in a colour nobody chose.
local function ranksClassColour(token)
    local colours = _G.RAID_CLASS_COLORS
    local entry = type(colours) == "table" and type(token) == "string"
        and colours[string.upper(token)] or nil

    if type(entry) == "table" then
        local r, g, b = tonumber(entry.r), tonumber(entry.g), tonumber(entry.b)
        if r and g and b then return r, g, b end
    end

    local fallback = LT.Palette.named.text
    return fallback.r, fallback.g, fallback.b
end

local function ranksFactionColour(faction)
    local colour = type(faction) == "string" and RANKS_FACTION_COLOURS[faction] or nil
    if colour then return colour[1], colour[2], colour[3] end

    -- Unknown side: the muted chrome colour, never one of the two sides.
    local fallback = LT.Palette.named.muted
    return fallback.r, fallback.g, fallback.b
end

-- A faint alternating row tone, not a faction wash. Faction stays on the
-- marker and the name; a whole-row tint makes the scoreboard look like a
-- different add-on.
function RANKS.rowColour(row, rank)
    local muted = LT.Palette.named.muted
    return muted.r, muted.g, muted.b, (rank and rank % 2 == 0) and 0.07 or 0.035
end

-- The played cell: current /played until the cap, then the frozen time-to-60
-- record. at60 is written once at the ding by Leaderboard.lua; a level-60 row
-- without one keeps showing its current played time instead of a made-up zero.
function RANKS.playedText(row)
    if type(row) ~= "table" then return "time unknown" end

    local level = tonumber(row.level) or 0
    local at60 = tonumber(row.at60)
    if level >= 60 and at60 and at60 > 0 then return ranksDuration(at60) end
    return ranksDuration(row.lifetime)
end

-- A row's played value for sorting: the record when it has one, else the
-- current total. nil is "unknown" and always sorts last.
function RANKS.playedSeconds(row)
    if type(row) ~= "table" then return nil end

    local level = tonumber(row.level) or 0
    local at60 = tonumber(row.at60)
    if level >= 60 and at60 and at60 > 0 then return at60 end
    return tonumber(row.lifetime)
end

function RANKS.deathCount(row)
    local deaths = type(row) == "table" and tonumber(row.deaths) or nil
    if not deaths or deaths < 0 then return nil end
    return math.floor(deaths)
end

function RANKS.hasDeaths(rows, extra)
    if type(rows) == "table" then
        for _, row in ipairs(rows) do
            if RANKS.deathCount(row) then return true end
        end
    end
    return extra ~= nil and RANKS.deathCount(extra) ~= nil
end

-- name + realm is one character everywhere the page groups rows.
function RANKS.rowKey(row)
    if type(row) ~= "table" then return "" end
    return string.lower(tostring(row.name or "")) .. "\31"
        .. string.lower(tostring(row.realm or ""))
end

function RANKS.character()
    local database = LT.Database
    return type(database) == "table" and database.character or nil
end

-- The local friends ladder: additive on the character record, written only by
-- Add to Friends. It is a list kept by this client; nothing is sent and no
-- channel is involved.
function RANKS.ladder(create)
    local character = RANKS.character()
    if type(character) ~= "table" then return nil end

    if type(character.ranksFriendsLadder) ~= "table" then
        if not create then return nil end
        character.ranksFriendsLadder = {}
    end
    return character.ranksFriendsLadder
end

function RANKS.onLadder(row)
    local ladder = RANKS.ladder(false)
    if type(ladder) ~= "table" then return false end
    return ladder[RANKS.rowKey(row)] ~= nil
end

function RANKS.addFriend(row)
    if type(row) ~= "table" or row.you then return false, "self" end

    local ladder = RANKS.ladder(true)
    if not ladder then return false, "no character record" end

    local key = RANKS.rowKey(row)
    if ladder[key] then return false, "already" end

    ladder[key] = {
        name = row.name,
        realm = row.realm,
        class = row.class,
        level = row.level,
        lifetime = row.lifetime,
        at60 = row.at60,
        added = (type(time) == "function" and time()) or 0,
    }

    local database = LT.Database
    if type(database) == "table" and type(database.Save) == "function" then
        pcall(database.Save, database, "ranks:friends")
    end
    return true
end

-- Sorting. Every comparator answers "does a come before b in the ascending
-- direction"; the draw reverses the two arguments when the triangle asks for
-- descending. Rank is the player's default: fastest time-to-60 first, then the
-- furthest along, then the least played, then the name for a stable order.
function RANKS.nameLess(a, b)
    return RANKS.rowKey(a) < RANKS.rowKey(b)
end

function RANKS.rankLess(a, b)
    local atA = tonumber(a and a.at60) or 0
    local atB = tonumber(b and b.at60) or 0

    if (atA > 0) ~= (atB > 0) then return atA > 0 end
    if atA > 0 and atA ~= atB then return atA < atB end

    local levelA = tonumber(a and a.level) or 0
    local levelB = tonumber(b and b.level) or 0
    if levelA ~= levelB then return levelA > levelB end

    local playedA, playedB = RANKS.playedSeconds(a), RANKS.playedSeconds(b)
    if playedA and playedB and playedA ~= playedB then return playedA < playedB end
    if playedA and not playedB then return true end
    if playedB and not playedA then return false end

    return RANKS.nameLess(a, b)
end

function RANKS.levelLess(a, b)
    local levelA = tonumber(a and a.level) or 0
    local levelB = tonumber(b and b.level) or 0
    if levelA ~= levelB then return levelA < levelB end
    return RANKS.nameLess(a, b)
end

function RANKS.playedLess(a, b)
    local playedA, playedB = RANKS.playedSeconds(a), RANKS.playedSeconds(b)
    if playedA and playedB and playedA ~= playedB then return playedA < playedB end
    if playedA and not playedB then return true end
    if playedB and not playedA then return false end
    return RANKS.nameLess(a, b)
end

function RANKS.deathsLess(a, b)
    local deathsA = RANKS.deathCount(a)
    local deathsB = RANKS.deathCount(b)
    if deathsA and deathsB and deathsA ~= deathsB then return deathsA < deathsB end
    if deathsA and not deathsB then return true end
    if deathsB and not deathsA then return false end
    return RANKS.nameLess(a, b)
end

RANKS.sorters = {
    rank = RANKS.rankLess,
    name = RANKS.nameLess,
    level = RANKS.levelLess,
    played = RANKS.playedLess,
    deaths = RANKS.deathsLess,
}

function RANKS.sortRows(rows, key, ascending)
    local less = RANKS.sorters[key] or RANKS.rankLess
    local list = {}
    for index, row in ipairs(rows or {}) do list[index] = row end

    table.sort(list, function(a, b)
        if ascending == false then
            return less(b, a)
        end
        return less(a, b)
    end)
    return list
end

function RANKS.toggleSort(key)
    if RANKS.state.sortKey == key then
        RANKS.state.ascending = not RANKS.state.ascending
    else
        RANKS.state.sortKey = key
        RANKS.state.ascending = true
    end
    UI:Refresh()
end

-- Every stored row the page can see: the real server + guild merge, or the
-- made-up demo board while it is on. The fallback is Boards().level so a build
-- without the pure helpers still draws its capped board.
function RANKS.storeRows(module, boards)
    if module then
        local pure = module.Pure
        local roster
        if type(module.GetRoster) == "function" then
            local ok, value = pcall(module.GetRoster, module, false)
            if ok then roster = value end
        end

        if type(pure) == "table" and type(roster) == "table" then
            if type(boards) == "table" and boards.demo
                and type(pure.DemoRows) == "function" then
                local ok, list = pcall(pure.DemoRows, roster)
                if ok and type(list) == "table" then return list end
            elseif type(pure.Merge) == "function" then
                local ok, list = pcall(pure.Merge, roster)
                if ok and type(list) == "table" then return list end
            end
        end
    end

    if type(boards) == "table" and type(boards.level) == "table" then
        return boards.level
    end
    return {}
end

function RANKS.ownRow(module)
    if module and type(module.OwnRow) == "function" then
        local ok, row = pcall(module.OwnRow, module)
        if ok and type(row) == "table" then return row end
    end
    return nil
end

-- One board's rows: the tab picks the source, then the own row is attached for
-- the two real boards so it stays inline at its rank. The Friends tab draws
-- only rows whose name is on the local ladder.
function RANKS.boardRows(module, boards, tab)
    if tab == "fastest" then
        local list = {}
        if type(boards) == "table" and type(boards.records) == "table" then
            for index, row in ipairs(boards.records) do list[index] = row end
        end
        return RANKS.sortRows(list, RANKS.state.sortKey, RANKS.state.ascending)
    end

    local source = RANKS.storeRows(module, boards)
    local filtered = {}
    local ladder = (tab == "friends") and RANKS.ladder(false) or nil

    if type(boards) == "table" and boards.demo then
        if tab == "server" then
            for _, row in ipairs(source) do filtered[#filtered + 1] = row end
        elseif tab == "friends" then
            for _, row in ipairs(source) do
                if type(ladder) == "table" and ladder[RANKS.rowKey(row)] then
                    filtered[#filtered + 1] = row
                end
            end
        end
    else
        local wanted = nil
        if tab == "guild" then
            wanted = (module and module.GUILD_BOARD) or "guild"
        elseif tab == "server" then
            wanted = (module and module.SERVER_BOARD) or "server"
        end

        for _, row in ipairs(source) do
            if tab == "friends" then
                if type(ladder) == "table" and ladder[RANKS.rowKey(row)] then
                    filtered[#filtered + 1] = row
                end
            elseif wanted and row.board == wanted then
                filtered[#filtered + 1] = row
            end
        end
    end

    if (tab == "server" or tab == "guild") and type(boards) == "table" then
        local own = RANKS.ownRow(module)
        local pure = module and module.Pure
        if own and type(pure) == "table" and type(pure.WithOwn) == "function" then
            local ok, list = pcall(pure.WithOwn, filtered, own)
            if ok and type(list) == "table" then filtered = list end
        elseif own then
            local key = RANKS.rowKey(own)
            local present = false
            for _, row in ipairs(filtered) do
                if RANKS.rowKey(row) == key then present = true; break end
            end
            if not present then filtered[#filtered + 1] = own end
        end
    end

    local list = RANKS.sortRows(filtered, RANKS.state.sortKey, RANKS.state.ascending)
    local limit = RANKS_LEVEL_LIMIT

    -- The own row is always visible even when its rank is past the cap: the
    -- last slot is given up to it, with its real rank, so the player can find
    -- themselves without a separate block. Every other row keeps its true rank.
    local ownIndex = nil
    for index, row in ipairs(list) do
        if row.you then ownIndex = index; break end
    end

    local function ranked(row, rank)
        local copy = {}
        for key, value in pairs(row) do copy[key] = value end
        copy.ranksRank = rank
        return copy
    end

    local selected = {}
    local visible = math.min(#list, limit)
    for index = 1, visible do
        selected[index] = ranked(list[index], index)
    end

    if ownIndex and ownIndex > limit and #selected > 0 then
        selected[#selected] = ranked(list[ownIndex], ownIndex)
    end

    return selected
end

-- A name in the store, with its place in the same sorted order the board is
-- using. The own row is included because it is on the board even before a
-- packet has reported it. nil means "not in the store", never a made-up row.
function RANKS.search(module, boards, query)
    local text = string.lower(trimmed(query))
    if text == "" then return nil end

    local pool = {}
    local seen = {}
    for _, row in ipairs(RANKS.storeRows(module, boards)) do
        local key = RANKS.rowKey(row)
        if not seen[key] then
            seen[key] = true
            pool[#pool + 1] = row
        end
    end

    local own = RANKS.ownRow(module)
    if own and not seen[RANKS.rowKey(own)] then pool[#pool + 1] = own end

    local sorted = RANKS.sortRows(pool, RANKS.state.sortKey, RANKS.state.ascending)
    for index, row in ipairs(sorted) do
        local name = string.lower(tostring(row.name or ""))
        local realm = string.lower(tostring(row.realm or ""))
        if name == text or (name .. "-" .. realm) == text
            or (name .. " " .. realm) == text then
            return row, index
        end
    end

    return nil
end

-- The width a cell really needs, measured from the font string after its text
-- exists. A client that cannot answer falls back to a per-character estimate;
-- the layout is never guessed from a row count.
local function ranksTextWidth(label)
    if not label then return 0 end

    local ok, width = pcall(label.GetStringWidth, label)
    if ok and type(width) == "number" and width > 0 then
        if not (LT.IsSecret and LT:IsSecret(width)) then return width end
    end

    local text = ""
    if type(label.GetText) == "function" then
        local read, value = pcall(label.GetText, label)
        if read and type(value) == "string" then text = value end
    end

    return #text * 6
end

local function ranksOptions()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return nil
    end

    local ok, options = pcall(database.GetOptions, database)
    if ok and type(options) == "table" then return options end
    return nil
end

-- Writes the live options table, flags the character record changed and redraws
-- the page, so a switch never leaves a stale control behind.
local function ranksSave(reason)
    local database = LT.Database
    if type(database) == "table" and type(database.Save) == "function" then
        pcall(database.Save, database, "ranks:" .. tostring(reason or "change"))
    end
    UI:Refresh()
end

-- Gold goal (S-15). The option stores copper; the Settings row cycles these
-- values only. This is a readout, not a ledger: nothing is saved toward the
-- goal and no money is moved. A hand-edited value still formats honestly, and
-- the cycle simply returns to Off because it is not one of the steps.
--
-- Fields on RANKS, like the gates on RAIL: the main chunk is at the Lua 5.1
-- local ceiling, so helpers cost no extra local.
RANKS.gold = {}

RANKS.gold.steps = {
    0,
    10 * 10000,
    50 * 10000,
    100 * 10000,
    500 * 10000,
    1000 * 10000,
}

function RANKS.gold.value()
    local options = ranksOptions()
    local value = options and LT:Number(options.goldGoal)
    if not value or value < 0 then return 0 end
    return value
end

-- "12g 40s", "50g", "40s", "7c". Silver is dropped when it is zero so a whole
-- gold goal reads as "50g" rather than "50g 0s".
function RANKS.gold.amountText(copper)
    local amount = LT:Number(copper) or 0
    local gold = math.floor(amount / 10000)
    local silver = math.floor((amount % 10000) / 100)

    if gold > 0 then
        if silver > 0 then
            return tostring(gold) .. "g " .. tostring(silver) .. "s"
        end
        return tostring(gold) .. "g"
    end

    if silver > 0 then return tostring(silver) .. "s" end
    return tostring(amount % 100) .. "c"
end

function RANKS.gold.label(value)
    local copper = LT:Number(value) or 0
    if copper <= 0 then return "Off" end
    return tostring(math.floor(copper / 10000)) .. "g"
end

function RANKS.gold.next(value)
    local copper = LT:Number(value) or 0
    local index = nil

    for position, step in ipairs(RANKS.gold.steps) do
        if step == copper then index = position end
    end

    if not index then return RANKS.gold.steps[1] end
    return RANKS.gold.steps[(index % #RANKS.gold.steps) + 1]
end

function RANKS.gold.set(value)
    local options = ranksOptions()
    if options then
        options.goldGoal = LT:Number(value) or 0
    end

    local database = LT.Database
    if type(database) == "table" and type(database.Save) == "function" then
        pcall(database.Save, database, "settings:goldGoal")
    end
end

-- The one-line progress readout on the Ranks page. nil when the goal is off,
-- the client cannot answer, or the amount is restricted. The percentage is not
-- capped: a balance past the goal still reads honestly instead of pretending
-- to be exactly 100%.
function RANKS.gold.line()
    local goal = RANKS.gold.value()
    if goal <= 0 then return nil end
    if type(GetMoney) ~= "function" then return nil end

    local ok, money = pcall(GetMoney)
    if not ok then return nil end

    local amount = LT:Number(money)
    if not amount or amount < 0 then return nil end

    local percent = math.floor((amount / goal) * 100 + 0.5)
    return "Gold: " .. RANKS.gold.amountText(amount) .. " of " .. RANKS.gold.amountText(goal)
        .. " (" .. tostring(percent) .. "%)"
end

-- One reader for the four switches, because the popup and the page must never
-- disagree about what a switch says. The module answers first; the options
-- table is the fallback for a build whose module does not publish the getter;
-- `fallback` is what an absent key means (off for the master switch).
local function ranksOptionOn(key, fallback)
    local module = ranksModule()
    local reader = (key == "ranksShare") and "IsSharing" or RANKS_SCOPE_READ[key]

    if module and reader and type(module[reader]) == "function" then
        local ok, value = pcall(module[reader], module)
        if ok and value ~= nil then return value == true end
    end

    local options = ranksOptions()
    local value = options and options[key]
    if value == nil then return fallback == true end
    return value == true
end

-- One writer for the same four keys. The module's keyed SetShare(key, bool) is
-- the contract; the older per-board setters are the fallback for a build that
-- predates it. The option is written either way, so the record and the module
-- can never end up saying different things.
local function ranksSetOption(key, value)
    local enabled = value == true
    local module = ranksModule()
    local writer = RANKS_SCOPE_WRITE[key]
    local call, mode

    if module then
        if type(module.SetShare) == "function" then
            call, mode = module.SetShare, "key"
        elseif key == "ranksShare" and type(module.SetSharing) == "function" then
            call, mode = module.SetSharing, "master"
        elseif writer and type(module[writer]) == "function" then
            call, mode = module[writer], "board"
        end
    end

    if call then
        local ok, accepted, message
        if mode == "key" then
            ok, accepted, message = pcall(call, module, key, enabled)
        else
            ok, accepted, message = pcall(call, module, enabled)
        end

        if not ok then
            LT:Warn("The board setting could not be changed: " .. tostring(accepted))
            return
        end
        if accepted == false then
            LT:Warn(tostring(message or "The board setting could not be changed."))
            return
        end
    end

    local options = ranksOptions()
    if options then options[key] = enabled end

    ranksSave(key)
end

local function ranksDefaultChannel()
    local module = ranksModule()
    local name = module and module.DEFAULT_CUSTOM_CHANNEL
    if type(name) == "string" and name ~= "" then return name end
    return RANKS_DEFAULT_CHANNEL
end

-- The transport's own rule for a channel name, applied before anything reaches
-- the saved variable: trimmed, non-empty, inside the module's limit and free of
-- the control characters and the pipe an addon-message channel cannot carry.
-- nil means the name cannot be used.
local function ranksCleanChannel(value)
    if type(value) ~= "string" then return nil end

    local name = trimmed(value)
    if name == "" then return nil end

    local module = ranksModule()
    local limit = tonumber(module and module.CHANNEL_LIMIT)
        or RANKS_CHANNEL_LIMIT_FALLBACK
    if #name > limit or name:find("[%c|]") then return nil end

    return name
end

-- The name a field commit should store: the typed text, or the default channel
-- when the field is only whitespace. nil means the text is not usable.
local function ranksFieldChannel(value)
    local name = ranksCleanChannel(value)
    if name then return name end
    if type(value) ~= "string" or trimmed(value) ~= "" then return nil end
    return ranksCleanChannel(ranksDefaultChannel())
end

local function ranksChannelName()
    local module = ranksModule()

    -- The module owns the name and sanitises it; reading through it keeps the
    -- field showing exactly the channel Join and Leave will use.
    if module and type(module.ChannelName) == "function" then
        local ok, name = pcall(module.ChannelName, module)
        if ok and type(name) == "string" and trimmed(name) ~= "" then
            return trimmed(name)
        end
    end

    local options = ranksOptions()
    local name = options and options.ranksChannel
    if type(name) ~= "string" or trimmed(name) == "" then return ranksDefaultChannel() end
    return trimmed(name)
end

local function ranksChannelState(boards)
    local module = ranksModule()
    local joined, name

    if type(boards) == "table" and type(boards.channel) == "table" then
        if boards.channel.joined ~= nil then joined = boards.channel.joined == true end
        if type(boards.channel.name) == "string" and boards.channel.name ~= "" then
            name = boards.channel.name
        end
    end

    if module then
        if type(module.IsChannelJoined) == "function" then
            local ok, value = pcall(module.IsChannelJoined, module)
            if ok and value ~= nil then joined = value == true end
        elseif type(module.ChannelJoined) == "function" then
            local ok, value = pcall(module.ChannelJoined, module)
            if ok and value ~= nil then joined = value == true end
        end
    end

    local options = ranksOptions()
    if joined == nil then
        joined = options ~= nil and options.ranksChannelJoined == true
    end
    if not name then name = ranksChannelName() end

    return joined == true, name
end

local function ranksJoin(page)
    local module = ranksModule()

    if not module or type(module.JoinChannel) ~= "function" then
        LT:Warn("This leaderboard has no channel to join.")
        return
    end

    -- The transport's own rule, applied before the name can be stored: a field
    -- that cannot be joined is refused here rather than saved and then refused.
    local name = ranksFieldChannel(page.channelBox:GetText())
    if not name then
        LT:Warn("That is not a usable channel name.")
        page.channelBox:SetText(ranksChannelName())
        return
    end

    local ok, accepted, message = pcall(module.JoinChannel, module, name)
    if not ok then
        LT:Error("Joining " .. name .. " failed: " .. tostring(accepted))
        page.channelBox:SetText(ranksChannelName())
        return
    end
    if accepted == false then
        LT:Warn(tostring(message or ("Could not join " .. name .. ".")))
        page.channelBox:SetText(ranksChannelName())
        return
    end

    -- The join succeeded, so the module owns the name now. Store what its own
    -- ChannelName() reports instead of the raw field text, so the record holds
    -- exactly the name Join and Leave will use.
    local committed = name
    if type(module.ChannelName) == "function" then
        local read, value = pcall(module.ChannelName, module)
        if read then
            local cleaned = ranksCleanChannel(value)
            if cleaned then committed = cleaned end
        end
    end

    local options = ranksOptions()
    if options then
        options.ranksChannel = committed
        options.ranksChannelJoined = true
    end

    page.channelBox:SetText(committed)
    ranksSave("ranksChannel")
end

local function ranksLeave()
    local module = ranksModule()

    if not module or type(module.LeaveChannel) ~= "function" then
        LT:Warn("This leaderboard has no channel to leave.")
        return
    end

    local ok, accepted, message = pcall(module.LeaveChannel, module)
    if not ok then
        LT:Error("Leaving the channel failed: " .. tostring(accepted))
        return
    end
    if accepted == false then
        LT:Warn(tostring(message or "Could not leave the channel."))
        return
    end

    local options = ranksOptions()
    if options then options.ranksChannelJoined = false end
    ranksSave("ranksLeave")
end

-- Turning the made-up demo board on or off. The module owns the roster write
-- and fires its own event; the page is redrawn here as well, so the button's
-- effect is visible on the same click even when the module's event is queued
-- for the next frame.
local function ranksSetDemo(enabled)
    local module = ranksModule()
    if not module or type(module.SetDemo) ~= "function" then
        LT:Warn("This leaderboard module cannot build a demo board.")
        return
    end

    local ok, done, detail = pcall(module.SetDemo, module, enabled == true)
    if not ok then
        LT:Warn("The demo board could not be changed: " .. tostring(done))
        return
    end
    if done == false then
        LT:Warn(tostring(detail or "The demo board could not be changed."))
        return
    end

    UI:Refresh()
end

-- Reads the boards with the friends filter where the module applies it: before
-- its own top-N cap, so a friend ranked past the cap still makes the board. A
-- client that cannot read a friend list gets the unfiltered board rather than an
-- empty one, and the module says so through boards.friendsAvailable.
local function ranksReadBoards()
    local module = ranksModule()
    if not module or type(module.Boards) ~= "function" then return nil, module end

    local friendsOnly = ranksOptionOn("ranksFriends", true)
    local ok, value = pcall(module.Boards, module, { friendsOnly = friendsOnly })
    local boards = ok and type(value) == "table" and value or nil

    if boards and friendsOnly and boards.friendsAvailable == false then
        local read, plain = pcall(module.Boards, module, { friendsOnly = false })
        if read and type(plain) == "table" then boards = plain end
    end

    return boards, module
end

------------------------------------------------------------------------------
-- Sharing popup
--
-- The four switches, the demo board and the channel row, in one window behind
-- the page's Share button. Nothing that changes what leaves the machine sits
-- next to a row a player might click by accident, and the channel does not
-- double the bottom chrome of the scoreboard's tab strip.
------------------------------------------------------------------------------

local RANKS_SHARE_WIDTH = 430
local RANKS_SHARE_HEIGHT = 322
local RANKS_RECORDS_WIDTH = 480
local RANKS_RECORDS_HEIGHT = 330

sharePopup = { frame = nil, toggles = {} }
recordsPopup = { frame = nil, rows = {}, headers = {} }

function sharePopup:IsShown()
    return self.frame ~= nil and self.frame:IsShown() and true or false
end

function sharePopup:Hide()
    if self.frame then self.frame:Hide() end
end

function sharePopup:EnsureFrame()
    if self.frame then return self.frame end

    local window = MakePopupFrame("LunchboxToolkitRanksShareFrame",
        RANKS_SHARE_WIDTH, RANKS_SHARE_HEIGHT, "share")
    if not window then return nil end

    local pad = 14
    local y = -pad

    local title = MakeLabel(window, "Sharing", "GameFontNormal", LT.Palette:RGB("brand"))
    title:SetPoint("TOPLEFT", pad, y)
    y = y - (title:GetStringHeight() or 16) - 2

    local note = MakeLabel(window,
        "Nothing leaves this machine while Share at all is off.",
        "GameFontNormalSmall", LT.Palette:RGB("muted"))
    note:SetPoint("TOPLEFT", pad, y)
    note:SetWidth(RANKS_SHARE_WIDTH - (pad * 2))
    note:SetJustifyH("LEFT")
    oneLine(note)
    y = y - (note:GetStringHeight() or 12) - 8

    for index, definition in ipairs(RANKS_TOGGLES) do
        local entry = { definition = definition }

        entry.check = MakeCheck(window, false, function(value)
            ranksSetOption(definition.key, value)
            -- The page and this window read the same key; redrawing both keeps
            -- the switch's own state and the board honest on the same click.
            sharePopup:Render()
        end)
        entry.check:SetPoint("TOPLEFT", pad, y - 1)

        entry.label = MakeLabel(window, definition.label, "GameFontNormalSmall",
            LT.Palette:RGB("text"))
        entry.label:SetPoint("TOPLEFT", pad + 24, y)
        entry.label:SetWidth(RANKS_SHARE_WIDTH - (pad * 2) - 60)
        entry.label:SetJustifyH("LEFT")
        oneLine(entry.label)

        entry.info = MakeInfo(window, definition.label, definition.help)
        if entry.info then
            entry.info:SetPoint("LEFT", entry.label, "RIGHT", 6, 0)
        end
        entry.hover = MakeHoverTarget(window, definition.label, definition.help,
            entry.label)

        self.toggles[index] = entry
        y = y - 22
    end

    y = y - 8

    self.demoNote = MakeLabel(window, "", "GameFontNormalSmall",
        LT.Palette:RGB("muted"))
    self.demoNote:SetPoint("TOPLEFT", pad, y)
    self.demoNote:SetWidth(RANKS_SHARE_WIDTH - (pad * 2))
    self.demoNote:SetJustifyH("LEFT")
    oneLine(self.demoNote)
    y = y - 18

    self.previewButton = MakeButton(window, "Preview board", 116, 20, function()
        ranksSetDemo(true)
        sharePopup:Render()
    end)
    self.previewButton:SetPoint("TOPLEFT", pad, y - 2)

    self.stopButton = MakeButton(window, "Stop demo", 90, 20, function()
        ranksSetDemo(false)
        sharePopup:Render()
    end)
    self.stopButton:SetPoint("TOPLEFT", pad + 124, y - 2)

    self.demoInfo = MakeInfo(window, "Demo board",
        "Demo rows are made up by the add-on and are never sent. They are never "
        .. "mixed into the guild or party boards either, so the real board is "
        .. "unchanged while they show. They exist so the scoreboard can be seen "
        .. "before anyone else has shared a row.")
    if self.demoInfo then
        self.demoInfo:SetPoint("LEFT", self.stopButton, "RIGHT", 6, 0)
    end

    -- The channel row lives here rather than under the scoreboard: the bottom
    -- of the page belongs to the four board tabs, and Join/Leave still need to
    -- be reachable without opening a second window.
    y = y - 30

    self.channelHeading = MakeLabel(window, "Channel", "GameFontNormalSmall",
        LT.Palette:RGB("brand"))
    self.channelHeading:SetPoint("TOPLEFT", pad, y)
    self.channelInfo = MakeInfo(window, "Channel", "Join or leave the custom "
        .. "channel the board travels on. The name is shared by everyone taking "
        .. "part; LBTK is the default. Joining reads no character data by itself.")
    if self.channelInfo then
        self.channelInfo:SetPoint("LEFT", self.channelHeading, "RIGHT", 6, 0)
    end
    y = y - 20

    self.channelBox = MakeEditBox(window, 140, 20, ranksChannelName(), function(text)
        local name = ranksFieldChannel(text)
        if not name then
            LT:Warn("That is not a usable channel name.")
            if sharePopup.channelBox then
                sharePopup.channelBox:SetText(ranksChannelName())
            end
            return
        end

        local options = ranksOptions()
        if options then options.ranksChannel = name end
        ranksSave("ranksChannel")
    end)
    self.channelBox:SetPoint("TOPLEFT", pad + 24, y)

    self.joinButton = MakeButton(window, "Join", 56, 20, function()
        ranksJoin(sharePopup)
    end)
    self.joinButton:SetPoint("LEFT", self.channelBox, "RIGHT", 8, 0)

    self.leaveButton = MakeButton(window, "Leave", 60, 20, function()
        ranksLeave()
    end)
    self.leaveButton:SetPoint("LEFT", self.joinButton, "RIGHT", 4, 0)

    self.channelState = MakeLabel(window, "", "GameFontNormalSmall",
        LT.Palette:RGB("muted"))
    self.channelState:SetPoint("TOPLEFT", pad + 24, y - 24)
    self.channelState:SetWidth(RANKS_SHARE_WIDTH - (pad * 2) - 24)
    self.channelState:SetJustifyH("LEFT")
    oneLine(self.channelState)

    local close = MakeButton(window, "Close", 70, 20, function()
        sharePopup:Hide()
    end)
    close:SetPoint("BOTTOMLEFT", pad, 12)

    window:Hide()
    self.frame = window
    return window
end

function sharePopup:Render()
    local boards = ranksReadBoards()

    for _, entry in ipairs(self.toggles) do
        local definition = entry.definition
        entry.check:SetChecked(ranksOptionOn(definition.key, definition.default))
    end

    local demo = type(boards) == "table" and boards.demo == true
    if demo then
        self.demoNote:SetText("Demo rows are showing — not real players.")
        self.previewButton:Hide()
        self.stopButton:Show()
    else
        self.demoNote:SetText("Preview fills the board with made-up rows.")
        self.previewButton:Show()
        self.stopButton:Hide()
    end

    -- The channel controls show the name Join and Leave will use. A focused
    -- field is left alone so a rebuild cannot eat the text being typed.
    if self.channelBox then
        if not (self.channelBox.HasFocus and self.channelBox:HasFocus()) then
            self.channelBox:SetText(ranksChannelName())
        end

        local module = ranksModule()
        local joined, channelName = ranksChannelState(boards)
        if joined then
            self.channelState:SetText("Joined " .. tostring(channelName) .. ".")
            local go = LT.Palette:RGB("go")
            self.channelState:SetTextColor(go.r, go.g, go.b)
        else
            self.channelState:SetText("Not joined.")
            local muted = LT.Palette:RGB("muted")
            self.channelState:SetTextColor(muted.r, muted.g, muted.b)
        end

        local hasJoin = module and type(module.JoinChannel) == "function"
        local hasLeave = module and type(module.LeaveChannel) == "function"
        if hasJoin then self.joinButton:Show() else self.joinButton:Hide() end
        if hasLeave then self.leaveButton:Show() else self.leaveButton:Hide() end
    end
end

function sharePopup:Open()
    local window = self:EnsureFrame()
    if not window then
        LT:Print("The sharing options cannot be built in combat. "
            .. "Open them again after the fight.")
        return false
    end

    placePopupFrame(window, "share", RANKS_SHARE_WIDTH, RANKS_SHARE_HEIGHT)
    self:Render()
    window:Show()
    return true
end

------------------------------------------------------------------------------
-- Records popup
--
-- The top ten recorded runs to level 60, fastest first. A separate window
-- because the page is the level board: mixing two boards on one page made the
-- second one a footnote.
------------------------------------------------------------------------------

function recordsPopup:IsShown()
    return self.frame ~= nil and self.frame:IsShown() and true or false
end

function recordsPopup:Hide()
    if self.frame then self.frame:Hide() end
end

function recordsPopup:EnsureFrame()
    if self.frame then return self.frame end

    local window = MakePopupFrame("LunchboxToolkitRanksRecordsFrame",
        RANKS_RECORDS_WIDTH, RANKS_RECORDS_HEIGHT, "records")
    if not window then return nil end

    local pad = 14
    local y = -pad

    local title = MakeLabel(window, "Fastest to 60", "GameFontNormal",
        LT.Palette:RGB("brand"))
    title:SetPoint("TOPLEFT", pad, y)
    y = y - (title:GetStringHeight() or 16) - 2

    local note = MakeLabel(window, "The " .. tostring(RANKS_RECORD_LIMIT)
        .. " fastest recorded runs to level 60, by active play time. A character "
        .. "without a recorded level 60 has no place here.",
        "GameFontNormalSmall", LT.Palette:RGB("muted"))
    note:SetPoint("TOPLEFT", pad, y)
    note:SetWidth(RANKS_RECORDS_WIDTH - (pad * 2))
    note:SetJustifyH("LEFT")
    oneLine(note)
    y = y - (note:GetStringHeight() or 12) - 8

    self.bodyTop = y

    local headerText = { "Rank", "Name", "Class", "Played" }
    self.headers = {}
    for index, text in ipairs(headerText) do
        local header = MakeLabel(window, text, "GameFontNormalSmall",
            LT.Palette:RGB("muted"))
        header:SetJustifyH("LEFT")
        oneLine(header)
        header:SetWidth(0)
        self.headers[index] = header
    end

    self.rows = {}
    for index = 1, RANKS_RECORD_LIMIT do
        local cells = {
            rank = MakeLabel(window, "", "GameFontNormalSmall", LT.Palette:RGB("muted")),
            name = MakeLabel(window, "", "GameFontNormalSmall", LT.Palette:RGB("text")),
            class = MakeLabel(window, "", "GameFontNormalSmall", LT.Palette:RGB("muted")),
            time = MakeLabel(window, "", "GameFontNormalSmall", LT.Palette:RGB("text")),
        }
        for _, key in ipairs({ "rank", "name", "class", "time" }) do
            cells[key]:SetJustifyH("LEFT")
            oneLine(cells[key])
            cells[key]:SetWidth(0)
        end
        self.rows[index] = cells
    end

    self.emptyLabel = MakeLabel(window, "", "GameFontNormalSmall",
        LT.Palette:RGB("muted"))
    self.emptyLabel:SetPoint("TOPLEFT", pad, y)
    self.emptyLabel:SetWidth(RANKS_RECORDS_WIDTH - (pad * 2))
    self.emptyLabel:SetJustifyH("LEFT")
    oneLine(self.emptyLabel)

    local close = MakeButton(window, "Close", 70, 20, function()
        recordsPopup:Hide()
    end)
    close:SetPoint("BOTTOMLEFT", pad, 12)

    window:Hide()
    self.frame = window
    return window
end

function recordsPopup:Render(boards)
    local pad = 14
    local list = {}
    if type(boards) == "table" and type(boards.records) == "table" then
        for _, row in ipairs(boards.records) do
            if type(row) == "table" and #list < RANKS_RECORD_LIMIT then
                list[#list + 1] = row
            end
        end
    end

    local widths = { 0, 0, 0, 0 }
    local keys = { "rank", "name", "class", "time" }

    for index, row in ipairs(list) do
        local cells = self.rows[index]
        cells.rank:SetText(tostring(index) .. ".")
        cells.name:SetText(ranksNameText(row))
        cells.class:SetText(ranksClassName(row.class))
        cells.time:SetText(ranksDuration(row.at60))

        local r, g, b = ranksClassColour(row.class)
        cells.name:SetTextColor(r, g, b)

        for column, key in ipairs(keys) do
            widths[column] = math.max(widths[column], ranksTextWidth(cells[key]))
        end
    end

    -- The headings are measured too, so a heading wider than every value still
    -- sits in a column wide enough for it.
    for column, header in ipairs(self.headers) do
        widths[column] = math.max(widths[column], ranksTextWidth(header))
    end

    local xs = {}
    local x = pad
    for column = 1, #keys do
        xs[column] = x
        x = x + widths[column] + RANKS_COLUMN_GAP
    end

    if #list == 0 then
        for _, header in ipairs(self.headers) do header:Hide() end
        for index = 1, #self.rows do
            local cells = self.rows[index]
            for _, key in ipairs(keys) do cells[key]:Hide() end
        end

        local sentence
        if type(boards) == "table" then
            sentence = tostring(boards.emptyRecords or "Nobody has reached level 60 yet.")
        else
            sentence = "The leaderboard could not be read."
        end
        self.emptyLabel:SetText(sentence)
        self.emptyLabel:ClearAllPoints()
        self.emptyLabel:SetPoint("TOPLEFT", pad, self.bodyTop or 0)
        self.emptyLabel:Show()
        return
    end

    self.emptyLabel:Hide()

    for column, header in ipairs(self.headers) do
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", xs[column], self.bodyTop)
        header:Show()
    end

    local y = self.bodyTop - math.max(RANKS_LINE_FALLBACK,
        ranksHeight(self.headers[1])) - 4

    for index = 1, #self.rows do
        local cells = self.rows[index]
        local row = list[index]

        if not row then
            for _, key in ipairs(keys) do cells[key]:Hide() end
        else
            for column, key in ipairs(keys) do
                cells[key]:ClearAllPoints()
                cells[key]:SetPoint("TOPLEFT", xs[column], y)
                cells[key]:Show()
            end

            y = y - math.max(RANKS_LINE_FALLBACK, ranksHeight(cells.name)) - RANKS_ROW_GAP
        end
    end
end

function recordsPopup:Open()
    local window = self:EnsureFrame()
    if not window then
        LT:Print("The record board cannot be built in combat. "
            .. "Open it again after the fight.")
        return false
    end

    local boards = ranksReadBoards()
    placePopupFrame(window, "records", RANKS_RECORDS_WIDTH, RANKS_RECORDS_HEIGHT)
    self:Render(boards)
    window:Show()
    return true
end

-- Builds every control and every row label once. Called only out of combat, so
-- a redraw during a fight can move and re-text what already exists.
local function buildRanksPage()
    if ranksPage then return ranksPage end
    if ranksLocked() then return nil end

    local scroll = MakeScroll(contentFrame, "ranks")

    -- The board's own edge: one hairline round the area the scoreboard fills,
    -- so the page reads as a panel inside the window rather than as loose text.
    -- A card is 1 px of texture and nothing else, so it moves no row and the
    -- board inside this scroll can carry its own tints and separators on top.
    LT.Chrome.Card(scroll)

    local pageContent = scroll.content

    -- Every label below is created once and then re-texted, so the scroll
    -- child needs no pool: nothing on this page is ever returned to one.
    --
    -- Hidden rows keep their last position, so asking the generic extent walk
    -- would leave empty space for a board that has since shrunk. The draw
    -- stores the height it actually placed, measured from the font strings.
    local baseExtent = scroll.GetContentExtent
    function scroll:GetContentExtent()
        local measured = self.ranksExtent
        if type(measured) == "number" and measured > 0 then return measured end
        return baseExtent(self)
    end

    local built = { scroll = scroll }

    local function label(size, colour)
        local text = MakeLabel(pageContent, "", size or "GameFontNormalSmall", colour)
        text:SetJustifyH("LEFT")
        oneLine(text)
        text:SetWidth(RANKS_CONTENT_WIDTH)
        return text
    end

    built.title = label("GameFontNormal")
    built.titleInfo = MakeInfo(pageContent, "Ranks", "Four boards in one page: "
        .. "Guild and party boards, plus Friends and Fastest to 60. Rank, class "
        .. "marker, name, level and played time. A row is tinted by its faction "
        .. "and the class marker carries the class colour. Played freezes at the "
        .. "time-to-60 record once level 60 has been reached. Click a heading to "
        .. "sort; the triangle marks the active column. Your own row is inline and "
        .. "tinted gold, without a '(you)' suffix. Rows are reported by other "
        .. "players and are not checked against their characters. Nothing leaves "
        .. "this machine until Share at all is on.")

    -- Both buttons stay reachable above the board; the bottom edge belongs to
    -- the four tabs.
    built.shareButton = MakeButton(pageContent, "Share…", 84, 20, function()
        sharePopup:Open()
    end)
    built.recordsButton = MakeButton(pageContent, "Records", 84, 20, function()
        recordsPopup:Open()
    end)

    built.demoNote = label("GameFontNormalSmall", LT.Palette:RGB("muted"))

    -- Search one player by name (or name-realm). A row is shown only when the
    -- store really holds that name; an unknown one is said to be unknown.
    built.searchLabel = label("GameFontNormalSmall", LT.Palette:RGB("brand"))
    built.searchLabel:SetText("Find player")
    built.searchInfo = MakeInfo(pageContent, "Find player", "Type a name that has "
        .. "been shared into the store. A row outside the top 20 is still shown, "
        .. "with an Add to Friends button. A name the store does not hold is "
        .. "reported as unknown; nothing is made up.")
    built.searchBox = MakeEditBox(pageContent, 170, 20, "", function(text)
        RANKS.state.search = trimmed(text)
        UI:Refresh()
    end)
    built.searchMessage = label("GameFontNormalSmall", LT.Palette:RGB("muted"))
    built.searchResult = nil

    -- The cap line is shown only when the character is level 60 and Played can
    -- answer. Created once with the page.
    built.level60Line = label("GameFontNormalSmall", LT.Palette:RGB("muted"))
    -- The optional gold readout sits in the same strip as the pace/cap line.
    built.goldGoalLine = label("GameFontNormalSmall", LT.Palette:RGB("muted"))

    built.levelHeading = label("GameFontNormalSmall", LT.Palette:RGB("brand"))
    built.levelInfo = MakeInfo(pageContent, "Boards", "Guild and party boards show "
        .. "the top " .. tostring(RANKS_LEVEL_LIMIT) .. " rows from each received "
        .. "board. Friends shows rows whose name you added to the local ladder. "
        .. "Fastest to 60 shows recorded runs at the cap. Your own row takes part "
        .. "like any other and is tinted, never marked with a word. Only rows "
        .. "received while sharing was on can appear.")

    -- The column headings of the scoreboard. Their x positions are measured in
    -- the draw, from the same labels the rows use, so the headings sit exactly
    -- over their columns. A heading is clickable; the active one is white and
    -- carries a ^ or v.
    built.headers = {}
    built.headerButtons = {}
    for _, spec in ipairs(RANKS.COLUMNS) do
        local header = label("GameFontNormalSmall", LT.Palette:RGB("muted"))
        header:SetText(spec.label)
        built.headers[spec.key] = header

        if spec.sortable then
            local button = CreateFrame("Button", nil, pageContent)
            button:SetHeight(RANKS_LINE_FALLBACK)
            button:SetScript("OnClick", function()
                RANKS.toggleSort(spec.key)
            end)
            built.headerButtons[spec.key] = button
        end
    end

    -- One set of labels and row tints per line, built once and re-texted. The
    -- tint carries the faction, the marker the class, and the 1 px rule is the
    -- separator the player asked to keep.
    local function rowCells()
        local cells = {
            rank = label("GameFontNormalSmall", LT.Palette:RGB("muted")),
            name = label("GameFontNormalSmall", LT.Palette:RGB("text")),
            level = label("GameFontNormalSmall", LT.Palette:RGB("text")),
            played = label("GameFontNormalSmall", LT.Palette:RGB("text")),
            deaths = label("GameFontNormalSmall", LT.Palette:RGB("text")),
        }

        cells.marker = pageContent:CreateTexture(nil, "ARTWORK")
        cells.marker:SetSize(RANKS_MARKER_SIZE, RANKS_MARKER_SIZE)

        cells.tint = pageContent:CreateTexture(nil, "BACKGROUND")
        cells.own = pageContent:CreateTexture(nil, "BACKGROUND")
        cells.rule = pageContent:CreateTexture(nil, "BACKGROUND")
        cells.rule:SetHeight(1)

        return cells
    end

    built.levelRows = {}
    for index = 1, RANKS_LEVEL_LIMIT do
        built.levelRows[index] = rowCells()
    end

    built.searchCells = rowCells()
    built.searchAdd = MakeButton(pageContent, "Add to Friends", 116, 18, function()
        local row = built.searchResult
        if not row then return end
        if RANKS.addFriend(row) then UI:Refresh() end
    end)
    built.searchNote = label("GameFontNormalSmall", LT.Palette:RGB("muted"))

    -- One honest sentence for a board with no rows. The demo preview lives in
    -- the sharing popup, not on the page.
    built.levelEmpty = label("GameFontNormalSmall", LT.Palette:RGB("muted"))

    -- The four bottom tabs. Same widget and same selected style as the window's
    -- own strip; they are re-parented to the content frame on every draw, so a
    -- page switch hides them with the rest of the Ranks page.
    built.tabButtons = {}
    for _, definition in ipairs(RANKS.TABS) do
        built.tabButtons[definition.key] = MakePageTab(contentFrame, definition.label,
            function()
                if RANKS.state.tab == definition.key then return end
                RANKS.state.tab = definition.key
                UI:Refresh()
            end)
    end

    ranksPage = built
    return built
end

-- The scoreboard itself. One pass measures every cell after its text exists,
-- then the columns are anchored from those measurements, so nothing is guessed
-- from a row count and a wider name or a taller font moves the next column
-- instead of overlapping it.
local function drawRanks(cursor)
    -- Ask for the end-of-fight redraw before anything else: a page opened for
    -- the first time during a fight has nothing to draw, and this registration
    -- is the only thing that will bring it back.
    watchRegen()

    local page = ranksPage or buildRanksPage()

    -- Never build a protected frame in combat. If the page has already been
    -- built, drawing it again only moves and re-texts existing widgets, which
    -- is safe; if it has not, the page stays empty until the fight ends.
    if not page then
        cursor.y = 0
        return
    end

    local textColour = LT.Palette:RGB("text")
    local mutedColour = LT.Palette:RGB("muted")
    local brandColour = LT.Palette:RGB("brand")

    local function hide(widget)
        if widget then widget:Hide() end
    end

    local function hideCells(cells)
        if not cells then return end
        for _, key in ipairs({ "rank", "name", "level", "played", "deaths" }) do
            hide(cells[key])
        end
        hide(cells.marker)
        hide(cells.tint)
        hide(cells.own)
        hide(cells.rule)
    end

    -- Tabs first: their measured height is what the scroll gives up at the
    -- bottom, so a taller client font never puts the last row under the strip.
    local tabX = RANKS_COLUMN_X
    local tabHeight = 0
    for _, definition in ipairs(RANKS.TABS) do
        local tab = page.tabButtons[definition.key]
        if tab then
            tab:SetParent(contentFrame)
            tab:SetSelected(RANKS.state.tab == definition.key)

            local width = tab.label and ranksTextWidth(tab.label) or 0
            if not width or width <= 0 then width = #definition.label * 7 end
            width = math.max(80, math.floor(width + 24))

            tab:SetWidth(width)
            tab:ClearAllPoints()
            tab:SetPoint("BOTTOMLEFT", contentFrame, "BOTTOMLEFT", tabX, 0)
            tab:Show()

            tabX = tabX + width + TAB.gap
            local height = tab:GetHeight() or 0
            if height > tabHeight then tabHeight = height end
        end
    end
    if tabHeight < 1 then tabHeight = TAB.heightIdle end

    local scroll = page.scroll
    scroll:SetParent(contentFrame)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", 0, cursor.y)
    scroll:SetPoint("BOTTOMRIGHT", 0, tabHeight + 6)
    scroll:Show()

    local y = 0

    local function line(target, x, gap, colour)
        if colour then target:SetTextColor(colour.r, colour.g, colour.b) end
        target:ClearAllPoints()
        target:SetPoint("TOPLEFT", x, y)
        target:Show()
        y = y - ranksHeight(target) - (gap or RANKS_ROW_GAP)
    end

    page.title:SetText("Ranks")
    page.title:SetTextColor(textColour.r, textColour.g, textColour.b)
    page.title:Show()
    page.title:ClearAllPoints()
    page.title:SetPoint("TOPLEFT", RANKS_COLUMN_X, y)
    if page.titleInfo then
        page.titleInfo:ClearAllPoints()
        page.titleInfo:SetPoint("LEFT", page.title, "RIGHT", 6, 0)
        page.titleInfo:Show()
    end

    -- Share… and Records stay reachable above the strip rather than being lost
    -- with the old bottom controls.
    page.shareButton:SetText("Share…")
    page.shareButton:ClearAllPoints()
    page.shareButton:SetPoint("TOPLEFT", 412, y - 2)
    page.shareButton:Show()

    page.recordsButton:SetText("Records")
    page.recordsButton:ClearAllPoints()
    page.recordsButton:SetPoint("TOPLEFT", 504, y - 2)
    page.recordsButton:Show()

    y = y - math.max(16, ranksHeight(page.title)) - 6

    local boards, module = ranksReadBoards()

    if type(boards) == "table" and boards.demo then
        page.demoNote:SetText("Demo rows — not real players. Stop them in Share…")
        line(page.demoNote, RANKS_COLUMN_X, RANKS_ROW_GAP, mutedColour)
    else
        hide(page.demoNote)
    end

    -- Search. The field commits on Enter; the row itself is measured and drawn
    -- with the board so its columns line up with every other row.
    page.searchLabel:SetText("Find player")
    page.searchLabel:SetTextColor(brandColour.r, brandColour.g, brandColour.b)
    page.searchLabel:ClearAllPoints()
    page.searchLabel:SetPoint("TOPLEFT", RANKS_COLUMN_X, y)
    page.searchLabel:Show()
    if page.searchInfo then
        page.searchInfo:ClearAllPoints()
        page.searchInfo:SetPoint("LEFT", page.searchLabel, "RIGHT", 6, 0)
        page.searchInfo:Show()
    end

    page.searchBox:ClearAllPoints()
    page.searchBox:SetPoint("TOPLEFT", RANKS_COLUMN_X + 78, y - 2)
    if not (page.searchBox.HasFocus and page.searchBox:HasFocus()) then
        page.searchBox:SetText(RANKS.state.search)
    end
    page.searchBox:Show()
    y = y - math.max(20, ranksHeight(page.searchLabel) + 8)

    local entries = RANKS.boardRows(module, boards, RANKS.state.tab)
    local query = trimmed(RANKS.state.search)
    local searchRow, searchRank = nil, nil
    if query ~= "" then searchRow, searchRank = RANKS.search(module, boards, query) end
    page.searchResult = searchRow

    if query ~= "" and not searchRow then
        page.searchMessage:SetText("No player named \"" .. query
            .. "\" in the board store.")
        line(page.searchMessage, RANKS_COLUMN_X, RANKS_AREA_GAP, LT.Palette:RGB("stop"))
    else
        hide(page.searchMessage)
    end

    -- The board heading names the tab that is up.
    page.levelHeading:SetText(RANKS.TITLES[RANKS.state.tab] or "Board")
    page.levelHeading:SetTextColor(brandColour.r, brandColour.g, brandColour.b)
    page.levelHeading:ClearAllPoints()
    page.levelHeading:SetPoint("TOPLEFT", RANKS_COLUMN_X, y)
    page.levelHeading:Show()
    if page.levelInfo then
        page.levelInfo:ClearAllPoints()
        page.levelInfo:SetPoint("LEFT", page.levelHeading, "RIGHT", 6, 0)
        page.levelInfo:Show()
    end
    y = y - math.max(14, ranksHeight(page.levelHeading)) - 6

    -- Deaths are a column only when a row actually carries a number. No row
    -- does today; omitting the column beats printing an em dash everywhere.
    local showDeaths = RANKS.hasDeaths(entries, searchRow)

    local widths = {
        rank = 0,
        marker = RANKS_MARKER_SIZE,
        name = 0,
        level = 0,
        played = 0,
        deaths = 0,
    }

    local function setCells(cells, row, rank)
        cells.rank:SetText(rank and (tostring(rank) .. ".") or "")
        cells.name:SetText(ranksNameText(row))
        cells.level:SetText(tostring(tonumber(row.level) or 0))
        cells.played:SetText(RANKS.playedText(row))
        local deaths = RANKS.deathCount(row)
        cells.deaths:SetText(deaths and tostring(deaths) or "")
    end

    local measuredKeys = { "rank", "name", "level", "played" }
    for index, row in ipairs(entries) do
        local cells = page.levelRows[index]
        setCells(cells, row, row.ranksRank or index)
        for _, key in ipairs(measuredKeys) do
            widths[key] = math.max(widths[key] or 0, ranksTextWidth(cells[key]))
        end
        if showDeaths then
            widths.deaths = math.max(widths.deaths, ranksTextWidth(cells.deaths))
        end
    end

    if searchRow then
        setCells(page.searchCells, searchRow, searchRank)
        for _, key in ipairs(measuredKeys) do
            widths[key] = math.max(widths[key] or 0, ranksTextWidth(page.searchCells[key]))
        end
        if showDeaths then
            widths.deaths = math.max(widths.deaths,
                ranksTextWidth(page.searchCells.deaths))
        end
    end

    -- Headings are measured after their active triangle is part of the text, so
    -- a sort marker cannot be clipped by a column measured without it.
    for _, spec in ipairs(RANKS.COLUMNS) do
        local header = page.headers[spec.key]
        if spec.key == "deaths" and not showDeaths then
            hide(header)
            hide(page.headerButtons[spec.key])
        else
            local text = spec.label
            if spec.sortable and RANKS.state.sortKey == spec.key then
                text = text .. (RANKS.state.ascending and " ^" or " v")
            end
            header:SetText(text)
            widths[spec.key] = math.max(widths[spec.key] or 0, ranksTextWidth(header))
        end
    end

    local columnKeys = { "rank", "marker", "name", "level", "played" }
    if showDeaths then columnKeys[#columnKeys + 1] = "deaths" end

    local xs = {}
    local columnX = RANKS_COLUMN_X
    for _, key in ipairs(columnKeys) do
        local width = (key == "marker") and RANKS_MARKER_SIZE or (widths[key] or 0)
        xs[key] = columnX
        columnX = columnX + width + RANKS_COLUMN_GAP
    end

    local rightAligned = {
        rank = true,
        level = true,
        played = true,
        deaths = true,
    }

    local haveRows = (#entries > 0) or (searchRow ~= nil)

    if haveRows then
        local headerHeight = RANKS_LINE_FALLBACK

        for _, spec in ipairs(RANKS.COLUMNS) do
            local header = page.headers[spec.key]
            local button = page.headerButtons[spec.key]

            if not (spec.key == "deaths" and not showDeaths) then
                local active = spec.sortable and RANKS.state.sortKey == spec.key
                local colour = active and textColour or mutedColour
                local width = (spec.key == "marker") and RANKS_MARKER_SIZE
                    or (widths[spec.key] or 0)

                header:SetTextColor(colour.r, colour.g, colour.b)
                header:SetWidth(width)
                header:SetJustifyH(spec.numeric and "RIGHT" or "LEFT")
                header:ClearAllPoints()
                if spec.numeric then
                    header:SetPoint("TOPRIGHT", xs[spec.key] + width, y)
                else
                    header:SetPoint("TOPLEFT", xs[spec.key], y)
                end
                header:Show()
                headerHeight = math.max(headerHeight, ranksHeight(header))

                if button then
                    button:ClearAllPoints()
                    button:SetPoint("TOPLEFT", xs[spec.key] - 2, y + 2)
                    button:SetSize(width + 4, math.max(RANKS_LINE_FALLBACK,
                        ranksHeight(header)))
                    button:Show()
                end
            end
        end

        y = y - headerHeight - 4
    else
        for _, spec in ipairs(RANKS.COLUMNS) do
            hide(page.headers[spec.key])
            hide(page.headerButtons[spec.key])
        end
    end

    local function drawCells(cells, row, rank, top)
        local height = math.max(RANKS_LINE_FALLBACK, ranksHeight(cells.name))

        local fr, fg, fb, fa = RANKS.rowColour(row, rank)
        cells.tint:ClearAllPoints()
        cells.tint:SetPoint("TOPLEFT", 0, top)
        cells.tint:SetSize(RANKS_CONTENT_WIDTH, height)
        cells.tint:SetColorTexture(fr, fg, fb, fa)
        cells.tint:Show()

        if row.you then
            local gold = LT.Palette.named.money
            cells.own:ClearAllPoints()
            cells.own:SetPoint("TOPLEFT", 0, top)
            cells.own:SetSize(RANKS_CONTENT_WIDTH, height)
            cells.own:SetColorTexture(gold.r, gold.g, gold.b, 0.12)
            cells.own:Show()
        else
            hide(cells.own)
        end

        local dark = LT.Palette.chrome.borderDark
        cells.rule:ClearAllPoints()
        cells.rule:SetPoint("TOPLEFT", 0, top - height)
        cells.rule:SetSize(RANKS_CONTENT_WIDTH, 1)
        cells.rule:SetColorTexture(dark[1], dark[2], dark[3], 0.25)
        cells.rule:Show()

        local cr, cg, cb = ranksClassColour(row.class)
        cells.marker:ClearAllPoints()
        cells.marker:SetPoint("TOPLEFT", xs.marker, top - 2)
        cells.marker:SetSize(RANKS_MARKER_SIZE, RANKS_MARKER_SIZE)
        cells.marker:SetColorTexture(cr, cg, cb, 1)
        cells.marker:Show()

        if row.you then
            cells.name:SetTextColor(textColour.r, textColour.g, textColour.b)
        else
            cells.name:SetTextColor(cr, cg, cb)
        end
        cells.rank:SetTextColor(mutedColour.r, mutedColour.g, mutedColour.b)
        cells.level:SetTextColor(textColour.r, textColour.g, textColour.b)
        cells.played:SetTextColor(textColour.r, textColour.g, textColour.b)
        cells.deaths:SetTextColor(textColour.r, textColour.g, textColour.b)

        for _, key in ipairs(columnKeys) do
            if key ~= "marker" then
                local cell = cells[key]
                local width = widths[key] or 0
                cell:SetWidth(width)
                cell:SetJustifyH(rightAligned[key] and "RIGHT" or "LEFT")
                cell:ClearAllPoints()
                if rightAligned[key] then
                    cell:SetPoint("TOPRIGHT", xs[key] + width, top)
                else
                    cell:SetPoint("TOPLEFT", xs[key], top)
                end
                cell:Show()
            end
        end

        if not showDeaths then hide(cells.deaths) end
        return height
    end

    if #entries > 0 then
        for index, row in ipairs(entries) do
            local cells = page.levelRows[index]
            local height = drawCells(cells, row, row.ranksRank or index, y)
            y = y - height - RANKS_ROW_GAP
        end

        for index = #entries + 1, #page.levelRows do
            hideCells(page.levelRows[index])
        end
    else
        for index = 1, #page.levelRows do
            hideCells(page.levelRows[index])
        end
    end

    if #entries == 0 then
        local sentence
        if RANKS.state.tab == "friends" then
            sentence = "No one on your Friends ladder yet. Search a name and "
                .. "choose Add to Friends."
        elseif RANKS.state.tab == "fastest" then
            if type(boards) == "table" then
                sentence = tostring(boards.emptyRecords
                    or "No one has reached level 60 yet.")
            else
                sentence = "The leaderboard could not be read."
            end
        elseif type(boards) == "table" then
            sentence = tostring(boards.emptyLevel or "No rows have been shared yet.")
        elseif not module then
            sentence = "The leaderboard module is not loaded."
        elseif type(module.Boards) ~= "function" then
            sentence = "This leaderboard module has no boards to show."
        else
            sentence = "The leaderboard could not be read."
        end

        page.levelEmpty:SetText(sentence)
        line(page.levelEmpty, RANKS_COLUMN_X, RANKS_AREA_GAP, mutedColour)
    else
        hide(page.levelEmpty)
    end

    -- A searched row is drawn after the board with the same columns and tints.
    -- Its Add to Friends button is the only action a row carries.
    if searchRow then
        y = y - 4
        local top = y
        local height = drawCells(page.searchCells, searchRow, searchRank, top)

        local addX = xs.played + (widths.played or 0) + 16
        if addX > RANKS_CONTENT_WIDTH - 124 then addX = RANKS_CONTENT_WIDTH - 124 end

        if searchRow.you then
            page.searchAdd:Hide()
            page.searchNote:SetText("This is your own row.")
        elseif RANKS.onLadder(searchRow) then
            page.searchAdd:Hide()
            page.searchNote:SetText("On the Friends ladder.")
        else
            page.searchNote:SetText("")
            page.searchAdd:ClearAllPoints()
            page.searchAdd:SetPoint("TOPLEFT", addX, top - 3)
            page.searchAdd:Show()
        end

        if page.searchNote:GetText() ~= "" then
            page.searchNote:ClearAllPoints()
            page.searchNote:SetPoint("TOPLEFT", addX, top - 1)
            page.searchNote:Show()
        else
            page.searchNote:Hide()
        end

        y = y - height - RANKS_ROW_GAP
    else
        hideCells(page.searchCells)
        hide(page.searchAdd)
        hide(page.searchNote)
    end

    -- The line at the bottom is only for a character at the cap: its lifetime,
    -- active/AFK split and time-to-60 record. If Played cannot answer, nothing is
    -- drawn at all, so no row of zeroes pretends to be a measurement.
    local playerLevel = tonumber(LT.player and LT.player.level) or 0
    local capLine = nil
    local showPace = true
    if type(LT.Database) == "table" and type(LT.Database.GetOptions) == "function" then
        local okOptions, options = pcall(LT.Database.GetOptions, LT.Database)
        showPace = okOptions and type(options) == "table" and options.showPaceLine ~= false
    end
    if playerLevel >= 60 then
        capLine = level60PlayedLine()
    elseif showPace and LT.Played and type(LT.Played.LevelPace) == "function" then
        -- Below the cap the same line carries the levelling pace instead: time at
        -- this level and the average over the last three, from the ledger Played
        -- already keeps.
        local okPace, pace = pcall(LT.Played.LevelPace, LT.Played)
        if okPace and type(pace) == "string" and pace ~= "" then capLine = pace end
    end

    if capLine then
        page.level60Line:SetText(capLine)
        line(page.level60Line, RANKS_COLUMN_X, RANKS_ROW_GAP, mutedColour)
    else
        hide(page.level60Line)
    end

    -- The gold goal is a progress readout, not a ledger. It shares the pace
    -- line's strip: always below 60, and at 60 only when the cap/pace line is
    -- empty, so the cap line is never displaced by it. A goal of Off or a money
    -- value the client will not hand over leaves the line hidden.
    local goldLine = RANKS.gold.line()
    if goldLine and (playerLevel < 60 or not capLine) then
        page.goldGoalLine:SetText(goldLine)
        line(page.goldGoalLine, RANKS_COLUMN_X, RANKS_ROW_GAP, mutedColour)
    else
        hide(page.goldGoalLine)
    end

    -- An open popup follows the same data the page just read, so a row that
    -- arrives while the Records window is up redraws it too.
    if sharePopup:IsShown() then sharePopup:Render() end
    if recordsPopup:IsShown() then recordsPopup:Render(boards) end

    scroll.ranksExtent = math.max(0, -y + 8)
    cursor.y = y
end

------------------------------------------------------------------------------
-- Page: Settings
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Settings layout
--
-- The page is a set of named areas, not one list. Every area is declared once
-- in drawSettings; this section only measures and places what was declared.
-- Heights come from the font strings after they exist, never from a row count,
-- so a taller client font pushes the next row down instead of overlapping it.
------------------------------------------------------------------------------

local SETTINGS_INFO_X = 4
local SETTINGS_CHECK_X = 28
local SETTINGS_LABEL_X = 52
local SETTINGS_ROW_MIN = 20
local SETTINGS_COLUMN_GAP = 14
local SETTINGS_BLOCK_GAP = 8

-- A column narrower than this holds no checkbox row on one line, so a
-- two-column page never gives its second column less than this: a block that
-- would need more moves to the wider column instead.
local SETTINGS_MIN_COLUMN = 240

-- The page is designed down to this content width; the 800-pixel window spends
-- 128 on the rail and its gutters and leaves 634 for a page, of which the widest
-- single-line note still fits at 480. Below it the page stays in one column with
-- clamped widths.
local SETTINGS_MIN_WIDTH = 480

local function settingsTextWidth(label)
    if not label then return 0 end

    local ok, width = pcall(label.GetStringWidth, label)
    if ok and type(width) == "number" and width > 0 then
        if not (LT.IsSecret and LT:IsSecret(width)) then
            return width
        end
    end

    local text = label.GetText and label:GetText() or ""
    return #tostring(text or "") * 5
end

local function settingsTextHeight(label)
    if not label then return 0 end

    local ok, height = pcall(label.GetStringHeight, label)
    if ok and type(height) == "number" and height > 0 then
        if not (LT.IsSecret and LT:IsSecret(height)) then
            return height
        end
    end

    return 12
end

-- A settings row is one line by contract. The width set on it is already at
-- least its measured natural width, so this only stops a client that would
-- otherwise wrap a row that fits from doing so.
local function settingsOneLine(label)
    if label and label.SetWordWrap then
        pcall(label.SetWordWrap, label, false)
    end
end

-- A settings write does not only change a checkbox. The quest-reward borders
-- and the bag markers are drawn from those keys, and an open tooltip panel is
-- drawn from them too, so each is told to redraw after the write. Every call is
-- guarded and the whole group is skipped in combat, where the client's own
-- lockdown is the stronger rule; each module also keeps its own combat guard.
local function refreshSettingsConsumers()
    if combatLocked() then return end

    local quest = LT.QuestRewards
    if type(quest) == "table" and type(quest.Refresh) == "function" then
        pcall(quest.Refresh, quest)
    end

    local drop = LT.DropHint
    if type(drop) == "table" and type(drop.Changed) == "function" then
        pcall(drop.Changed, drop)
    end

    -- The tooltip's live state is the panel of a tooltip that is open right now.
    -- Tooltip.decorate is the one entry point that rebuilds it; the three frames
    -- named here are the ones a player normally hovers.
    local tooltip = LT.Tooltip
    if type(tooltip) == "table" and type(tooltip.decorate) == "function" then
        for _, name in ipairs({ "GameTooltip", "ItemRefTooltip", "ShoppingTooltip1" }) do
            local frame = _G[name]
            if type(frame) == "table" and type(frame.IsShown) == "function" then
                local okShown, shown = pcall(frame.IsShown, frame)
                if okShown and shown then
                    pcall(tooltip.decorate, tooltip, frame)
                end
            end
        end
    end
end

------------------------------------------------------------------------------
-- Buff watch rows
--
-- One checkbox per maintenance reminder, and the list is the logged-in
-- class's pack: Classes\<Class>.lua carries the label, help line, option key
-- and default for every entry it declares. Nothing below repeats that data
-- per class, so a reminder added to a pack appears in Settings without a
-- second edit. The literal list further down is only the fallback for a core
-- without the pack registry.
------------------------------------------------------------------------------

-- The shipped default for an option key, or nil when this core cannot answer.
local function settingsCoreDefaults()
    local database = LT.Database
    if type(database) ~= "table" or type(database.defaultOptions) ~= "function" then
        return nil
    end

    local ok, defaults = pcall(database.defaultOptions)
    if ok and type(defaults) == "table" then return defaults end
    return nil
end

-- A pack entry as a settings row. `default` is the pack's when it states one —
-- ClassPacks only accepts a default that agrees with Database.defaultOptions()
-- — and the core's default otherwise, so the checkbox never disagrees with
-- what the module reading the key treats as unset.
local function settingsBuffRow(entry, coreDefaults)
    if type(entry) ~= "table" then return nil end

    local key = entry.optionKey
    local label = entry.label
    if type(key) ~= "string" or key == "" then return nil end
    if type(label) ~= "string" or label == "" then return nil end

    local default = entry.default
    if type(default) ~= "boolean" and type(coreDefaults) == "table" then
        default = coreDefaults[key]
    end

    return {
        key = key,
        label = label,
        help = type(entry.help) == "string" and entry.help or nil,
        default = default == true,
    }
end

-- Rows for one class, in the order the pack declares them. nil means "no pack
-- to read" — no registry, no GetBuffs, or no pack for this class — and that is
-- what selects the fallback list. An empty array is a real answer: the pack
-- exists and declares no reminder, so the section shows its sentence instead.
local function settingsPackBuffRows(classToken)
    local packs = LT.ClassPacks
    if type(packs) ~= "table" or type(packs.GetBuffs) ~= "function" then return nil end

    if type(packs.Get) == "function" then
        local okPack, pack = pcall(packs.Get, packs, classToken)
        if not okPack or type(pack) ~= "table" then return nil end
    end

    local okEntries, entries = pcall(packs.GetBuffs, packs, classToken)
    if not okEntries or type(entries) ~= "table" then return nil end

    local coreDefaults = settingsCoreDefaults()
    local rows = {}

    for _, entry in ipairs(entries) do
        local row = settingsBuffRow(entry, coreDefaults)
        if row then rows[#rows + 1] = row end
    end

    return rows
end

-- The rows this page drew before the packs owned the data, word for word. A
-- default is read from the database so the checkbox still shows what the
-- reminder does with a key that was never written.
local function settingsFallbackBuffRows(classToken, coreDefaults)
    local function defaultFor(key)
        if type(coreDefaults) == "table" and coreDefaults[key] ~= nil then
            return coreDefaults[key] == true
        end
        return nil
    end

    local rows = {}

    if classToken == "SHAMAN" then
        rows[#rows + 1] = {
            key = "shamanImbueReminder",
            label = "Warn when main-hand imbue is missing or expiring",
            help = "Shows an on-screen warning and chat message when no main-hand Shaman "
                .. "imbue is detected, or within 5 minutes of expiry. Does not cast an "
                .. "imbue or choose which imbue is correct.",
            default = defaultFor("shamanImbueReminder"),
        }
    end

    if classToken == "PALADIN" then
        rows[#rows + 1] = {
            key = "paladinSealReminder",
            label = "Warn when no Paladin seal is active",
            help = "Alerts when no seal buff is detected. Confirm the seal spell names "
                .. "are correct in ClassData.lua before relying on this.",
            default = defaultFor("paladinSealReminder"),
        }
    end

    if classToken == "HUNTER" then
        rows[#rows + 1] = {
            key = "hunterAspectReminder",
            label = "Warn when no Hunter aspect is active",
            help = "Alerts when no aspect buff is detected. Confirm the aspect spell "
                .. "names are correct in ClassData.lua before relying on this.",
            default = defaultFor("hunterAspectReminder"),
        }
    end

    if classToken == "WARRIOR" then
        rows[#rows + 1] = {
            key = "warriorShoutReminder",
            label = "Warn when no Battle/Commanding Shout is active",
            help = "Optional levelling reminder. Confirm shout spell names in "
                .. "ClassData.lua before enabling.",
            default = defaultFor("warriorShoutReminder"),
        }
    end

    return rows
end

-- The sentence a class with no reminder row reads instead of an empty heading.
-- The class list is built from the packs that declare a reminder, so the line
-- can never name a class this page would draw a row for; the old literal is
-- what a core with no pack registry shows. The names come from ranksClassName,
-- the file's one class-name resolver.
local function settingsBuffWatchNote()
    local packs = LT.ClassPacks
    local names = {}

    if type(packs) == "table"
        and type(packs.GetOrder) == "function"
        and type(packs.GetBuffs) == "function" then

        local okOrder, order = pcall(packs.GetOrder, packs)
        if okOrder and type(order) == "table" then
            for _, classToken in ipairs(order) do
                local okEntries, entries = pcall(packs.GetBuffs, packs, classToken)
                if okEntries and type(entries) == "table" and #entries > 0 then
                    names[#names + 1] = ranksClassName(classToken)
                end
            end
        end
    end

    if #names == 0 then
        return "Buff reminders appear here for Shaman, Paladin, Hunter, Warrior, and "
            .. "Rogue (with the Rogue plugin)."
    end

    local list
    if #names == 1 then
        list = names[1]
    elseif #names == 2 then
        list = names[1] .. " and " .. names[2]
    else
        list = table.concat(names, ", ", 1, #names - 1) .. ", and " .. names[#names]
    end

    return "Buff reminders appear here for " .. list
        .. "; the Rogue plugin adds its poison row while it is loaded."
end

local function drawSettings(cursor)
    -- The page is taller than the window, so everything is drawn inside a
    -- scroll area (mouse wheel) instead of running past the background. The
    -- scroll child is the single owner of every widget this page draws.
    local pageHost = contentFrame
    local scroll = MakeScroll(pageHost, "settings")
    local contentFrame = scroll.content
    local pageWidth = scroll:GetWidth()

    if type(pageWidth) ~= "number" or pageWidth < 1 then
        pageWidth = pageHost:GetWidth()
    end
    if type(pageWidth) ~= "number" or pageWidth < 1 then
        pageWidth = 632
    end

    local options = LT.Database:GetOptions()
    local playerClass = LT.player and LT.player.class
    local gearDefaults = (type(LT.GearPopup) == "table" and LT.GearPopup.OPTION_DEFAULTS) or {}
    local scoringLabel = (LT.Imbues and LT.Imbues.SCORING_LABEL)
        or "Score weapons using the chosen imbue"

    -- Buff watch: one checkbox per maintenance reminder this class's pack
    -- declares, so only the options that mean something here are drawn and the
    -- pack stays the single place a reminder is described.
    local buffRows = {}
    local buffRowKeys = {}

    -- One row per option key. A pack entry, the Rogue plugin and WeaponBuffs can
    -- all name the same key, and two checkboxes for one switch would be a bug,
    -- so the first row that claims a key wins and the later ones are dropped.
    local function addBuffRow(row)
        if type(row) ~= "table" then return end

        local key = row.key
        if type(key) == "string" and key ~= "" then
            if buffRowKeys[key] then return end
            buffRowKeys[key] = true
        end

        buffRows[#buffRows + 1] = row
    end

    -- Before the class is readable the page shows the Shaman main-hand imbue
    -- row, as it always has: it is the reminder a new character can watch work.
    -- That row is the one special case — it is the enchant-backed definition,
    -- because a main-hand imbue is a weapon enchant and not an aura — and it
    -- comes from the pack entry that owns it, so it is never drawn twice.
    local packClass = playerClass or "SHAMAN"

    local classBuffRows = settingsPackBuffRows(packClass)
    if classBuffRows == nil then
        -- No pack registry, or no pack for this class: the rows this page drew
        -- before the packs owned the data.
        classBuffRows = settingsFallbackBuffRows(packClass, settingsCoreDefaults())
    end
    for _, row in ipairs(classBuffRows) do addBuffRow(row) end

    -- The Rogue plugin owns its poison warnings: its SetEnabled is the only
    -- writer, so the rows exist only while the plugin is loaded and exposes
    -- both accessors. It publishes the rows itself through GetOptionRows, so a
    -- switch added there appears here without a second hard-coded row; the
    -- single main-hand row below is the shape a plugin without that call gets.
    local rogue = LT.Rogue
    if playerClass == "ROGUE"
        and type(rogue) == "table"
        and type(rogue.GetEnabled) == "function"
        and type(rogue.SetEnabled) == "function" then

        local rogueRows
        if type(rogue.GetOptionRows) == "function" then
            local okRows, published = pcall(rogue.GetOptionRows, rogue, "ROGUE")
            if okRows and type(published) == "table" and #published > 0 then
                rogueRows = published
            end
        end

        if not rogueRows then
            rogueRows = {
                {
                    key = "rogueMainHandPoison",
                    label = "Warn when the main hand has no poison",
                    help = "Rogue only. One warning when the main hand carries no temporary "
                        .. "enhancement. A sharpening stone or oil counts as present, and an "
                        .. "unreadable main hand stays silent, so this never warns from a "
                        .. "guess. Nothing is applied. Off by default.",
                    default = false,
                },
            }
        end

        for _, entry in ipairs(rogueRows) do
            local key = type(entry) == "table" and entry.key or nil

            if type(key) == "string" and key ~= "" then
                addBuffRow({
                    key = key,
                    label = tostring(entry.label or key),
                    help = type(entry.help) == "string" and entry.help or nil,
                    default = entry.default == true,
                    get = function()
                        return rogue:GetEnabled(key) == true
                    end,
                    apply = function(value)
                        rogue:SetEnabled(key, value)
                    end,
                })
            end
        end
    end

    -- One table per area, declared once, before anything is drawn. A row keeps
    -- the existing { key, label, help } shape; `default` covers a key whose
    -- default lives with the module that reads it. `note` is a line of text with
    -- nothing to click, and `button` is the one control that is not a checkbox.
    local tooltipArea = {
        heading = "Tooltip",
        rows = {
            { key = "tooltipEnabled", label = "Show item scores in tooltips",
              help = "Displays Lunchbox Toolkit scores on supported item tooltips." },
            { key = "tooltipBuildOne", label = "Show Build 1 score",
              help = "Controls whether the first build is included in item tooltips." },
            { key = "tooltipBuildTwo", label = "Show Build 2 score",
              help = "Controls whether the second build is included in item tooltips." },
            { key = "tooltipCombatShiftOnly", label = "In combat, only with Shift",
              help = "During a fight the panel appears only while Shift (or Control) is held, "
                  .. "so it never covers the view. A panel already open when a fight starts "
                  .. "disappears and comes back when the fight ends. Off: combat behaves like "
                  .. "the rest of the game." },
            { key = "tooltipCompareEquipped", label = "Compare with equipped gear",
              help = "On: tooltips compare against what you are wearing right now. Off: they "
                  .. "compare against the saved equipment set for each build." },
        },
    }

    local questArea = {
        heading = "Quest rewards",
        rows = {
            { key = "questRewardHighlight", label = "Highlight the best quest reward",
              help = "Outlines the quest reward that is the biggest upgrade for the active "
                  .. "slot. Hover any reward for its own score, hold shift for the "
                  .. "stat-level reason." },
            { key = "questRewardRanking", label = "Rank the top two quest rewards",
              help = "Purple outlines the biggest upgrade for the active slot and blue the "
                  .. "second biggest. Off: only the biggest upgrade is outlined, in purple." },
            { key = "questVendorFallback", label = "Coin on the most profitable reward",
              help = "Marks the reward worth the most to a vendor with a coin. The coin rides "
                  .. "on whatever border that reward already has, so a purple or blue border "
                  .. "keeps its colour; a reward with no verdict border gets the gold one." },
        },
    }

    local gearArea = {
        heading = "Gear check",
        help = "Lists what in the bags beats what is worn, split into what can be worn now "
            .. "and what a level will unlock. /lt scan prints the same list in chat; the "
            .. "Gear check button in the header opens it as a window.",
        rows = {
            { key = "gearCheckOnLevel", label = "Check gear after a level",
              default = gearDefaults.gearCheckOnLevel == true,
              help = "After a level-up, once you are out of combat, scans the bags and "
                  .. "opens the gear-check window when something is worth wearing. Off: "
                  .. "/lt scan and the header button still work." },
            { key = "gearCheckOnBagOpen", label = "Check gear when bags open",
              default = gearDefaults.gearCheckOnBagOpen == true,
              help = "Opening the bags scans them and opens the gear-check window, once, "
                  .. "out of combat. Off by default; /lt scan and the header button "
                  .. "always work. The upgrade arrow on a bag item is drawn either way." },
            { key = "gearCheckBankPrompt", label = "Offer a bank scan",
              default = gearDefaults.gearCheckBankPrompt == true,
              help = "While the bank is open, offers a scan. Nothing in the bank is read "
                  .. "until you choose Scan, and bank items are marked \"bank\" in the "
                  .. "list." },
        },
    }

    local weaponArea = {
        heading = "Weapon imbues",
        help = "Imbue coefficients and speed preferences are stated starting points, not "
            .. "measured game mechanics. /lt imbune lists them with what each one assumes.",
        onlyClass = "SHAMAN",
        rows = {
            { key = "shamanImbueScoring", label = scoringLabel,
              help = "Values a weapon's DPS and damage through the imbue selected for "
                  .. "each build slot on the Builds page. Each imbue has its own "
                  .. "coefficients and speed preference, and every figure is provisional. "
                  .. "This switch only decides for a build slot that has not set its own; "
                  .. "the Builds page can switch it on or off per slot. Off by default." },
        },
        button = {
            key = "shamanDefaultImbue",
            label = "Default imbue: ",
            apply = function(nextKey)
                LT.Database:GetOptions().shamanDefaultImbue = nextKey
            end,
        },
    }

    -- The WeaponBuffs plugin owns these two option keys: its SetEnabled is the
    -- only writer, so the rows exist only while the plugin is loaded. Both
    -- start off, and a missing key reads as off in the plugin and BuffMonitor.
    -- The plugin registers each definition for the classes it can answer for:
    -- the off-hand imbue is Shaman-only, and a weapon imbue (Shaman) or poison
    -- (Rogue) fills the slot the temporary-enhancement check reads, so that
    -- reminder is never registered there. A row whose definition does not
    -- exist would be a silent no-op, so the class has to agree with the plugin
    -- before the row is drawn.
    local WEAPON_BUFF_TEMP_EXCLUDED = { SHAMAN = true, ROGUE = true }

    local weaponBuffRows = {}
    local weaponBuffs = LT.WeaponBuffs
    if type(weaponBuffs) == "table"
        and type(weaponBuffs.SetEnabled) == "function"
        and type(weaponBuffs.GetEnabled) == "function" then

        local function pluginRow(key, label, help)
            return {
                key = key,
                label = label,
                help = help,
                default = false,
                get = function()
                    return weaponBuffs:GetEnabled(key) == true
                end,
                apply = function(value)
                    weaponBuffs:SetEnabled(key, value)
                end,
            }
        end

        if playerClass == "SHAMAN" then
            weaponBuffRows[#weaponBuffRows + 1] = pluginRow(
                "weaponBuffsOffHandImbue",
                "Warn when the off-hand weapon has no imbue",
                "Shaman only. One warning when a one-handed weapon in the off hand has "
                    .. "no imbue, or an imbue is within 5 minutes of expiry. Nothing is "
                    .. "cast or applied. Off by default.")
        end

        if type(playerClass) == "string" and playerClass ~= ""
            and playerClass ~= "UNKNOWN"
            and not WEAPON_BUFF_TEMP_EXCLUDED[playerClass] then

            weaponBuffRows[#weaponBuffRows + 1] = pluginRow(
                "weaponBuffsTempEnhancement",
                "Warn when no temporary weapon enhancement",
                "One warning when a weapon the client reports has no sharpening stone, "
                    .. "weightstone or oil, or the enhancement is within 5 minutes of "
                    .. "expiry. Off by default.")
        end
    end

    -- The plugin rows keep the class gating above; each one joins the list only
    -- where no row already carries its option key.
    for _, row in ipairs(weaponBuffRows) do addBuffRow(row) end

    local buffArea = {
        heading = "Buff watch",
        rows = buffRows,
        -- A class with no row at all keeps the explanation instead of an empty
        -- heading, exactly as the old page did. The list is the classes whose
        -- pack declares a reminder, so it cannot drift from what the page draws.
        note = (#buffRows == 0) and settingsBuffWatchNote() or nil,
    }

    local windowArea = {
        heading = "Window",
        rows = {
            { key = "loginMessage", label = "Show the login line",
              help = "One line in chat at login and after /reload, saying where the options "
                  .. "are. Off: nothing is printed until you ask for something." },
            -- The dot and the two lines Toasts draws. Their defaults live in
            -- Database.defaultOptions(), so `default` here only covers the moment
            -- before the key is ever written: the checkbox then shows what
            -- Minimap:IsEnabled and Toasts:Option actually do with a missing key.
            { key = "minimapButton", label = "Show the minimap dot",
              default = false,
              help = "The small dot on the minimap ring. Left-click opens the window, "
                  .. "right-click opens Settings, and dragging it moves it to another "
                  .. "point on the ring. Off by default: the addon also registers in the "
                  .. "client's addon compartment, which is the normal launcher. /lt still "
                  .. "opens the window." },
            { key = "weaponTrainerHint", label = "Weapon trainer hint",
              default = true,
              help = "Entering a city whose weapon master teaches a type you have not "
                  .. "trained raises one toast, once per city per session." },
            { key = "shamanTotemBar", label = "Show the Shaman totem bar",
              default = true,
              apply = function(value)
                  if LT.ShamanHUD and type(LT.ShamanHUD.SetEnabled) == "function" then
                      LT.ShamanHUD:SetEnabled(value)
                  end
              end,
              help = "The small Fire / Earth / Water / Air row with the active shield and "
                  .. "each totem's time left, for a Shaman only. It never takes the mouse "
                  .. "and has no close button, so this switch is how it is turned on and "
                  .. "off. Also /lt shamanhud on|off." },
            { key = "shamanHudScale", label = "Totem bar size",
              slider = { min = 0.5, max = 1.6, step = 0.05, default = 1,
                  format = function(value) return string.format("%.2f", value) end },
              apply = function(value)
                  LT.Database:GetOptions().shamanHudScale = value
                  LT.Database:Save("settings:shamanHudScale")
                  if LT.ShamanHUD and type(LT.ShamanHUD.ApplyLook) == "function" then
                      LT.ShamanHUD:ApplyLook()
                  end
              end,
              help = "How big the totem bar draws, 0.5 to 1.6. It scales the whole frame, "
                  .. "text included. Also /lt shamanhud scale <n>." },
            { key = "shamanHudAlpha", label = "Totem bar background opacity",
              slider = { min = 0.1, max = 1, step = 0.05, default = 0.9,
                  format = function(value) return string.format("%.2f", value) end },
              apply = function(value)
                  LT.Database:GetOptions().shamanHudAlpha = value
                  LT.Database:Save("settings:shamanHudAlpha")
                  if LT.ShamanHUD and type(LT.ShamanHUD.ApplyLook) == "function" then
                      LT.ShamanHUD:ApplyLook()
                  end
              end,
              help = "How much of the world shows through the totem bar's background, "
                  .. "0.1 to 1. Only the fill fades: the labels and the border stay sharp. "
                  .. "Also /lt shamanhud alpha <n>." },
            { key = "shamanImbueGlow", label = "Glow the imbue action buttons",
              default = true,
              apply = function(value)
                  if LT.ImbueGlow and type(LT.ImbueGlow.SetEnabled) == "function" then
                      LT.ImbueGlow:SetEnabled(value)
                  end
              end,
              help = "While the main hand carries no imbue, the four imbue buttons glow. "
                  .. "It only ever adds a glow or a small corner mark - no button is "
                  .. "greyed out. Also /lt imbueglow on|off." },
            { key = "shamanCastClock", label = "Mana cast clock",
              default = false,
              help = "Counts five seconds from your last spell and says when mana regen "
                  .. "starts; with a dying target it suggests finishing in melee. It never "
                  .. "reads or prints a mana number in combat. Off by default." },
            { key = "shamanTotemAlert", label = "Totem expiry and Recall cue",
              default = false,
              help = "One warning when a short totem is about to drop, and a cue when you "
                  .. "have walked away from your totems (Totemic Recall refunds 25%). "
                  .. "Off by default." },
            { key = "bagSortEnabled", label = "Allow /lt sort to move bag items",
              default = false,
              help = "Sorting calls the client's own sort, so this addon never moves an "
                  .. "item by its own code. Off by default because it rearranges your bags. "
                  .. "Then /lt sort bags, /lt sort bank or /lt sort all - the bank window "
                  .. "must be open for the client to move anything in it." },
            { key = "toastUpgrades", label = "Toast when loot is an upgrade",
              default = true,
              help = "When the loot window opens, one line names an item that beats what "
                  .. "you are wearing in that slot and says nothing about the rest. It "
                  .. "stays for eight seconds and nothing on it is clickable. On by "
                  .. "default." },
            { key = "bagSpaceWarning", label = "Warn when the bags are nearly full",
              default = true,
              help = "One line when the bags are down to two free slots or fewer. It is "
                  .. "said once per bag state rather than on every change, and it leaves "
                  .. "as soon as space is freed. On by default." },
            { key = "campfireToasts", label = "Campfire lines",
              default = false,
              help = "At a campfire: what it gives you, when the buff lands, and when it "
                  .. "is about to run out. The fire names are the guide's (" ..
                  "campfire, bonfire and a few named fires); on this server the match is "
                  .. "unconfirmed, so the switch starts off." },
            { key = "questTurnInScan", label = "Check gear when a quest is handed in",
              default = false,
              help = "One bag scan each time a quest is turned in, out of combat. Off by "
                  .. "default: the level-up check and /lt scan cover the same ground." },
            { key = "bagFrames", label = "Bag frames", cycle = {
                get = function()
                    local db = LT.Database
                    local ok, options = pcall(db.GetOptions, db)
                    local value = ok and type(options) == "table" and options.bagFrames or nil
                    return value == "replacement" and "replacement" or "client"
                end,
                next = function(value)
                    return value == "replacement" and "client" or "replacement"
                end,
                set = function(value)
                    local db = LT.Database
                    local ok, options = pcall(db.GetOptions, db)
                    if ok and type(options) == "table" then
                        options.bagFrames = value == "replacement" and "replacement" or "client"
                        pcall(db.Save, db, "options:bagFrames")
                    end
                end,
                format = function(value)
                    return value == "replacement" and "replacement add-on" or "client"
                end,
            },
              help = "Client: the upgrade arrow and bag checks run on the client's own "
                  .. "bags. Replacement: a bag add-on such as Bagnon or Baganator owns "
                  .. "those frames, so this add-on stops marking them instead of going "
                  .. "quietly dark. Also offered by the first-use tour." },
            { key = "windowScale", label = "Window scale",
              cycle = {
                  get = function() return UI:GetScale() end,
                  next = function(value) return UI:NextScale(value) end,
                  set = function(value) UI:SetScale(value) end,
                  format = function(value)
                      return string.format("%d%%", math.floor(value * 100 + 0.5))
                  end,
              },
              help = "Cycles the whole window through 80%, 90%, 100%, 110% and 125%. "
                  .. "The remembered position is re-clamped after the new size, so the "
                  .. "window never leaves the screen. Saved per character." },
        },
    }

    -- Class gating: the totem bar row only exists for a Shaman, so no other
    -- class is offered a switch for a module that is not running.
    if playerClass ~= "SHAMAN" then
        local kept = {}
        local shamanOnly = { shamanTotemBar = true, shamanImbueGlow = true,
            shamanCastClock = true, shamanTotemAlert = true }
        for _, row in ipairs(windowArea.rows) do
            if not shamanOnly[row.key] then
                kept[#kept + 1] = row
            end
        end
        windowArea.rows = kept
    end

    -- The vendor plugin owns its switches; this page only draws what it
    -- publishes, so a switch can never mean two different things. Same contract
    -- as the Rogue rows: key/label/help/default plus get/apply closures.
    local function vendorOptionRows()
        local rows = {}
        local plugin = LT.Vendor
        if type(plugin) ~= "table" or type(plugin.GetOptionRows) ~= "function" then
            return rows
        end
        local ok, published = pcall(plugin.GetOptionRows, plugin)
        if not ok or type(published) ~= "table" then return rows end
        for _, entry in ipairs(published) do
            local key = type(entry) == "table" and entry.key or nil
            if type(key) == "string" and key ~= "" then
                rows[#rows + 1] = {
                    key = key,
                    label = tostring(entry.label or key),
                    help = type(entry.help) == "string" and entry.help or nil,
                    default = entry.default == true,
                    get = function()
                        if type(plugin.GetEnabled) ~= "function" then return false end
                        return plugin:GetEnabled(key) == true
                    end,
                    apply = function(value)
                        if type(plugin.SetEnabled) == "function" then
                            plugin:SetEnabled(key, value)
                        end
                    end,
                }
            end
        end
        return rows
    end

    local vendorArea = {
        heading = "Vendoring",
        help = "Marks the one cheapest item to lose, sells grey junk only while a merchant is "
            .. "open, and outlines surplus gear in gold. Gear is never sold for you — the best "
            .. "item and a spare are kept for every slot, two spares for rings, and trinkets "
            .. "and relics are left alone. Every switch here starts off.",
        rows = (function()
            local rows = {
                { key = "durabilityWarn", label = "Warn when gear is worn out",
                  default = true,
                  help = "At a merchant, one line when an equipped item is below about 30% "
                      .. "durability. Nothing is repaired unless the next switch is on." },
                { key = "autoRepair", label = "Repair all at a merchant",
                  default = false,
                  help = "Pays to repair every equipped item when a merchant is opened, using "
                      .. "your own money only — guild funds are never touched, and a repair "
                      .. "you cannot afford is skipped with one line." },
                { key = "junkSale", label = "Allow the score-based junk sale",
                  default = false,
                  help = "Lets the bag button and /lbv junk offer items the score says are "
                      .. "worthless for this build, not only grey. The first press borders "
                      .. "them, the second sells exactly those; it never destroys anything." },
            }
            for _, row in ipairs(vendorOptionRows()) do rows[#rows + 1] = row end
            return rows
        end)(),
        note = "Vendor commands: /lt vendor (also /lbv, /ltvendor). The ignore list is "
            .. "saved for the account; everything else here is per character.",
        noteOneLine = true,
    }

    local otherArea = {
        heading = "Other",
        rows = {
            { key = "showProvisionalNote", label = "Show provisional-data warning",
              help = "Labels bundled starting weights and other unvalidated estimates as "
                  .. "provisional." },
            { key = "capsEndgame", label = "Use endgame cap targets at every level",
              help = "Boss hit and expertise targets apply from level 1 instead of "
                  .. "same-level targets while levelling. Off: a low-level character is "
                  .. "measured against a target of the same level." },
            { key = "capBoostUnknown", label = "Boost caps whose value is unknown",
              default = false,
              help = "While a cap's current value cannot be read (no rating gear yet), the "
                  .. "score normally ignores that cap instead of tilting toward a stat you "
                  .. "cannot get. On: the old behaviour, which boosts the stat anyway." },
            { key = "levellingBands", label = "Use levelling weight bands",
              default = true,
              help = "Below 60, scales the weights per level band (1-9, 10-29, 30-44, "
                  .. "45-59): more stamina and weapon damage early, less hit and "
                  .. "expertise. Off: one weight table for every level. The bands are "
                  .. "provisional until measured." },
            -- A readout, not a ledger: the Ranks page draws the balance against
            -- this target and nothing is saved toward it. The label step list
            -- lives with the Ranks page so both sides read the same copper.
            { key = "goldGoal", label = "Gold goal",
              cycle = {
                  get = RANKS.gold.value,
                  next = RANKS.gold.next,
                  set = RANKS.gold.set,
                  format = RANKS.gold.label,
              },
              help = "Adds one line to the Ranks page: your gold against this target, "
                  .. "for example \"Gold: 12g 40s of 50g (25%)\". It is a readout "
                  .. "only — nothing is saved toward the goal and no money is moved. "
                  .. "Off hides the line. Saved per character." },
        },
        -- Debug is not a tab any more; this is the one way to it, and the log
        -- explains itself on its own "?" rather than here.
        button = {
            label = "Open the debug log",
            onClick = function()
                if debugPopup then debugPopup:Open() end
            end,
        },
    }

    local areas = {
        tooltipArea, questArea, gearArea, weaponArea,
        buffArea, windowArea, vendorArea, otherArea,
    }

    local hint = MakeLabel(contentFrame, "Hover an option (or click ?) for what it does.",
        "GameFontNormalSmall", LT.Palette:RGB("muted"))
    hint:SetJustifyH("LEFT")
    hint:SetWidth(math.max(40, pageWidth - 8))
    settingsOneLine(hint)
    hint:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", SETTINGS_INFO_X, 0)

    local topY = -(math.max(12, settingsTextHeight(hint)) + 8)

    -- Build every widget before placing any of them: a block's height is its
    -- font strings' measured height at its final width, not a guessed row count.
    local blocks = {}

    local function buildBlock(area)
        local block = {
            rows = {},
            noteOneLine = area.noteOneLine,
        }

        block.heading = MakeLabel(contentFrame, area.heading, "GameFontNormalSmall",
            LT.Palette.named.brand)
        settingsOneLine(block.heading)
        block.headingInfo = MakeInfo(contentFrame, area.heading, area.help)

        local minWidth = SETTINGS_CHECK_X + settingsTextWidth(block.heading) + 12

        for _, row in ipairs(area.rows) do
            -- A slider row: the label on its own line, the control beneath it and
            -- the current value printed beside the knob.
            if row.slider then
                local spec = row.slider
                local current = tonumber(options[row.key]) or tonumber(spec.default) or spec.min
                if current < spec.min then current = spec.min end
                if current > spec.max then current = spec.max end

                local label = MakeLabel(contentFrame, row.label, "GameFontNormalSmall")
                label:SetJustifyH("LEFT")
                settingsOneLine(label)

                local valueLabel = MakeLabel(contentFrame,
                    spec.format and spec.format(current) or tostring(current),
                    "GameFontNormalSmall", LT.Palette.named.brand)
                settingsOneLine(valueLabel)

                local slider = UI:MakeSlider(contentFrame, spec.min, spec.max,
                    spec.step or 0.05, current, function(value)
                        if spec.format then valueLabel:SetText(spec.format(value)) end
                        if row.apply then
                            pcall(row.apply, value)
                        else
                            options[row.key] = value
                            LT.Database:Save("settings:" .. row.key)
                        end
                    end)

                local info = MakeInfo(contentFrame, row.label, row.help)

                table.insert(block.rows, {
                    row = row,
                    label = label,
                    slider = slider,
                    valueLabel = valueLabel,
                    info = info,
                })

                local rowMin = SETTINGS_LABEL_X + 150 + 8 + 40
                if rowMin > minWidth then minWidth = rowMin end
            elseif row.cycle then
                local cycle = row.cycle
                local value = cycle.get and cycle.get() or options[row.key]
                local text = cycle.format and cycle.format(value) or tostring(value)

                local button = MakeButton(contentFrame,
                    tostring(row.label) .. ": " .. text, 140, 20, function()
                        local nextValue = cycle.next and cycle.next(value) or value
                        if cycle.set then
                            pcall(cycle.set, nextValue)
                        end
                        refreshSettingsConsumers()
                        UI:Refresh()
                    end)

                local info = MakeInfo(contentFrame, row.label, row.help)
                table.insert(block.rows, {
                    row = row,
                    button = button,
                    info = info,
                })

                -- Button plus the "?" beside it, so the row still fits the
                -- narrowest Settings column.
                local rowMin = SETTINGS_CHECK_X + 140 + 8 + 16
                if rowMin > minWidth then minWidth = rowMin end
            else
                local current = options[row.key]
                if row.get then
                    local okGet, value = pcall(row.get)
                    if okGet then current = value end
                elseif current == nil then
                    current = row.default
                end

                local check = MakeCheck(contentFrame, current == true, function(value)
                    if row.apply then
                        -- The owning module writes its own key and saves it.
                        pcall(row.apply, value and true or false)
                    else
                        options[row.key] = value and true or false
                        LT.Database:Save("settings:" .. row.key)
                    end
                    refreshSettingsConsumers()
                    UI:Refresh()
                end)

                local label = MakeLabel(contentFrame, row.label, "GameFontNormalSmall")
                label:SetJustifyH("LEFT")
                settingsOneLine(label)

                local info = MakeInfo(contentFrame, row.label, row.help)

                -- Anchored to the label, so it follows the label into its column.
                MakeHoverTarget(contentFrame, row.label, row.help, label)

                table.insert(block.rows, {
                    row = row,
                    check = check,
                    label = label,
                    info = info,
                })

                local rowMin = SETTINGS_LABEL_X + settingsTextWidth(label) + 12
                if rowMin > minWidth then minWidth = rowMin end
            end
        end

        if area.button then
            -- A cycle button owns its value (the default imbue); an action button
            -- only opens something, and the debug log is the one of those.
            if area.button.onClick then
                block.button = MakeButton(contentFrame,
                    tostring(area.button.label or "Open"), 260, 20, area.button.onClick)

                local actionMin = 4 + 260 + 8
                if actionMin > minWidth then minWidth = actionMin end
            else
                local buttonKey = area.button.key
                local current = options[buttonKey] or "none"
                local definition = (LT.Imbues and LT.Imbues.GetDefinition
                        and LT.Imbues:GetDefinition(current))
                    or (LT.Imbues and LT.Imbues.definitions and LT.Imbues.definitions.none)
                local text = (LT.Imbues and definition and definition.label) or tostring(current)

                block.button = MakeButton(contentFrame,
                    area.button.label .. tostring(text), 260, 20, function()
                        area.button.apply(LT.Imbues and LT.Imbues:Next(current) or current)
                        LT.Database:Save("settings:" .. buttonKey)
                        LT.Profiles:Invalidate()
                        refreshSettingsConsumers()
                        UI:Refresh()
                    end)

                local buttonMin = 4 + 260 + 8
                if buttonMin > minWidth then minWidth = buttonMin end
            end
        end

        if area.note then
            block.note = MakeLabel(contentFrame, area.note, "GameFontNormalSmall",
                LT.Palette:RGB("muted"))
            block.note:SetJustifyH("LEFT")
            if area.noteOneLine then settingsOneLine(block.note) end

            if area.noteOneLine then
                local noteMin = SETTINGS_CHECK_X + settingsTextWidth(block.note) + 8
                if noteMin > minWidth then minWidth = noteMin end
            end
        end

        block.minWidth = minWidth
        return block
    end

    for _, area in ipairs(areas) do
        if not area.onlyClass or area.onlyClass == playerClass then
            local block = buildBlock(area)
            if #block.rows > 0 or block.note or block.button then
                table.insert(blocks, block)
            end
        end
    end

    -- Pick the layout from measured room. The window is a fixed 800 wide and the
    -- rail takes 128 of it, so a page holds 634 and at most two columns: three of
    -- the minimum width could not keep a single row on one line.
    --
    -- The split is measured, not equal. Equal halves are refused as soon as one
    -- row is a pixel too wide, and the widest row here is a buff reminder, so
    -- the page fell back to one column at the default size. Instead the widest
    -- block owns one column and the rest of the page is the other; a block that
    -- fits neither column goes full width below them, and nothing is ever
    -- squeezed into a column too narrow for its rows.
    local widest = 0
    for index, block in ipairs(blocks) do
        if not block.noteOneLine and block.minWidth > widest then
            widest = block.minWidth
        end
    end

    local columns = 1
    local columnWidth = { math.max(120, pageWidth) }
    local wide = {}

    if pageWidth >= SETTINGS_MIN_WIDTH and widest > 0
        and (widest + SETTINGS_MIN_COLUMN + SETTINGS_COLUMN_GAP) <= pageWidth then
        columns = 2
        columnWidth = {
            widest,
            pageWidth - widest - SETTINGS_COLUMN_GAP,
        }
    end

    local function applyWidth(block, width)
        block.heading:SetWidth(math.max(20, width - SETTINGS_CHECK_X - 8))
        settingsOneLine(block.heading)

        for _, row in ipairs(block.rows) do
            if row.label then
                -- Four pixels more than the measured minimum, so a fractional
                -- string width cannot tip a one-line row into a wrap.
                row.label:SetWidth(math.max(20, width - SETTINGS_LABEL_X - 8))
                settingsOneLine(row.label)
            elseif row.button then
                -- Leave room for the 16-pixel "?" marker and its 6-pixel gap.
                row.button:SetSize(math.min(210,
                    math.max(100, width - SETTINGS_CHECK_X - 24)), 20)
            end
        end

        if block.button then
            block.button:SetSize(math.min(260, math.max(80, width - 8)), 20)
        end

        if block.note then
            block.note:SetWidth(math.max(20, width - SETTINGS_CHECK_X - 8))
            if block.noteOneLine then settingsOneLine(block.note) end
        end
    end

    local function measureBlock(block)
        block.headingStep = math.max(14, settingsTextHeight(block.heading)) + 6

        local height = block.headingStep
        for _, row in ipairs(block.rows) do
            if row.button then
                row.step = SETTINGS_ROW_MIN
            elseif row.slider then
                -- Label line plus the slider beneath it.
                row.step = math.max(SETTINGS_ROW_MIN, settingsTextHeight(row.label) + 2) + 20
            else
                row.step = math.max(SETTINGS_ROW_MIN, settingsTextHeight(row.label) + 2)
            end
            height = height + row.step
        end

        if block.button then
            height = height + 24
        end

        if block.note then
            block.noteStep = settingsTextHeight(block.note)
            height = height + 4 + block.noteStep
        end

        block.height = height + 2
    end

    local columnHeights = {}
    for index = 1, columns do columnHeights[index] = 0 end

    for index, block in ipairs(blocks) do
        -- The shortest column whose width holds every one of this block's rows
        -- on a single line. A one-line note is wide by design and stays full
        -- width; so does a block that fits neither column.
        local target = 1

        if columns > 1 then
            target = nil

            if not block.noteOneLine then
                for column = 1, columns do
                    if block.minWidth <= columnWidth[column]
                        and (not target or columnHeights[column] < columnHeights[target]) then
                        target = column
                    end
                end
            end
        end

        if not target then wide[index] = true end

        applyWidth(block, target and columnWidth[target] or pageWidth)
        measureBlock(block)

        if target then
            block.column = target
            block.offset = columnHeights[target]
            columnHeights[target] = columnHeights[target] + block.height + SETTINGS_BLOCK_GAP
        end
    end

    local columnBottom = 0
    for index = 1, columns do
        if columnHeights[index] > columnBottom then
            columnBottom = columnHeights[index]
        end
    end
    if columnBottom > 0 then
        columnBottom = columnBottom - SETTINGS_BLOCK_GAP
    end

    -- Wide blocks continue below both columns, so they never overlap a column.
    local wideBottom = columnBottom
    for index, block in ipairs(blocks) do
        if wide[index] then
            block.offset = wideBottom + SETTINGS_BLOCK_GAP
            wideBottom = block.offset + block.height
        end
    end

    local pageBottom = columnBottom
    if wideBottom > pageBottom then pageBottom = wideBottom end

    for _, block in ipairs(blocks) do
        local x = 0
        if block.column then
            for column = 1, block.column - 1 do
                x = x + columnWidth[column] + SETTINGS_COLUMN_GAP
            end
        end

        local baseY = topY - block.offset

        block.heading:ClearAllPoints()
        block.heading:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
            x + SETTINGS_CHECK_X, baseY)
        if block.headingInfo then
            block.headingInfo:ClearAllPoints()
            block.headingInfo:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
                x + SETTINGS_INFO_X, baseY - 1)
        end

        local y = baseY - block.headingStep

        for _, row in ipairs(block.rows) do
            if row.button then
                row.button:ClearAllPoints()
                row.button:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
                    x + SETTINGS_CHECK_X, y - 1)

                if row.info then
                    row.info:ClearAllPoints()
                    row.info:SetPoint("LEFT", row.button, "RIGHT", 6, 0)
                end
            elseif row.slider then
                row.label:ClearAllPoints()
                row.label:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
                    x + SETTINGS_LABEL_X, y)

                row.slider:ClearAllPoints()
                row.slider:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
                    x + SETTINGS_LABEL_X, y - 20)

                row.valueLabel:ClearAllPoints()
                row.valueLabel:SetPoint("LEFT", row.slider, "RIGHT", 8, 0)

                if row.info then
                    row.info:ClearAllPoints()
                    row.info:SetPoint("LEFT", row.valueLabel, "RIGHT", 4, 0)
                end
            else
                row.check:ClearAllPoints()
                row.check:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
                    x + SETTINGS_CHECK_X, y - 1)

                row.label:ClearAllPoints()
                row.label:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
                    x + SETTINGS_LABEL_X, y)

                if row.info then
                    row.info:ClearAllPoints()
                    row.info:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
                        x + SETTINGS_INFO_X, y - 1)
                end
            end

            y = y - row.step
        end

        if block.button then
            block.button:ClearAllPoints()
            block.button:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", x + 4, y - 4)
            y = y - 24
        end

        if block.note then
            block.note:ClearAllPoints()
            block.note:SetPoint("TOPLEFT", contentFrame, "TOPLEFT",
                x + SETTINGS_CHECK_X, y - 4)
            y = y - 4 - (block.noteStep or 0)
        end
    end

    cursor.y = topY - pageBottom - 4
end

------------------------------------------------------------------------------
-- Debug, as a popup
--
-- The content is what the page used to print, unchanged: the level it scores
-- at, the modules loaded, the profile in force and the weight changes applied
-- on top of it, the class quirks it can value, the stat keys it does not model,
-- the buff registrations and the last self-test result.
--
-- It is a popup opened from Settings rather than a tab because it is the one
-- screen a player mostly does not need. The frame is built on its first open
-- and only outside combat; every later open redraws the same frame, so a fight
-- can never ask the client to create anything. Its height is measured from the
-- labels after they exist and capped to 80% of the screen, with the body
-- scrolling when the log does not fit.
------------------------------------------------------------------------------

debugPopup = {
    frame = nil,
    scroll = nil,
    -- The window's own lengths. They live on the table rather than in chunk
    -- locals because this file is close to the client's local limit.
    width  = 520,
    min    = 220,
    max    = 460,
    pad    = 14,
    footer = 44,
}

-- Draws the log into `host` from y = 0 and answers the y it finished on, so the
-- popup sizes itself from what was drawn rather than from a row count.
function debugPopup:DrawLog(host)
    local y = 0
    local textWidth = math.max(80, self.width - (self.pad * 2) - 12)

    local function line(text, colour)
        local label = MakeLabel(host, tostring(text), "GameFontNormalSmall",
            colour or LT.Palette:RGB("muted"))
        label:SetPoint("TOPLEFT", 0, y)
        label:SetWidth(textWidth)
        label:SetJustifyH("LEFT")
        y = y - ((label:GetStringHeight() or 12) + 2)
        return label
    end

    line("Level " .. tostring(LT.Levels:GetCurrentLevel()) .. " — "
        .. LT.Levels:DescribeScoringLevel(), LT.Palette:RGB("text"))

    local loaded = {}
    for _, name in ipairs(LT.ModuleOrder) do
        if LT.Modules[name] then table.insert(loaded, name) end
    end
    line("Modules loaded: " .. table.concat(loaded, ", "))

    local buildIndex = LT.Builds:GetActiveIndex()
    local effective = LT.Profiles:GetEffective(buildIndex)

    line("Active slot: " .. LT.Builds:Describe(buildIndex))
    line("Profile: " .. tostring(effective.scaleName or "none")
        .. (effective.provisional and " (provisional)" or ""))

    line("Weight changes applied on top of the stored profile:")
    local changes = LT.Profiles:ExplainEffective(buildIndex)
    if #changes == 0 then
        line("    none", LT.Palette:RGB("muted"))
    else
        for _, text in ipairs(changes) do
            line("    " .. text, LT.Palette:RGB("go"))
        end
    end

    for _, limitation in ipairs(effective.limitations or {}) do
        line("  " .. limitation, LT.Palette:RGB("caution"))
    end

    -- Class quirks: each line says which weight carries the quirk, or why the
    -- addon has no channel to value it. Nothing here is a control, and a class
    -- with no pack or no quirks draws no block at all.
    local classData = LT.ClassData
    if type(classData) == "table" and type(classData.DescribeQuirks) == "function" then
        local classToken = LT.player and LT.player.class or nil
        local okQuirks, quirks = pcall(classData.DescribeQuirks, classData, classToken)
        if okQuirks and type(quirks) == "table" and #quirks > 0 then
            line("Quirks:")
            for _, quirk in ipairs(quirks) do
                line("    " .. tostring(quirk))
            end
        end
    end

    local unmapped = LT.ItemStats:GetUnmappedKeys()
    line("Stat keys Forever returned that this addon does not model: "
        .. (#unmapped > 0 and table.concat(unmapped, ", ") or "none seen yet"))

    -- BuffMonitor registry summary (Decision 1)
    if LT.BuffMonitor then
        local reg = LT.BuffMonitor:GetRegistry()
        local parts = {}
        for class, defs in pairs(reg) do
            table.insert(parts, class .. ":" .. tostring(#defs))
        end
        line("BuffMonitor registrations: " .. (next(parts) and table.concat(parts, ", ") or "none"))
    end

    y = y - 4

    local testButton = MakeButton(host, "Run self tests", 120, 20, function()
        local report = LT.SelfTest:Run(true)
        UI.lastTestReport = report
        -- The popup is the page now: redraw it where it stands.
        if debugPopup then debugPopup:Render() end
    end)
    testButton:SetPoint("TOPLEFT", 0, y)
    y = y - 24

    if UI.lastTestReport then
        line("Last self test: " .. tostring(UI.lastTestReport.summary),
            UI.lastTestReport.failed == 0 and LT.Palette:RGB("go") or LT.Palette:RGB("stop"))
    end

    return y
end

function debugPopup:IsShown()
    return self.frame ~= nil and self.frame:IsShown() and true or false
end

function debugPopup:Hide()
    if self.frame then self.frame:Hide() end
end

function debugPopup:EnsureFrame()
    if self.frame then return self.frame end

    local window = MakePopupFrame("LunchboxToolkitDebugFrame", self.width, self.min, "debug")
    if not window then return nil end

    self.title = MakeLabel(window, "Debug log", "GameFontNormal", LT.Palette:RGB("brand"))
    self.title:SetPoint("TOPLEFT", self.pad, -12)

    self.info = MakeInfo(window, "Debug log",
        "What the addon sees right now: the level it scores at, the modules loaded, the "
        .. "weights in force after caps and plugins, the class quirks it can value, the "
        .. "stat keys it does not model, and the last self-test result. Nothing here "
        .. "changes a setting.")
    if self.info then self.info:SetPoint("LEFT", self.title, "RIGHT", 6, 0) end

    local body = CreateFrame("Frame", nil, window)
    body:SetPoint("TOPLEFT", self.title, "BOTTOMLEFT", 0, -8)
    body:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -self.pad, self.footer)

    self.scroll = MakeScroll(body, "debug")
    self.scroll.content.lunchboxLabelPool = {}

    local closeButton = MakeButton(window, "Close", 70, 20, function()
        debugPopup:Hide()
    end)
    closeButton:SetPoint("BOTTOMRIGHT", -self.pad, 12)
    self.closeButton = closeButton

    window:Hide()
    self.frame = window
    return window
end

function debugPopup:Render()
    if not self.frame then return end

    local content = self.scroll and self.scroll.content
    if not content then return end

    recycleHost(content)

    local y = self:DrawLog(content)

    self.scroll.offset = 0
    content:SetPoint("TOPLEFT", 0, 0)

    local extent = math.max(20, -y + 4)
    local header = 12 + (self.title:GetStringHeight() or 16) + 8

    local target = header + extent + self.footer + 8
    local uiHeight = (UIParent and UIParent.GetHeight and UIParent:GetHeight()) or 0
    local cap = self.max

    if type(uiHeight) == "number" and uiHeight > 0 then
        local screenCap = math.floor(uiHeight * 0.8)
        if screenCap < cap then cap = screenCap end
    end
    if cap < self.min then cap = self.min end
    if target > cap then target = cap end
    if target < self.min then target = self.min end

    self.frame:SetHeight(target)
    placePopupFrame(self.frame, "debug", self.width, target)
end

function debugPopup:Open()
    if combatLocked() then
        LT:Print("The debug log cannot be built in combat. Open it again after the fight.")
        return false
    end

    local window = self:EnsureFrame()
    if not window then
        LT:Print("The debug log could not be built. Try again.")
        return false
    end

    self:Render()
    window:Show()
    if window.Raise then pcall(window.Raise, window) end
    return true
end

function debugPopup:Toggle()
    if self:IsShown() then
        self:Hide()
    else
        self:Open()
    end
end

------------------------------------------------------------------------------
-- Character panel: "LBTK 30.3 as worn" and "34.7 with bags"
--
-- One card under the character's name on the character sheet. The worn number
-- comes from GearPopup:WornTotal — the same walk of the worn items the Equipment
-- page and the gear check use — so the three can never disagree. The button
-- carries the projected total and opens the gear-check list; pressing it equips
-- nothing.
--
-- Rules this obeys:
--   * nothing is printed at all when no worn item could be scored, so the line
--     can never read 0.0;
--   * the button is hidden when the bags hold nothing better, rather than
--     showing the same number twice;
--   * the card is built once, on the first pane opening outside a fight, and
--     reused, so a /reload cannot leave a second one behind (the frame lives in
--     one local, and a fresh Lua state builds a fresh card);
--   * an opening during a fight is remembered and built when the fight ends,
--     because the client refuses a frame creation there;
--   * the width is measured from the label and the button after their text
--     exists, not guessed.
------------------------------------------------------------------------------

-- A closure keeps the card's own names out of the chunk's local budget, which
-- this file is close to: only the hook below is visible to the rest of it.
local hookCharacterPane = (function()
    local charScore = {
        frame = nil,
        label = nil,
        button = nil,
        deferred = false,
        hooked = false,
    }

    local function characterPane()
        -- PaperDollFrame is the sheet the player sees; CharacterFrame is the
        -- outer window and stays the fallback.
        for _, name in ipairs({ "PaperDollFrame", "CharacterFrame" }) do
            local pane = _G[name]
            if pane and type(pane.HookScript) == "function" then return pane end
        end

        return nil
    end

    -- Worn total, projected total and how many upgrades the projection used. nil
    -- when nothing on the character could be scored.
    local function charScoreNumbers()
        local popup = LT.GearPopup
        if type(popup) ~= "table" or type(popup.WornTotal) ~= "function" then return nil end
        if type(LT.Builds) ~= "table" or type(LT.Builds.GetActiveIndex) ~= "function" then
            return nil
        end

        local index = LT.Builds:GetActiveIndex()

        local okWorn, worn = pcall(popup.WornTotal, popup, index)
        worn = okWorn and tonumber(worn) or nil
        if not worn or worn <= 0 then return nil end

        local withBags, upgrades = nil, 0

        local okScan, result = pcall(popup.Scan, popup, { buildIndex = index })
        if okScan and type(result) == "table" then
            local okClass, entries = pcall(popup.Classify, popup, result)

            if okClass and type(entries) == "table"
                and type(popup.ProjectedTotal) == "function" then
                local okTotal, total, count = pcall(popup.ProjectedTotal, popup, worn, entries)
                if okTotal then
                    withBags = tonumber(total)
                    upgrades = tonumber(count) or 0
                end
            end
        end

        return worn, withBags, upgrades
    end

    local function measureWidth(region, fallback)
        if not region then return fallback or 0 end

        local ok, width = pcall(region.GetStringWidth, region)
        if ok and type(width) == "number" and width > 0 then
            if not (LT.IsSecret and LT:IsSecret(width)) then return width end
        end

        local text = region.GetText and region:GetText() or ""
        return math.max(fallback or 0, #tostring(text or "") * 4)
    end

    local function refreshCharScore()
        local card = charScore.frame
        if not card then return end

        local worn, withBags, upgrades = charScoreNumbers()

        -- Nothing scorable: nothing printed. A "0.0" would read as a score.
        if not worn then
            card:Hide()
            return
        end

        charScore.label:SetText("LBTK " .. LT:FormatNumber(worn, 1) .. " as worn")

        local labelWidth = measureWidth(charScore.label, 60)
        charScore.label:SetWidth(math.max(60, labelWidth + 2))

        local showButton = (upgrades > 0) and withBags ~= nil and withBags > worn + 0.05
        local buttonWidth = 0

        if showButton then
            charScore.button:SetText(LT:FormatNumber(withBags, 1) .. " with bags")

            -- The button's own text is measured, so a four-digit total does not
            -- clip its label.
            local fontString = nil
            if type(charScore.button.GetFontString) == "function" then
                local okFont, found = pcall(charScore.button.GetFontString, charScore.button)
                if okFont then fontString = found end
            end
            buttonWidth = math.max(80, measureWidth(fontString, 70) + 20)

            charScore.button:SetWidth(buttonWidth)
            charScore.button:Show()

            card:SetWidth(8 + labelWidth + 8 + buttonWidth + 8)
        else
            charScore.button:Hide()
            card:SetWidth(8 + labelWidth + 8)
        end

        card:Show()
    end

    local function buildCharScore()
        if charScore.frame then return charScore.frame end
        if combatLocked() then
            charScore.deferred = true
            return nil
        end

        local pane = characterPane()
        if not pane then return nil end

        local card = CreateFrame("Frame", nil, pane)
        card:SetSize(240, 26)

        -- A card, not a new window: the quieter hairline on the opaque slab, so
        -- it sits on the character sheet rather than floating in the world.
        cardChrome(card, { edge = LT.Palette.chrome.border, fill = windowSurface() })

        charScore.label = MakeLabel(card, "", "GameFontNormalSmall", LT.Palette:RGB("text"))
        charScore.label:SetPoint("LEFT", 8, 0)
        charScore.label:SetJustifyH("LEFT")
        oneLine(charScore.label)

        charScore.button = MakeButton(card, "with bags", 92, 20, function()
            local popup = LT.GearPopup
            if type(popup) ~= "table" or type(popup.Open) ~= "function" then
                LT:Error("The gear check module is not loaded.")
                return
            end

            local shown, reason = popup:Open()
            if reason then LT:Print(reason) end
        end)
        charScore.button:SetPoint("LEFT", charScore.label, "RIGHT", 8, 0)

        -- Above the character window, never inside it: the sheet's corner
        -- belongs to the client's own sidebar, and CharacterName is not a
        -- global any shipped client addon uses.
        local window = _G.CharacterFrame
        if window and type(window.GetPoint) == "function" then
            pcall(card.SetParent, card, window)
            card:SetPoint("BOTTOMLEFT", window, "TOPLEFT", 12, 4)
        else
            card:SetPoint("BOTTOMLEFT", pane, "TOPLEFT", 12, 4)
        end

        -- Gear, bags and a ding can all change the two numbers while the sheet
        -- is open; the card is cheap to recompute and only ticks when shown.
        pcall(card.RegisterEvent, card, "BAG_UPDATE_DELAYED")
        pcall(card.RegisterEvent, card, "PLAYER_EQUIPMENT_CHANGED")
        pcall(card.RegisterEvent, card, "PLAYER_LEVEL_UP")
        card:SetScript("OnEvent", function(self)
            if self:IsShown() then refreshCharScore() end
        end)

        card:Hide()

        charScore.frame = card
        return card
    end

    return function()
        local pane = characterPane()
        if not pane or charScore.hooked then return end

        pcall(pane.HookScript, pane, "OnShow", function()
            if not charScore.frame and not buildCharScore() then return end
            refreshCharScore()
        end)

        -- An opening that happened during a fight could not build anything; the
        -- fight's end is the first moment it can, and nothing else would retry.
        pcall(pane.RegisterEvent, pane, "PLAYER_REGEN_ENABLED")
        pcall(pane.HookScript, pane, "OnEvent", function(_, event)
            if event ~= "PLAYER_REGEN_ENABLED" then return end
            if not charScore.deferred then return end

            charScore.deferred = false
            if buildCharScore() then refreshCharScore() end
        end)

        -- A level, a build switch or a new equipment set changes the number
        -- while the sheet is open.
        for _, event in ipairs({ LT.EVENT_LEVEL, LT.EVENT_BUILDS, LT.EVENT_PROFILE,
            LT.EVENT_GEARSET }) do
            LT:On(event, function()
                if charScore.frame and charScore.frame:IsShown() then refreshCharScore() end
            end)
        end

        charScore.hooked = true

        -- A sheet already on screen when this runs gets its card now.
        if pane.IsShown and pane:IsShown() then
            if buildCharScore() then refreshCharScore() end
        end
    end
end)()

------------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------------

local refreshing = false
local refreshQueued = false

function UI:Refresh()
    if not frame or not frame:IsShown() then return end

    -- Hiding a focused edit box fires OnEditFocusLost, which commits the text
    -- and fires EVENT_BUILDS, which lands back here in the middle of
    -- clearContent(). Rebuilding the page from inside a rebuild would draw it
    -- twice, so a nested request is queued and run once the outer one finishes.
    if refreshing then
        refreshQueued = true
        return
    end

    refreshing = true
    local ok, err = pcall(UI.RefreshNow, UI)
    refreshing = false

    if not ok then
        LT:Error("UI refresh failed: " .. tostring(err))
    end

    if refreshQueued then
        refreshQueued = false
        UI:Refresh()
    end
end

function UI:RefreshNow()
    -- The rail is what says which page is up: one accent bar, on one row.
    for key, button in pairs(pageButtons or {}) do
        if button.SetSelected then
            button:SetSelected(key == currentPage)
        end
    end

    local cursor = clearContent()

    if contextText then
        contextText:SetText(describeContext())
    end

    if specToggle and type(specToggle.SetText) == "function" then
        specToggle:SetText("Spec: " .. activeBuildShortLabel())
        if type(specToggle.fit) == "function" then specToggle.fit() end
    end

    local draw = {
        builds = drawBuilds,
        profiles = drawProfiles,
        gear = drawGear,
        setup = drawSetup,
        actions = function(cursor) return UI:DrawActions(cursor) end,
        plugins = drawPlugins,
        settings = drawSettings,
        ranks = drawRanks,
    }

    local drawer = draw[currentPage] or externalDrawers[currentPage] or drawBuilds

    -- Only a scroll area the page itself makes may take the window's bar; a
    -- popup's body is not this page's.
    inPageDraw = true
    local ok, err = pcall(drawer, cursor, contentFrame)
    inPageDraw = false

    -- The page has claimed a scroll area by now (or not). The bar is measured
    -- from content that exists, which is why it is decided here rather than when
    -- the scroll frame was made.
    refreshScrollBar()

    if not ok then
        local label = MakeLabel(contentFrame, "Page failed to draw: " .. tostring(err),
            "GameFontNormalSmall", LT.Palette:RGB("stop"))
        label:SetPoint("TOPLEFT", 4, 0)
    end
end

function UI:OnPlayerLogin()
    -- Nothing is built until the player asks for the window; this keeps login
    -- time untouched. The character sheet's score card hooks the pane here (a
    -- hook creates no frame) and builds itself on the first opening, outside a
    -- fight.
    hookCharacterPane()
    LT:Debug("UI ready")
end