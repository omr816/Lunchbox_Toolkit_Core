--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Chrome
    One owner for the edge around every window the add-on draws.

    Why this file exists:

      * before it, each window did "if frame.SetBackdrop then ... end" with the
        ornate dialog border. On a frame created without the backdrop mixin that
        method is absent, so the else branch ran and the window got a flat fill
        and NO edge at all: a popup sitting on a page had no visible boundary;
      * where the SetBackdrop branch did run, the edge was the thick ornate
        dialog frame, which is not the flat look the rest of the UI uses. So one
        add-on had three possible appearances for one window, depending on the
        client;
      * the one place that already looked right was TooltipPanel.lua: four thin
        BORDER textures with SetColorTexture and no texture file. That is the
        proven pattern on this client, and this file is that pattern with one
        name.

    What it draws, and nothing else:

      * one BACKGROUND texture for the fill (SetAllPoints, SetColorTexture);
      * four BORDER textures for the outer edge, anchored to BOTH ends of each
        side so a frame that is resized later cannot leave the edge short, and
        never sized with SetSize/SetWidth/SetHeight;
      * the two vertical lines are inset by the edge width, exactly like
        TooltipPanel's, so no corner doubles up or leaves a notch;
      * Windows add a second inner set, 1 px of near-black, inset by the outer
        width. That is the line that makes a popup read as a separate slab from
        the page behind it even when both fills are near-black. Cards do not
        have one: a panel inside a window is a hairline, not a second frame.
      * one four-texture set holding the bevel (since the 2026-10-31 client-skin
        brief): 1 px along the top and the left, 1 px along the bottom and the
        right, inset past the edge. A raised surface - a window, a button - is
        lit on its top-left and shaded on its bottom-right; an inset surface - a
        panel, a card, the rail - is the other way round. That swap is how the
        client tells a thing you can press from a hole you look into, and it is
        still one flat colour per pixel with no texture file: this client packs
        its own art away, so a path that does not exist would draw nothing and
        leave the frame flat again.

    What it never does: enable the mouse, create a child frame, touch a texture
    file, or skin a Blizzard frame. Textures cannot take the mouse and cannot
    affect taint, which is why this approach is safe where a backdrop hook was
    not. Everything here is type-guarded and the creates are in pcall, so on a
    client without CreateTexture or SetColorTexture the frame simply has no
    edge: the helpers return nil and never raise.

    Colours come from Palette (chrome.border, chrome.borderDark,
    chrome.cardEdge, chrome.fill) so the edge cannot drift from the legend's
    palette. The regions are stored on the frame as frame.ltChrome and returned,
    and the helpers are idempotent: calling one twice repaints the same textures
    instead of stacking a second set.
--------------------------------------------------------------------------]]
local LT = LunchboxToolkit

local Chrome = {}
LT.Chrome = Chrome
LT.Modules.Chrome = Chrome

-- Line widths in UI units. A window carries the 1 px rim the client's own frames
-- carry, with a 1 px line inside it; a card inside a window carries a single 1 px
-- hairline so a dialog full of cards does not become a wall of boxes. BEVEL is the
-- thickness of the light and shadow pixels that give either of them depth.
local WINDOW_EDGE = 1
local INNER_LINE  = 1
local CARD_EDGE   = 1
local BEVEL       = 1

------------------------------------------------------------------------------
-- Palette, read at call time
------------------------------------------------------------------------------

-- The four-number table behind a chrome key, or nil on a build without the
-- palette (an offline harness). Read per call so a frame built after a palette
-- edit picks up the new numbers instead of a copy taken at load.
local function colourOf(key)
    local palette = LT.Palette
    if type(palette) ~= "table" then return nil end
    local group = palette.chrome
    if type(group) ~= "table" then return nil end
    local colour = group[key]
    if type(colour) ~= "table" then return nil end
    return colour
end

------------------------------------------------------------------------------
-- Guarded region work
--
-- Every one of these is a type check plus a pcall: a client missing any single
-- method costs the frame its edge, never an error in the middle of a build.
------------------------------------------------------------------------------

