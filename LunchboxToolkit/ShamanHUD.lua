--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — ShamanHUD (X03)

    Shaman-only. A small totem timer bar plus the active shield, rebuilt from
    the working ShamanForever addon's mechanism:
      * totems via GetTotemInfo(slot) — client slot order is 1 Fire, 2 Earth,
        3 Water, 4 Air. Our rows show the time-left only: the client totem bar
        already shows icon and name, so this never duplicates it;
      * shield via UnitAura (Lightning / Water / Earth Shield).

    This is the lean core, not a port of ShamanForever's whole HUD: no Ace, no
    profiles, no styling system. The weapon-imbue half already lives in
    ImbueGlow.lua. Every client read is pcall'd and secret-guarded; a missing API
    degrades to an empty row, never an error.

    The whole file returns early on every other class: no table, no frame, no
    events. On a Shaman the frame is built once, stays hidden until at least one
    totem or shield spell is known, and draws through the core's own chrome so
    it matches the rest of the addon.
--------------------------------------------------------------------------]]

if not LunchboxToolkit then return end
local LT = LunchboxToolkit

------------------------------------------------------------------------------
-- Reads
------------------------------------------------------------------------------

local function isSecret(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(issecretvalue, value)
    return ok and secret == true
end

local function isShaman()
    if type(UnitClassBase) == "function" then
        local ok, class = pcall(UnitClassBase, "player")
        if ok and class == "SHAMAN" then return true end
    end
    if type(UnitClass) == "function" then
        local ok, class = pcall(UnitClass, "player")
        if ok and class == "SHAMAN" then return true end
    end
    return false
end

-- The whole module is inert on every other class: no table, no frame, no
-- events, no slash command. Nothing below this line runs for a non-Shaman.
if not isShaman() then return end

local ShamanHUD = {}
LT.ShamanHUD = ShamanHUD

ShamanHUD.VERSION = "0.1.0"

local enabled = true

-- slot -> label order. GetTotemInfo's slot argument is fixed by the client:
-- 1 Fire, 2 Earth, 3 Water, 4 Air.
local TOTEM_SLOTS = { "Fire", "Earth", "Water", "Air" }
local SHIELDS = { "Lightning Shield", "Water Shield", "Earth Shield" }

-- L-7 (T-128): the guide's durations, used for the countdown only when the
-- client's own GetTotemInfo duration is missing or unreadable. Searing is 30-55 s
-- by rank, so the table carries the top rank and the client's rank value always
-- wins when it answers. Everything unlisted keeps the guide's 5-minute fallback.
local TOTEM_DURATIONS = {
    ["magma totem"] = 20,
    ["stoneclaw totem"] = 15,
    ["searing totem"] = 55,
    ["earthbind totem"] = 45,
    ["grounding totem"] = 45,
    ["mana tide totem"] = 12,
}
local DEFAULT_TOTEM_DURATION = 300

local function totemDuration(name)
    if type(name) == "string" then
        local duration = TOTEM_DURATIONS[name:lower()]
        if duration then return duration end
    end
    return DEFAULT_TOTEM_DURATION
end

-- The HUD stays hidden until the character has learned at least one totem or
-- shield spell, and shows as soon as one is known. "Totem" covers every summon
-- spell in the book; the three shield names carry no "Totem" token.
-- KnowsSpellName returns nil when the spellbook is unreadable, and that must
-- not hide the bar forever, so an all-nil answer counts as "show".
local function knowsAnyTotemOrShield()
    local cd = LT.ClassData
    if type(cd) ~= "table" or type(cd.KnowsSpellName) ~= "function" then return true end
    local readable = false
    for _, pattern in ipairs({ "Totem", SHIELDS[1], SHIELDS[2], SHIELDS[3] }) do
        local ok, known = pcall(cd.KnowsSpellName, cd, pattern)
        if ok and known == true then return true end
        if ok and known == false then readable = true end
    end
    if not readable then return true end
    return false
end

-- GetTotemInfo(slot) returns haveTotem, name, startTime, duration, icon for
-- client slot 1 Fire, 2 Earth, 3 Water, 4 Air. The icon may be a texture path
-- (string) or an id (number); only a string is usable.
--
-- UNVERIFIED (2026-11-04): whether these fields come back as secrets in combat
-- has not been confirmed in game yet; /lbp probe totem-secrecy exists to check
-- it. Until the probe runs the guard stays: any secret field makes the whole
-- read "unknown" (nil) so the caller keeps drawing the cached timer instead of
-- blanking the row at the moment the timer matters.
local function totemInfo(slot)
    if type(GetTotemInfo) ~= "function" then return nil end
    local ok, have, name, start, dur, icon = pcall(GetTotemInfo, slot)
    if not ok then return nil end
    if isSecret(have) or isSecret(name) or isSecret(start) or isSecret(dur) then
        return nil
    end
    if have ~= true then return { have = false } end
    return {
        have = true,
        name = type(name) == "string" and name ~= "" and name or nil,
        start = tonumber(start),
        duration = tonumber(dur),
        icon = type(icon) == "string" and icon or nil,
    }
end

-- Last readable state per slot, so a combat read that turns secret still has a
-- start time and duration to count down from. PLAYER_TOTEM_UPDATE (and any other
-- Refresh while the read is readable) refreshes the cache; only a readable
-- "no totem" clears it.
local totemCache = {}

local function slotState(slot)
    local info = totemInfo(slot)
    if info then
        if info.have then
            -- The client's duration wins; the table only fills a missing or
            -- unusable one (L-7), so a short totem never shows the 5-minute default.
            local duration = info.duration
            if not duration or duration <= 0 then duration = totemDuration(info.name) end
            totemCache[slot] = {
                name = info.name,
                icon = info.icon,
                duration = duration,
                start = info.start,
            }
        else
            totemCache[slot] = nil
        end
    end
    return totemCache[slot]
end

local function activeShield()
    if type(UnitAura) ~= "function" then return nil end
    for _, name in ipairs(SHIELDS) do
        local ok, auraName = pcall(UnitAura, "player", name)
        if ok and type(auraName) == "string" and not isSecret(auraName) and auraName ~= "" then
            return name
        end
    end
    return nil
end

------------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------------

local frame

------------------------------------------------------------------------------
-- Look: position, scale and background transparency
--
-- The player keeps the HUD open while levelling, so where it sits, how big it is
-- and how much world it hides are per-character choices. All three are stored on
-- the character and applied whenever the frame is built.
------------------------------------------------------------------------------

local function options()
    local database = LT.Database
    local character = database and database.character
    return type(character) == "table" and character.options or nil
end

local function numberOption(key, fallback, low, high)
    local stored = options()
    local value = type(stored) == "table" and tonumber(stored[key]) or nil
    if not value then value = fallback end
    if value < low then value = low end
    if value > high then value = high end
    return value
end

local chromeFill
local positionApplied = false

-- Scale, then the background alpha. Only the fill is made transparent: the
-- labels and the border stay at full strength so the readout stays legible.
local function applyLook()
    if not frame then return end

    -- The saved spot is applied here as well as in build(): on login the frame
    -- can be created before the character record exists, and then nothing ever
    -- moved it back (player report 2026-11-05: "hud does not stay").
    if not positionApplied then
        local database = LT.Database
        local character = database and database.character
        local placed = type(character) == "table" and character.hudPosition or nil
        if type(placed) == "table" and type(placed.point) == "string" then
            frame:ClearAllPoints()
            pcall(frame.SetPoint, frame, placed.point, UIParent,
                placed.relativePoint or placed.point, placed.x or 0, placed.y or 0)
            positionApplied = true
        end
    end

    if type(frame.SetScale) == "function" then
        pcall(frame.SetScale, frame, numberOption("shamanHudScale", 1, 0.5, 2))
    end

    local fill = chromeFill or frame.__ltBackground
    if fill and type(fill.SetAlpha) == "function" then
        pcall(fill.SetAlpha, fill, numberOption("shamanHudAlpha", 0.9, 0.1, 1))
    end
end

function ShamanHUD:ApplyLook()
    build()
    applyLook()
end

-- Locked is the fighting state: no mouse, no drag, no panel. The cog toggles it
-- and the choice is per character.
function ShamanHUD:IsUnlocked()
    local stored = options()
    return type(stored) == "table" and stored.shamanHudUnlocked == true
end

function ShamanHUD:ApplyUnlock()
    if not frame then return end
    local unlocked = self:IsUnlocked()

    if type(frame.EnableMouse) == "function" then
        pcall(frame.EnableMouse, frame, unlocked)
    end
    local panel = frame.settingsPanel
    if panel then
        if unlocked then panel:Show() else panel:Hide() end
    end
end

function ShamanHUD:ToggleUnlock()
    local stored = options()
    if type(stored) ~= "table" then return end
    stored.shamanHudUnlocked = not (stored.shamanHudUnlocked == true)
    self:ApplyUnlock()
    LT:Print("Totem HUD " .. (stored.shamanHudUnlocked and "unlocked: drag it, sliders below."
        or "locked."))
end

local function tint(label, key)
    local palette = LT.Palette
    if type(palette) ~= "table" or type(palette.Colour) ~= "function" then return label end
    local ok, colour = pcall(palette.Colour, palette, key)
    if ok and type(colour) == "table" and label and type(label.SetTextColor) == "function" then
        label:SetTextColor(colour[1], colour[2], colour[3])
    end
    return label
end

local totemRows = {}

local function build()
    if frame then return frame end

    frame = CreateFrame("Frame", "LunchboxToolkitShamanHUD", UIParent)
    -- Wider than the old 200 so the longest cue ("your totems are behind you -
    -- Totemic Recall refunds 25%") stays inside the frame on one line.
    frame:SetSize(340, 212)
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -120)
    frame:SetFrameStrata("MEDIUM")
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        -- Only an unlocked HUD moves; a locked one lets the mouse through so it
        -- never eats a click while the player is fighting.
        if not ShamanHUD:IsUnlocked() then return end
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local database = LT.Database
        local character = database and database.character
        if type(character) ~= "table" then return end
        if type(self.GetPoint) ~= "function" then return end
        local ok, point, _, relativePoint, x, y = pcall(self.GetPoint, self, 1)
        if not ok or type(point) ~= "string" then return end
        character.hudPosition = {
            point = point,
            relativePoint = relativePoint or point,
            x = x or 0,
            y = y or 0,
        }
        positionApplied = true
    end)

    chromeFill = nil
    if LT.Chrome and type(LT.Chrome.Window) == "function" then
        local ok, chrome = pcall(LT.Chrome.Window, frame)
        if ok and type(chrome) == "table" then chromeFill = chrome.fill end
    end
    if not chromeFill then
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.04, 0.04, 0.04, 0.9)
        frame.__ltBackground = bg
    end

    -- Where the player last dragged it, then the stored scale and alpha.
    positionApplied = false
    frame:SetClampedToScreen(true)
    applyLook()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("Totems")
    tint(title, "brand")

    -- The cog unlocks the HUD: drag, and the two sliders appear beneath it.
    local cog = CreateFrame("Button", nil, frame)
    cog:SetSize(18, 18)
    cog:SetPoint("TOPRIGHT", -8, -5)
    local cogIcon = cog:CreateTexture(nil, "ARTWORK")
    if cogIcon then
        cogIcon:SetAllPoints()
        if type(cogIcon.SetTexture) == "function" then
            pcall(cogIcon.SetTexture, cogIcon, "Interface\\Icons\\INV_Misc_Gear_01")
        end
    end
    cog:SetScript("OnClick", function() ShamanHUD:ToggleUnlock() end)
    frame.cog = cog

    local panel = CreateFrame("Frame", nil, frame)
    panel:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -6)
    panel:SetSize(324, 68)
    local panelBg = panel:CreateTexture(nil, "BACKGROUND")
    if panelBg then
        panelBg:SetAllPoints()
        panelBg:SetColorTexture(0.02, 0.02, 0.02, 0.9)
    end
    frame.settingsPanel = panel

    local ui = LT.UI
    local function addSliderRow(offsetY, text, key, low, high, fallback)
        local label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", 8, offsetY)
        label:SetText(text)

        local valueText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        valueText:SetPoint("TOPRIGHT", -8, offsetY)
        local current = numberOption(key, fallback, low, high)
        valueText:SetText(string.format("%.2f", current))

        if ui and type(ui.MakeSlider) == "function" then
            local slider = ui:MakeSlider(panel, low, high, 0.05, current, function(value)
                valueText:SetText(string.format("%.2f", value))
                local stored = options()
                if type(stored) == "table" then stored[key] = value end
                applyLook()
            end)
            if slider then
                slider:SetPoint("TOPLEFT", 8, offsetY - 16)
            end
        end
    end

    addSliderRow(-6, "Size", "shamanHudScale", 0.5, 1.6, 1)
    addSliderRow(-38, "Opacity", "shamanHudAlpha", 0.1, 1, 0.9)

    local y = -30
    for i = 1, 4 do
        local row = CreateFrame("Frame", nil, frame)
        row:SetPoint("TOPLEFT", 10, y)
        row:SetSize(320, 18)

        local label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", 0, 0)
        label:SetText(TOTEM_SLOTS[i] .. ":")
        row.label = label

        local time = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        time:SetPoint("RIGHT", 0, 0)
        time:SetJustifyH("RIGHT")
        row.time = time

        totemRows[i] = row
        y = y - 22
    end

    local shield = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    shield:SetPoint("TOPLEFT", 10, y)
    shield:SetText("")
    frame.shield = shield

    -- L-6 and L-7 readouts, all inside the frame: the cast clock, the combat
    -- mana line, the once-per-fight melee prompt and the totem alert/cue.
    local function line(offset)
        local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("TOPLEFT", 10, offset)
        text:SetJustifyH("LEFT")
        text:SetText("")
        return text
    end

    frame.clock = line(y - 18)
    frame.mana = line(y - 34)
    frame.prompt = line(y - 50)
    frame.alert = line(y - 66)

    -- The Recall cue is the longest line; wrap defensively on a client that has
    -- FontString:SetWordWrap, so it can never spill outside the 340 px frame.
    if type(frame.alert.SetWordWrap) == "function" then
        pcall(frame.alert.SetWordWrap, frame.alert, true)
    end
    if type(frame.alert.SetWidth) == "function" then
        pcall(frame.alert.SetWidth, frame.alert, 320)
    end

    ShamanHUD:ApplyUnlock()
    frame:Hide()
    return frame
