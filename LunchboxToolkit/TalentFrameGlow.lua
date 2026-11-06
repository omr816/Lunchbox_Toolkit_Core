--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — TalentFrameGlow

    Classic Era only. While the 3-tree talent frame (PlayerTalentFrame) is open,
    the border of every talent the spec advisor can take next is coloured by its
    ranking against the primary build (slot 1): rank 1 purple, rank 2 blue,
    rank 3 green, rank 4+ red. Gated, maxed and not-yet-reachable talents stay
    uncoloured, so only the recommendation reads as colour.

    Forever keeps the talent UI in PlayerSpellsFrame/ClassTalentFrame. The host
    is probed in the order PlayerSpellsFrame, ClassTalentFrame, PlayerTalentFrame,
    TalentFrame and reported through LT:Diag. Only the two legacy hosts carry the
    buttons this classic pass understands; on the newer hosts the module reports
    its host and stays a no-op, and when no host exists at all it initialises as
    a no-op.

    The ranking is the same maths /lbs prints:
        SpecAdvisor:Read() -> classic trees, then
        TalentValuation:Rank(trees, nil, 1) -> ordered array, best first.

    The four rank colours are fixed RGBs held here, not Palette entries: they
    describe this one overlay, not the shared chrome or the verdict ladder the
    legend explains. The border is four solid-colour textures parented to each
    talent button (the same pattern QuestRewards uses for reward buttons), never
    a tint of the talent icon itself.

    Classic frame scheme (confirmed against working Classic-Era addons):
        tabs    PlayerTalentFrameTab1..3, selected via PanelTemplates_GetSelectedTab
        buttons PlayerTalentFrameTalent1..N where N = GetNumTalents(currentTab)
        data    GetTalentInfo(tab, index) -> name, icon, row, column, rank, maxRank
        (GetNumTalentTabs -> 3; GetNumTalents(tab) -> cells in that tab)

    Hooks are built once, outside combat (deferred via C_Timer.After when locked
    down). Refresh happens on frame show, on tab click, and on PLAYER_TALENT_UPDATE
    / CHARACTER_POINTS_CHANGED; the borders clear when the frame hides.
--------------------------------------------------------------------------]]

if not LunchboxToolkit then return end
local LT = LunchboxToolkit

local TalentFrameGlow = {}
LT.TalentFrameGlow = TalentFrameGlow
LT.Modules = LT.Modules or {}
LT.Modules.TalentFrameGlow = TalentFrameGlow

------------------------------------------------------------------------------
-- Fixed rank colours (see header; not palette entries)
------------------------------------------------------------------------------

local RANK_COLOURS = {
    [1] = { 0.75, 0.30, 0.95, 1.00 },  -- purple: best
    [2] = { 0.30, 0.55, 1.00, 1.00 },  -- blue
    [3] = { 0.30, 0.85, 0.35, 1.00 },  -- green
    [4] = { 0.95, 0.25, 0.25, 1.00 },  -- red: 4th and worse
}

local RING_SIZE = 2

------------------------------------------------------------------------------
-- Guarded helpers
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

local function canDefer()
    return type(C_Timer) == "table" and type(C_Timer.After) == "function"
end

-- The same normalisation TalentValuation uses to match talent names, so a button
-- read straight from GetTalentInfo lands on the same key as the ranked list.
local function normalizeName(name)
    if type(name) ~= "string" then return "" end
    return name:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- WoW exposes frames and regions as either tables or userdata depending on the
-- client, so every object check accepts both (the same rule CharMarks uses).
local function isRegion(value)
    return type(value) == "table" or type(value) == "userdata"
end

------------------------------------------------------------------------------
-- Classic talent frame pieces
------------------------------------------------------------------------------

-- Forever hosts the talent UI in PlayerSpellsFrame/ClassTalentFrame; Classic
-- Era keeps the 3-tree PlayerTalentFrame, and some builds exposed TalentFrame.
-- Probe in that order, report the answer once, and keep the ring pass to the
-- two legacy hosts.
local HOST_NAMES = { "PlayerSpellsFrame", "ClassTalentFrame", "PlayerTalentFrame", "TalentFrame" }
local CLASSIC_HOSTS = { PlayerTalentFrame = true, TalentFrame = true }

local hostFrame, hostName, hostReported, missingReported

local function diag(message)
    if type(LT.Diag) == "function" then pcall(LT.Diag, LT, message) end
