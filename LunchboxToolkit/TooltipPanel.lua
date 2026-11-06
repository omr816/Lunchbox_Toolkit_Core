--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — TooltipPanel
    The visible tooltip surface: a small frame that sits ABOVE the tooltip it
    belongs to, rather than adding lines inside it.

    Why a separate frame:

      * the client shows its own comparison tooltip when Shift is held. Lines
        appended to GameTooltip end up interleaved with that comparison, and a
        Shift-driven "expand" toggle fights the client for the same key;
      * a companion frame can be anchored above its own tooltip, so the item
        tooltip and the comparison tooltip each get their own panel, and the
        extended detail appears next to the item it describes;
      * nothing is ever written into the client's tooltip, so removing the
        addon leaves the tooltips exactly as the game drew them.

    One panel per tooltip frame, created on first use and reused afterwards, so
    hovering repeatedly never accumulates anything.

    The panel is sized to its rows, not the rows to the panel. Every row is
    measured in pixels by the client's own font, the caption widens to hold the
    widest one (up to MAX_WIDTH) and anything longer wraps onto a second line.
    Only a row with no space left in it to wrap at — a long profile or set name —
    is shortened. Cutting rows to a fixed character estimate is what turned
    "Not yet — Mail is training" into "Not yet — Mail is train...".
--------------------------------------------------------------------------]]
local LT = LunchboxToolkit

local TooltipPanel = {}
LT.TooltipPanel = TooltipPanel
LT.Modules.TooltipPanel = TooltipPanel

local PANEL_WIDTH = 330
local LINE_HEIGHT = 13
local PADDING = 6

-- The two lines this panel draws itself, by hand, in four thin textures rather
-- than a backdrop. The outer 2 px is the same bronze every window carries
-- (Palette chrome.border), so the caption and the windows read as one family;
-- the 1 px line just inside it is the verdict tone, which is what the outline
-- is for. The mechanism is the one the windows now copy, not the other way
-- round: no backdrop, no texture file, both ends of every side anchored.
local CHROME_EDGE = 2
local TONE_EDGE = 1

-- How wide a caption may grow to hold one of its own rows. A row longer than
-- this is wrapped onto a second line rather than cut: the "**" limitation note
-- runs to about 550 px, and half a sentence tells the player less than nothing.
local MAX_WIDTH = 400

-- Gap between the panel and the tooltip it belongs to, so the panel reads as a
-- separate caption rather than part of the item text.
local GAP = 4

local panels = {}