end

-- Timer-only rows: the client's own totem bar shows the icon and name, so this
-- frame never duplicates them. When the client's MultiCastActionBarFrame exists
-- the frame sits just above it; otherwise it keeps its saved/dragged position.
-- The client frame is only read, never hidden or reparented.
local anchoredToBar = false

local function anchorAboveClientBar()
    if anchoredToBar or not frame then return end
    local bar = rawget(_G, "MultiCastActionBarFrame")
    if not bar or type(bar.SetPoint) ~= "function" then return end
    frame:ClearAllPoints()
    local ok = pcall(frame.SetPoint, frame, "BOTTOM", bar, "TOP", 0, 4)
    if ok then
        anchoredToBar = true
    else
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -120)
    end
end

------------------------------------------------------------------------------
-- Refresh
------------------------------------------------------------------------------

local function remainingSeconds(start, duration, now)
    if not start or not duration then return nil end
    if not now then
        if type(GetTime) ~= "function" then return nil end
        local ok, value = pcall(GetTime)
        if not ok then return nil end
        now = tonumber(value)
    end
    if not now then return nil end
    return (start + duration) - now
end

local function remainingText(start, duration)
    local left = remainingSeconds(start, duration)
    if not left then return "" end
    if left < 0 then left = 0 end
    return string.format("%.0fs", left)