end

local function probeHost()
    if hostFrame then return hostFrame end

    for _, name in ipairs(HOST_NAMES) do
        local candidate = rawget(_G, name)
        if isRegion(candidate) then
            hostFrame, hostName = candidate, name
            if not hostReported then
                hostReported = true
                local suffix = CLASSIC_HOSTS[name] and " (classic talent ring)"
                    or " (not a classic talent frame; idle)"
                diag("TalentFrameGlow: talent host " .. name .. suffix)
            end
            return candidate
        end
    end

    return nil
end

-- nil for any host that is not the classic 3-tree frame, so every caller below
-- becomes a no-op on the newer hosts instead of touching missing globals.
local function talentFrame()
    local frame = probeHost()
    if not frame then return nil end
    if not CLASSIC_HOSTS[hostName] then return nil end
    return frame
end

local function maxTab()
    if type(GetNumTalentTabs) ~= "function" then return 3 end
    local ok, n = pcall(GetNumTalentTabs)
    if ok then n = tonumber(n) end
    if type(n) == "number" and n > 0 then return math.min(n, 10) end
    return 3
end

local function selectedTab()
    local frame = talentFrame()
    if not frame then return nil end
    if type(PanelTemplates_GetSelectedTab) ~= "function" then return nil end

    local ok, tab = pcall(PanelTemplates_GetSelectedTab, frame)
    if not ok then return nil end

    tab = tonumber(tab)
    if not tab or tab < 1 or tab > maxTab() then return nil end
    return tab
end

local function talentCount(tab)
    if not tab or type(GetNumTalents) ~= "function" then return 0 end
    local ok, count = pcall(GetNumTalents, tab)
    if not ok then return 0 end
    count = tonumber(count)
    if type(count) ~= "number" or count <= 0 then return 0 end
    return math.min(count, 60)
end

local function talentName(tab, index)
    if type(GetTalentInfo) ~= "function" then return nil end
    local ok, name = pcall(GetTalentInfo, tab, index)
    if not ok or isSecret(name) then return nil end
    if type(name) ~= "string" or name == "" then return nil end
    return name
end

local function talentButton(index)
    local button = rawget(_G, "PlayerTalentFrameTalent" .. index)
    if isRegion(button) then return button end
    return nil
end

------------------------------------------------------------------------------
-- Border ring (four solid-colour textures, never a tint of the icon)
------------------------------------------------------------------------------

local OVERLAY_POINTS = {
    { "TOPLEFT",     "TOPLEFT",     -RING_SIZE,  RING_SIZE },
    { "TOPRIGHT",    "TOPRIGHT",     RING_SIZE,  RING_SIZE },
    { "BOTTOMLEFT",  "BOTTOMLEFT",  -RING_SIZE, -RING_SIZE },
    { "BOTTOMRIGHT", "BOTTOMRIGHT",  RING_SIZE, -RING_SIZE },
}

local EDGE_GEOMETRY = {
    { "TOPLEFT",    "TOPRIGHT",    "HEIGHT" },  -- top
    { "BOTTOMLEFT", "BOTTOMRIGHT", "HEIGHT" },  -- bottom
    { "TOPLEFT",    "BOTTOMLEFT",  "WIDTH"  },  -- left
    { "TOPRIGHT",   "BOTTOMRIGHT", "WIDTH"  },  -- right
}

local function anchorOverlay(overlay, button)
    if type(overlay.ClearAllPoints) == "function" then
        pcall(overlay.ClearAllPoints, overlay)
    end
    for _, point in ipairs(OVERLAY_POINTS) do
        pcall(overlay.SetPoint, overlay, point[1], button, point[2], point[3], point[4])
    end
end

local function layoutEdges(overlay)
    local edges = overlay.__edges
    if type(edges) ~= "table" then return end

    for index = 1, #EDGE_GEOMETRY do
        local texture = edges[index]
        local geometry = EDGE_GEOMETRY[index]
        if isRegion(texture) then
            if type(texture.ClearAllPoints) == "function" then
                pcall(texture.ClearAllPoints, texture)
            end
            pcall(texture.SetPoint, texture, geometry[1], overlay, geometry[1], 0, 0)
            pcall(texture.SetPoint, texture, geometry[2], overlay, geometry[2], 0, 0)
            if geometry[3] == "HEIGHT" then
                pcall(texture.SetHeight, texture, RING_SIZE)
            else
                pcall(texture.SetWidth, texture, RING_SIZE)
            end
        end
    end
