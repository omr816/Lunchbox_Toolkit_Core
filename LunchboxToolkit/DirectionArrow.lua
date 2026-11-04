--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — DirectionArrow

    A small HUD arrow pointing at the player's corpse when dead (a corpse run),
    read from C_DeathInfo.GetCorpseMapPosition and, as a second route, the
    legacy GetCorpseMapPosition global.

    Quest waypoints are not drawn here: the client ships its own super-track
    waypoint arrow, so a second arrow would only duplicate it.

    Bearing. Normalized map coordinates grow east (+x) and south (+y), so the
    compass angle for an upward-pointing texture is

        angle = -math.atan2(tx - px, py - ty)

    (0 = north, positive clockwise — the convention Texture:SetRotation wants).
    Every client read is pcall'd and secret-guarded: a client without the map
    or death APIs simply draws no arrow, never an error. A death with no corpse
    position to read hides the arrow quietly.

    Toggle: /lt arrow on|off (default on).
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local DirectionArrow = {}
LT.DirectionArrow = DirectionArrow
LT.Modules = LT.Modules or {}
LT.Modules.DirectionArrow = DirectionArrow

-- WoW embeds Lua 5.1, which has math.atan2; the fallback keeps this file
-- loadable under a newer standalone Lua (5.3+) where it was removed.
local atan2 = math.atan2
if type(atan2) ~= "function" then
    atan2 = function(y, x)
        if x == 0 then
            if y > 0 then return math.pi / 2 end
            if y < 0 then return -math.pi / 2 end
            return 0
        end
        local angle = math.atan(y / x)
        if x < 0 then
            if y >= 0 then angle = angle + math.pi else angle = angle - math.pi end
        end
        return angle
    end
end

-- The client's own quest-arrow artwork, tinted with the addon's accent colour.
-- No texture file ships with the addon; this one is always present on the client.
local ARROW_TEXTURE = "Interface\\MINIMAP\\MiniMap-QuestArrow"
local ARROW_SIZE = 36

DirectionArrow.UPDATE_INTERVAL = 0.2

local frame, arrow, distanceText
local tickElapsed = 0
local deferredScheduled = false

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

local function combatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

local function canDefer()
    return type(C_Timer) == "table" and type(C_Timer.After) == "function"
end

------------------------------------------------------------------------------
-- Position reads
------------------------------------------------------------------------------

-- A normalized map position in whatever shape the client returns it: two
-- numbers (x, y), a table with .x/.y, or a Vector2D with GetXY().
local function readPosition(a, b)
    local x, y = safeNumber(a), safeNumber(b)
    if x and y then return x, y end

    local value = a
    if type(value) ~= "table" or isSecret(value) then return nil end

    if type(value.GetXY) == "function" then
        local ok, gx, gy = pcall(value.GetXY, value)
        gx, gy = safeNumber(gx), safeNumber(gy)
        if gx and gy then return gx, gy end
    end

    local okX, fx = pcall(function() return value.x end)
    local okY, fy = pcall(function() return value.y end)
    fx, fy = safeNumber(fx), safeNumber(fy)
    if fx and fy then return fx, fy end

    return nil
end

local function playerMapID()
    if type(C_Map) ~= "table" or type(C_Map.GetBestMapForUnit) ~= "function" then return nil end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok then return nil end
    return safeNumber(mapID)
end

local function playerPosition(mapID)
    if not mapID or type(C_Map) ~= "table" or type(C_Map.GetPlayerMapPosition) ~= "function" then return nil end
    local ok, a, b = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
    if not ok then return nil end
    return readPosition(a, b)
end

local function isDeadOrGhost()
    if type(UnitIsGhost) == "function" then
        local ok, ghost = pcall(UnitIsGhost, "player")
        if ok and ghost then return true end
    end
    if type(UnitIsDeadOrGhost) == "function" then
        local ok, dead = pcall(UnitIsDeadOrGhost, "player")
        if ok and dead then return true end
    end
    return false
end

local function corpsePosition(mapID)
    -- Modern route.
    if type(C_DeathInfo) == "table" and type(C_DeathInfo.GetCorpseMapPosition) == "function" then
        local ok, a, b = pcall(C_DeathInfo.GetCorpseMapPosition, mapID)
        if ok then
            local x, y = readPosition(a, b)
            -- The client reports (0, 0) when it has no corpse position for the map.
            if x and y and not (x == 0 and y == 0) then return x, y, "C_DeathInfo" end
        end
    end

    -- Legacy global. Some clients take the map id, some take no argument; a
    -- failed or empty answer only means this route has nothing to add.
    if type(GetCorpseMapPosition) == "function" then
        local ok, a, b = pcall(GetCorpseMapPosition, mapID)
        if not ok then ok, a, b = pcall(GetCorpseMapPosition) end
        if ok then
            local x, y = readPosition(a, b)
            if x and y and not (x == 0 and y == 0) then return x, y, "GetCorpseMapPosition" end
        end
    end

    return nil
end

