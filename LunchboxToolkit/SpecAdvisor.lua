--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — SpecAdvisor

    /lbs spec advisor. Reads the player's active talent build and prints the
    talents that can take the next point, one per line, plus a summary. Text
    output only: this revision does not touch the talent frame.

    API, in order of preference:
      1. Classic talent API  GetNumTalentTabs / GetTalentTabInfo /
         GetNumTalents / GetTalentInfo. A talent in row R may take its next
         point once (R-1)*5 points are spent in the same tab.
      2. C_Traits            config -> tree -> nodes -> node info, using the
         client's own canPurchaseRank / isAvailable flag as the tier gate.

    Every client call sits behind a pcall and every value is secret-guarded;
    a missing API is a normal result, never an error.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local SpecAdvisor = {}
LT.SpecAdvisor = SpecAdvisor
LT.Modules = LT.Modules or {}
LT.Modules.SpecAdvisor = SpecAdvisor

------------------------------------------------------------------------------
-- Guarded helpers
------------------------------------------------------------------------------

local function isSecret(value)
    if type(LT.IsSecret) == "function" then
        return LT:IsSecret(value) == true
    end
    local checker = rawget(_G, "issecretvalue")
    if type(checker) ~= "function" then return false end
    local ok, result = pcall(checker, value)
    return ok and result == true
end

local function safeNumber(value)
    if isSecret(value) then return nil end
    return tonumber(value)
end

local function safeString(value)
    if type(value) ~= "string" or value == "" then return nil end
    if isSecret(value) then return nil end
    return value
end

local function safeField(container, key)
    if container == nil or isSecret(container) then return nil end
    local ok, value = pcall(function() return container[key] end)
    if not ok or isSecret(value) then return nil end
    return value
end

------------------------------------------------------------------------------
-- Classic talent API
--
-- Return order (Classic Era): GetTalentTabInfo -> name, icon, pointsSpent,
-- description; GetTalentInfo -> name, icon, row, column, rank, maxRank.
------------------------------------------------------------------------------

local function readClassic()
    if type(GetNumTalentTabs) ~= "function" then
        return nil, "GetNumTalentTabs is absent"
    end

    local ok, tabCount = pcall(GetNumTalentTabs)
    if not ok then return nil, "GetNumTalentTabs failed" end
    tabCount = safeNumber(tabCount)
    if not tabCount or tabCount <= 0 then
        return nil, "no talent tabs"
    end

    local trees = {}

    for tab = 1, math.min(tabCount, 10) do
        local treeName = "tab " .. tostring(tab)
        local pointsSpent = 0

        if type(GetTalentTabInfo) == "function" then
            local tabOk, name, _, spent = pcall(GetTalentTabInfo, tab)
            if tabOk then
                local cleanName = safeString(name)
                if cleanName then treeName = cleanName end
                pointsSpent = safeNumber(spent) or 0
            end
        end

        local talents = {}

        if type(GetNumTalents) == "function" and type(GetTalentInfo) == "function" then
            local countOk, count = pcall(GetNumTalents, tab)
            if countOk then
                count = safeNumber(count)
                if count then
                    for index = 1, math.min(count, 60) do
                        local infoOk, name, _, row, _, rank, maxRank =
                            pcall(GetTalentInfo, tab, index)
                        if not infoOk then break end

                        local cleanName = safeString(name)
                        if cleanName then
                            talents[#talents + 1] = {
                                name = cleanName,
                                rank = safeNumber(rank) or 0,
                                maxRank = safeNumber(maxRank) or 0,
                                row = safeNumber(row) or 1,
                            }
                        end
                    end
                end
            end
        end

        trees[#trees + 1] = {
            name = treeName,
            pointsSpent = pointsSpent,
            talents = talents,
        }
    end

    if #trees == 0 then return nil, "classic talent tree empty" end
    return trees, "classic"
end

------------------------------------------------------------------------------
-- C_Traits (Forever trait stack)
--
-- Flow (from TalentsForeverBook): configID -> GetConfigInfo -> treeIDs ->
-- GetTreeNodes -> GetNodeInfo. GetNodeInfo carries the name and the client's
-- own "can this node take a rank now" flag.
------------------------------------------------------------------------------