-- Outline colours, one per verdict the tooltip can act on. The values come from
-- Palette, so the border and the word inside the panel cannot disagree:
--   normal    purple — the best answer: usable, and the score is this build's;
--   deferred  green — usable but not yet (Usability's DEFERRED): the score is
--             still shown, and the outline says the character cannot wear or
--             wield it at this level;
--   never     grey — the class can never use it (Usability's NEVER), or a build
--             calls it ineligible: no score is printed, because there is no "no"
--             number to give;
--   unknown   red — the add-on cannot answer: no build produced a score and
--             Usability made no claim either. Red is never used for an answer
--             the add-on actually has (see Tooltip:ToneFor for the precedence).
local TONE_COLOURS = {
    normal   = LT.Palette.verdict.go,
    deferred = LT.Palette.verdict.caution,
    never    = LT.Palette.verdict.stop,
    unknown  = LT.Palette.verdict.unknown,
}

-- Exposed so the self test can prove these are the palette's own tables rather
-- than copies of its numbers.
TooltipPanel.toneColours = TONE_COLOURS

local function paintEdges(panel, tone, tone2)
    local colour1 = TONE_COLOURS[tone] or TONE_COLOURS.normal
    local colour2 = TONE_COLOURS[tone2] or colour1

    -- edges[1]=top, edges[2]=bottom, edges[3]=left, edges[4]=right.
    -- Build 1 owns top + left, build 2 owns bottom + right. A single tone (no
    -- tone2) paints all four the same colour.
    panel.edges[1]:SetColorTexture(colour1[1], colour1[2], colour1[3], 0.90)
    panel.edges[3]:SetColorTexture(colour1[1], colour1[2], colour1[3], 0.90)
    panel.edges[2]:SetColorTexture(colour2[1], colour2[2], colour2[3], 0.90)
    panel.edges[4]:SetColorTexture(colour2[1], colour2[2], colour2[3], 0.90)
end

local function createPanel(owner)
    local panel = CreateFrame("Frame", nil, UIParent)
    panel:SetSize(PANEL_WIDTH, LINE_HEIGHT + PADDING * 2)

    -- Tooltips live in the TOOLTIP strata, so the panel has to as well or it
    -- would be drawn underneath the tooltip it is meant to caption.
    if panel.SetFrameStrata then panel:SetFrameStrata("TOOLTIP") end
    if panel.SetFrameLevel then panel:SetFrameLevel(200) end

    -- The panel must never intercept the mouse: hovering a tooltip that is
    -- inside the panel's rectangle has to keep working normally.
    if panel.EnableMouse then panel:EnableMouse(false) end
    if panel.SetMouseClickEnabled then pcall(panel.SetMouseClickEnabled, panel, false) end

    local background = panel:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(true)
    local panelBg = LT.Palette.chrome.panelBg
    background:SetColorTexture(panelBg[1], panelBg[2], panelBg[3], panelBg[4])
    panel.background = background

    -- A font string that is never shown, in the same font as the rows: it
    -- answers "how wide is this text" so the panel can be sized to its content
    -- instead of the content being cut to the panel.
    local gauge = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    gauge:SetWordWrap(false)
    gauge:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    gauge:Hide()
    panel.measure = gauge

    -- The outline is four thin textures rather than a backdrop, so the panel
    -- looks the same on a client without SetBackdrop support: an outer bronze
    -- edge from the palette, exactly the one every window now draws, and the
    -- verdict tone as the line just inside it.
    panel.chromeEdges = {}
    for index = 1, 4 do
        local edge = panel:CreateTexture(nil, "BORDER")
        local border = LT.Palette.chrome.border
        edge:SetColorTexture(border[1], border[2], border[3], border[4])
        panel.chromeEdges[index] = edge
    end

    panel.edges = {}
    for index = 1, 4 do
        local edge = panel:CreateTexture(nil, "BORDER")
        local normal = TONE_COLOURS.normal
        edge:SetColorTexture(normal[1], normal[2], normal[3], 0.90)
        panel.edges[index] = edge
    end

    panel.lines = {}
    panel.owner = owner
    panel.tone = "normal"
    panel.tone2 = nil
    panel:Hide()

    return panel
end

-- One side, pinned by its two ends: both anchor points carry the offset, so the
-- region needs no SetWidth/SetHeight and a panel that is widened or shortened
-- later keeps an unbroken edge.
local function pin(edge, panel, firstPoint, firstX, firstY, secondPoint, secondX, secondY)
    if not edge then return end

    edge:ClearAllPoints()
    edge:SetPoint(firstPoint, panel, firstPoint, firstX, firstY)
    edge:SetPoint(secondPoint, panel, secondPoint, secondX, secondY)
end

local function layoutEdges(panel)
    local outer = panel.chromeEdges or {}
    local tone = panel.edges or {}
    local w = CHROME_EDGE
    local l = TONE_EDGE

    -- The chrome edge: full width along the top and bottom, the two vertical
    -- sides inset by its own width so the corners neither double up nor leave a
    -- notch.
    pin(outer[1], panel, "TOPLEFT", 0, 0, "TOPRIGHT", 0, -w)
    pin(outer[2], panel, "BOTTOMLEFT", 0, 0, "BOTTOMRIGHT", 0, w)
    pin(outer[3], panel, "TOPLEFT", 0, -w, "BOTTOMLEFT", w, w)
    pin(outer[4], panel, "TOPRIGHT", 0, -w, "BOTTOMRIGHT", -w, w)

    -- The verdict line, one pixel wide, just inside the chrome edge.
    pin(tone[1], panel, "TOPLEFT", w, -w, "TOPRIGHT", -w, -w - l)
    pin(tone[2], panel, "BOTTOMLEFT", w, w, "BOTTOMRIGHT", -w, w + l)
    pin(tone[3], panel, "TOPLEFT", w, -w - l, "BOTTOMLEFT", w + l, w + l)
    pin(tone[4], panel, "TOPRIGHT", -w, -w - l, "BOTTOMRIGHT", -w - l, w + l)
end

-- The client's own comparison and shopping tooltips are placed beside the item
-- tooltip: to its right when there is room, to its left or below when there is
-- not. A caption anchored above the item tooltip therefore lands on top of them,
-- which is what made the Shift view unreadable, and moving the caption to the
-- left whenever one of them is on screen only moved the collision to the case
-- where the client had put its own box on the left. So the caption now reads
-- where each comparison frame actually is and takes the first side that is on
-- screen and clear of both the tooltip and those frames.
local COMPARISON_FRAMES = {
    "GameTooltip2",
    "ShoppingTooltip1",
    "ShoppingTooltip2",
    "ShoppingTooltip3",
    "ItemRefShoppingTooltip1",
    "ItemRefShoppingTooltip2",
}

local function comparisonIsShown()
    for _, name in ipairs(COMPARISON_FRAMES) do
        local frame = _G[name]
        -- A WoW frame may be userdata, not a table: type()=="table" made every
        -- comparison invisible here, so the panel never avoided one (report
        -- 2026-11-05: our caption over the client compare on quest rewards).
        if (type(frame) == "table" or type(frame) == "userdata")
            and type(frame.IsShown) == "function" and frame:IsShown() then
            return true
        end
    end

    return false
end

-- The rectangle a frame occupies, in UIParent coordinates, or nil when the
-- client will not answer — a hidden frame, or one whose size it reports as
-- nothing usable.
local function rectOf(frame)
    -- LT:Rect reads every edge through LT:Number, so a value the client marks
    -- secret — which still answers type() "number" — comes back nil here instead
    -- of reaching the arithmetic below.
    local rect = LT:Rect(frame)
    if not rect then return nil end
    if rect.width <= 0 or rect.height <= 0 then return nil end

    return { left = rect.left, right = rect.left + rect.width,
        bottom = rect.bottom, top = rect.bottom + rect.height }
end

-- Every comparison tooltip on screen, as rectangles. Empty while the client is
-- not drawing one, which is the normal case.
local function comparisonRects()
    local rects = {}

    for _, name in ipairs(COMPARISON_FRAMES) do
        local frame = _G[name]
        if (type(frame) == "table" or type(frame) == "userdata")
            and type(frame.IsShown) == "function" and frame:IsShown() then
            local rect = rectOf(frame)
            if rect then table.insert(rects, rect) end
        end
    end

    return rects
end

-- Do two rectangles share a pixel? Rectangles that only touch do not overlap,
-- so a caption hung exactly GAP away from a tooltip is accepted.
local function overlaps(a, b)
    if not a or not b then return false end

    return a.left < b.right and b.left < a.right and a.bottom < b.top and b.bottom < a.top
end

-- The box a panel of `width` x `height` would occupy hung on `side` of `owner`,
-- in the same coordinates as `rectOf`.
local function boxFor(owner, width, height, side)
    if side == "left" then
        return {
            left = owner.left - GAP - width,
            right = owner.left - GAP,
            bottom = owner.top - height,
            top = owner.top,
        }
    elseif side == "right" then
        return {
            left = owner.right + GAP,
            right = owner.right + GAP + width,
            bottom = owner.top - height,
            top = owner.top,
        }
    elseif side == "above" then
        return {
            left = owner.right - width,
            right = owner.right,
            bottom = owner.top + GAP,
            top = owner.top + GAP + height,
        }
    elseif side == "below" then
        return {
            left = owner.right - width,
            right = owner.right,
            bottom = owner.bottom - GAP - height,
            top = owner.bottom - GAP,
        }
    end

    return nil
end

-- The first side in `order` whose box fits the screen and touches none of
-- `blockers`. Pure — no frame and no item — so the self test can prove the
-- choice; `screen` is passed as { width, height } because a synthetic check has
-- no UIParent to measure.
local function pickSide(owner, width, height, blockers, screen, order)
    if type(owner) ~= "table" then return nil end

    -- Every coordinate goes through LT:Number, so a secret edge is nil here
    -- instead of an arithmetic error later. The tooltip rectangle is rebuilt
    -- from the four checked numbers rather than trusted as given.
    local rect = {
        left = LT:Number(owner.left),
        right = LT:Number(owner.right),
        bottom = LT:Number(owner.bottom),
        top = LT:Number(owner.top),
    }

    if not (rect.left and rect.right and rect.bottom and rect.top) then return nil end

    width = LT:Number(width)
    height = LT:Number(height)
    if not width or not height then return nil end

    local screenWidth = LT:Number(screen and screen[1]) or 1024
    local screenHeight = LT:Number(screen and screen[2]) or 768

    for _, side in ipairs(order or { "left", "right", "above", "below" }) do
        local box = boxFor(rect, width, height, side)

        if box
            and box.left >= 0 and box.right <= screenWidth
            and box.bottom >= 0 and box.top <= screenHeight then
            local clear = true

            for _, blocker in ipairs(blockers or {}) do
                if overlaps(box, blocker) then
                    clear = false
                    break
                end
            end

            if clear then return side end
        end
    end

    return nil
end

-- The side order an ordinary hover tries. Above the tooltip is where a caption
-- has always sat; below is for a tooltip against the top of the screen; beside
-- it is the answer when neither vertical side has room. Exposed beside pickSide
-- so the self test proves the order the panel actually uses, not a copy of it.
local PLAIN_ORDER = { "above", "below", "left", "right" }

-- Exposed for the self test: the placement rule is geometry, not a frame.
TooltipPanel.pickSide = pickSide
TooltipPanel.rectOf = rectOf
TooltipPanel.plainOrder = PLAIN_ORDER

-- Hangs the panel on one side of its tooltip. Kept apart from the choice above
-- so the four sides are written down in exactly one place.
local function placePanel(panel, owner, side)
    panel:ClearAllPoints()

    if side == "left" then
        panel:SetPoint("TOPRIGHT", owner, "TOPLEFT", -GAP, 0)
    elseif side == "right" then
        panel:SetPoint("TOPLEFT", owner, "TOPRIGHT", GAP, 0)
    elseif side == "below" then
        panel:SetPoint("TOPRIGHT", owner, "BOTTOMRIGHT", 0, -GAP)
    else
        panel:SetPoint("BOTTOMRIGHT", owner, "TOPRIGHT", 0, GAP)
    end
end

-- The screen's own size, read through the same guarded reader as every other
-- piece of geometry: a value the client will not hand over keeps the 1024x768
-- floor instead of being used in arithmetic.
local function screenSize()
    local width, height = 1024, 768

    if type(UIParent) == "table" and type(UIParent.GetWidth) == "function"
        and type(UIParent.GetHeight) == "function" then
        local ok, w, h = pcall(function()
            return UIParent:GetWidth(), UIParent:GetHeight()
        end)

        if ok then
            width = LT:Number(w) or width
            height = LT:Number(h) or height
        end
    end

    return width, height
end

-- Anchors the panel above `owner` when there is room, and below it when the
-- tooltip is near the top of the screen: a caption pushed off-screen is worse
-- than one on the wrong side. While the client is drawing its own comparison
-- the caption takes the first free side instead, because that is the only case
-- where the tooltip has company on screen. Returns false when the tooltip's own
-- box cannot be read: the caller then draws nothing this tick rather than
-- hanging the caption on a guessed anchor.
local function anchorTo(panel, owner)
    local ownerRect = rectOf(owner)

    if not ownerRect then return false end

    local screenWidth, screenHeight = screenSize()
    local width, height = PANEL_WIDTH, LINE_HEIGHT

    if type(panel.GetWidth) == "function" then
        local ok, raw = pcall(panel.GetWidth, panel)
        width = ok and LT:Number(raw) or nil
        width = width or PANEL_WIDTH
    end

    if type(panel.GetHeight) == "function" then
        local ok, raw = pcall(panel.GetHeight, panel)
        height = ok and LT:Number(raw) or nil
        height = height or LINE_HEIGHT
    end

    -- Any owner, not only GameTooltip: a quest reward pane may hang the item on a
    -- shopping tooltip while the comparison sits beside it.
    if comparisonIsShown() then
        local blockers = { ownerRect }
        for _, rect in ipairs(comparisonRects()) do
            table.insert(blockers, rect)
        end

        -- Left first, so a comparison drawn on the right leaves the caption
        -- exactly where it has always been.
        local side = pickSide(ownerRect, width, height, blockers,
            { screenWidth, screenHeight }, { "left", "right", "above", "below" })

        if side then
            placePanel(panel, owner, side)
            return true
        end
    end

    -- A plain hover goes through the same fit test, with the order a caption has
    -- always used first. It used to skip the test altogether: above the tooltip
    -- by rule, and below it only when the tooltip was within 60 px of the top, so
    -- a bag item near the right edge or the top of the screen hung the caption
    -- off the screen and the player lost the end of every row.
    do
        local side = pickSide(ownerRect, width, height, {},
            { screenWidth, screenHeight }, PLAIN_ORDER)

        if side then
            placePanel(panel, owner, side)
            return true
        end
    end

    -- Nothing fits: a caption taller than the room on every side. Hung where it
    -- has always hung, so it is clipped rather than missing.
    if ownerRect.top > screenHeight - 60 then
        placePanel(panel, owner, "below")
    else
        placePanel(panel, owner, "above")
    end

    return true
end

-----------------------------------------------------------------------------
-- Drawing
--
-- `rows` is a list of strings, each with WoW colour codes already applied. The
-- first row is the heading and is drawn in the toolkit green; the rest follow
-- the colours the caller chose.
-----------------------------------------------------------------------------

local LINE_SPACING = 14

-- Vertical gap between rows. Rows are placed by their own measured height, so a
-- wrapped note simply takes two lines' worth of room.
local ROW_GAP = 1

-- How many row font strings a prepared panel starts with. A hover must never
-- create a frame or a font string inside a tooltip hook — that is what taints
-- the client's bag buttons on Forever — so the rows are built with the panel at
-- Initialize and reused. A taller panel still grows on demand in Show, which is
-- rare and costs nothing when it does not happen.
local PREPARED_LINES = 12

-- One row font string, in the panel's font. Kept in one place so a row prepared
-- ahead of time and a row built on demand are configured identically.
local function createLine(panel)
    local line = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    line:SetJustifyH("LEFT")
    -- Wrap rather than clip: a row longer than the panel takes a second line,
    -- which is how a long "**" note stays whole.
    line:SetWordWrap(true)
    return line
end

-- How wide a row is at the panel's font, in pixels. Asked of the client rather
-- than estimated: the old fixed "six pixels per character" guess cut rows that
-- would have fitted and kept rows that then ran past the edge.
local function textWidth(panel, text)
    local gauge = panel and panel.measure
    if not gauge then return nil end

    gauge:SetText(tostring(text or ""))
    local ok, raw = pcall(gauge.GetStringWidth, gauge)
    gauge:SetText("")

    local width = ok and LT:Number(raw) or nil
    if width and width > 0 then return width end

    return nil
end

-- The fallback for a row that cannot wrap: one unbroken token wider than the
-- panel — a long profile or set name — is shortened here, keeping the colour
-- code that precedes the kept text so the shortened row keeps its colour.
-- Anything with a space in it is left whole, because the client wraps it and a
-- caption one line taller still says the whole sentence.
local function fit(text, available, natural)
    local raw = tostring(text or "")
    if not available or available <= 0 then return raw end
    if not natural or natural <= available then return raw end

    local plain = raw:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    if #plain == 0 then return raw end

    -- The widest single word, in pixels, from this row's own average character
    -- width: the same string is being measured in the same font throughout.
    local longest = 0
    for word in plain:gmatch("%S+") do
        if #word > longest then longest = #word end
    end

    if longest < #plain and (natural * longest / #plain) <= available then
        return raw
    end

    local capacity = math.max(8, math.floor(#plain * available / natural))
    if capacity >= #plain then return raw end

    local keep = capacity - 3   -- three characters are spent on "..."
    local visible = 0
    local position = 1
    local out = {}

    while position <= #raw and visible < keep do
        -- A colour code at the cursor is copied whole and never counted.
        local codeStart, codeEnd = raw:find("|c%x%x%x%x%x%x%x%x", position)
        if codeStart == position then
            table.insert(out, raw:sub(codeStart, codeEnd))
            position = codeEnd + 1
        elseif raw:sub(position, position + 1) == "|r" then
            table.insert(out, "|r")
            position = position + 2
        else
            table.insert(out, raw:sub(position, position))
            position = position + 1
            visible = visible + 1
        end
    end

    table.insert(out, "|r...")
    return table.concat(out)
end

-- Exposed so the self test can prove a row that fits is left alone, a row with
-- spaces is left for the client to wrap, and an unbreakable row keeps its colour
-- when it is shortened.
TooltipPanel.fitRow = fit

function TooltipPanel:Clear(owner)
    local panel = owner and panels[owner]
    if not panel then return end

    panel:Hide()
    panel:ClearAllPoints()
end

function TooltipPanel:ClearAll()
    for _, panel in pairs(panels) do
        panel:Hide()
        panel:ClearAllPoints()
    end
end

-- Calls `redraw(owner)` for every tooltip frame that currently has a panel on
-- screen. Used when the modifier key changes while a tooltip is still open: the
-- item tooltip and the client's comparison tooltip both get redrawn, each with
-- its own detail.
function TooltipPanel:RefreshOwners(redraw)
    if type(redraw) ~= "function" then return end

    for owner, panel in pairs(panels) do
        if panel:IsShown() and owner.__ltLink then
            pcall(redraw, owner)
        end
    end
end

-- Builds (or returns) the panel of one tooltip frame without drawing it. The
-- known frames are prepared once at Initialize, outside every tooltip hook:
-- creating a frame from inside a hook is what taints the client's bag buttons on
-- Forever, and a tainted bag button can no longer right-click sell. Show reuses
-- what this built; the creation below is only the fallback for a frame nobody
-- named.
function TooltipPanel:Prepare(owner)
    if type(owner) ~= "table" then return nil end

    local panel = panels[owner]
    if panel then return panel end

    panel = createPanel(owner)

    for index = 1, PREPARED_LINES do
        panel.lines[index] = createLine(panel)
    end

    panels[owner] = panel

    -- When the owner disappears, so does its caption. This is what keeps a
    -- panel from being left behind after a tooltip is hidden.
    if owner.HookScript then
        pcall(owner.HookScript, owner, "OnHide", function()
            if panels[owner] then panels[owner]:Hide() end
        end)
    end

    return panel
end

-- Shows `rows` above `owner`. An empty list hides the panel instead of leaving
-- an empty box behind. `tone` is "normal" (purple outline), "deferred" (green),
-- "never" (grey) or "unknown" (red, no answer); anything else falls back to
-- "normal".
function TooltipPanel:Show(owner, rows, tone, tone2)
    if type(owner) ~= "table" or type(rows) ~= "table" or #rows == 0 then
        self:Clear(owner)
        return nil
    end

    local panel = self:Prepare(owner)

    if not panel then
        return nil
    end

    -- Follow the tooltip's width when the client reports one wider than the
    -- floor, so a wide item tooltip and its caption share an edge; below the
    -- floor the caption keeps its own width, because a caption narrower than its
    -- own sentence cuts the sentence — which is how "Not yet — Mail is training"
    -- used to read as "Not yet — Mail is train..." beside a narrow tooltip.
    -- Read through LT:Number: a secret width answers nil, and the caption keeps
    -- its own floor rather than being sized from a value it may not use.
    local ownerWidth = nil

    if type(owner.GetWidth) == "function" then
        local ok, raw = pcall(owner.GetWidth, owner)
        ownerWidth = ok and LT:Number(raw) or nil
    end

    local width = PANEL_WIDTH

    if ownerWidth and ownerWidth > PANEL_WIDTH then
        width = math.floor(ownerWidth)
    end

    local widest = 0
    for _, row in ipairs(rows) do
        local rowWidth = textWidth(panel, row)
        if rowWidth and rowWidth > widest then widest = rowWidth end
    end

    if widest > 0 and widest + PADDING * 2 > width then
        width = math.ceil(widest + PADDING * 2)
    end

    -- The cap keeps a long note from stretching the caption across the screen;
    -- past this width the row wraps instead of widening the panel further.
    local screenWidth = screenSize()
    local cap = math.min(MAX_WIDTH, math.max(PANEL_WIDTH, screenWidth - 40))

    if width > cap then width = cap end

    panel:SetWidth(width)

    -- Repainted only when the tone changes, so an ordinary hover never touches
    -- the edge textures.
    tone = TONE_COLOURS[tone] and tone or "normal"
    tone2 = TONE_COLOURS[tone2] and tone2 or nil
    if panel.tone ~= tone or panel.tone2 ~= tone2 then
        panel.tone = tone
        panel.tone2 = tone2
        paintEdges(panel, tone, tone2)
    end

    -- Reuse the font strings: a hover must never create new ones, or the addon
    -- would leak a little memory on every mouse-over.
    local needed = #rows
    local available = #panel.lines

    for index = available + 1, needed do
        panel.lines[index] = createLine(panel)
    end

    local usable = width - PADDING * 2
    local y = PADDING

    for index, line in ipairs(panel.lines) do
        if index <= needed then
            local row = rows[index]
            local natural = textWidth(panel, row) or 0
            local text = fit(row, usable, natural)

            line:SetWidth(usable)
            line:SetText(text)

            -- Rows are placed by their own height, because a wrapped row is
            -- taller than one line. The client's measurement is used when it
            -- looks sane; otherwise the pixel measurement gives the least
            -- number of lines this row can need and one spare line is added.
            -- Too much padding still reads, overlapping rows do not.
            local shown = textWidth(panel, text) or natural
            local least = math.max(1, math.ceil(shown / usable))
            local height = nil

            local okHeight, rawHeight = pcall(line.GetStringHeight, line)
            local reported = okHeight and LT:Number(rawHeight) or nil
            if reported and reported >= LINE_SPACING * least - 1 then
                height = reported
            end

            if not height then
                height = (least > 1 and least + 1 or 1) * LINE_SPACING
            end

            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", PADDING, -y)
            line:Show()

            y = y + height + ROW_GAP
        else
            line:Hide()
            line:SetText("")
        end
    end

    panel:SetHeight(y - ROW_GAP + PADDING)
    layoutEdges(panel)

    -- A tooltip box the client will not hand over means no caption this tick:
    -- hiding is the only safe answer, and the next lookup redraws.
    if not anchorTo(panel, owner) then
        panel:Hide()
        return nil
    end

    panel:Show()

    return panel
end

-- The row format the rest of the addon builds: a heading, then one line per
-- build, then anything the caller wants to add while a modifier is held.
function TooltipPanel:BuildRows(heading, lines)
    local rows = {}

    if heading and heading ~= "" then
        table.insert(rows, LT.Palette:Wrap("brand", heading))
    end

    for _, line in ipairs(lines or {}) do
        table.insert(rows, tostring(line))
    end

    return rows
end

-- The modifier keys that expand the panel. Shift is included because the client
-- also uses Shift for its own comparison: because the panel lives in its own
-- frame above the tooltip instead of inside it, the two no longer compete —
-- Shift simply shows the comparison tooltip *and* the detail, each in place.
function TooltipPanel:IsExpandedByKey()
    if type(IsShiftKeyDown) == "function" then
        local ok, down = pcall(IsShiftKeyDown)
        if ok and down then return true end
    end

    if type(IsControlKeyDown) == "function" then
        local ok, down = pcall(IsControlKeyDown)
        if ok and down then return true end
    end

    return false
end