end

-- The stored switch is the authority: the bar refreshes twice a second, so a
-- settings row only has to write the option and this reads it on the next tick.
-- `enabled` stays as the in-session override that /lt shamanhud on|off uses.
local function optionOn()
    local db = LT.Database
    if type(db) == "table" and type(db.GetOptions) == "function" then
        local ok, options = pcall(db.GetOptions, db)
        if ok and type(options) == "table" and options.shamanTotemBar == false then
            return false
        end
    end
    return enabled
end

------------------------------------------------------------------------------
-- L-6 / L-7 switches and reads (T-127, T-128)
------------------------------------------------------------------------------

-- Both switches are additive keys in Database.defaultOptions and default to
-- false. A missing Database, a failed read or an absent key all mean "off":
-- this file never assumes a key exists.
local function featureOn(key)
    local db = LT.Database
    if type(db) ~= "table" or type(db.GetOptions) ~= "function" then return false end
    local ok, options = pcall(db.GetOptions, db)
    if ok and type(options) == "table" then return options[key] == true end
    return false
end

local function safeNumber(value)
    if isSecret(value) then return nil end
    local ok, number = pcall(tonumber, value)
    if ok then return number end
    return nil
end

local function currentTime()
    if type(GetTime) ~= "function" then return nil end
    local ok, now = pcall(GetTime)
    if not ok then return nil end
    return safeNumber(now)
