--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Palette
    One owner for every colour the add-on draws or prints.

    Why this file exists:

      * before it, a colour literal lived in every file that painted something,
        so the same warm yellow meant "not yet usable" in the tooltip panel and
        "not comparable" in the score line, and two different oranges could
        appear in one tooltip;
      * an entry here is a MEANING, not a hue. The key is what the colour says
        ("go", "caution", "money"); the numbers are only how it says it.
        Re-hueing a meaning is a one-line change in this table;
      * the legend window, /lt colours and the self test all read `legend` below,
        so what the add-on shows and what it explains cannot drift apart.

    What this file does not own: the client's own colours (item quality, the
    money frame). Purple and blue are used here on purpose, because "purple beats
    blue beats green" is the quality ladder a player already reads — not because a
    border claims to be an epic item, and the legend window says so in words.

    Every entry is { r, g, b, a } in 0..1 — the shape the quest-reward outlines
    already used — plus, derived once at load, a bare hex string ("bf7aff") for
    the callers that build |cff codes and a named { r, g, b } table for the UI
    label builder.
--------------------------------------------------------------------------]]
local LT = LunchboxToolkit

local Palette = {}
LT.Palette = Palette
LT.Modules.Palette = Palette

-- Verdicts: what the add-on concludes about something. These are the colours
-- the legend explains. The order is the client's own quality ladder, best first —
-- purple, blue, green — because that is the order a player already reads, then
-- grey for "no", red for "no answer", and gold (always with the coin) for money.
local verdict = {
    -- "Best" — purple. Usable at this level and the strongest answer this build
    -- gives: the biggest upgrade, a cap that is met, a check that passed.
    go      = { 0.75, 0.48, 1.00, 1.00 },

    -- "Second best" — blue. A rank, never a warning: the second best quest
    -- reward today, and the talent-page equivalent when it lands.
    good    = { 0.25, 0.62, 1.00, 1.00 },

    -- "Act on it, but not yet" — green. The condition is unmet: not usable at
    -- this level, provisional data, a cap still short, an estimate.
    caution = { 0.20, 1.00, 0.20, 1.00 },

    -- "No" — grey. The class can never use it, or it is a downgrade, or a check
    -- failed. Grey rather than red, because red is kept for "no answer at all".
    stop    = { 0.70, 0.70, 0.70, 1.00 },

    -- "No answer" — red. Incomplete or incomparable data, an item that could not
    -- be read: the add-on cannot rank this and says so in red, so a gap in the
    -- data is visible instead of hidden in dead text.
    unknown = { 1.00, 0.33, 0.33, 1.00 },

    -- "Money" — the vendor colour. Gold is the client's own currency colour and is
    -- always carried with a coin glyph at the reward window, so it is never
    -- mistaken for a verdict. Since the 2026-10-27 ruling the coin is the money
    -- channel and rides on a purple or blue border too; gold is used for the
    -- border only when the most profitable reward has no verdict border of its own.
    money   = { 1.00, 0.82, 0.10, 1.00 },
}

-- Declared but drawn nowhere yet: yellow, the one hue of the client's quality
-- ladder the verdicts above leave unused, and kept pale so it cannot be taken for
-- the gold of the money border. The legend explains it anyway, with a "not drawn
-- anywhere yet" line, so the palette is complete in the window and the self test
-- can insist every colour has a row.
local reserved = {
    special = { 1.00, 0.96, 0.45, 1.00 },
}