------------------------------------------------------------------------------
-- Target selection
------------------------------------------------------------------------------

-- The client's own super-track arrow owns quest waypoints, so only the corpse
-- run is drawn here. A death with nothing to read returns nil and the caller
-- hides the arrow.
local reportedRoute

local function resolveTarget()
    local mapID = playerMapID()
    if not mapID then return nil end
    if not isDeadOrGhost() then return nil end

    local x, y, route = corpsePosition(mapID)
    if not x or not y then return nil end

    if route and route ~= reportedRoute then
        reportedRoute = route
        if type(LT.Diag) == "function" then
            pcall(LT.Diag, LT, "DirectionArrow: corpse position via " .. route)
        end
    end

    return { mapID = mapID, x = x, y = y, kind = "corpse", route = route }
end

------------------------------------------------------------------------------
-- Bearing and distance
------------------------------------------------------------------------------

local function bearing(px, py, tx, ty)
    return -atan2(tx - px, py - ty)
end

-- World (yard) position when the map position can be converted to world space;
-- nil when the client cannot answer, in which case only the arrow is shown.
local function worldPosition(mapID, x, y)
    if not mapID or type(C_Map) ~= "table" or type(C_Map.GetWorldPosFromMapPos) ~= "function" then return nil end
    if type(CreateVector2D) ~= "function" then return nil end

    local okVec, vec = pcall(CreateVector2D, x, y)
    if not okVec or not vec then return nil end

    local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos, mapID, vec)
    if not ok or continentID == nil or worldPos == nil then return nil end

    local wx, wy = readPosition(worldPos)
    if not wx or not wy then return nil end
    return continentID, wx, wy
end

local function yardDistance(mapID, px, py, tx, ty)
    local playerContinent, pwx, pwy = worldPosition(mapID, px, py)
    local targetContinent, twx, twy = worldPosition(mapID, tx, ty)
    if not playerContinent or not targetContinent or playerContinent ~= targetContinent then return nil end
    local dx, dy = twx - pwx, twy - pwy
    return math.sqrt(dx * dx + dy * dy)
end

local function formatYards(yards)
    local number = safeNumber(yards)
    if not number then return nil end
    if number >= 1000 then
        return string.format("%.1fk yd", number / 1000)
    end
    return tostring(math.floor(number + 0.5)) .. " yd"
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

local function colourRGB(key)
    local palette = LT.Palette
    if type(palette) == "table" and type(palette.Colour) == "function" then
        local ok, value = pcall(palette.Colour, palette, key)
        if ok and type(value) == "table" then
            return (value[1] or 1), (value[2] or 1), (value[3] or 1)
        end
    end
    return 1, 1, 1
end

local function hideArrow()
    if frame and type(frame.Hide) == "function" then pcall(frame.Hide, frame) end
end

local function buildFrame()
    if frame then return frame end
    if combatLocked() then return nil end
    if type(CreateFrame) ~= "function" then return nil end

    local ok, window = pcall(CreateFrame, "Frame", "LunchboxToolkitDirectionArrowFrame", UIParent)
    if not ok or not window then
        ok, window = pcall(CreateFrame, "Frame", nil, UIParent)
        if not ok or not window then return nil end
    end

    if type(window.SetFrameStrata) == "function" then pcall(window.SetFrameStrata, window, "MEDIUM") end
    if type(window.SetSize) == "function" then pcall(window.SetSize, window, ARROW_SIZE, ARROW_SIZE) end
    if type(window.SetPoint) == "function" then pcall(window.SetPoint, window, "CENTER", UIParent, "CENTER", 0, 0) end
    if type(window.EnableMouse) == "function" then pcall(window.EnableMouse, window, false) end

    if type(window.CreateTexture) == "function" then
        local okTex, tex = pcall(window.CreateTexture, window, nil, "OVERLAY")
        if okTex and tex then
            arrow = tex
            if type(tex.SetAllPoints) == "function" then pcall(tex.SetAllPoints, tex, window) end
            if type(tex.SetTexture) == "function" then pcall(tex.SetTexture, tex, ARROW_TEXTURE) end
            if type(tex.SetDesaturated) == "function" then pcall(tex.SetDesaturated, tex, true) end
            if type(tex.SetVertexColor) == "function" then
                local r, g, b = colourRGB("accent")
                pcall(tex.SetVertexColor, tex, r, g, b, 1)
            end
        end
    end

    if type(window.CreateFontString) == "function" then
        local okText, text = pcall(window.CreateFontString, window, nil, "OVERLAY", "GameFontNormal")
        if okText and text then
            distanceText = text
            if type(text.SetPoint) == "function" then pcall(text.SetPoint, text, "TOP", window, "BOTTOM", 0, -4) end
            if type(text.SetShadowOffset) == "function" then pcall(text.SetShadowOffset, text, 1, -1) end
            if type(text.SetShadowColor) == "function" then pcall(text.SetShadowColor, text, 0, 0, 0, 1) end
            local r, g, b = colourRGB("text")
            if type(text.SetTextColor) == "function" then pcall(text.SetTextColor, text, r, g, b, 1) end
        end
    end

    if type(window.SetScript) == "function" then
        window:SetScript("OnUpdate", function(_, delta)
            tickElapsed = tickElapsed + (tonumber(delta) or 0)
            if tickElapsed < DirectionArrow.UPDATE_INTERVAL then return end
            tickElapsed = 0
            DirectionArrow:Refresh()
        end)

        window:SetScript("OnEvent", function(_, event)
            DirectionArrow:OnEvent(event)
        end)
    end

    for _, eventName in ipairs({
        "PLAYER_ENTERING_WORLD",
        "PLAYER_DEAD",
        "PLAYER_ALIVE",
        "ZONE_CHANGED_NEW_AREA",
        "PLAYER_REGEN_ENABLED",
    }) do
        if type(window.RegisterEvent) == "function" then
            pcall(window.RegisterEvent, window, eventName)
        end
    end

    frame = window
    hideArrow()
    return window