end

-- PLAYER_REGEN_DISABLED/ENABLED is the fallback; the two client calls are asked
-- first, so a missed event cannot leave the combat flag stuck.
local eventInCombat = false

local function inCombat()
    if type(InCombatLockdown) == "function" then
        local ok, locked = pcall(InCombatLockdown)
        if ok then return locked == true end
    end
    if type(UnitAffectingCombat) == "function" then
        local ok, fighting = pcall(UnitAffectingCombat, "player")
        if ok then return fighting == true end
    end
    return eventInCombat
end

local function targetHealthPercent()
    if type(UnitHealth) ~= "function" or type(UnitHealthMax) ~= "function" then return nil end
    local okHealth, health = pcall(UnitHealth, "target")
    local okMax, maximum = pcall(UnitHealthMax, "target")
    if not okHealth or not okMax then return nil end
    health, maximum = safeNumber(health), safeNumber(maximum)
    if not health or not maximum or maximum <= 0 then return nil end
    return (health / maximum) * 100
end

-- Out of combat only: in combat the power value is secret on Forever, so the
-- number is dropped and the line keeps its place ("keep any bar" — this frame
-- has no bar, so the em dash is the whole readout).
local function manaLine(fighting)
    if fighting then return "Mana: —" end
    if type(UnitPower) ~= "function" or type(UnitPowerMax) ~= "function" then return "" end
    local okPower, power = pcall(UnitPower, "player", 0)
    local okMax, maximum = pcall(UnitPowerMax, "player", 0)
    if not okPower or not okMax then return "" end
    power, maximum = safeNumber(power), safeNumber(maximum)
    if not power or not maximum or maximum <= 0 then return "" end
    if power >= maximum then return "Mana: full" end
    return string.format("Mana: %d%%", math.floor((power / maximum) * 100 + 0.5))
