--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — TalentRoutes
    The levelling order, authored as data. Loaded like the other data files
    (see LunchboxToolkit.toc); no frames, no client API, data + pure readers
    only.

    Why a table and not an algorithm: the guide publishes the path, and a
    solver that infers a path from weights will disagree with the guide and be
    impossible to argue with. One row per talent point:
      level    the character level the point is spent at (points start at 10)
      name     the talent name as the client shows it (English)
      points   points this step spends (1: one point per level)
      reason   one line on why this point, in the guide's words
      unlocks  optional note; printed in the step's own line (e.g. the
               level-24 Ancestral Knowledge point exists only to open the
               Stormstrike tier)

    `TalentRoutes:Next` answers "what is the route's next step" from the
    character's current ranks, so a character that deviated gets the earliest
    unfinished step rather than a step it already took.

    The route is advisory. It annotates the scorer's candidates; it never
    changes a score.

    Sources: Tiqqle, "Shaman Leveling Guide (1-60)" (page + video, updated
    2026-11-04), section 1.1 of _docs/leveling-2026-11-04/
    LEVELING-SHAMAN-WORK-ORDER.md. Nothing here has been observed in game.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local TalentRoutes = {}
LT.TalentRoutes = TalentRoutes
LT.Modules = LT.Modules or {}
LT.Modules.TalentRoutes = TalentRoutes