local function makeTexture(frame, layer, sublevel)
    if not frame or type(frame.CreateTexture) ~= "function" then return nil end
    local ok, texture = pcall(frame.CreateTexture, frame, nil, layer, sublevel)
    if not ok or not texture then return nil end
    return texture
end

local function paint(texture, colour)
    if not texture or type(colour) ~= "table" then return false end
    if type(texture.SetColorTexture) ~= "function" then return false end

    local r = tonumber(colour[1]) or 0
    local g = tonumber(colour[2]) or 0
    local b = tonumber(colour[3]) or 0
    local a = tonumber(colour[4])
    if a == nil then a = 1 end

    return (pcall(texture.SetColorTexture, texture, r, g, b, a))
end

-- Two points and no size: each point carries both coordinates, so the region is
-- defined entirely by where its two ends are. A SetSize on the frame afterwards
-- moves them with it instead of leaving a line behind.
local function place(texture, first, second)
    if not texture or type(texture.SetPoint) ~= "function" then return false end
    if type(texture.ClearAllPoints) == "function" then
        pcall(texture.ClearAllPoints, texture)
    end

    local okFirst = pcall(texture.SetPoint, texture, first[1], first[2], first[3],
        first[4] or 0, first[5] or 0)
    local okSecond = pcall(texture.SetPoint, texture, second[1], second[2], second[3],
        second[4] or 0, second[5] or 0)

    return okFirst and okSecond
end

local function show(texture)
    if texture and type(texture.Show) == "function" then
        pcall(texture.Show, texture)
    end
end

local function hide(texture)
    if not texture then return end
    if type(texture.Hide) == "function" then pcall(texture.Hide, texture) end
    if type(texture.ClearAllPoints) == "function" then
        pcall(texture.ClearAllPoints, texture)
    end
end

------------------------------------------------------------------------------
-- Geometry
--
-- Four sides, each given by its two ends. `inset` moves the whole side in from
-- the frame's own edge and `width` is that side's thickness; the vertical sides
-- are pushed in by `width` again at both ends so they meet the horizontal ones
-- exactly, which is what keeps the corners clean at any size.
------------------------------------------------------------------------------