end

-- L-6: the clock starts on the last spell cast and counts to 5 s. The melee
-- prompt is cleared on PLAYER_REGEN_DISABLED, so it is once per fight.
local cast = { last = nil, promptShown = false, promptUntil = 0 }
local PROMPT_TEXT = "let it die to melee - regen starts at 5 s"

local function clockLine(now)
    if not cast.last or not now then return "" end
    local elapsed = now - cast.last
    if elapsed >= 5 then return "mana regen started" end
    local left = math.ceil(5 - elapsed)
    if left < 1 then left = 1 end
    return string.format("regen in %ds", left)
end

local function promptLine(now)
    if not now then return "" end
    if cast.promptShown then
        if now < cast.promptUntil then return PROMPT_TEXT end
        return ""
    end
    if not inCombat() or not cast.last then return "" end
    if (now - cast.last) > 5 then return "" end
    local health = targetHealthPercent()
    if health and health < 30 then
        cast.promptShown = true
        cast.promptUntil = now + 8
        return PROMPT_TEXT
    end
    return ""
end

-- Position reads for the Totemic Recall cue. C_Map gives a map id and, when the
-- world conversion exists, real yards; the legacy global gives normalized
-- coordinates only, and then the fallback compares the fraction moved. Every
-- route degrades to "no cue" rather than an error.
local function readXY(a, b)
    local x, y = safeNumber(a), safeNumber(b)
    if x and y then return x, y end

    local value = a
    if value == nil or isSecret(value) then return nil end
    local kind = type(value)
    if kind ~= "table" and kind ~= "userdata" then return nil end

    -- Vector2D (C_Map returns one for world positions) may be userdata, so the
    -- method access itself is guarded rather than assuming a table.
    local okMethod, method = pcall(function() return value.GetXY end)
    if okMethod and type(method) == "function" then
        local ok, gx, gy = pcall(method, value)
        if ok then
            gx, gy = safeNumber(gx), safeNumber(gy)
            if gx and gy then return gx, gy end
        end
    end

    local okX, fx = pcall(function() return value.x end)
    local okY, fy = pcall(function() return value.y end)
    if okX and okY then
        fx, fy = safeNumber(fx), safeNumber(fy)
        if fx and fy then return fx, fy end
    end
    return nil