-- Chrome: everything that is not a verdict. Headings, secondary text, panel
-- backgrounds and the build-name tints. The legend does not explain these; they
-- carry no meaning about the item in front of the player.
-- Every entry in this group is OPAQUE: alpha 1.00, no exception. The set this
-- replaces shipped 0.92-0.96 alphas, so the game world showed through the
-- window, the tooltip and the buttons, and the player said so plainly. A
-- translucent background is not a style choice here, it is the defect the
-- rework exists to remove, and the contest's G1 gate fails a build that keeps
-- it.
--
-- Hues: since the 2026-10-31 client-skin brief (round 2) they are the CLIENT's
-- own family, not this add-on's invention - brown-black slabs, an aged-gold rim
-- and parchment text - so the window reads as part of the game it sits in
-- instead of drawn alongside it. The one cold colour left is `accent`, the
-- "you are here" mark, which the same brief lets each contest arm keep so the
-- two arms stay tellable apart at a glance. Verdict colours above are untouched:
-- re-hueing one would break the legend and the ladder the player reads.
local chrome = {
    brand     = { 0.93, 0.80, 0.52, 1.00 },   -- headings, chat prefix, "?" markers
    muted     = { 0.60, 0.55, 0.46, 1.00 },   -- secondary text, de-emphasis
    text      = { 0.94, 0.90, 0.81, 1.00 },   -- body text, parchment off-white
    panelBg   = { 0.14, 0.11, 0.08, 1.00 },   -- tooltip panel background
    windowBg  = { 0.09, 0.07, 0.05, 1.00 },   -- main window background
    buttonBg  = { 0.17, 0.14, 0.10, 1.00 },   -- every button face
    buttonHot = { 0.26, 0.21, 0.14, 1.00 },   -- the same face under the cursor
    warningBg = { 0.15, 0.07, 0.04, 1.00 },   -- the buff / imbue reminder bar
    buildOne  = { 0.20, 0.80, 1.00, 1.00 },   -- build 1 name in a tooltip line
    buildTwo  = { 1.00, 0.60, 1.00, 1.00 },   -- build 2 name in a tooltip line
    debug     = { 0.53, 0.67, 1.00, 1.00 },   -- the "Lunchbox Toolkit (debug):" prefix

    -- The window chrome (Chrome.lua). None of these asserts anything about an
    -- item, so none is a verdict and the legend does not explain them: they are
    -- the frame the content sits in, the same on every window. The rim is the
    -- client's aged gold and the line inside it its near-black; the two bevel
    -- pixels give the slab thickness - lit along the top and the left of a
    -- raised surface, shaded along the top and the left of an inset one.
    border     = { 0.76, 0.62, 0.36, 1.00 },  -- the 1 px gold rule every window draws
    borderDark = { 0.03, 0.02, 0.01, 1.00 },  -- the line just inside it, so a popup reads as a slab
    cardEdge   = { 0.42, 0.34, 0.21, 1.00 },  -- the quieter bronze hairline on a panel inside a window
    fill       = { 0.07, 0.05, 0.04, 1.00 },  -- the default window fill behind its content
    bevelLit   = { 0.99, 0.88, 0.62, 1.00 },  -- the bevel's light pixel
    bevelShade = { 0.00, 0.00, 0.00, 1.00 },  -- the bevel's shadow pixel

    -- The shell's own four. These are what make this window recognisable: a rail
    -- down the left, bands above and below the content, and one accent line on
    -- the page you are looking at. The accent appears nowhere else, so a teal
    -- mark on screen always means "this is where you are".
    railBg     = { 0.06, 0.05, 0.03, 1.00 },  -- the rail column, one step below the slab
    headerBg   = { 0.13, 0.10, 0.07, 1.00 },  -- the title band and the footer strip
    accent     = { 0.27, 0.83, 0.77, 1.00 },  -- the marker on the page you are on
    accentDim  = { 0.16, 0.47, 0.44, 1.00 },  -- the same marker, for a hovered row
}