-- Returned in the order top, bottom, left, right, so region 1 of a set is
-- always the same side of the frame.
local function outerSides(frame, width)
    return {
        { "TOPLEFT", frame, "TOPLEFT", 0, 0 },
        { "TOPRIGHT", frame, "TOPRIGHT", 0, -width },
    }, {
        { "BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0 },
        { "BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, width },
    }, {
        { "TOPLEFT", frame, "TOPLEFT", 0, -width },
        { "BOTTOMLEFT", frame, "BOTTOMLEFT", width, width },
    }, {
        { "TOPRIGHT", frame, "TOPRIGHT", 0, -width },
        { "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -width, width },
    }
end

local function innerSides(frame, inset, line)
    return {
        { "TOPLEFT", frame, "TOPLEFT", inset, -inset },
        { "TOPRIGHT", frame, "TOPRIGHT", -inset, -inset - line },
    }, {
        { "BOTTOMLEFT", frame, "BOTTOMLEFT", inset, inset },
        { "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset + line },
    }, {
        { "TOPLEFT", frame, "TOPLEFT", inset, -inset - line },
        { "BOTTOMLEFT", frame, "BOTTOMLEFT", inset + line, inset + line },
    }, {
        { "TOPRIGHT", frame, "TOPRIGHT", -inset, -inset - line },
        { "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset - line, inset + line },
    }
end

------------------------------------------------------------------------------
-- Region bookkeeping
--
-- The frame keeps its own regions so a second call repaints what is already
-- there. `edges` is the outer edge, `inner` the near-black line (Windows only),
-- `fill` the background; a set that is not wanted is left in place but hidden,
-- so a frame that changes tier does not leak a texture per change.
------------------------------------------------------------------------------

local function recordFor(frame)
    local existing = frame.ltChrome
    if type(existing) == "table" and type(existing.edges) == "table" then
        return existing
    end

    local created = { edges = {}, inner = {}, bevel = {} }
    frame.ltChrome = created
    return created
end

local function ensureSet(frame, set, layer)
    if type(set) ~= "table" then return nil end

    for index = 1, 4 do
        if not set[index] then
            local texture = makeTexture(frame, layer)
            if not texture then return nil end
            set[index] = texture
        end
    end

    return set
end

local function layoutSet(set, placed)
    if type(set) ~= "table" then return end
    for index = 1, 4 do
        local texture = set[index]
        if texture then
            show(texture)
            local pair = placed[index]
            place(texture, pair[1], pair[2])
        end
    end
end

local function paintSet(set, colour)
    if type(set) ~= "table" then return false end
    local painted = false
    for index = 1, 4 do
        if paint(set[index], colour) then painted = true end
    end
    return painted
end

local function hideSet(set)
    if type(set) ~= "table" then return end
    for index = 1, 4 do hide(set[index]) end
end

-----------------------------------------------------------------------------
-- Bevel
--
-- Four 1 px pixels inside the edge, returned in the same top, bottom, left,
-- right order as outerSides so region 1 of the set is always the top. The
-- caller decides which two of them are lit: raised surfaces are lit on the top
-- and the left, inset ones on the bottom and the right.
-----------------------------------------------------------------------------

local function bevelSides(frame, inset)
    local inner = inset
    local outer = inset + BEVEL

    return {
        { { "TOPLEFT", frame, "TOPLEFT", inner, -inner },
          { "TOPRIGHT", frame, "TOPRIGHT", -inner, -outer } },
        { { "BOTTOMLEFT", frame, "BOTTOMLEFT", inner, inner },
          { "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inner, outer } },
        { { "TOPLEFT", frame, "TOPLEFT", inner, -outer },
          { "BOTTOMLEFT", frame, "BOTTOMLEFT", outer, outer } },
        { { "TOPRIGHT", frame, "TOPRIGHT", -inner, -outer },
          { "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -outer, outer } },
    }
end

local function paintBevel(frame, chrome, inset, raised, litColour, shadeColour)
    local set = chrome and chrome.bevel
    if type(set) ~= "table" then return false end

    if not ensureSet(frame, set, "BORDER") then return false end

    local placed = bevelSides(frame, inset)
    local painted = false

    for index = 1, 4 do
        local texture = set[index]
        if texture then
            show(texture)
            place(texture, placed[index][1], placed[index][2])

            -- The top and the left take the light on a raised surface and the
            -- shadow on an inset one.
            local light = (index == 1 or index == 3)
            if not raised then light = not light end

            if paint(texture, light and litColour or shadeColour) then
                painted = true
            end
        end
    end

    return painted
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

-- A top-level window: the client's 1 px gold rim, a 1 px near-black line inside
-- it, a raised bevel, and a fill. `opts.fill` is a colour table, or false for a
-- frame that already paints its own background; omitted, the palette's window
-- fill is used. `opts.bevel = false` drops the depth, `opts.bevelMode` is
-- "raised" (the default here) or "inset", and `opts.bevelLit`/`opts.bevelShade`
-- override the two pixels for a surface that is not gold.
function Chrome.Window(frame, opts)
    if not frame then return nil end

    local settings = (type(opts) == "table") and opts or {}

    local edgeColour = settings.edge or colourOf("border")
    local innerColour = settings.inner or colourOf("borderDark")

    local fillColour = settings.fill
    if fillColour == nil then fillColour = colourOf("fill") end

    local chrome = recordFor(frame)

    local edges = ensureSet(frame, chrome.edges, "BORDER")
    if not edges then return nil end

    local top, bottom, left, right = outerSides(frame, WINDOW_EDGE)
    layoutSet(edges, { top, bottom, left, right })
    paintSet(edges, edgeColour)

    -- The inner line is the second half of the window look, not the whole of
    -- it: a client that cannot draw it gets the outer edge and no error.
    local inner = ensureSet(frame, chrome.inner, "BORDER")
    if inner then
        local top, bottom, left, right = innerSides(frame, WINDOW_EDGE, INNER_LINE)
        layoutSet(inner, { top, bottom, left, right })
        paintSet(inner, innerColour)
    end

    -- The bevel sits inside the inner line, so the gold rim stays the outermost
    -- thing the eye sees. A window is a raised slab: lit top-left, shaded
    -- bottom-right.
    if settings.bevel ~= false then
        paintBevel(frame, chrome, WINDOW_EDGE + INNER_LINE,
            (settings.bevelMode ~= "inset"),
            settings.bevelLit or colourOf("bevelLit"),
            settings.bevelShade or colourOf("bevelShade"))
    else
        hideSet(chrome.bevel)
    end

    if type(fillColour) == "table" then
        local fill = chrome.fill
        if not fill then
            fill = makeTexture(frame, "BACKGROUND")
            chrome.fill = fill
        end

        if fill then
            if type(fill.SetAllPoints) == "function" then
                pcall(fill.SetAllPoints, fill, frame)
            end
            show(fill)
            paint(fill, fillColour)
        end
    else
        hide(chrome.fill)
    end

    return chrome
end

-- A panel sitting inside a window: one 1 px hairline in the quieter card colour,
-- an inset bevel (swapped to raised by `opts.bevelMode = "raised"`, which is what
-- a button inside a panel is) and, optionally, a light fill. `opts.fill` behaves
-- as in Window; `opts.bevel = false` drops the depth entirely.
function Chrome.Card(frame, opts)
    if not frame then return nil end

    local settings = (type(opts) == "table") and opts or {}

    local edgeColour = settings.edge or colourOf("cardEdge")
    local chrome = recordFor(frame)

    local edges = ensureSet(frame, chrome.edges, "BORDER")
    if not edges then return nil end

    local top, bottom, left, right = outerSides(frame, CARD_EDGE)
    layoutSet(edges, { top, bottom, left, right })
    paintSet(edges, edgeColour)

    -- A card has no inner line: if this frame used to be a window, that line is
    -- retired rather than left behind on top of the card edge.
    hideSet(chrome.inner)

    -- ...and a card is inset unless it is a button: the same two pixels, swapped,
    -- so a panel reads as a hole in the window and a control reads as raised out
    -- of it.
    if settings.bevel ~= false then
        paintBevel(frame, chrome, CARD_EDGE,
            (settings.bevelMode == "raised"),
            settings.bevelLit or colourOf("bevelLit"),
            settings.bevelShade or colourOf("bevelShade"))
    else
        hideSet(chrome.bevel)
    end

    local fillColour = settings.fill
    if fillColour ~= nil then
        if type(fillColour) == "table" then
            local fill = chrome.fill
            if not fill then
                fill = makeTexture(frame, "BACKGROUND")
                chrome.fill = fill
            end

            if fill then
                if type(fill.SetAllPoints) == "function" then
                    pcall(fill.SetAllPoints, fill, frame)
                end
                show(fill)
                paint(fill, fillColour)
            end
        end
    end

    return chrome
end

-- Recolour the outer edge only, for a frame whose tone changes at run time
-- (the toast's upgrade / reminder colour). The inner line and the fill keep the
-- window colours, so a tinted frame is still the same frame.
function Chrome.Tint(frame, colour)
    if not frame then return false end

    local chrome = frame.ltChrome
    if type(chrome) ~= "table" or type(colour) ~= "table" then return false end

    local painted = paintSet(chrome.edges, colour)
    if painted then chrome.edgeColour = colour end
    return painted
end

-- Drop every region this module added. The textures are hidden and unpinned
-- rather than destroyed: the client offers no destroy for a texture, and a
-- hidden region draws nothing and takes no mouse. The record is cleared, so the
-- next Window or Card call builds a fresh set.
function Chrome.Remove(frame)
    if not frame then return false end

    local chrome = frame.ltChrome
    if type(chrome) ~= "table" then return false end

    hideSet(chrome.edges)
    hideSet(chrome.inner)
    hideSet(chrome.bevel)
    hide(chrome.fill)

    frame.ltChrome = nil
    return true
end