end

local function readPlayerPosition()
    if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function"
        and type(C_Map.GetPlayerMapPosition) == "function" then
        local okID, mapID = pcall(C_Map.GetBestMapForUnit, "player")
        if okID and mapID then
            local ok, a, b = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
            if ok then
                local x, y = readXY(a, b)
                if x and not (x == 0 and y == 0) then
                    return { mapID = mapID, x = x, y = y }
                end
            end
        end
    end
    if type(GetPlayerMapPosition) == "function" then
        local ok, a, b = pcall(GetPlayerMapPosition, "player")
        if ok then
            local x, y = readXY(a, b)
            if x and not (x == 0 and y == 0) then
                return { mapID = nil, x = x, y = y }
            end
        end
    end
    return nil
end

local function worldPosition(pos)
    if not pos or pos.mapID == nil then return nil end
    if type(C_Map) ~= "table" or type(C_Map.GetWorldPosFromMapPos) ~= "function" then return nil end
    if type(CreateVector2D) ~= "function" then return nil end
    local okVector, vector = pcall(CreateVector2D, pos.x, pos.y)
    if not okVector or not vector then return nil end
    local ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, pos.mapID, vector)
    if not ok or continent == nil or world == nil then return nil end
    local wx, wy = readXY(world)
    if not wx then return nil end
    return continent, wx, wy
end

local function yardDistance(a, b)
    local continent, ax, ay = worldPosition(a)
    if not continent then return nil end
    local other, bx, by = worldPosition(b)
    if not other or other ~= continent then return nil end
    local dx, dy = bx - ax, by - ay
    return math.sqrt(dx * dx + dy * dy)
end

-- L-7: one expiry warning per totem (never per tick), then one Recall cue when
-- the player walks away from the set. Both are drawn on the alert line.
local warnedStart = {}
local seenStart = {}
local alertText, alertUntil = "", 0
local recallText, recallUntil = "", 0
local dropPosition, recallCued = nil, false
local RECALL_TEXT = "your totems are behind you - Totemic Recall refunds 25%"
local WARN_SECONDS = 30
local RECALL_YARDS = 40
local RECALL_REARM_YARDS = 20
local RECALL_MAP_FRACTION = 0.03

