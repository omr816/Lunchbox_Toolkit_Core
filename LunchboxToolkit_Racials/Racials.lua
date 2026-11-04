--[[--------------------------------------------------------------------------
    LunchboxToolkit_Racials — racial passives that scale a stat weight

    One rule decides what is registered here: an adjustment may only change
    the *marginal* value of a stat the scorer already prices, and only when
    the number behind it is known. Two passives meet that rule after the
    2026-11-04 launch notes:

      * Tauren Endurance — +5% maximum health (the +2% critical damage and
        healing is gone). Health comes from stamina, so the stamina weight is
        multiplied by 1.05. This is a model: the share of health that comes
        from base rather than stamina is not separated.
      * Human Spirit — +10% Spirit (was 5%), so the spirit weight is
        multiplied by 1.10 for a Human.

    Cap-moving racials go through the core's Caps:RegisterAdjustment, where a
    positive delta *reduces* the cap. Since the October pass removed the
    weapon-specialisation racials (Human sword/mace, Orc axe, Dwarf gun, Troll
    bow and throwing), the only one left is Dwarf Artisan's Precision: +1% hit
    with spells and attacks, which is one point off the hit cap. The old
    weapon-skill entries and their 0.04%-per-skill fallback are deliberately
    gone - registering a cap for a racial that no longer exists would shave a
    cap the player cannot see.

    Deliberately NOT registered (no weight can hold them):
      * flat bonuses (Quickness +1% dodge, Ruthless +1% crit, Wind-Blessed +2%
        haste, the resistance passives) — they do not make a rating point worth
        more, so no weight can hold them;
      * actives (Blood Fury 2 min, Berserking 15 s, Stoneform, War Stomp,
        Read Leyline, Skysight) — an average contribution would need an uptime
        nobody has measured;
      * pet and on-hit effects (Orc Command's +5% pet damage, Undead Touch of
        the Grave's heal) — the scorer prices the player's item stats only.

    Every client read is pcall'd. A missing PluginAPI or slash surface is
    reported once and changes nothing else. The plugin registers at
    PLAYER_LOGIN, exactly once per session; a second copy of the same file
    finds the ids already present and adds nothing.

    The plugin declares no SavedVariables of its own: its settings and the
    registered adjustments live in the core's tables. The one thing it writes
    is the raw UnitRace token, kept account-wide in LunchboxToolkitDB.raceTokens
    as a probe for the unconfirmed Skyborne token (T-65).
--------------------------------------------------------------------------]]

if not LunchboxToolkit then return end
local LT = LunchboxToolkit

-- A second copy of this file in one session is recognised by the module table
-- already being present. It must not re-register, and it must not report the
-- refused slash word as a new problem.
local previousModule = LT.Racials
local duplicateLoad = type(previousModule) == "table"

local Racials = {}
LT.Racials = Racials

Racials.PLUGIN_ID = "lunchbox_racials"
Racials.VERSION = "1.0.0"

------------------------------------------------------------------------------
-- Logging and secret-value guards
------------------------------------------------------------------------------

local function report(message)
    if type(LT.Print) == "function" then
        if pcall(LT.Print, LT, message) then return end
    end
    pcall(print, message)
end

-- Settings -> "Show the login line" is the core's own switch for what appears
-- in chat at login and after /reload. This plugin's registration line is part
-- of that login output, so it follows the same key: a player who turned the
-- line off gets a quiet login here too. Registration itself is untouched, and
-- /lt racials still prints the report on demand.
local function loginLineEnabled()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return true
    end

    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then return true end
    return options.loginMessage ~= false
end

local function loginReport(message)
    if loginLineEnabled() then
        report(message)
    end
end

local function debug(message)
    if type(LT.Debug) == "function" then
        pcall(LT.Debug, LT, message)
    end
end

-- A value the client marks secret must not be compared, formatted or hashed.
-- It is checked before any other operation on the value.
local function isSecret(value)
    if type(LT.IsSecret) == "function" then
        local ok, result = pcall(LT.IsSecret, LT, value)
        return ok and result == true
    end
    if type(issecretvalue) == "function" then
        local ok, result = pcall(issecretvalue, value)
        return ok and result == true
    end
    return false
end

local function readableString(value)
    if isSecret(value) then return nil end
    if type(value) ~= "string" or value == "" then return nil end
    return value
end

------------------------------------------------------------------------------
-- Race keys
--
-- UnitRace returns the race name and the race file/token ("Orc", "Scourge",
-- "NightElf"). ClassData.races mixes key styles ("ORC", "SkyborneAlliance"), so
-- every lookup goes through NormaliseRace first. Both returns are tried, token
-- first. Skyborne has no confirmed token yet: a token containing SKYBORNE is
-- resolved by faction, and the raw token is kept in the probe table below.
------------------------------------------------------------------------------

local RACE_ALIASES = {
    HUMAN    = "HUMAN",
    ORC      = "ORC",
    DWARF    = "DWARF",
    NIGHTELF = "NIGHTELF",
    GNOME    = "GNOME",
    TROLL    = "TROLL",
    TAUREN   = "TAUREN",
    UNDEAD   = "UNDEAD",
    SCOURGE  = "UNDEAD",   -- UnitRace's token for Undead
    FORSAKEN = "UNDEAD",
    DRAENEI  = "DRAENEI",
    -- The two Skyborne versions, keyed as UnitRace reports them in the dev
    -- notes. Skyborne is real on this client; Draenei is not playable here.
    SKYBORNEALLIANCE = "SkyborneAlliance",
    SKYBORNEHORDE    = "SkyborneHorde",
}

-- Which Skyborne entry a token belongs to when the token itself is not one of
-- the two documented names. Only UnitFactionGroup can answer that; with no
-- readable faction the token stays unmatched rather than being guessed.
local SKYBORNE_KEYS = {
    ALLIANCE = "SkyborneAlliance",
    HORDE    = "SkyborneHorde",
}

local RACE_LABELS = {
    HUMAN    = "Human",
    ORC      = "Orc",
    DWARF    = "Dwarf",
    NIGHTELF = "Night Elf",
    GNOME    = "Gnome",
    TROLL    = "Troll",
    TAUREN   = "Tauren",
    UNDEAD   = "Undead",
    DRAENEI  = "Draenei",
    SkyborneAlliance = "High Order Skyborne",
    SkyborneHorde    = "Windshaper Skyborne",
}

-- UnitFactionGroup's group only ("Alliance"/"Horde"), nil when unreadable.
-- pcall'd and secret-checked like every other client read here.
local function factionGroup()
    if type(UnitFactionGroup) ~= "function" then return nil end
    local ok, group = pcall(UnitFactionGroup, "player")
    if not ok or isSecret(group) or type(group) ~= "string" then return nil end
    local key = string.upper(group)
    if SKYBORNE_KEYS[key] then return key end
    return nil
end

-- "Orc" -> "ORC", "Night Elf" -> "NIGHTELF", "Scourge" -> "UNDEAD".
-- A token whose uppercase contains SKYBORNE is one of the two Skyborne
-- versions; when the exact key is absent only UnitFactionGroup can say which,
-- and with no readable faction the token stays unmatched rather than being
-- guessed at. Every other unknown or unreadable input returns nil.
function Racials.NormaliseRace(token)
    local text = readableString(token)
    if not text then return nil end

    local key = string.upper(text)
    key = string.gsub(key, "[%s_%-]", "")

    local alias = RACE_ALIASES[key]
    if alias then return alias end

    if string.find(key, "SKYBORNE", 1, true) then
        local group = factionGroup()
        if group then return SKYBORNE_KEYS[group] end
    end

    return nil
end

------------------------------------------------------------------------------
-- Race-token probe
--
-- The exact UnitRace token for each Skyborne version is still owed (T-65), so
-- the raw token is recorded once and never inferred. The table is account-wide
-- because the token describes the client, not one character.
------------------------------------------------------------------------------

local raceTokenCaptured = false

local function captureRaceToken()
    if raceTokenCaptured then return end
    raceTokenCaptured = true

    if type(UnitRace) ~= "function" then return end
    local ok, _, token = pcall(UnitRace, "player")
    if not ok then return end
    local text = readableString(token)
    if not text then return end

    local db = rawget(_G, "LunchboxToolkitDB")
    if type(db) ~= "table" then
        if db ~= nil then return end   -- a non-table global is left alone
        db = {}
        _G.LunchboxToolkitDB = db
    end

    if type(db.raceTokens) ~= "table" then db.raceTokens = {} end
    if db.raceTokens[text] == nil then
        db.raceTokens[text] = true
    end
end

local function raceLabel(raceKey)
    if type(raceKey) ~= "string" then return "Unknown" end

    -- The normalised key is what ClassData expects; without it GetRace returns
    -- nil for "Orc". The bundled table is only a display-name source here.
    local classData = LT.ClassData
    if type(classData) == "table" and type(classData.GetRace) == "function" then
        local ok, definition = pcall(classData.GetRace, classData, raceKey)
        if ok and type(definition) == "table" and type(definition.name) == "string" then
            return definition.name
        end
    end

    return RACE_LABELS[raceKey] or raceKey
end

function Racials.DetectRace()
    local candidates, count = {}, 0
    local function add(value)
        count = count + 1
        candidates[count] = value
    end

    if type(UnitRace) == "function" then
        local ok, name, token = pcall(UnitRace, "player")
        if ok then
            add(token)   -- race file/token first: "Orc", "Scourge", "NightElf"
            add(name)    -- localized name second
        end
    end

    local player = LT.player
    if type(player) == "table" then
        add(player.race)
        add(player.raceName)
    end

    local fallback
    for index = 1, count do
        local text = readableString(candidates[index])
        if text then
            local key = Racials.NormaliseRace(text)
            if key then return key, text end
            fallback = fallback or text
        end
    end

    return nil, fallback
end

------------------------------------------------------------------------------
-- What was registered, and why
--
-- `value` is the change to the weight: mode "multiplier" multiplies it by
-- (1 + value). Only entries whose value is known and non-zero are registered.
------------------------------------------------------------------------------

local PASSIVES = {
    {
        race    = "TAUREN",
        id      = "tauren_endurance",
        title   = "Endurance",
        benefit = "tauren_endurance_max_health",
        stat    = "stamina",
        mode    = "multiplier",
        value   = 0.05,
        effect  = "+5% maximum health",
        reason  = "Health comes from stamina, so the stamina weight is lifted 5%. "
            .. "The part of health that comes from base health is not separated, "
            .. "so this is a model, not a measured conversion. The +2% critical "
            .. "damage and healing Endurance used to carry was removed on 2026-10-26.",
    },
    {
        race    = "HUMAN",
        id      = "human_spirit",
        title   = "The Human Spirit",
        benefit = "human_spirit",
        stat    = "spirit",
        mode    = "multiplier",
        value   = 0.10,
        effect  = "+10% Spirit",
        reason  = "Spirit is raised 10% by the racial, so a point of Spirit on an "
            .. "item is worth 10% more to a Human. Doubled from +5% on 2026-10-26. "
            .. "Only a profile that prices spirit sees any change.",
    },
}

local FLAT_RESIST_REASON =
    "A flat resistance bonus does not make a resistance rating point worth more, "
    .. "so no weight can hold it."
local FLAT_DODGE_REASON =
    "+1% dodge is a flat percentage; the dodge weight is per rating and the "
    .. "rating-per-percent conversion is unmeasured."
local FLAT_CRIT_REASON =
    "+1% critical chance is a flat percentage; the crit weight is per rating and "
    .. "the rating-per-percent conversion is unmeasured, so no weight can hold it."
local FLAT_HASTE_REASON =
    "+2% haste is a flat percentage; the haste weight is per rating, so no weight "
    .. "can hold it."
local PET_REASON =
    "It moves a pet's damage, not the player's item stats, and the scorer prices "
    .. "items for the character."
local PROC_REASON =
    "An on-hit heal with an internal cooldown would need a proc rate and an uptime "
    .. "nobody has measured."

-- Passives left out on purpose, with the reason. Listed by /lt racials for the
-- character's own race so "nothing else registered" is explained rather than
-- silent. Dwarf Artisan's Precision is deliberately absent: it is registered as a
-- cap adjustment (see CAP_FLAT below) because +1% hit is one point off the cap.
local UNHELD_PASSIVES = {
    { race = "HUMAN",    name = "Diplomacy",
      reason = "Reputation gain is not a stat the scorer prices." },
    { race = "HUMAN",    name = "Ruthless",          reason = FLAT_CRIT_REASON },
    { race = "DWARF",    name = "Frost Resistance",  reason = FLAT_RESIST_REASON },
    { race = "NIGHTELF", name = "Quickness",         reason = FLAT_DODGE_REASON },
    { race = "NIGHTELF", name = "Nature Resistance", reason = FLAT_RESIST_REASON },
    { race = "GNOME",    name = "Arcane Resistance", reason = FLAT_RESIST_REASON },
    { race = "GNOME",    name = "Engineering Specialization",
      reason = "The engineering skill has no stat weight." },
    { race = "ORC",      name = "Hardiness",
      reason = "Stun resistance is not a stat the scorer prices." },
    { race = "ORC",      name = "Command",           reason = PET_REASON },
    { race = "UNDEAD",   name = "Shadow Resistance", reason = FLAT_RESIST_REASON },
    { race = "UNDEAD",   name = "Touch of the Grave", reason = PROC_REASON },
    { race = "TAUREN",   name = "Nature Resistance", reason = FLAT_RESIST_REASON },
    { race = "TROLL",    name = "Quickness",         reason = FLAT_DODGE_REASON },
    { race = "TROLL",    name = "Regeneration",
      reason = "Health regeneration is a share of maximum health per tick; no "
          .. "weight channel prices it (hp5 is flat gear regeneration per 5 seconds)." },
    { race = "SkyborneAlliance", name = "Wind Blessed", reason = FLAT_HASTE_REASON },
    { race = "SkyborneHorde",    name = "Wind Blessed", reason = FLAT_HASTE_REASON },
}

-- Actives are named but never registered: an average contribution would need
-- an uptime nobody has measured, and inventing one is exactly the fake weight
-- this project rules out.
local ACTIVES = {
    { race = "ORC",   name = "Blood Fury",
      reason = "on-use attack-power cooldown, now 2 min (was 3); no uptime has "
          .. "been measured." },
    { race = "TROLL", name = "Berserking",
      reason = "on-use haste cooldown, now 15 s (was 10); no uptime has been "
          .. "measured." },
    { race = "DWARF", name = "Stoneform",
      reason = "on-use defensive cooldown and cleanse; no uptime has been measured." },
    { race = "TAUREN", name = "War Stomp",
      reason = "on-use area stun; it changes control, not a stat weight, and no "
          .. "uptime has been measured." },
    { race = "SkyborneAlliance", name = "Read Leyline",
      reason = "on-use regeneration, 50% for 15 s (100% for an hour with Attuned); "
          .. "regeneration is not a stat the scorer prices." },
    { race = "SkyborneAlliance", name = "Skysight",
      reason = "on-use movement speed, 15% (30% with Charged); movement is not a "
          .. "stat the scorer prices." },
    { race = "SkyborneHorde", name = "Read Leyline",
      reason = "on-use regeneration, 50% for 15 s (100% for an hour with Attuned); "
          .. "regeneration is not a stat the scorer prices." },
    { race = "SkyborneHorde", name = "Skysight",
      reason = "on-use movement speed, 15% (30% with Charged); movement is not a "
          .. "stat the scorer prices." },
}

-- Pure: the passives defined for a normalised race key.
function Racials.PassivesFor(raceKey)
    local rows = {}
    if type(raceKey) ~= "string" or raceKey == "" then return rows end

    for _, entry in ipairs(PASSIVES) do
        if entry.race == raceKey then
            rows[#rows + 1] = entry
        end
    end

    return rows
end

-- Pure: the passives left out for a normalised race key.
function Racials.UnheldPassivesFor(raceKey)
    local rows = {}
    if type(raceKey) ~= "string" or raceKey == "" then return rows end

    for _, entry in ipairs(UNHELD_PASSIVES) do
        if entry.race == raceKey then
            rows[#rows + 1] = entry
        end
    end

    return rows
end

-- Pure: whether one definition is complete enough to register. A zero or
-- missing value is refused here, before the API is ever called.
function Racials.IsRegisterable(entry)
    if type(entry) ~= "table" then return false end
    if type(entry.id) ~= "string" or entry.id == "" then return false end
    if type(entry.benefit) ~= "string" or entry.benefit == "" then return false end
    if type(entry.stat) ~= "string" or entry.stat == "" then return false end

    local value = tonumber(entry.value)
    if not value or value == 0 then return false end

    return true
end

-- Pure: the definitions to register for a race, each id at most once. Ids the
-- API already holds are skipped, which is what makes a duplicate load harmless.
function Racials.BuildPlan(raceKey, existingIds)
    local plan, seen = {}, {}
    if type(raceKey) ~= "string" or raceKey == "" then return plan end

    for _, entry in ipairs(PASSIVES) do
        if entry.race == raceKey then
            local duplicate = seen[entry.id] == true
            local alreadyRegistered = type(existingIds) == "table"
                and existingIds[entry.id] == true

            if not duplicate and not alreadyRegistered and Racials.IsRegisterable(entry) then
                seen[entry.id] = true
                plan[#plan + 1] = entry
            end
        end
    end

    return plan
end

------------------------------------------------------------------------------
-- Adjustments
------------------------------------------------------------------------------

local function statLabel(stat)
    if type(LT.Label) == "function" then
        local ok, label = pcall(LT.Label, LT, stat)
        if ok and type(label) == "string" then return label end
    end
    return tostring(stat)
end

local function contributionFor(entry)
    -- The weight must exist before a multiplier can mean anything: a profile
    -- with no stamina weight gets no contribution and no trace entry.
    return function(ctx)
        local weights = type(ctx) == "table" and ctx.weights or nil
        if type(weights) ~= "table" then return nil end

        local current = tonumber(weights[entry.stat])
        if not current or current == 0 then return nil end

        return {
            stats = { [entry.stat] = entry.value },
            notes = { entry.title .. ": " .. entry.effect .. " — " .. entry.reason },
        }
    end
end

local function explainFor(entry)
    return function()
        return "Lunchbox Racials / " .. entry.title .. ": " .. entry.effect
            .. " — " .. entry.reason
    end
end

local function definitionFor(entry)
    return {
        id           = entry.id,
        title        = entry.title,
        benefit      = entry.benefit,
        priority     = entry.priority or 50,
        mode         = entry.mode,
        contribution = contributionFor(entry),
        explain      = explainFor(entry),
    }
end

------------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------------

local state = {
    attempted = false,
    failure   = nil,
}

-- The slash surface is wired at file load. If it is missing or refused, the
-- single login line says so; nothing else changes.
local commandRegistered = false
local commandProblem = nil

local function describeCommandProblem(message)
    if commandRegistered or not commandProblem then return message end
    return message .. " (" .. commandProblem .. ")"
end

local META = {
    id          = Racials.PLUGIN_ID,
    name        = "Lunchbox Racials",
    version     = Racials.VERSION,
    author      = "Lunchbox",
    apiVersion  = 1,
    description = "Registers the racial passives that can move a stat weight "
        .. "(Tauren Endurance +5% health on the stamina weight, Human Spirit "
        .. "+10% on the spirit weight), and the one flat cap racial left after "
        .. "the weapon specialisations were removed: Dwarf Artisan's Precision, "
        .. "+1% hit with spells and attacks, which comes off the hit cap.",
}

local function pluginApi()
    local api = LT.PluginAPI
    if type(api) ~= "table"
        or type(api.RegisterPlugin) ~= "function"
        or type(api.RegisterAdjustment) ~= "function" then
        return nil
    end
    return api
end

local function ensurePlugin(api)
    local plugins = type(api.plugins) == "table" and api.plugins or nil
    if plugins and type(plugins[Racials.PLUGIN_ID]) == "table" then
        return plugins[Racials.PLUGIN_ID]
    end

    local ok, plugin, reason = pcall(api.RegisterPlugin, api, META)
    if not ok then
        return nil, tostring(plugin)
    end

    if not plugin then
        -- A second copy of this file in the same session lands here: the id is
        -- already ours, so use it instead of calling that a failure.
        if plugins and type(plugins[Racials.PLUGIN_ID]) == "table" then
            return plugins[Racials.PLUGIN_ID]
        end
        return nil, tostring(reason)
    end

    return plugin
end

local function existingAdjustmentIds(api)
    local ids = {}
    local list = type(api.adjustments) == "table" and api.adjustments[Racials.PLUGIN_ID]
    if type(list) == "table" then
        for _, adjustment in ipairs(list) do
            if type(adjustment) == "table" and type(adjustment.id) == "string" then
                ids[adjustment.id] = true
            end
        end
    end
    return ids
end

local function describeEntries(entries)
    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = entry.title .. " (" .. entry.effect
            .. "; " .. statLabel(entry.stat) .. " weight)"
    end
    return table.concat(parts, ", ")
end

-- Runs once per session. Returns the number of adjustments actually added.
function Racials:Register()
    if state.attempted then
        debug("Racials: registration was already attempted this session; nothing added.")
        return 0
    end
    state.attempted = true

    -- Record the raw UnitRace token once for T-65; nothing here depends on the
    -- answer, so it runs even when the PluginAPI is missing.
    captureRaceToken()

    local api = pluginApi()
    if not api then
        state.failure = "PluginAPI is not available, so no racial adjustment was registered."
        loginReport(describeCommandProblem(state.failure))
        return 0
    end

    local plugin, pluginProblem = ensurePlugin(api)
    if not plugin then
        state.failure = "PluginAPI refused the plugin: " .. tostring(pluginProblem)
        loginReport(describeCommandProblem(state.failure))
        return 0
    end

    local raceKey, rawLabel = Racials.DetectRace()

    if not raceKey then
        if rawLabel then
            state.failure = "the race \"" .. rawLabel .. "\" has no entry this build "
                .. "normalises, so no racial adjustment was registered."
        else
            state.failure = "the character race could not be read, so no racial "
                .. "adjustment was registered."
        end
        loginReport(describeCommandProblem(state.failure))
        return 0
    end

    local existing = existingAdjustmentIds(api)
    local plan = Racials.BuildPlan(raceKey, existing)
    local added, refused = {}, {}

    for _, entry in ipairs(plan) do
        local definition = definitionFor(entry)
        local ok, adjustment, reason = pcall(api.RegisterAdjustment, api, Racials.PLUGIN_ID, definition)

        if not ok then
            refused[#refused + 1] = entry.title .. " (" .. tostring(adjustment) .. ")"
        elseif adjustment then
            added[#added + 1] = entry
        elseif not existingAdjustmentIds(api)[entry.id] then
            refused[#refused + 1] = entry.title .. " (" .. tostring(reason) .. ")"
        end
    end

    local message
    if #added > 0 then
        message = "registered " .. describeEntries(added) .. " — /lt racials for the full list."
        if #refused > 0 then
            message = message .. " Refused: " .. table.concat(refused, "; ") .. "."
        end
    elseif #refused > 0 then
        message = "nothing registered: " .. table.concat(refused, "; ") .. "."
        state.failure = message
    else
        local already = 0
        for _, entry in ipairs(Racials.PassivesFor(raceKey)) do
            if existing[entry.id] then already = already + 1 end
        end

        if already > 0 then
            message = "nothing new registered — " .. tostring(already)
                .. " racial passive(s) were already registered in this session. "
                .. "/lt racials lists them."
        else
            message = "nothing registered for " .. raceLabel(raceKey)
                .. " — no passive on this race moves a stat weight. /lt racials explains."
        end
    end

    -- The outcome of registration, not the registration itself: the plugin has
    -- already registered by now, and only the chat line follows the switch.
    loginReport(describeCommandProblem(message))
    return #added
end

------------------------------------------------------------------------------
-- Cap-moving racial passives (flat percentages)
------------------------------------------------------------------------------

-- A positive delta reduces the cap (Caps.lua: "positive delta = cap reduced"), so
-- +1% hit is delta 1.0 on "hit". Registering one is only allowed when the number
-- is fixed and published.
--
-- The weapon specialisations that used to live here - Human sword/mace, Orc axe,
-- Dwarf gun, Troll bow and throwing - were removed in the 15 October pass and
-- Blizzard said they will not come back, so no entry remains for them: a cap
-- registered for a racial that no longer exists would silently shave a cap.
local CAP_FLAT = {
    DWARF = {
        {
            stat   = "hit",
            delta  = 1.0,
            source = "Artisan's Precision",
            reason = "+1% hit chance with spells and attacks (flat; one point off "
                .. "the hit cap)",
        },
    },
}

local capState = { attempted = false }

-- Flat racial cap adjustments, registered once per session alongside
-- Racials:Register(). Reads nothing from the client: the number is in the notes.
function Racials:RegisterCaps()
    if capState.attempted then return 0 end
    capState.attempted = true

    local raceKey = Racials.DetectRace()
    if not raceKey then return 0 end

    local parser = LT.CapAdjustments
    if type(parser) ~= "table"
        or type(parser.RegisterList) ~= "function"
        or type(parser.RACIAL_SOURCE_PREFIX) ~= "string" then
        debug("Racials: CapAdjustments is not available; no racial cap adjustment registered.")
        return 0
    end

    local entries = CAP_FLAT[raceKey]
    if type(entries) ~= "table" or #entries == 0 then return 0 end

    local list = {}
    for _, entry in ipairs(entries) do
        if type(entry) == "table" then
            local stat = type(entry.stat) == "string" and entry.stat or nil
            local delta = tonumber(entry.delta)
            if stat and delta and delta ~= 0 then
                list[#list + 1] = {
                    stat   = stat,
                    delta  = delta,
                    source = parser.RACIAL_SOURCE_PREFIX .. tostring(entry.source or stat),
                    reason = tostring(entry.reason or ""),
                }
            end
        end
    end

    local count = parser:RegisterList(list, parser.RACIAL_SOURCE_PREFIX)
    if count > 0 then
        debug("Racials: registered " .. tostring(count) .. " racial cap adjustment(s).")
    end
    return count
end

------------------------------------------------------------------------------
-- /lt racials
------------------------------------------------------------------------------

function Racials:RegisteredEntries()
    local api = LT.PluginAPI
    if type(api) ~= "table" or type(api.adjustments) ~= "table" then
        return nil, "PluginAPI is not available, so no adjustment is registered."
    end

    local list = api.adjustments[Racials.PLUGIN_ID]
    if type(list) ~= "table" then return {} end

    local byId = {}
    for _, entry in ipairs(PASSIVES) do
        byId[entry.id] = entry
    end

    local rows = {}
    for _, adjustment in ipairs(list) do
        if type(adjustment) == "table" then
            rows[#rows + 1] = {
                id    = adjustment.id,
                title = adjustment.title or tostring(adjustment.id),
                data  = byId[adjustment.id],
            }
        end
    end

    return rows
end

function Racials:Report()
    local raceKey, rawLabel = Racials.DetectRace()
    local shown = raceLabel(raceKey)
    if raceKey then
        shown = shown .. " (" .. raceKey .. ")"
    elseif rawLabel then
        shown = rawLabel .. " (no normalised key)"
    end

    report("Racials — character race: " .. shown .. ".")

    local rows, apiProblem = Racials:RegisteredEntries()
    if apiProblem then
        report("  " .. apiProblem)
    elseif #rows == 0 then
        local why = state.failure
        if not state.attempted then
            why = "registration runs at login; it has not run yet."
        elseif not why then
            why = "no passive on this race moves a stat weight."
        end
        report("  registered adjustments: none — " .. why)
    else
        report("  registered adjustments (" .. tostring(#rows) .. "):")
        for _, row in ipairs(rows) do
            local data = row.data
            if data then
                report("    " .. data.title .. " — " .. data.effect
                    .. "; " .. (data.mode == "multiplier" and "multiplier" or "addition")
                    .. " on the " .. statLabel(data.stat) .. " weight. "
                    .. "Source: Lunchbox Racials (" .. Racials.PLUGIN_ID .. "). "
                    .. "Reason: " .. data.reason)
            else
                report("    " .. row.title .. " — registered; no local description.")
            end
        end
    end

    report("  cannot be valued yet (actives — no measured uptime, nothing registered):")
    for _, active in ipairs(ACTIVES) do
        report("    " .. active.name .. " (" .. raceLabel(active.race) .. "): " .. active.reason)
    end

    local unheld = Racials.UnheldPassivesFor(raceKey)
    if #unheld > 0 then
        report("  passives with no weight that can hold them:")
        for _, entry in ipairs(unheld) do
            report("    " .. entry.name .. ": " .. entry.reason)
        end
    end

    -- Racial cap adjustments registered through Caps (a flat percentage point off
    -- the cap). The number is the one published for the racial.
    local prefix = "racial:"
    if type(LT.CapAdjustments) == "table"
        and type(LT.CapAdjustments.RACIAL_SOURCE_PREFIX) == "string" then
        prefix = LT.CapAdjustments.RACIAL_SOURCE_PREFIX
    end
    local capAdjustments = (type(LT.Caps) == "table" and type(LT.Caps.adjustments) == "table")
        and LT.Caps.adjustments or {}
    local capRows = {}
    for _, adj in ipairs(capAdjustments) do
        if type(adj) == "table" and type(adj.source) == "string"
            and adj.source:sub(1, #prefix) == prefix then
            capRows[#capRows + 1] = adj
        end
    end

    if #capRows > 0 then
        report("  cap adjustments (racial, in percentage points off the cap):")
        for _, adj in ipairs(capRows) do
            report("    " .. tostring(adj.source) .. " — " .. tostring(adj.reason)
                .. " (" .. tostring(adj.delta) .. " " .. statLabel(adj.stat) .. ")")
        end
    else
        report("  cap adjustments: none for this race.")
    end
end

------------------------------------------------------------------------------
-- Slash surface
--
-- Registered through the core's documented hook, at file load when the core
-- has already loaded (the TOC dependency guarantees that). A refusal or a
-- missing Slash module is reported once at login instead of being silent.
------------------------------------------------------------------------------

local function commandWordListed(slash)
    if type(slash.RegisteredCommands) ~= "function" then return false end

    local ok, words = pcall(slash.RegisteredCommands, slash)
    if not ok or type(words) ~= "table" then return false end

    for _, word in ipairs(words) do
        if word == "racials" then return true end
    end
    return false
end

local function registerCommand()
    if commandRegistered then return true end

    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then
        commandProblem = "the /lt slash command surface is not available"
        return false
    end

    local ok, added = pcall(slash.RegisterCommand, slash, "racials",
        function() Racials:Report() end,
        "/lt racials — racial adjustments registered, and what cannot be valued yet")

    if ok and added == true then
        commandRegistered = true
        commandProblem = nil
        return true
    end

    if ok and added == false and duplicateLoad and commandWordListed(slash) then
        -- A second copy of this file already registered the word; it calls the
        -- same report, so this is not a failure.
        commandRegistered = true
        commandProblem = nil
        return true
    end

    commandProblem = "the /lt racials command could not be registered (the word is already taken)"
    return false
end

-- Registered at file load so `/lt help` lists it before login.
registerCommand()

------------------------------------------------------------------------------
-- PLAYER_LOGIN
------------------------------------------------------------------------------

local function onLogin()
    registerCommand()
    Racials:Register()
    Racials:RegisterCaps()
end

Racials.OnLogin = onLogin

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
        else
            debug("Racials: the login event could not be wired; registration waits for OnLogin.")
        end
    else
        debug("Racials: the login frame could not be created; registration waits for OnLogin.")
    end
end