end

local function ringFor(button)
    if not isRegion(button) or type(button.CreateTexture) ~= "function" then
        return nil
    end
    if button.__ltTalentRing then return button.__ltTalentRing end

    local ok, overlay = pcall(CreateFrame, "Frame", nil, button)
    if not ok or not isRegion(overlay) then return nil end

    if type(button.GetFrameLevel) == "function" and type(overlay.SetFrameLevel) == "function" then
        local okLevel, level = pcall(button.GetFrameLevel, button)
        if okLevel and type(level) == "number" then
            pcall(overlay.SetFrameLevel, overlay, level + 5)
        end
    end

    anchorOverlay(overlay, button)

    overlay.__edges = {}
    for index = 1, #EDGE_GEOMETRY do
        local okEdge, texture = pcall(overlay.CreateTexture, overlay, nil, "OVERLAY")
        if okEdge and isRegion(texture) then
            overlay.__edges[index] = texture
        end
    end

    layoutEdges(overlay)
    if type(overlay.Hide) == "function" then pcall(overlay.Hide, overlay) end

    button.__ltTalentRing = overlay
    return overlay
end

local function applyRing(button, colour)
    local overlay = ringFor(button)
    if not overlay or type(colour) ~= "table" then return end

    anchorOverlay(overlay, button)
    layoutEdges(overlay)

    local alpha = tonumber(colour[4]) or 1
    for index = 1, #EDGE_GEOMETRY do
        local texture = overlay.__edges and overlay.__edges[index]
        if isRegion(texture) and type(texture.SetColorTexture) == "function" then
            pcall(texture.SetColorTexture, texture, colour[1], colour[2], colour[3], alpha)
        end
    end

    if type(overlay.Show) == "function" then pcall(overlay.Show, overlay) end
end

local function clearRing(button)
    if not isRegion(button) or not button.__ltTalentRing then return end
    local overlay = button.__ltTalentRing
    if isRegion(overlay) and type(overlay.Hide) == "function" then
        pcall(overlay.Hide, overlay)
    end
end

------------------------------------------------------------------------------
-- Forever — PlayerSpellsFrame.TalentsFrame.nodeIDToButton
--
-- The modern talent UI keeps no named talent buttons: the map field
-- `TalentsFrame.nodeIDToButton` is the only handle, and a node is named through
-- C_Traits (node.activeEntry.entryID -> entry.definitionID -> definition.spellID
-- -> C_Spell.GetSpellName). Every step below was read off the client in the
-- talents-ui probe on 2026-11-05; nothing here is assumed.
------------------------------------------------------------------------------

local function modernTalents()
    local frame = _G.PlayerSpellsFrame
    if not isRegion(frame) or type(frame.IsShown) ~= "function" then return nil end
    local talents = frame.TalentsFrame
    if not isRegion(talents) or type(talents.nodeIDToButton) ~= "table" then return nil end
    return frame, talents
end

local function nodeIdentity(configID, nodeID)
    if not configID or type(C_Traits) ~= "table" then return nil end
    if type(C_Traits.GetNodeInfo) ~= "function" then return nil end

    local okNode, node = pcall(C_Traits.GetNodeInfo, configID, nodeID)
    if not okNode or type(node) ~= "table" then return nil end

    local active = node.activeEntry
    local entryID = type(active) == "table" and (active.ID or active.entryID) or active
    if type(entryID) ~= "number" then return nil end

    local okEntry, entry = pcall(C_Traits.GetEntryInfo, configID, entryID)
    if not okEntry or type(entry) ~= "table" or not entry.definitionID then return nil end

    local okDef, def = pcall(C_Traits.GetDefinitionInfo, entry.definitionID)
    if not okDef or type(def) ~= "table" then return nil end

    local name = def.overrideName
    if type(name) ~= "string" and def.spellID and type(C_Spell) == "table" then
        if type(C_Spell.GetSpellName) == "function" then
            local ok, spelled = pcall(C_Spell.GetSpellName, def.spellID)
            if ok and type(spelled) == "string" then name = spelled end
        end
        if type(name) ~= "string" and type(C_Spell.GetSpellInfo) == "function" then
            local ok, info = pcall(C_Spell.GetSpellInfo, def.spellID)
            if ok and type(info) == "table" and type(info.name) == "string" then name = info.name end
        end
    end

    return name, node
