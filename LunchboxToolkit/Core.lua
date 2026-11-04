--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Core
    Namespace, logging, event bus, player context and module bootstrap.

    Target client: World of Warcraft: Forever — Interface 16001.
    API surface verified against a working Forever addon and the player's own
    in-game dump:
      present : C_Item.GetItemStats, C_Item.GetItemInfoInstant,
                C_Item.GetDetailedItemLevelInfo, C_TooltipInfo.GetHyperlink,
                C_PlayerInfo.CanUseItem, C_Container.*, GetCombatRating,
                GetCombatRatingBonus, C_ClassTalents, C_Traits, issecretvalue
      varies  : GetTalentInfo, GetNumTalentTabs — presence varies by build;
                both branches are tried and the one used is reported

    Nothing in this addon invents game mechanics. Where Forever does not expose
    a value, or the addon has no defensible model for it, that is reported as a
    limitation instead of a number.
--------------------------------------------------------------------------]]

LunchboxToolkit = LunchboxToolkit or {}
local LT = LunchboxToolkit

LT.name        = "LunchboxToolkit"    -- must match the TOC/folder name for ADDON_LOADED
LT.displayName = "Lunchbox Toolkit"
LT.version     = "1.0.0"
LT.apiVersion  = 1

-- Confirmed by the player: Forever's level cap is 60.
LT.MAX_LEVEL = 60   -- Forever cap 1.60.1; the December raids are level 60, so do not raise

LT.DEBUG = false

-- Provenance markers. Every weight, divisor and cap the addon carries states
-- where it came from, so provisional data is never presented as authoritative.
LT.SOURCE_BUNDLED  = "bundled"     -- shipped with the addon, unvalidated
LT.SOURCE_MEASURED = "measured"    -- read out of the client in game
LT.SOURCE_MANUAL   = "manual"      -- typed in by the player

-- Chat prefixes. The colour is looked up from Palette at call time, not
-- captured in an upvalue here: Palette.lua loads immediately after this file, so
-- a value captured at load would freeze whatever the palette held then. Keeping
-- the lookup live is what lets one table own the colour.
local function coloured(key, text)
    local palette = LT.Palette
    if palette and palette.Code then
        return palette:Code(key) .. tostring(text) .. "|r"
    end
    return tostring(text)
end

function LT:Print(message)      print(coloured("brand", "Lunchbox Toolkit: ") .. tostring(message)) end
function LT:Warn(message)       print(coloured("caution", "Lunchbox Toolkit (warning): ") .. tostring(message)) end
function LT:Error(message)      print(coloured("stop", "Lunchbox Toolkit (error): ") .. tostring(message)) end
function LT:Debug(message)
    if self.DEBUG then
        print(coloured("debug", "Lunchbox Toolkit (debug): ") .. tostring(message))
    end
end

------------------------------------------------------------------------------
-- Utilities
------------------------------------------------------------------------------

-- Forever marks some combat values as restricted. Never touch one directly:
-- arithmetic on a secret value raises an error on the modern client.
if type(issecretvalue) ~= "function" then
    function LT:IsSecret() return false end
else
    function LT:IsSecret(value)
        local ok, result = pcall(issecretvalue, value)
        if not ok then return false end
        return result == true
    end
end

-- One reader for a client number: nil means "no number", never 0. A restricted
-- value and anything that is not a number or a numeric string come back nil, so
-- no caller ever does arithmetic on a value this client will not hand over.
function LT:Number(value)
    if value == nil then return nil end
    if self:IsSecret(value) then return nil end
    local kind = type(value)
    if kind == "number" then return value end
    if kind == "string" then return tonumber(value) end
    return nil
end

-- The four edges of a frame, each read through Number so a restricted or absent
-- value becomes nil instead of an error. nil when any one edge is unknown.
function LT:Rect(frame)
    if type(frame) ~= "table" then return nil end
    if type(frame.GetLeft) ~= "function" or type(frame.GetBottom) ~= "function"
        or type(frame.GetWidth) ~= "function" or type(frame.GetHeight) ~= "function" then
        return nil
    end

    local left   = self:Number(self:Safe(frame.GetLeft, frame))
    local bottom = self:Number(self:Safe(frame.GetBottom, frame))
    local width  = self:Number(self:Safe(frame.GetWidth, frame))
    local height = self:Number(self:Safe(frame.GetHeight, frame))
    if left == nil or bottom == nil or width == nil or height == nil then return nil end

    return { left = left, bottom = bottom, width = width, height = height }