local function refreshTotemAlert(states, now)
    if not now then return "" end

    local any = false
    local newSet = false
    for i = 1, 4 do
        local entry = states[i]
        if entry and entry.start then
            any = true
            if seenStart[i] ~= entry.start then
                seenStart[i] = entry.start
                newSet = true
            end
            local left = remainingSeconds(entry.start, entry.duration, now)
            if left and left > 0 and left < WARN_SECONDS and warnedStart[i] ~= entry.start then
                warnedStart[i] = entry.start
                local name = entry.name or (TOTEM_SLOTS[i] .. " Totem")
                alertText = name .. " expires in " .. math.ceil(left) .. "s"
                alertUntil = now + 5
            end
        elseif entry then
            any = true
        else
            seenStart[i] = nil
            warnedStart[i] = nil
        end
    end

    if not any then
        dropPosition, recallCued = nil, false
    else
        local here = readPlayerPosition()
        if newSet or not dropPosition then dropPosition = here end
        if here and dropPosition and here.mapID == dropPosition.mapID then
            local yards = yardDistance(dropPosition, here)
            if yards then
                if recallCued and yards < RECALL_REARM_YARDS then recallCued = false end
                if not recallCued and yards > RECALL_YARDS then
                    recallCued = true
                    recallText = RECALL_TEXT
                    recallUntil = now + 8
                end
            else
                local dx, dy = here.x - dropPosition.x, here.y - dropPosition.y
                local moved = math.sqrt(dx * dx + dy * dy)
                if recallCued and moved < RECALL_MAP_FRACTION / 3 then recallCued = false end
                if not recallCued and moved > RECALL_MAP_FRACTION then
                    recallCued = true
                    recallText = RECALL_TEXT
                    recallUntil = now + 8
                end
            end
        end
    end

    if now < recallUntil then return recallText end
    if now < alertUntil then return alertText end
    return ""
end

local spellsKnown = false

function ShamanHUD:Refresh()
    if not optionOn() then
        if frame then frame:Hide() end
        return
    end
    if not spellsKnown then spellsKnown = knowsAnyTotemOrShield() end
    if not spellsKnown then
        if frame then frame:Hide() end
        return
    end

    build()
    frame:Show()
    -- The client-bar anchor is only the starting place for a HUD the player has
    -- never moved. Once a position is applied this must not run again: it ran on
    -- every refresh and snapped the frame back after each reload (report
    -- 2026-11-05).
    if not positionApplied then anchorAboveClientBar() end

    local states = {}
    for i = 1, 4 do
        local entry = slotState(i)
        states[i] = entry
        local row = totemRows[i]
        if row then
            if entry then
                -- A cached start+duration keeps counting through a combat read
                -- that turned secret; the dash only means nothing was cached.
                row.time:SetText(remainingText(entry.start, entry.duration))
            else
                row.time:SetText("—")
            end
        end
    end

    local shield = activeShield()
    if frame.shield then
        frame.shield:SetText(shield and ("Shield: " .. shield) or "Shield: none")
        tint(frame.shield, shield and "good" or "muted")
    end

    local now = currentTime()
    local clockOn = featureOn("shamanCastClock")
    local alertOn = featureOn("shamanTotemAlert")
    local fighting = inCombat()

    if frame.clock then
        frame.clock:SetText(clockOn and clockLine(now) or "")
        tint(frame.clock, "good")
    end
    if frame.mana then
        frame.mana:SetText(clockOn and manaLine(fighting) or "")
        tint(frame.mana, "muted")
    end
    if frame.prompt then
        frame.prompt:SetText(clockOn and promptLine(now) or "")
        tint(frame.prompt, "caution")
    end
    if frame.alert then
        frame.alert:SetText(alertOn and refreshTotemAlert(states, now) or "")
        tint(frame.alert, "caution")
    end
end

-- UNIT_SPELLCAST_SUCCEEDED carries (unit, castGUID, spellID) on newer clients
-- and (unit, spellName, spellRank, spellID) on older ones; both shapes are read
-- here. Auto-attacks never fire this event; the name filter is only for a
-- client that reports the plain Attack action as a spell.
function ShamanHUD:OnSpellcast(unit, a, b, c)
    if unit ~= "player" then return end
    local spellID
    if type(c) == "number" then spellID = c
    elseif type(b) == "number" then spellID = b end
    local name
    if spellID and type(GetSpellInfo) == "function" then
        local ok, spellName = pcall(GetSpellInfo, spellID)
        if ok and type(spellName) == "string" and not isSecret(spellName) then name = spellName end
    end
    if not name and type(a) == "string" and not isSecret(a) then name = a end
    if not name or name == "" then return end
    local lower = name:lower()
    if lower == "attack" or lower == "auto attack" or lower == "auto shot" or lower == "shoot" then
        return
    end
    local now = currentTime()
    if not now then return end
    cast.last = now
end