local function readNodeRank(node)
    local value = safeField(node, "activeRank")
        or safeField(node, "ranksPurchased")
        or safeField(node, "currentRank")
    return safeNumber(value) or 0
end

local function readNodeMaxRank(node)
    local value = safeField(node, "maxRanks")
        or safeField(node, "maxRank")
        or safeField(node, "max")
    local n = safeNumber(value)
    if n and n > 0 then return n end
    return math.max(readNodeRank(node), 1)
end

local function readNodeReady(node)
    local canBuy = safeField(node, "canPurchaseRank")
    if type(canBuy) == "boolean" then return canBuy end

    local available = safeField(node, "isAvailable")
    if type(available) == "boolean" then return available end

    -- The client gave no flag; rank < max is all we can verify.
    return true
end

-- A node has no name field: the client names it through its active entry's
-- definition spell. Every step below was read off the client in the talents-ui
-- probe on 2026-11-05, and the fallback to "Talent <id>" is the old behaviour.
local function traitNodeName(cfg, node)
    if type(node) ~= "table" or type(C_Traits) ~= "table" then return nil end

    local active = safeField(node, "activeEntry")
    local entryID
    if type(active) == "table" then
        entryID = safeNumber(safeField(active, "ID")) or safeNumber(safeField(active, "entryID"))
    else
        entryID = safeNumber(active)
    end

    if not entryID then
        local ids = safeField(node, "entryIDs")
        if type(ids) == "table" and ids[1] ~= nil then
            local first = ids[1]
            if type(first) == "table" then
                entryID = safeNumber(safeField(first, "ID")) or safeNumber(safeField(first, "entryID"))
            else
                entryID = safeNumber(first)
            end
        end
    end

    if not entryID or type(C_Traits.GetEntryInfo) ~= "function" then return nil end

    local okEntry, entry = pcall(C_Traits.GetEntryInfo, cfg, entryID)
    if not okEntry or type(entry) ~= "table" then return nil end

    local definitionID = safeNumber(safeField(entry, "definitionID"))
    if not definitionID or type(C_Traits.GetDefinitionInfo) ~= "function" then return nil end

    local okDef, def = pcall(C_Traits.GetDefinitionInfo, definitionID)
    if not okDef or type(def) ~= "table" then return nil end

    local name = safeString(safeField(def, "overrideName"))
    if name then return name end

    local spellID = safeNumber(safeField(def, "spellID"))
    if not spellID then return nil end

    if type(C_Spell) == "table" then
        if type(C_Spell.GetSpellName) == "function" then
            local ok, spelled = pcall(C_Spell.GetSpellName, spellID)
            if ok and type(spelled) == "string" then return spelled end
        end
        if type(C_Spell.GetSpellInfo) == "function" then
            local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
            if ok and type(info) == "table" and type(info.name) == "string" then return info.name end
        end
    end

    return nil
end

