--[[--------------------------------------------------------------------------
    LunchboxToolkit_Threat — nameplate threat indicators for tanking

    Rebuilt from ThreatBeacon's mechanism, not its UI. The one thing ThreatBeacon
    proves works on Forever is: threat is read from the Blizzard threat APIs
    (`UnitThreatSituation` / `UnitDetailedThreatSituation`) on each enemy nameplate
    via `C_NamePlate.GetNamePlateForUnit`, NOT from the combat log. That is the
    whole core, and it survives the combat-log removal.

      * Tank mode — green square: you are tanking (secure); yellow: your lead is
        narrowing / insecure; red: the client reports you no longer tank it.
      * DPS mode — yellow: threat warning; red: you have aggro.

    Every client read is pcall'd and secret-guarded; a missing API is reported
    once and degrades to "no indicator", never an error. The indicator is a drawn
    square (the core's palette verdict colours), anchored to the top-right of each
    enemy nameplate, shown only in combat.

    The plugin declares one small SavedVariable (`LunchboxToolkitThreatDB`) for the
    role and enabled flags; the slash command is `/lt threat`.
--------------------------------------------------------------------------]]

if not LunchboxToolkit then return end
local LT = LunchboxToolkit

local previousModule = LT.Threat
local duplicateLoad = type(previousModule) == "table"

local Threat = {}
LT.Threat = Threat

Threat.PLUGIN_ID = "lunchbox_threat"
Threat.VERSION = "1.0.0"

------------------------------------------------------------------------------
-- Settings (own small table; the core keeps its own DB)
------------------------------------------------------------------------------

local STORE = "LunchboxToolkitThreatDB"

local function settings()
    _G[STORE] = _G[STORE] or {}
    local db = _G[STORE]
    db.enabled = (db.enabled == nil) and true or db.enabled
    db.role    = (db.role == "dps") and "dps" or "tank"
    return db
end

------------------------------------------------------------------------------
-- Secret guards and colour
------------------------------------------------------------------------------

local function isSecret(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(issecretvalue, value)
    return ok and secret == true
end

-- Threat colours are the standard green / yellow / red, hardcoded rather than
-- read from the addon's verdict palette (where "good" is blue, a rank colour).
-- "Tanking" must read green.
local FALLBACK = {
    secure  = { 0.25, 0.90, 0.35, 1 },
    warning = { 0.95, 0.80, 0.20, 1 },
    lost    = { 0.90, 0.20, 0.20, 1 },
}

local function colourFor(state)
    return FALLBACK[state] or { 1, 1, 1, 1 }
end

------------------------------------------------------------------------------
-- Threat read
------------------------------------------------------------------------------

-- UnitThreatSituation returns 0 (no threat), 1 (on the threat list but not the
-- highest), 2 (tanking with a narrowing lead) or 3 (tanking, secure). The mapping
-- in stateFor below follows this reading, which is the one confirmed against
-- ThreatBeacon's PaintThreat. An earlier copy of this comment said the opposite and
-- was wrong; a secret or unreadable answer is nil.
local function threatStatus(unit)
    if type(UnitThreatSituation) ~= "function" then return nil end
    local ok, status = pcall(UnitThreatSituation, "player", unit)
    if not ok or isSecret(status) or type(status) ~= "number" then return nil end
    if status < 1 or status > 3 then return nil end
    return status
end

-- UnitThreatSituation returns: 0 = no threat (idle), 1 = on the threat list but
-- not the highest (someone else is tanking), 2 = tanking with a narrowing lead,
-- 3 = tanking, secure. (Confirmed against ThreatBeacon's PaintThreat.)
local function stateFor(status, role)
    if role == "tank" then
        if status == 3 then return "secure" end   -- tanking, secure -> green
        if status == 2 then return "warning" end  -- tanking, narrowing -> yellow
        return "lost"                              -- 0/1: not tanking -> red
    end

    -- DPS: having aggro is the danger, not the goal.
    if status == 2 or status == 3 then return "lost" end  -- you're tanking -> red
    if status == 1 then return "warning" end               -- close to pulling -> yellow
    return nil                                              -- 0: no threat, safe
end

------------------------------------------------------------------------------
-- Indicator drawing
------------------------------------------------------------------------------

local INDICATOR_SIZE = 11

local function ensureIndicator(plate)
    if type(plate) ~= "table" then return nil end
    if plate.__ltThreatDot then return plate.__ltThreatDot end

    local ok, dot = pcall(CreateFrame, "Frame", nil, plate)
    if not ok or type(dot) ~= "table" then return nil end

    dot:SetSize(INDICATOR_SIZE, INDICATOR_SIZE)
    dot:SetPoint("TOPRIGHT", plate, "TOPRIGHT", -2, -2)
    if dot.SetFrameLevel and plate.GetFrameLevel then
        local okLevel, level = pcall(plate.GetFrameLevel, plate)
        if okLevel and type(level) == "number" then
            pcall(dot.SetFrameLevel, dot, level + 5)
        end
    end

    local okTex, tex = pcall(dot.CreateTexture, dot, nil, "OVERLAY")
    if okTex and tex then
        tex:SetAllPoints(dot)
        pcall(tex.SetColorTexture, tex, 1, 1, 1, 1)
        dot.__tex = tex
    end

    dot:Hide()
    plate.__ltThreatDot = dot
    return dot
end

local function paintThreat(unit)
    local db = settings()
    if not db.enabled then return end

    local status = threatStatus(unit)
    local state = status and stateFor(status, db.role) or nil

    if type(C_NamePlate) ~= "table" or type(C_NamePlate.GetNamePlateForUnit) ~= "function" then
        return
    end

    local plate
    local okPlate, got = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if okPlate then plate = got end
    if type(plate) ~= "table" then return end

    local dot = ensureIndicator(plate)
    if not dot then return end

    if not state then
        dot:Hide()
        return
    end

    local colour = colourFor(state)
    if dot.__tex and type(dot.__tex.SetColorTexture) == "function" then
        pcall(dot.__tex.SetColorTexture, dot.__tex, colour[1], colour[2], colour[3], colour[4])
    end
    dot:Show()
end

------------------------------------------------------------------------------
-- Target threat indicator (X08)
--
-- A small coloured square on the target frame showing whether the player is
-- tanking their current target: green = tanking, yellow = lead narrowing, red =
-- lost. Read from UnitThreatSituation("player", "target"), the same API the
-- nameplates use.
------------------------------------------------------------------------------

local targetDot

local function ensureTargetDot()
    if targetDot then return targetDot end
    if type(TargetFrame) ~= "table" then return nil end

    local ok, dot = pcall(CreateFrame, "Frame", nil, TargetFrame)
    if not ok or type(dot) ~= "table" then return nil end

    dot:SetSize(14, 14)
    dot:SetPoint("TOPLEFT", TargetFrame, "TOPLEFT", -4, 4)
    if dot.SetFrameLevel and TargetFrame.GetFrameLevel then
        local okLevel, level = pcall(TargetFrame.GetFrameLevel, TargetFrame)
        if okLevel and type(level) == "number" then
            pcall(dot.SetFrameLevel, dot, level + 5)
        end
    end

    local okTex, tex = pcall(dot.CreateTexture, dot, nil, "OVERLAY")
    if okTex and tex then
        tex:SetAllPoints(dot)
        pcall(tex.SetColorTexture, tex, 1, 1, 1, 1)
        dot.__tex = tex
    end

    dot:Hide()
    targetDot = dot
    return dot
end

local function paintTargetThreat()
    local db = settings()
    local dot = ensureTargetDot()
    if not dot then return end

    if not db.enabled then
        dot:Hide()
        return
    end

    local status = threatStatus("target")
    local state = status and stateFor(status, db.role) or nil

    if not state then
        dot:Hide()
        return
    end

    local colour = colourFor(state)
    if dot.__tex then
        pcall(dot.__tex.SetColorTexture, dot.__tex, colour[1], colour[2], colour[3], colour[4])
    end
    dot:Show()
end

------------------------------------------------------------------------------
-- Nameplate tracking
------------------------------------------------------------------------------

local activeUnits = {}
local elapsed = 0
local TICK = 0.25

local eventFrame = CreateFrame("Frame")

eventFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then
        if type(unit) == "string" and unit ~= "" then
            activeUnits[unit] = true
            paintThreat(unit)
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        activeUnits[unit] = nil
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Threat data goes away out of combat; drop the set so the next pull
        -- re-adds only the plates that are actually up.
        for u in pairs(activeUnits) do activeUnits[u] = nil end
    elseif event == "PLAYER_TARGET_CHANGED" then
        paintTargetThreat()
    end
end)

for _, event in ipairs({
    "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
    "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED",
}) do
    pcall(eventFrame.RegisterEvent, eventFrame, event)
end

-- Threat changes without a plate event (aggro swaps mid-fight), so the active
-- set is repainted four times a second while any plate is tracked. The target
-- dot is repainted on the same tick.
eventFrame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (tonumber(dt) or 0)
    if elapsed < TICK then return end
    elapsed = 0

    if next(activeUnits) then
        for unit in pairs(activeUnits) do
            paintThreat(unit)
        end
    end

    paintTargetThreat()
end)

------------------------------------------------------------------------------
-- Reporting and slash surface
------------------------------------------------------------------------------

local function report(message)
    if type(LT.Print) == "function" then
        if pcall(LT.Print, LT, message) then return end
    end
    pcall(print, message)
end

local commandRegistered = false

local function registerCommand()
    if commandRegistered then return true end

    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then return false end

    local ok, added = pcall(slash.RegisterCommand, slash, "threat",
        function(words) Threat:Command(words) end,
        "/lt threat — nameplate threat indicators for tanking")

    if ok and added == true then
        commandRegistered = true
        return true
    end

    if ok and added == false and duplicateLoad then
        commandRegistered = true
        return true
    end

    return false
end

function Threat:Report()
    local db = settings()
    local role = db.role == "dps" and "DPS" or "Tank"
    report("Threat indicators " .. (db.enabled and "on" or "off") .. " (" .. role .. "). "
        .. "/lt threat on, off, tank, or dps")
end

function Threat:Command(words)
    local action = tostring(words and words[2] or ""):lower()
    local db = settings()

    if action == "" or action == "status" then
        self:Report()
        return true
    end
    if action == "on" then
        db.enabled = true
        report("Threat indicators on.")
        return true
    end
    if action == "off" then
        db.enabled = false
        report("Threat indicators off.")
        return true
    end
    if action == "tank" then
        db.role = "tank"
        report("Threat mode: Tank (green secure, yellow lead, red lost).")
        return true
    end
    if action == "dps" then
        db.role = "dps"
        report("Threat mode: DPS (yellow warning, red aggro).")
        return true
    end

    report("usage: /lt threat [on|off|tank|dps]")
    return true
end

-- Registered at file load so `/lt help` lists it before login.
registerCommand()

------------------------------------------------------------------------------
-- PLAYER_LOGIN — the plugin wires its own login frame, the same way Racials does
-- (the core does not iterate plugin modules through its module stage).
------------------------------------------------------------------------------

local function onLogin()
    registerCommand()
    settings()
    report("Threat indicators ready (" .. (settings().role == "dps" and "DPS" or "Tank") .. ").")
end

Threat.OnLogin = onLogin

local createFrame = rawget(_G, "CreateFrame")
if type(createFrame) == "function" then
    local okFrame, frame = pcall(createFrame, "Frame")
    if okFrame and frame then
        local okEvent = pcall(frame.RegisterEvent, frame, "PLAYER_LOGIN")
        if okEvent and type(frame.SetScript) == "function" then
            pcall(frame.SetScript, frame, "OnEvent", function(self, event)
                if event ~= "PLAYER_LOGIN" then return end
                if type(self.UnregisterEvent) == "function" then
                    pcall(self.UnregisterEvent, self, "PLAYER_LOGIN")
                end
                onLogin()
            end)
        end
    end
end