function ShamanHUD:SetEnabled(on)
    enabled = (on ~= false)

    -- One switch, two doors: the Settings row and /lt shamanhud both write the
    -- same stored option, so the next reload agrees with what is on screen.
    local db = LT.Database
    if type(db) == "table" and type(db.GetOptions) == "function" then
        local ok, options = pcall(db.GetOptions, db)
        if ok and type(options) == "table" then options.shamanTotemBar = enabled end
    end

    self:Refresh()
end

------------------------------------------------------------------------------
-- Driver
------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local elapsed = 0

eventFrame:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (tonumber(dt) or 0)
    if elapsed < 0.5 then return end
    elapsed = 0
    if ShamanHUD then ShamanHUD:Refresh() end
end)

eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    -- UNIT_AURA is registered without a filter (RegisterUnitEvent is not on
    -- every supported client), so every other unit's auras are dropped here.
    if event == "UNIT_AURA" then
        if arg1 ~= "player" then return end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if ShamanHUD then pcall(ShamanHUD.OnSpellcast, ShamanHUD, arg1, arg2, arg3, arg4) end
        return
    elseif event == "PLAYER_REGEN_DISABLED" then
        eventInCombat = true
        cast.promptShown = false
        cast.promptUntil = 0
        return
    elseif event == "PLAYER_REGEN_ENABLED" then
        eventInCombat = false
        return
    elseif event ~= "PLAYER_LOGIN" and event ~= "PLAYER_ENTERING_WORLD"
        and event ~= "PLAYER_TOTEM_UPDATE" then
        return
    end
    -- PLAYER_TOTEM_UPDATE lands here; Refresh re-reads and caches every slot
    -- while the read is readable.
    if ShamanHUD then ShamanHUD:Refresh() end
end)

for _, event in ipairs({
    "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_TOTEM_UPDATE", "UNIT_AURA",
    "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
}) do
    pcall(eventFrame.RegisterEvent, eventFrame, event)
end

------------------------------------------------------------------------------
-- Slash: /lt shamanhud [on|off]
------------------------------------------------------------------------------

local commandRegistered = false

local function registerCommand()
    if commandRegistered then return true end
    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then return false end
    local ok, added = pcall(slash.RegisterCommand, slash, "shamanhud",
        function(words) ShamanHUD:Command(words) end,
        "/lt shamanhud — Shaman totem bar and shield status")
    if ok and added == true then
        commandRegistered = true
        return true
    end
    return false
end

function ShamanHUD:Report()
    local message = enabled and "Shaman HUD is on (totems + shield)." or "Shaman HUD is off."
    if type(LT.Print) == "function" then
        pcall(LT.Print, LT, message)
    else
        pcall(print, message)
    end
end

function ShamanHUD:Command(words)
    local action = tostring(words and words[2] or ""):lower()

    if action == "scale" or action == "alpha" then
        local key = action == "scale" and "shamanHudScale" or "shamanHudAlpha"
        local low, high = 0.5, 2
        if key == "shamanHudAlpha" then low, high = 0.1, 1 end

        local value = tonumber(words and words[3])
        if not value then
            local current = numberOption(key, key == "scale" and 1 or 0.9, low, high)
            LT:Print("Totem HUD " .. action .. " is " .. tostring(current)
                .. " (/lt shamanhud " .. action .. " " .. tostring(low) .. "-" .. tostring(high) .. ")")
            return true
        end

        if value < low then value = low end
        if value > high then value = high end

        local stored = options()
        if type(stored) == "table" then stored[key] = value end
        self:ApplyLook()
        LT:Print("Totem HUD " .. action .. ": " .. tostring(value))
        return true
    end

    if action == "on" then
        self:SetEnabled(true)
    elseif action == "off" then
        self:SetEnabled(false)
    end
    self:Report()
    return true
end

-- Slash.lua loads after this file in both TOCs, so the first attempt can fail.
-- The retry runs a second later, by which time the whole addon has loaded; without
-- it /lt shamanhud never existed at all.
do
    if not registerCommand() then
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            pcall(C_Timer.After, 1, function() registerCommand() end)
        end
    end
end