end

local function routeRows()
    local routes = LT.TalentRoutes
    if type(routes) ~= "table" or type(routes.Get) ~= "function" then return nil end

    local classToken = LT.player and LT.player.class
    local spec
    local builds = LT.Builds
    if type(builds) == "table" and type(builds.GetActive) == "function" then
        local ok, build = pcall(builds.GetActive, builds)
        if ok and type(build) == "table" then spec = build.spec end
    end

    local ok, rows = pcall(routes.Get, routes, classToken, spec)
    if ok and type(rows) == "table" then return rows end
    return nil
end

local modernRings = {}
local hookModern   -- defined below; RefreshModern calls it to attach hooks

function TalentFrameGlow:RefreshModern(verbose)
    hookModern()

    -- verbose is the /lt glowdebug path: it prints whether or not chat
    -- diagnostics are on, because this is the one question left for the rings.
    local function note(message)
        if verbose and type(LT.Print) == "function" then
            pcall(LT.Print, LT, message)
            return
        end
        if type(LT.Diag) == "function" then pcall(LT.Diag, LT, message) end
    end

    local frame, talents = modernTalents()
    if not frame then
        note("talent glow: no PlayerSpellsFrame.TalentsFrame.nodeIDToButton")
        return
    end

    for button in pairs(modernRings) do clearRing(button) end
    modernRings = {}

    if type(frame.IsShown) == "function" and not frame:IsShown() then return end
    if type(talents.IsShown) == "function" and not talents:IsShown() then return end

    local configID
    if type(C_ClassTalents) == "table" and type(C_ClassTalents.GetActiveConfigID) == "function" then
        local ok, id = pcall(C_ClassTalents.GetActiveConfigID)
        if ok then configID = id end
    end
    if not configID then
        note("talent glow: no config id")
        return
    end

    -- The route is the preferred plan. Where a class/spec has no authored route,
    -- fall back to the ranked candidates from TalentValuation, so every class with
    -- talent data gets rings (player decision 2026-11-05).
    local ordered = {}

    local rows = routeRows()
    if rows then
        local seen = {}
        for _, row in ipairs(rows) do
            local key = normalizeName(type(row.name) == "string" and row.name or "")
            if key ~= "" and not seen[key] then
                seen[key] = true
                ordered[#ordered + 1] = key
            end
        end
    end

    if #ordered == 0 then
        local advisor = LT.SpecAdvisor
        local valuation = LT.TalentValuation
        if type(advisor) == "table" and type(advisor.Read) == "function"
            and type(valuation) == "table" and type(valuation.Rank) == "function" then
            local okRead, trees = pcall(advisor.Read, advisor)
            if okRead and type(trees) == "table" then
                local index = 1
                local builds = LT.Builds
                if type(builds) == "table" and type(builds.GetActiveIndex) == "function" then
                    local okIndex, active = pcall(builds.GetActiveIndex, builds)
                    if okIndex and tonumber(active) then index = tonumber(active) end
                end

                local okRank, ranked = pcall(valuation.Rank, valuation, trees, nil, index)
                if okRank and type(ranked) == "table" then
                    for _, entry in ipairs(ranked) do
                        local key = normalizeName(type(entry.name) == "string" and entry.name or "")
                        if key ~= "" then ordered[#ordered + 1] = key end
                    end
                end
            end
        end
    end

    local byName = {}
    for nodeID, button in pairs(talents.nodeIDToButton) do
        local name, node = nodeIdentity(configID, nodeID)
        if type(name) == "string" then
            byName[normalizeName(name)] = { button = button, node = node }
        end
    end

    local resolved = 0
    for _ in pairs(byName) do resolved = resolved + 1 end
    note("talent glow: nodes=" .. tostring(resolved) .. " order=" .. tostring(#ordered))

    if verbose then
        local names = {}
        for name in pairs(byName) do
            names[#names + 1] = name
            if #names >= 6 then break end
        end
        note("  resolved: " .. table.concat(names, ", "))

        local orderNames = {}
        for index = 1, math.min(#ordered, 6) do
            orderNames[index] = ordered[index]
        end
        note("  order: " .. table.concat(orderNames, ", "))
    end

    -- The same four rank colours the classic frame uses, on the first four ordered
    -- talents that are not maxed. Ordered is already one entry per talent (route
    -- rows repeat per rank; ranked entries are one per talent).
    local painted = 0
    local seenName = {}
    for _, key in ipairs(ordered) do
        if key and seenName[key] then
            key = nil
        elseif key then
            seenName[key] = true
        end

        local entry = key and byName[key] or nil
        if entry then
            local node = entry.node or {}
            local purchased = tonumber(node.ranksPurchased) or 0
            local maxRanks = tonumber(node.maxRanks) or 0
            if maxRanks > 0 and purchased < maxRanks then
                painted = painted + 1
                applyRing(entry.button, RANK_COLOURS[painted] or RANK_COLOURS[4])
                modernRings[entry.button] = true
                if painted >= 4 then break end
            end
        end
    end

    note("talent glow: painted " .. tostring(painted))
end

------------------------------------------------------------------------------
-- Ranking
------------------------------------------------------------------------------

local function rankMap()
    local advisor = LT.SpecAdvisor
    local valuation = LT.TalentValuation

    if type(advisor) ~= "table" or type(advisor.Read) ~= "function" then return nil end
    if type(valuation) ~= "table" or type(valuation.Rank) ~= "function" then return nil end

    local ok, trees = pcall(advisor.Read, advisor)
    if not ok or type(trees) ~= "table" then return nil end

    local okRank, ranked = pcall(valuation.Rank, valuation, trees, nil, 1)
    if not okRank or type(ranked) ~= "table" then return nil end

    local map = {}
    for index, entry in ipairs(ranked) do
        local key = normalizeName(entry and entry.name)
        if key ~= "" then
            map[key] = (index <= 3) and index or 4
        end
    end
    return map
end

------------------------------------------------------------------------------
-- Refresh / clear
------------------------------------------------------------------------------

local ringed = {}

local function clearAll()
    for button in pairs(ringed) do
        clearRing(button)
    end
    ringed = {}
end

local function refresh()
    local frame = talentFrame()
    if not frame or type(frame.IsShown) ~= "function" or not frame:IsShown() then
        clearAll()
        return
    end

    -- Wipe every ring, then redraw only the talents that rank today.
    clearAll()

    local map = rankMap()
    if not map then return end

    local tab = selectedTab()
    if not tab then return end

    local count = talentCount(tab)
    for index = 1, count do
        local button = talentButton(index)
        if button then
            local name = talentName(tab, index)
            local rank = name and map[normalizeName(name)]
            if rank then
                applyRing(button, RANK_COLOURS[rank])
                ringed[button] = true
            end
        end
    end
end

local refreshPending = false

local function scheduleRefresh()
    if not canDefer() then
        refresh()
        return
    end
    if refreshPending then return end
    refreshPending = true
    local ok = pcall(C_Timer.After, 0.05, function()
        refreshPending = false
        refresh()
    end)
    if not ok then
        refreshPending = false
        refresh()
    end
end

------------------------------------------------------------------------------
-- Frame hooks (built once, outside combat)
------------------------------------------------------------------------------

local hooksBuilt = false

local LEGEND_LABELS = {
    { "Best",    RANK_COLOURS[1] },
    { "2nd",     RANK_COLOURS[2] },
    { "3rd",     RANK_COLOURS[3] },
    { "No good", RANK_COLOURS[4] },
}

local legendFrame

local function buildLegend()
    if legendFrame then return legendFrame end

    local anchor = talentFrame()
    if not anchor then return nil end

    local ok, frame = pcall(CreateFrame, "Frame", "LunchboxToolkitTalentLegend", UIParent)
    if not ok or not isRegion(frame) then return nil end

    frame:SetWidth(110)
    frame:SetHeight(16 * #LEGEND_LABELS)
    frame:SetFrameStrata("MEDIUM")
    pcall(frame.SetPoint, frame, "TOPRIGHT", anchor, "TOPLEFT", -10, 0)

    for index, entry in ipairs(LEGEND_LABELS) do
        local swatch = frame:CreateTexture(nil, "ARTWORK")
        swatch:SetSize(10, 10)
        swatch:SetColorTexture(entry[2][1], entry[2][2], entry[2][3], 1)
        swatch:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(index - 1) * 16)

        local label = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetText(entry[1])
        label:SetPoint("LEFT", swatch, "RIGHT", 6, 0)
    end

    frame:Hide()
    legendFrame = frame
    return frame
end

local function onShow()
    scheduleRefresh()
    local legend = buildLegend()
    if legend and type(legend.Show) == "function" then pcall(legend.Show, legend) end
end

local function onHide()
    clearAll()
    if legendFrame and type(legendFrame.Hide) == "function" then
        pcall(legendFrame.Hide, legendFrame)
    end
end

local function hookTabs()
    for tab = 1, maxTab() do
        local tabButton = rawget(_G, "PlayerTalentFrameTab" .. tab)
        if isRegion(tabButton) and type(tabButton.HookScript) == "function" then
            pcall(tabButton.HookScript, tabButton, "OnClick", scheduleRefresh)
        end
    end
end

local function buildHooks()
    if hooksBuilt then return true end

    if inCombat() then
        if canDefer() then
            pcall(C_Timer.After, 0.5, buildHooks)
        end
        return false
    end

    local host = probeHost()
    if not host then
        if not missingReported then
            missingReported = true
            diag("TalentFrameGlow: no talent host found; idle")
        end
        return false
    end

    -- A newer host answered: the host is reported already, and there are no
    -- PlayerTalentFrame buttons to ring, so stay a settled no-op.
    if not CLASSIC_HOSTS[hostName] then
        hooksBuilt = true
        return true
    end

    local frame = host
    if type(frame.HookScript) ~= "function" then return false end

    pcall(frame.HookScript, frame, "OnShow", onShow)
    pcall(frame.HookScript, frame, "OnHide", onHide)
    hookTabs()

    hooksBuilt = true

    if type(frame.IsShown) == "function" and frame:IsShown() then
        scheduleRefresh()
    end

    return true
end

function TalentFrameGlow:BuildHooks() return buildHooks() end
function TalentFrameGlow:Refresh() refresh() end
function TalentFrameGlow:Clear() clearAll() end

-- Called by Core's module stage at PLAYER_LOGIN. Registration is idempotent.
function TalentFrameGlow:OnPlayerLogin()
    return buildHooks()
end

------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------

local modernHooked, modernPending

-- Hook the modern window once its map exists, then refresh on the same events
-- the classic path uses. The window is lazy: it may not exist until the player
-- opens it, so every event retries the hook.
-- Hooks the window as soon as it EXISTS, not once the node map exists: the map
-- (and TalentsFrame) are created on first open, so requiring them here meant the
-- hook was never attached at all (report 2026-11-05: /lbs printed, no rings).
hookModern = function()
    local frame = _G.PlayerSpellsFrame
    if not isRegion(frame) or type(frame.HookScript) ~= "function" then
        if type(LT.Diag) == "function" then
            pcall(LT.Diag, LT, "talent glow: PlayerSpellsFrame is " .. type(_G.PlayerSpellsFrame))
        end
        return false
    end

    if not modernHooked then
        pcall(frame.HookScript, frame, "OnShow", function()
            TalentFrameGlow:RefreshModern()
        end)
        pcall(frame.HookScript, frame, "OnHide", function()
            TalentFrameGlow:RefreshModern()
        end)
        modernHooked = true
    end

    -- TalentsFrame appears later; hook it the first time it is visible, and hook
    -- it only once.
    local talents = frame.TalentsFrame
    if type(talents) == "table" and type(talents.HookScript) == "function"
        and not talents.__ltGlowHooked then
        talents.__ltGlowHooked = true
        pcall(talents.HookScript, talents, "OnShow", function()
            TalentFrameGlow:RefreshModern()
        end)
    end

    return true
end

local function scheduleModern()
    if modernPending then return end
    modernPending = true

    local function run()
        modernPending = false
        hookModern()
        TalentFrameGlow:RefreshModern()
    end

    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        pcall(C_Timer.After, 0.2, run)
    else
        run()
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == "Blizzard_TalentUI"
            or arg1 == "Blizzard_PlayerSpells"
            or arg1 == "Blizzard_ClassTalentUI" then
            buildHooks()
            hookModern()
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        hookModern()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        hookModern()
        scheduleModern()
        return
    end

    if event == "PLAYER_TALENT_UPDATE" or event == "CHARACTER_POINTS_CHANGED" then
        local frame = talentFrame()
        if frame and type(frame.IsShown) == "function" and frame:IsShown() then
            scheduleRefresh()
        end
        scheduleModern()
    end
end)

for _, event in ipairs({
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_TALENT_UPDATE",
    "CHARACTER_POINTS_CHANGED",
}) do
    pcall(eventFrame.RegisterEvent, eventFrame, event)
end