local function normalizeName(name)
    if type(name) ~= "string" then return "" end
    return (name:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

TalentRoutes.NormalizeName = normalizeName

------------------------------------------------------------------------------
-- Authoring helpers
------------------------------------------------------------------------------

local function step(level, name, reason, unlocks)
    return {
        level = level,
        name = name,
        points = 1,
        reason = reason,
        unlocks = unlocks,
    }
end

-- One row per level from `first` to `last`, one point each.
local function steps(first, last, name, reason)
    local out = {}
    for level = first, last do
        out[#out + 1] = step(level, name, reason)
    end
    return out
end

-- Flattens steps(...) arrays and single step(...) rows into one row list, so
-- the route reads top to bottom in level order.
local function rowsFrom(...)
    local parts = { ... }
    local out = {}
    for _, part in ipairs(parts) do
        if type(part) == "table" then
            if #part > 0 then
                for _, row in ipairs(part) do
                    out[#out + 1] = row
                end
            else
                out[#out + 1] = part
            end
        end
    end
    return out
end

------------------------------------------------------------------------------
-- Enhancement 1-60 (the default route)
--
-- 4/36/11 = 51 points, levels 10-60. One target governs the first fifteen
-- levels: every point from 10 to 24 is spent to reach Stormstrike at 25,
-- including a point in Ancestral Knowledge at 24 that is only there to open
-- the tier. Then a deliberate Restoration detour (32-42) buys Water Shield
-- and mana regen before the tree is finished.
------------------------------------------------------------------------------

local ENHANCEMENT = rowsFrom(
    steps(10, 14, "Thundering Strikes",
        "5% crit, the biggest early damage"),
    steps(15, 17, "Mental Dexterity",
        "Intellect becomes attack power, 1 Int = 1.5 AP"),
    steps(18, 19, "Ancestral Knowledge",
        "more Intellect, which feeds Mental Dexterity"),
    step(20, "Shamanistic Focus",
        "cheaper shocks"),
    steps(21, 23, "Elemental Weapons",
        "buffs Rockbiter / Windfury / Flametongue"),
    step(24, "Ancestral Knowledge",
        "one more Intellect point before the tier",
        "opens the Stormstrike tier"),
    step(25, "Stormstrike",
        "the route's first goal - the single most important ability in the build"),
    steps(26, 27, "Improved Ghost Wolf",
        "instant, and usable indoors"),
    steps(28, 29, "Flurry",
        "attack speed, compounds with Windfury"),
    steps(30, 31, "Improved Stormstrike",
        "mana regeneration while casting"),
    steps(32, 36, "Tidal Focus",
        "cheaper heals and +5% hit"),
    steps(37, 39, "Mindfulness",
        "mana regen continues while casting"),
    steps(40, 41, "Totemic Focus",
        "cheaper totems"),
    step(42, "Water Shield",
        "from here mana cost is solved"),
    steps(43, 44, "Mental Quickness",
        "spell damage from Intellect"),
    step(45, "Flurry",
        "filler, opens the tier"),
    steps(46, 50, "Maelstrom Weapon",
        "stacked Lightning Bolt becomes free and instant"),
    step(51, "Rage of the Farseer",
        "the big offensive cooldown (25 s, 3 min)"),
    step(52, "Spirit Weapons",
        "30% less threat if the imbue is not Rockbiter"),
    steps(53, 54, "Flurry",
        "more attack speed"),
    steps(55, 56, "Ancestral Knowledge",
        "more Intellect"),
    steps(57, 60, "Concussion",
        "shock and Lightning Bolt damage")
)

------------------------------------------------------------------------------
-- Water Shield First (the guide's second variant, not the default)
--
-- Same first fifteen levels, then Restoration at 25-35 so Water Shield and
-- mana regen arrive first. The cost is Stormstrike: 36 instead of 25. The
-- guide recommends against this variant; it is shipped so the choice is
-- visible, not so it can be mistaken for the plan.
------------------------------------------------------------------------------

local WATER_SHIELD_FIRST = rowsFrom(
    steps(10, 14, "Thundering Strikes",
        "5% crit, the biggest early damage"),
    steps(15, 17, "Mental Dexterity",
        "Intellect becomes attack power, 1 Int = 1.5 AP"),
    steps(18, 19, "Ancestral Knowledge",
        "more Intellect, which feeds Mental Dexterity"),
    step(20, "Shamanistic Focus",
        "cheaper shocks"),
    steps(21, 23, "Elemental Weapons",
        "buffs Rockbiter / Windfury / Flametongue"),
    step(24, "Ancestral Knowledge",
        "kept for the same reason as the default: it opens the tier",
        "opens the Stormstrike tier"),
    steps(25, 29, "Tidal Focus",
        "cheaper heals and +5% hit"),
    steps(30, 32, "Mindfulness",
        "mana regen continues while casting"),
    steps(33, 34, "Totemic Focus",
        "cheaper totems"),
    step(35, "Water Shield",
        "the point of this variant: mana first"),
    step(36, "Stormstrike",
        "the route's first goal - reached at 36 in this variant"),
    steps(37, 38, "Improved Ghost Wolf",
        "instant, and usable indoors"),
    steps(39, 40, "Flurry",
        "attack speed, compounds with Windfury"),
    steps(41, 42, "Improved Stormstrike",
        "mana regeneration while casting"),
    steps(43, 44, "Mental Quickness",
        "spell damage from Intellect"),
    step(45, "Flurry",
        "filler, opens the tier"),
    steps(46, 50, "Maelstrom Weapon",
        "stacked Lightning Bolt becomes free and instant"),
    step(51, "Rage of the Farseer",
        "the big offensive cooldown (25 s, 3 min)"),
    step(52, "Spirit Weapons",
        "30% less threat if the imbue is not Rockbiter"),
    steps(53, 54, "Flurry",
        "more attack speed"),
    steps(55, 56, "Ancestral Knowledge",
        "more Intellect"),
    steps(57, 60, "Concussion",
        "shock and Lightning Bolt damage")
)

------------------------------------------------------------------------------
-- Route table
------------------------------------------------------------------------------

TalentRoutes.routes = {
    SHAMAN = {
        Enhancement = {
            {
                name = "Enhancement 1-60",
                class = "SHAMAN",
                spec = "Enhancement",
                points = 51,
                firstLevel = 10,
                lastLevel = 60,
                default = true,
                note = "The guide's default Enhancement levelling path: Stormstrike at 25, "
                    .. "then a deliberate Restoration detour for Water Shield and mana regen.",
                rows = ENHANCEMENT,
            },
            {
                name = "Water Shield First",
                class = "SHAMAN",
                spec = "Enhancement",
                points = 51,
                firstLevel = 10,
                lastLevel = 60,
                default = false,
                note = "NON-DEFAULT: the guide's second variant, which it recommends against. "
                    .. "It buys Water Shield and mana regen first, so Stormstrike arrives at "
                    .. "36 instead of 25.",
                rows = WATER_SHIELD_FIRST,
            },
        },
    },
}

-- Class -> spec whose route is the levelling default. Only the spec the guide
-- actually publishes a path for is listed; a class with no entry has no route.
TalentRoutes.defaultSpec = {
    SHAMAN = "Enhancement",
}

------------------------------------------------------------------------------
-- Readers (pure; no client calls)
------------------------------------------------------------------------------

local function findSpec(classRoutes, specName)
    if type(specName) ~= "string" or specName == "" then return nil end
    local key = normalizeName(specName)
    if key == "any" then return nil end
    for spec, routes in pairs(classRoutes) do
        if normalizeName(spec) == key then return routes end
    end
    return nil
end

local function findRoute(routes, routeName)
    if type(routeName) == "number" then
        return routes[routeName]
    end
    if type(routeName) == "string" and routeName ~= "" then
        local key = normalizeName(routeName)
        for _, route in ipairs(routes) do
            if type(route) == "table" and normalizeName(route.name) == key then
                return route
            end
        end
        return nil
    end
    -- No name: the route marked default, else the first one authored.
    for _, route in ipairs(routes) do
        if type(route) == "table" and route.default == true then return route end
    end
    return routes[1]
end

-- TalentRoutes:Get(classToken, specName, routeName) -> rows, route
-- `specName` may be nil or "Any": the class's default spec answers instead.
-- `routeName` may be nil (the default route), a route name, or a 1-based index.
function TalentRoutes:Get(classToken, specName, routeName)
    if type(classToken) ~= "string" or classToken == "" then
        return nil, "no class"
    end
    local class = classToken:upper()
    local classRoutes = self.routes[class]
    if type(classRoutes) ~= "table" then
        return nil, "no talent route for " .. class
    end

    -- "Any" (or no spec) means "use the class's levelling default". A real
    -- spec that has no authored route stays unauthored rather than silently
    -- borrowing another spec's plan.
    local spec = specName
    if type(spec) ~= "string" or spec == "" or normalizeName(spec) == "any" then
        spec = self.defaultSpec[class]
    end

    local routes = findSpec(classRoutes, spec)
    if type(routes) ~= "table" then
        return nil, "no talent route for " .. class .. "/" .. tostring(specName or "Any")
    end

    local route = findRoute(routes, routeName)
    if type(route) ~= "table" or type(route.rows) ~= "table" then
        return nil, "no route named " .. tostring(routeName) .. " for " .. class
    end

    return route.rows, route
end

-- The talent's max rank from the static TalentValues pack (data only). Used
-- solely to print "1/5" honestly; nil when the talent is not in the pack.
function TalentRoutes:MaxRank(classToken, talentName)
    local tv = LT.TalentValues
    if type(tv) ~= "table" or type(tv.classes) ~= "table" then return nil end
    local class = type(classToken) == "string" and classToken:upper() or nil
    local classData = class and tv.classes[class]
    if type(classData) ~= "table" or type(classData.trees) ~= "table" then return nil end

    local key = normalizeName(talentName)
    for _, tree in ipairs(classData.trees) do
        if type(tree) == "table" and type(tree.talents) == "table" then
            for _, talent in ipairs(tree.talents) do
                if type(talent) == "table" and normalizeName(talent.name) == key then
                    local maxRank = tonumber(talent.max)
                    if maxRank and maxRank > 0 then return maxRank end
                end
            end
        end
    end
    return nil
end

-- TalentRoutes:Next(classToken, specName, level, ranksByName) -> row, index
-- `ranksByName` is the client's current rank per talent name (any casing).
-- The first route row whose cumulative point target is not yet met is the next
-- step. `level` is accepted for the caller's bookkeeping and is not used to
-- skip steps: a character that deviated gets the earliest unfinished point.
function TalentRoutes:Next(classToken, specName, level, ranksByName)
    local rows = self:Get(classToken, specName)
    if type(rows) ~= "table" then return nil, nil end

    local ranks = {}
    if type(ranksByName) == "table" then
        for name, value in pairs(ranksByName) do
            local key = normalizeName(name)
            local n = tonumber(value)
            if key ~= "" and n then
                ranks[key] = math.max(ranks[key] or 0, n)
            end
        end
    end

    local targets = {}
    for index, row in ipairs(rows) do
        if type(row) == "table" then
            local key = normalizeName(row.name)
            local target = (targets[key] or 0) + (tonumber(row.points) or 1)
            targets[key] = target
            if (ranks[key] or 0) < target then
                return row, index
            end
        end
    end

    return nil, nil
end

-- One line for a step, e.g.
--   "level 24: Ancestral Knowledge 1/5 - opens the Stormstrike tier"
-- The rank fraction is the points this step spends over the talent's max rank;
-- a single-rank talent prints no fraction.
function TalentRoutes:FormatStep(row, classToken)
    if type(row) ~= "table" then return "" end

    local label = "level " .. tostring(row.level) .. ": " .. tostring(row.name or "?")
    local points = tonumber(row.points) or 1
    local maxRank = self:MaxRank(classToken, row.name)
    if maxRank and maxRank > 1 then
        label = label .. " " .. tostring(points) .. "/" .. tostring(maxRank)
    end

    local detail = row.unlocks
    if detail and row.reason then
        detail = detail .. " - " .. row.reason
    end
    detail = detail or row.reason
    if detail then label = label .. " - " .. detail end

    return label
end