end

local function scheduleDeferred()
    if deferredScheduled then return end
    if not canDefer() then return end

    deferredScheduled = true
    local ok = pcall(C_Timer.After, 2, function()
        deferredScheduled = false
        DirectionArrow:AttemptBuild()
    end)
    if not ok then deferredScheduled = false end
end

------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------

function DirectionArrow:AttemptBuild()
    if combatLocked() then
        scheduleDeferred()
        return false
    end
    if frame then return true end
    return buildFrame() ~= nil
end

function DirectionArrow:IsEnabled()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then return true end
    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then return true end
    return options.directionArrow ~= false
end

function DirectionArrow:SetEnabled(on)
    on = on == true

    local database = LT.Database
    if type(database) == "table" and type(database.GetOptions) == "function" then
        local ok, options = pcall(database.GetOptions, database)
        if ok and type(options) == "table" then
            options.directionArrow = on
        end
    end

    if not on then
        hideArrow()
        return "off"
    end

    if not frame and not self:AttemptBuild() then
        return "deferred"
    end

    self:Refresh()
    return "on"
end

function DirectionArrow:Refresh()
    if not frame then return end

    if not self:IsEnabled() then
        hideArrow()
        return
    end

    local target = resolveTarget()
    if not target then
        hideArrow()
        return
    end

    local px, py = playerPosition(target.mapID)
    if not px or not py then
        hideArrow()
        return
    end

    local angle = bearing(px, py, target.x, target.y)
    if arrow and type(arrow.SetRotation) == "function" then
        pcall(arrow.SetRotation, arrow, angle)
    end

    local yards = yardDistance(target.mapID, px, py, target.x, target.y)
    if distanceText then
        local label = formatYards(yards)
        if label and type(distanceText.SetText) == "function" then
            pcall(distanceText.SetText, distanceText, label)
            if type(distanceText.Show) == "function" then pcall(distanceText.Show, distanceText) end
        else
            if type(distanceText.SetText) == "function" then pcall(distanceText.SetText, distanceText, "") end
            if type(distanceText.Hide) == "function" then pcall(distanceText.Hide, distanceText) end
        end
    end

    if type(frame.Show) == "function" then pcall(frame.Show, frame) end
end

function DirectionArrow:OnEvent(event)
    if event == "PLAYER_REGEN_ENABLED" then
        if self:IsEnabled() and not frame then
            self:AttemptBuild()
        end
        self:Refresh()
        return
    end
    self:Refresh()
end

------------------------------------------------------------------------------
-- Command and module stages
------------------------------------------------------------------------------

local function registerCommand()
    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then return false end
    local ok, result = pcall(slash.RegisterCommand, slash, "arrow",
        function(words) DirectionArrow:Command(words) end,
        "/lt arrow on|off — direction arrow to your corpse")
    return ok and result == true
end

function DirectionArrow:Command(words)
    local action = words and words[2]

    if action == "on" then
        local result = self:SetEnabled(true)
        if result == "on" then
            LT:Print("Direction arrow on.")
        elseif result == "deferred" then
            LT:Print("Direction arrow on; the frame appears when you leave combat.")
        else
            LT:Warn("The client did not allow the arrow frame to be created; try again out of combat.")
        end
        return
    end

    if action == "off" then
        self:SetEnabled(false)
        LT:Print("Direction arrow off.")
        return
    end

    if action == nil or action == "status" then
        LT:Print("Direction arrow: " .. (self:IsEnabled() and "on" or "off"))
        return
    end

    LT:Print("Usage: /lt arrow [on|off|status]")
end

function DirectionArrow:Initialize()
    if self.initialized then return end
    self.initialized = true

    if not self:IsEnabled() then return end

    if combatLocked() then
        scheduleDeferred()
        return
    end

    buildFrame()
end

function DirectionArrow:OnPlayerLogin()
    return registerCommand()
end

function DirectionArrow:OnEnterWorld()
    if not self:IsEnabled() then
        hideArrow()
        return
    end

    if not frame then
        self:AttemptBuild()
    end

    self:Refresh()
end