local function collectTreeIDs(info)
    local ids, seen = {}, {}

    local function add(id)
        local n = safeNumber(id)
        if n and not seen[n] then
            seen[n] = true
            ids[#ids + 1] = n
        end
    end

    -- Working Forever addons read treeIDs as a plain array.
    local treeIDs = safeField(info, "treeIDs")
    if type(treeIDs) == "table" then
        for _, id in ipairs(treeIDs) do add(id) end
    end

    -- Documented alternate shape: trees = { { ID = ... }, ... }.
    if #ids == 0 then
        local trees = safeField(info, "trees")
        if type(trees) == "table" then
            for _, tree in ipairs(trees) do
                if type(tree) == "table" then
                    add(safeField(tree, "ID"))
                end
            end
        end
    end

    return ids
end

local function readTraits()
    local C_Traits = rawget(_G, "C_Traits")
    local C_ClassTalents = rawget(_G, "C_ClassTalents")

    if type(C_Traits) ~= "table" then return nil, "C_Traits is absent" end

    local cfg

    if type(C_ClassTalents) == "table"
        and type(C_ClassTalents.GetActiveConfigID) == "function" then
        local ok, id = pcall(C_ClassTalents.GetActiveConfigID)
        if ok then cfg = safeNumber(id) end
    end

    if not cfg and type(C_Traits.GetConfigIDBySystemID) == "function" then
        for sys = 1, 40 do
            local ok, id = pcall(C_Traits.GetConfigIDBySystemID, sys)
            if ok then
                local n = safeNumber(id)
                if n then cfg = n break end
            end
        end
    end

    if not cfg then return nil, "no trait config id" end

    local info
    if type(C_Traits.GetConfigInfo) == "function" then
        local ok, result = pcall(C_Traits.GetConfigInfo, cfg)
        if ok then info = result end
    end
    if type(info) ~= "table" then return nil, "GetConfigInfo returned nothing" end

    local treeIDs = collectTreeIDs(info)
    if #treeIDs == 0 then return nil, "no trait trees in config" end

    local trees = {}

    for ti, treeID in ipairs(treeIDs) do
        local treeName = "tree " .. tostring(ti)

        if type(C_Traits.GetTreeInfo) == "function" then
            local ok, treeInfo = pcall(C_Traits.GetTreeInfo, cfg, treeID)
            if ok and type(treeInfo) == "table" then
                local cleanName = safeString(safeField(treeInfo, "name"))
                if cleanName then treeName = cleanName end
            end
        end

        local talents = {}

        if type(C_Traits.GetTreeNodes) == "function" then
            local ok, nodes = pcall(C_Traits.GetTreeNodes, treeID)
            if ok and type(nodes) == "table" and type(C_Traits.GetNodeInfo) == "function" then
                for _, nodeID in ipairs(nodes) do
                    local nid = safeNumber(nodeID)
                    if nid then
                        local nodeOk, node = pcall(C_Traits.GetNodeInfo, cfg, nid)
                        if nodeOk and type(node) == "table" then
                            local cleanName = traitNodeName(cfg, node)
                            if not cleanName then
                                cleanName = safeString(safeField(node, "name"))
                            end
                            if not cleanName then
                                cleanName = "Talent " .. tostring(nid)
                            end

                            talents[#talents + 1] = {
                                name = cleanName,
                                rank = readNodeRank(node),
                                maxRank = readNodeMaxRank(node),
                                ready = readNodeReady(node),
                            }
                        end
                    end
                end
            end
        end

        trees[#trees + 1] = { name = treeName, talents = talents }
    end

    if #trees == 0 then return nil, "trait tree empty" end
    return trees, "C_Traits"
end

------------------------------------------------------------------------------
-- Pure candidate computation
--
-- Given a list of trees, return the talents that can take the next point.
--   classic record : { name, rank, maxRank, row }        + tree.pointsSpent
--   C_Traits record: { name, rank, maxRank, ready }      (ready is a boolean)
------------------------------------------------------------------------------

local function nextPoints(trees)
    local out = {}
    if type(trees) ~= "table" then return out end

    for ti, tree in ipairs(trees) do
        if type(tree) == "table" then
            local pointsSpent = safeNumber(tree.pointsSpent) or 0

            for _, talent in ipairs(tree.talents or {}) do
                if type(talent) == "table" then
                    local rank = safeNumber(talent.rank) or 0
                    local maxRank = safeNumber(talent.maxRank) or 0

                    if maxRank > 0 and rank < maxRank then
                        local open = true

                        if talent.row ~= nil then
                            local row = safeNumber(talent.row) or 1
                            if row < 1 then row = 1 end
                            open = pointsSpent >= (row - 1) * 5
                        elseif talent.ready ~= nil then
                            open = talent.ready == true
                        end

                        if open then
                            out[#out + 1] = {
                                treeIndex = ti,
                                treeName = tree.name or ("tree " .. tostring(ti)),
                                name = talent.name or "?",
                                rank = rank,
                                maxRank = maxRank,
                            }
                        end
                    end
                end
            end
        end
    end

    return out
end

SpecAdvisor.NextPoints = nextPoints

------------------------------------------------------------------------------
-- Read
------------------------------------------------------------------------------

function SpecAdvisor:Read()
    local trees, source = readClassic()
    if trees then return trees, source end
    local classicReason = source

    trees, source = readTraits()
    if trees then return trees, source end

    return nil, "classic (" .. tostring(classicReason)
        .. "), C_Traits (" .. tostring(source) .. ")"
end

------------------------------------------------------------------------------
-- Report
------------------------------------------------------------------------------

function SpecAdvisor:Report(buildIndex)
    buildIndex = buildIndex or 1
    local trees, source, reason = self:Read()
    if not trees then
        LT:Print("Spec advisor could not read talents: " .. tostring(reason) .. ".")
        return {}
    end

    local candidates = nextPoints(trees)

    if #candidates == 0 then
        LT:Print("Spec advisor: no talent can take the next point right now "
            .. "(no points spent, tree empty, or every available talent is maxed).")
        return candidates
    end

    -- Ranked recommendation when the valuation layer is present and can score at
    -- least one candidate. Otherwise fall through to the plain list below.
    local ranked = nil
    local valuation = LT.TalentValuation
    if type(valuation) == "table" and type(valuation.Rank) == "function" then
        local ok, result = pcall(valuation.Rank, valuation, trees, nil, buildIndex)
        if ok and type(result) == "table" and #result > 0 then
            ranked = result
        end
    end

    if ranked then
        for _, entry in ipairs(ranked) do
            local line = "Take: " .. entry.name .. " (+" .. entry.scoreText .. ")"
            if entry.suffix and entry.suffix ~= "" then
                line = line .. entry.suffix
            end
            LT:Print(line)
        end
        LT:Print(string.format("Spec advisor: %d talent(s) ranked (via %s API).",
            #ranked, tostring(source)))
        return ranked
    end

    -- Plain fallback: the un-ranked list kept for when scoring is unavailable.
    for _, candidate in ipairs(candidates) do
        LT:Print("Next point: " .. candidate.name .. " (tab " .. candidate.treeName .. ")")
    end

    LT:Print(string.format("Spec advisor: %d talent(s) can take the next point (via %s API).",
        #candidates, tostring(source)))

    return candidates
end

------------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------------

local function profileNameFor(buildIndex)
    if LT.Profiles and type(LT.Profiles.ResolveSlot) == "function" then
        local ok, slot = pcall(LT.Profiles.ResolveSlot, LT.Profiles, buildIndex)
        if ok and type(slot) == "table" and slot.name then return slot.name end
    end
    return nil
end

local function reportBuild(buildIndex, label)
    local name = profileNameFor(buildIndex) or "(no profile)"
    LT:Print(label .. ": " .. name)

    -- Dump the weights first so the capture shows which profile drove the
    -- ranking (for comparing e.g. "WF 2H PVP" vs "Enhancement 2H").
    local valuation = LT.TalentValuation
    if type(valuation) == "table" and type(valuation.DumpWeights) == "function" then
        pcall(valuation.DumpWeights, valuation, nil, buildIndex)
    end

    local ok, err = pcall(SpecAdvisor.Report, SpecAdvisor, buildIndex)
    if not ok and type(err) == "string" then
        LT:Error("Spec advisor failed (" .. label .. "): " .. tostring(err))
    end
end

local function runReport()
    -- Export both builds, named, so the two profiles can be compared side by
    -- side. Slot 1 = Primary build, slot 2 = Offspec.
    reportBuild(1, "Primary build")
    reportBuild(2, "Offspec")
end

------------------------------------------------------------------------------
-- Route view (/lbs next, /lbs route)
--
-- The route is the authored levelling order in TalentRoutes. These commands
-- print it beside the greedy scorer: where the two disagree, both are shown
-- and the route is named as the plan. Nothing here changes a score.
------------------------------------------------------------------------------

local function normalizeName(name)
    if type(name) ~= "string" then return "" end
    return (name:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The class and the spec the build slot names. A slot left on "Any" resolves
-- to the class's default route spec inside TalentRoutes:Get.
local function routeContext(buildIndex)
    local classToken = (LT.player and LT.player.class) or "UNKNOWN"
    local spec
    if LT.Builds and type(LT.Builds.Get) == "function" then
        local ok, build = pcall(LT.Builds.Get, LT.Builds, buildIndex)
        if ok and type(build) == "table" then spec = build.spec end
    end
    return classToken, spec
end

local function readTrees()
    local ok, trees = pcall(SpecAdvisor.Read, SpecAdvisor)
    if ok and type(trees) == "table" then return trees end
    return nil
end

local function ranksFromTrees(trees)
    local ranks = {}
    if type(trees) ~= "table" then return ranks end
    for _, tree in ipairs(trees) do
        if type(tree) == "table" and type(tree.talents) == "table" then
            for _, talent in ipairs(tree.talents) do
                if type(talent) == "table" and type(talent.name) == "string" then
                    ranks[talent.name] = safeNumber(talent.rank) or 0
                end
            end
        end
    end
    return ranks
end

local function rankedFromTrees(trees, buildIndex)
    if type(trees) ~= "table" then return nil end
    local valuation = LT.TalentValuation
    if type(valuation) ~= "table" or type(valuation.Rank) ~= "function" then return nil end
    local ok, result = pcall(valuation.Rank, valuation, trees, nil, buildIndex)
    if ok and type(result) == "table" and #result > 0 then return result end
    return nil
end

local function compareWithRoute(ranked, routeStep)
    if type(routeStep) ~= "table" then return end
    local top = ranked and ranked[1]
    if type(top) ~= "table" then
        LT:Print("The scorer had no candidate to compare; the route's next step is "
            .. tostring(routeStep.name) .. ".")
        return
    end
    if normalizeName(top.name) == normalizeName(routeStep.name) then
        LT:Print("The scorer agrees with the route: " .. tostring(top.name)
            .. " (+" .. tostring(top.scoreText) .. ").")
    else
        LT:Print("The scorer would take " .. tostring(top.name)
            .. " (+" .. tostring(top.scoreText) .. "); the route says "
            .. tostring(routeStep.name) .. " - the route is the plan.")
    end
end

-- Next step from the client's ranks. When the talents cannot be read at all,
-- the route row for the character's level is shown rather than guessing from
-- an empty rank map.
local function nextRouteStep(routes, classToken, spec, rows, level, trees)
    if type(trees) == "table" then
        return routes:Next(classToken, spec, level, ranksFromTrees(trees))
    end
    for index, row in ipairs(rows) do
        if type(row) == "table" and (tonumber(row.level) or 0) >= level then
            return row, index
        end
    end
    return nil, nil
end

local function routeHeader(classToken, route)
    local line = "Route: " .. tostring(route.name)
        .. " (" .. tostring(classToken) .. " / " .. tostring(route.spec or "?") .. ")"
    if route.default ~= true then
        line = line .. " - NON-DEFAULT variant"
    end
    LT:Print(line)
end

-- The unit's level, not the cached one: the cache lags, and /lbs answered
-- "starts at level 10" to a level-10 character (report 2026-11-05).
local function currentLevel()
    if type(UnitLevel) == "function" then
        local ok, unit = pcall(UnitLevel, "player")
        if ok and safeNumber(unit) then return safeNumber(unit) end
    end
    return (LT.player and safeNumber(LT.player.level)) or 1
end

local function runNext(buildIndex)
    local routes = LT.TalentRoutes
    if type(routes) ~= "table" or type(routes.Next) ~= "function" then
        LT:Print("/lbs next: talent routes are not loaded.")
        return
    end

    local classToken, spec = routeContext(buildIndex)
    local rows, route = routes:Get(classToken, spec)
    if type(rows) ~= "table" then
        LT:Print("/lbs next: " .. tostring(route) .. " yet.")
        return
    end

    routeHeader(classToken, route)
    if route.note then
        LT:Print("Note: " .. route.note)
    end

    local level = currentLevel()
    if level < 10 then
        LT:Print("No talent point before level 10; the route starts at level 10.")
        return
    end

    local trees = readTrees()
    local row, index = nextRouteStep(routes, classToken, spec, rows, level, trees)
    if type(trees) ~= "table" then
        LT:Print("Talents could not be read; showing the route by level.")
    end

    if type(row) ~= "table" then
        LT:Print("The route has no unfinished step for this character.")
        return
    end

    LT:Print("Next: " .. routes:FormatStep(row, classToken)
        .. " (step " .. tostring(index) .. " of " .. tostring(#rows) .. ")")
    compareWithRoute(rankedFromTrees(trees, buildIndex), row)
end

local function runRoute(buildIndex)
    local routes = LT.TalentRoutes
    if type(routes) ~= "table" or type(routes.Next) ~= "function" then
        LT:Print("/lbs route: talent routes are not loaded.")
        return
    end

    local classToken, spec = routeContext(buildIndex)
    local rows, route = routes:Get(classToken, spec)
    if type(rows) ~= "table" then
        LT:Print("/lbs route: " .. tostring(route) .. " yet.")
        return
    end

    routeHeader(classToken, route)
    if route.note then
        LT:Print("Note: " .. route.note)
    end

    local level = currentLevel()
    if level < 10 then level = 10 end

    local trees = readTrees()
    local nextRow = nextRouteStep(routes, classToken, spec, rows, level, trees)

    local shown = 0
    for _, row in ipairs(rows) do
        if type(row) == "table" and (tonumber(row.level) or 0) >= level then
            local marker = (row == nextRow) and "* " or "  "
            LT:Print(marker .. routes:FormatStep(row, classToken))
            shown = shown + 1
        end
    end

    if shown == 0 then
        LT:Print("No route steps at or above this level.")
    end

    compareWithRoute(rankedFromTrees(trees, buildIndex), nextRow)
end

-- "/lt lbs" hands the parsed words table ({"lbs", "next"}); the standalone
-- "/lbs" hands the raw remainder ("next"). Both shapes are accepted.
local function runCommand(input)
    if type(LT.Diag) == "function" then
        pcall(LT.Diag, LT, "/lbs entered, level=" .. tostring(currentLevel())
            .. " input=" .. tostring(type(input) == "table" and "table" or input))
    end

    local args = {}
    if type(input) == "table" then
        for index = 2, #input do args[#args + 1] = input[index] end
    else
        for word in tostring(input or ""):gmatch("%S+") do args[#args + 1] = word end
    end

    local action = type(args[1]) == "string" and args[1]:lower() or ""

    -- Player decision 2026-11-05: the talent advisor is a level-10 feature, the
    -- same gate as the build wizard. Before the first talent point there is
    -- nothing to rank and no route step to take.
    local level = currentLevel()
    if level < 10 then
        LT:Print("The talent advisor starts at level 10, when the first talent point is available.")
        return
    end

    if action == "next" then
        runNext(1)
    elseif action == "route" then
        runRoute(1)
    else
        runReport()
    end
end

-- /lbs (standalone). WoW reads SLASH_ globals during addon loading, so this is
-- set at file load like Slash.lua sets /lt.
local function assertStandaloneSlash()
    _G.SLASH_LUNCHBOXSPECADVISOR1 = "/lbs"
    if type(SlashCmdList) == "table" then
        SlashCmdList["LUNCHBOXSPECADVISOR"] = function(input) runCommand(input) end
        if type(LT.Diag) == "function" then
            pcall(LT.Diag, LT, "/lbs slash registered (SlashCmdList present)")
        end
        return true
    end
    if type(LT.Diag) == "function" then
        pcall(LT.Diag, LT, "/lbs slash NOT registered: SlashCmdList is " .. type(SlashCmdList))
    end
    return false
end

local function registerCommand()
    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then
        return false
    end

    local ok, result = pcall(slash.RegisterCommand, slash, "lbs",
        function(input) runCommand(input) end,
        "/lt lbs [next|route] — spec advisor: ranked next points, or the talent route")

    return ok and result == true
end

assertStandaloneSlash()

-- Called by Core's module stage at PLAYER_LOGIN. Registration is idempotent:
-- the registry refuses a second "lbs".
-- Public entry, so /lt lbs can route here even when the standalone slash is not
-- the one the client happens to read (report 2026-11-05: /lbs silent while the
-- /lt tree worked).
function SpecAdvisor:Command(input)
    return runCommand(input)
end

function SpecAdvisor:OnPlayerLogin()
    assertStandaloneSlash()
    return registerCommand()
end