end

-- A diagnostic line. LT.DEBUG is the dev build's switch; debugChat is the
-- per-character option. The option is read defensively because Diag can run
-- before the Database module has initialised, and that must print nothing
-- rather than raise.
function LT:Diag(message)
    local on = self.DEBUG == true
    if not on then
        local db = self.Database
        if type(db) == "table" and type(db.GetOptions) == "function" then
            local ok, options = pcall(db.GetOptions, db)
            on = ok and type(options) == "table" and options.debugChat == true
        end
    end
    if on then
        self:Print(message)
    end
end

-- The class check every module asks for, so the token comparison lives once.
function LT:IsClass(token)
    local player = self.player
    return type(player) == "table" and player.class == token
end

function LT:Safe(fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    if not ok then
        return nil, tostring(a)
    end
    return a, b, c, d
end

function LT:Copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do
        out[key] = self:Copy(item)
    end
    return out
end

function LT:Round(value, places)
    local number = tonumber(value)
    if not number then return nil end
    local factor = 10 ^ (places or 2)
    if number >= 0 then
        return math.floor(number * factor + 0.5) / factor
    end
    return -math.floor(-number * factor + 0.5) / factor
end

function LT:FormatNumber(value, places)
    local number = tonumber(value)
    if not number then return "n/a" end
    return string.format("%." .. tostring(places or 2) .. "f", number)
end

function LT:FormatSigned(value, places)
    local number = tonumber(value)
    if not number then return "n/a" end
    local text = self:FormatNumber(math.abs(number), places)
    if number > 0 then return "+" .. text end
    if number < 0 then return "-" .. text end
    return text
end

-- A stable, readable key for a stat channel: "attackPower" -> "Attack Power".
function LT:Label(stat)
    local labels = self.StatLabels
    return (labels and labels[stat]) or tostring(stat)
end

------------------------------------------------------------------------------
-- Event bus
--
-- Modules and plugins talk to each other through this rather than by reaching
-- into each other's files. Every listener is pcall'd, so a broken listener can
-- never take the core down with it.
------------------------------------------------------------------------------

LT.listeners = {}
LT.listenerErrors = {}

function LT:On(eventName, fn, owner)
    if type(eventName) ~= "string" or type(fn) ~= "function" then return nil end
    self.listeners[eventName] = self.listeners[eventName] or {}
    table.insert(self.listeners[eventName], { fn = fn, owner = owner or "anonymous" })
    return fn
end

function LT:Fire(eventName, payload)
    local list = self.listeners[eventName]
    if not list then return end
    for _, entry in ipairs(list) do
        local ok, err = pcall(entry.fn, payload)
        if not ok then
            self.listenerErrors[eventName] = self.listenerErrors[eventName] or {}
            table.insert(self.listenerErrors[eventName], tostring(err))
            self:Debug("listener failed on " .. tostring(eventName) .. ": " .. tostring(err))
        end
    end
end

-- Named events used across the core.
LT.EVENT_LEVEL        = "LEVEL_CHANGED"
LT.EVENT_BUILDS       = "BUILDS_CHANGED"
LT.EVENT_PROFILE      = "PROFILE_CHANGED"
LT.EVENT_WEIGHTS      = "EFFECTIVE_WEIGHTS_REBUILT"
LT.EVENT_GEARSET      = "GEARSET_CHANGED"
LT.EVENT_PLUGINS      = "PLUGINS_CHANGED"
LT.EVENT_ITEM_REQUEST = "ITEM_SCORE_REQUEST"

------------------------------------------------------------------------------
-- Player context
------------------------------------------------------------------------------

LT.player = { class = "UNKNOWN", className = "Unknown", race = "UNKNOWN", level = 1,
    faction = "UNKNOWN", factionName = "Unknown" }

function LT:GetPlayerKey()
    local name = UnitName("player") or "Unknown"
    local realm = GetRealmName() or "Unknown"
    return tostring(name) .. "-" .. tostring(realm)
end

function LT:DetectPlayer()
    local className, classToken = UnitClass("player")
    local raceName, raceToken = UnitRace("player")
    local faction, factionName = UnitFactionGroup("player")

    self.player.class     = classToken or "UNKNOWN"
    self.player.className = className or "Unknown"
    self.player.race      = raceToken or "UNKNOWN"
    self.player.raceName  = raceName or "Unknown"
    self.player.level     = tonumber(UnitLevel("player")) or 1
    self.player.name      = UnitName("player") or "Unknown"
    self.player.realm     = GetRealmName() or "Unknown"

    -- Only ever "Horde" or "Alliance" (the second return is the localised name).
    -- Kept apart from race: the trainer tables are per side, not per race.
    self.player.faction     = faction or "UNKNOWN"
    self.player.factionName = factionName or "Unknown"

    return self.player
end

-- Single entry point for "something about the character changed". Modules
-- subscribe to the fired events instead of being called by name.
function LT:Refresh(reason)
    local previousLevel = self.player.level
    self:DetectPlayer()

    if self.player.level ~= previousLevel then
        self:Fire(self.EVENT_LEVEL, { level = self.player.level, previous = previousLevel })
    end

    if self.Builds and self.player.class ~= "UNKNOWN" then
        self.Builds:EnsureForClass(self.player.class)
    end

    if self.Profiles then
        self.Profiles:Invalidate()
    end

    self:Fire(self.EVENT_BUILDS, { reason = reason })
    self:Debug("refreshed: " .. tostring(reason or "unknown"))

    if self.UI and self.UI.Refresh then
        self.UI:Refresh()
    end
end

------------------------------------------------------------------------------
-- Module bootstrap
--
-- Load order is the TOC's job; initialisation order is this list's job. Each
-- module registers itself in LT.Modules and optionally exposes Initialize /
-- OnPlayerLogin / OnEnterWorld.
--
-- Every module that registers in LT.Modules is named here exactly once, and no
-- module appends itself at run time. This list is the only place the order is
-- written down. A name whose module has no stage method is inert here and
-- exists so the Debug page ("Modules loaded") lists it; a new module goes in at
-- its .toc position. Listing TalentsProbe here is why that file needs no login
-- frame of its own; Estimates keeps its own frame, whose handlers are
-- idempotent, so the stage and the frame cannot register the command twice.
------------------------------------------------------------------------------

LT.Modules = {}
LT.ModuleOrder = {
    "Database",
    "Palette",
    "Chrome",
    "Skins",
    "Levels",
    "ClassData",
    "TalentValues",
    "Usability",
    "ClassPacks",
    "PrivateProfiles",
    "Builds",
    "Profiles",
    "GearSets",
    "Caps",
    "CapAdjustments",
    "Imbues",
    "SpecAdvisor",
    "DirectionArrow",
    "TalentValuation",
    "TalentFrameGlow",
    "ItemStats",
    "Score",
    "Compare",
    "GearCheck",
    "PluginAPI",
    "BuffMonitor",   -- replaces ClassTools in dev fork
    "Trackers",
    "SelfTest",
    "TooltipPanel",
    "Tooltip",
    "QuestRewards",
    "DropHint",
    "UI",
    "Wizard",
    "Minimap",
    "Legend",
    "Slash",
    "BagSort",
    "Spellbook",
    "Estimates",
    "Leaderboard",
    "TalentsProbe",
    -- Registered for the Debug page's module list only. None of the five needs
    -- a stage method: GearPopup, BestSetup and Toasts wire their own listeners
    -- at load, CharMarks:Initialize is idempotent, and Played:OnLogin is guarded
    -- so the login stage and the hooked PLAYER_LOGIN cannot both run it.
    "GearPopup",
    "BestSetup",
    "CharMarks",
    "Toasts",
    "Played",
}

function LT:RunModuleStage(stage, ...)
    for _, name in ipairs(self.ModuleOrder) do
        local module = self.Modules[name]
        local fn = module and module[stage]
        if type(fn) == "function" then
            local ok, err = pcall(fn, module, ...)
            if not ok then
                self:Error(name .. "." .. stage .. " failed: " .. tostring(err))
            end
        end
    end
end

function LT:IsModuleLoaded(name)
    return self.Modules[name] ~= nil
end

-- Which loaded bag replacement owns the bag frames, if any. LBTK annotates the
-- client's own combined bags, so a replacement hides that work; the login
-- diagnostic names it instead of the addon going quietly dark (T-132).
local function loadedBagReplacement()
    local lookup
    if type(C_AddOns) == "table" and type(C_AddOns.IsAddOnLoaded) == "function" then
        lookup = C_AddOns.IsAddOnLoaded
    elseif type(IsAddOnLoaded) == "function" then
        lookup = IsAddOnLoaded
    end
    if lookup == nil then return nil end

    for _, name in ipairs({ "Bagnon", "Baganator" }) do
        local ok, loaded = pcall(lookup, name)
        if ok and loaded == true then return name end
    end
    return nil
end

------------------------------------------------------------------------------
-- Client events
------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
LT.frame = frame

local watched = {
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_LEVEL_UP",
    "UNIT_INVENTORY_CHANGED",
    "PLAYER_EQUIPMENT_CHANGED",
    "PLAYER_TALENT_UPDATE",
    "CHARACTER_POINTS_CHANGED",
    "SPELLS_CHANGED",
}

-- RegisterEvent raises on an event this client does not know, so every one is
-- pcall'd rather than assumed.
for _, event in ipairs(watched) do
    pcall(frame.RegisterEvent, frame, event)
end
pcall(frame.RegisterEvent, frame, "ADDON_LOADED")

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == LT.name and LT.Database then
            -- Dev-store adoption was removed: no TOC declares that variable.
            LT.Database:Initialize()
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        LT:DetectPlayer()
        if LT.Database and not LT.Database.character then
            LT.Database:Initialize()
        end
        LT:RunModuleStage("Initialize")
        -- Decision 1: register buff definitions before OnPlayerLogin so
        -- BuffMonitor:CheckAll() finds them on the very first call.
        if LT.ClassData and LT.ClassData.RegisterBuffDefs then
            pcall(LT.ClassData.RegisterBuffDefs, LT.ClassData)
        end
        LT:RunModuleStage("OnPlayerLogin")

        -- One line so an install is never silent. /reload also fires this event,
        -- which is acceptable: it is one line, and it repeats the entry point.
        if LT.Database and LT.Database.GetOptions then
            local options = LT.Database:GetOptions()
            if not (options and options.loginMessage == false) then
                LT:Print("loaded — /lt for options")
            end
        end

        local replacement = loadedBagReplacement()
        if replacement then
            LT:Diag("bag replacement " .. replacement
                .. " owns the bag frames — the upgrade arrow and bag checks will not appear")
        end

        LT:Refresh("PLAYER_LOGIN")
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        LT:RunModuleStage("OnEnterWorld")
        LT:Refresh("PLAYER_ENTERING_WORLD")
        return
    end

    if event == "PLAYER_LEVEL_UP" then
        LT:Refresh("PLAYER_LEVEL_UP")
        LT:Fire("PLAYER_LEVEL_UP", { level = tonumber(arg1) or LT.player.level })
        return
    end

    if event == "PLAYER_TALENT_UPDATE" or event == "CHARACTER_POINTS_CHANGED" then
        LT:Refresh(event)
        LT:Fire("TALENTS_CHANGED", { source = event })
        return
    end

    if event == "SPELLS_CHANGED" then
        LT:Fire("SPELLS_CHANGED", {})
        return
    end

    if event == "UNIT_INVENTORY_CHANGED" and arg1 == "player" then
        LT:Fire("INVENTORY_CHANGED", {})
        return
    end

    if event == "PLAYER_EQUIPMENT_CHANGED" then
        LT:Fire("EQUIPMENT_CHANGED", { slot = arg1 })
    end
end)