-- The one list the window, /lt colours and the self test read. `meaning` says
-- what the colour asserts, `where` says where it appears, `example` is the kind
-- of line the player will see in that colour.
Palette.legend = {
    {
        key = "go",
        name = "Purple",
        meaning = "Yes. Usable at this level, the biggest upgrade, a cap that is met, "
            .. "a check that passed.",
        where = "Tooltip box and score word, the best quest reward usable now, cap status, test results.",
        example = "Upgrade: +4.5",
    },
    {
        key = "good",
        name = "Blue",
        meaning = "Good, but not the best. A rank, never a warning.",
        where = "The second best quest reward usable now, when ranking rewards is turned on.",
        example = "Second biggest upgrade",
    },
    {
        key = "caution",
        name = "Green",
        meaning = "An answer you can act on, with a condition: not usable yet at this "
            .. "level, provisional data, a cap still short, an estimate.",
        where = "Tooltip box and the \"Not yet\" line, a quest reward usable later, "
            .. "provisional labels, cap status.",
        example = "Not yet — requires level 40",
    },
    {
        key = "stop",
        name = "Grey",
        meaning = "No. This class can never use the item, or it is a downgrade.",
        where = "Tooltip box and \"Unusable\", a downgrade score word, a failed check.",
        example = "Unusable",
    },
    {
        key = "unknown",
        name = "Red",
        meaning = "No answer yet: the data is incomplete, or two items cannot be "
            .. "ranked against each other.",
        where = "Score words such as \"not comparable\", and the reason beside them.",
        example = "incomparable — no weapon equipped",
    },
    {
        key = "special",
        name = "Yellow",
        meaning = "Worth your own look: a strong effect no weight scores, a talent point "
            .. "that opens a tier, a set completion.",
        where = "A weapon type you can train now (the proficiency table), a talent "
            .. "border once T-22 lands, and a set completion.",
        example = "a tier-opening talent, once T-22 lands",
    },
    {
        key = "money",
        name = "Gold + coin",
        meaning = "Money, not a verdict. The reward worth the most to a vendor — the "
            .. "coin is drawn on whatever border that reward already has.",
        where = "The coin glyph in the corner of its icon; the gold border only when "
            .. "that reward has no purple, blue or green border of its own.",
        example = "3g 20s to a vendor",
    },
}

-- The coin glyph that marks the money border. Only the vendor outline carries
-- it, so gold can never be read as a judgement on the item.
Palette.coinTexture = "Interface\\Icons\\INV_Misc_Coin_01"

Palette.verdict = verdict
Palette.chrome = chrome
Palette.reserved = reserved

-- Derived tables, built once. `hex` is the bare six digits a |cff code needs,
-- `code` is the |cff prefix on its own, and `named` is the { r, g, b } shape the
-- UI label builder takes.
local function hexOf(colour)
    local function part(value)
        local byte = math.floor((tonumber(value) or 0) * 255 + 0.5)
        if byte < 0 then byte = 0 end
        if byte > 255 then byte = 255 end
        return string.format("%02x", byte)
    end

    return part(colour[1]) .. part(colour[2]) .. part(colour[3])
end

Palette.hex = {}
Palette.code = {}
Palette.named = {}

local function indexColours(group)
    for key, colour in pairs(group) do
        local hex = hexOf(colour)
        Palette.hex[key] = hex
        Palette.code[key] = "|cff" .. hex
        Palette.named[key] = { r = colour[1], g = colour[2], b = colour[3] }
    end
end

indexColours(verdict)
indexColours(reserved)
indexColours(chrome)

-- The four-number table for a key, or nil when the key is unknown. Callers use
-- this when they need the table itself: the outlines compare identity, which is
-- what the self test checks for drift.
function Palette:Colour(key)
    return verdict[key] or reserved[key] or chrome[key]
end

function Palette:Hex(key)
    return Palette.hex[key] or Palette.hex.text
end

function Palette:Code(key)
    return Palette.code[key] or Palette.code.text
end

function Palette:RGB(key)
    return Palette.named[key] or Palette.named.text
end

-- Wraps text in a colour, always in the eight-digit |cffRRGGBB form. Anything
-- shorter would slip past the note-stripping pattern in Tooltip.lua and leave
-- raw codes on screen.
function Palette:Wrap(key, text)
    return self:Code(key) .. tostring(text) .. "|r"
end

-- The legend as chat lines, in the same words the window shows. /lt colours
-- prints this, so a player who cannot separate the hues still reads the
-- meanings.
function Palette:Describe()
    local lines = { "What the colours mean — the same palette everywhere:" }

    for _, row in ipairs(self.legend) do
        table.insert(lines, "  " .. self:Wrap(row.key, row.name) .. " — " .. row.meaning)
        table.insert(lines, "      " .. self:Wrap("muted", row.where)
            .. "  e.g. " .. self:Wrap(row.key, row.example))
    end

    table.insert(lines, "  " .. self:Wrap("muted",
        "An equal score (\"Even\") is dimmed text, not a verdict."))
    table.insert(lines, "The Colours button in the window header opens the same list.")

    return lines
end
