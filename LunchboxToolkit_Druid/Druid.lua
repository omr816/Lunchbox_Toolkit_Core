--[[--------------------------------------------------------------------------
    LunchboxToolkit_Druid — form, self-buff and proc support for Druids

    This plugin is behaviour and presentation only. The Druid's class data
    (specRoles, the levelling templates, the feral weight profiles and the
    "Preferred form" class option) stays in the core at Classes\Druid.lua and
    ClassData.lua, so this whole folder can be deleted and the addon still
    works for a Druid.

    What the core already owns, and what this file therefore never registers:
      * druid_cat_form and druid_bear_form, the two bundled BuffMonitor
        definitions (option keys druidCatFormReminder and
        druidBearFormReminder). Registering the same id again makes
        BuffMonitor:Register refuse it and print a warning on every load, so
        the guard below asks the registry first and steps aside;
      * the cat-form combo point tracker (Trackers) and the feral attack power
        weight channel (ClassData, quirk feral_attack_power).

    What this plugin adds:
      * three BuffMonitor definitions, registered for DRUID only, each with its
        own per-character switch and each off by default:
          - Mark of the Wild or Gift of the Wild missing on the player,
            option druidMotwReminder, definition id druid_motw_self;
          - Thorns missing on the player, option druidThornsReminder,
            definition id druid_thorns_self;
          - a feral build's Preferred form not being worn, option
            druidFormReminder, definition id druid_preferred_form. It reads the
            build's own class option through PluginAPI:GetClassOptions, which
            is the part the core's two fixed reminders cannot do: they are
            separate switches a player has to remember to tick, this one
            follows the build the player is actually scoring;
      * a Druid page in the toolkit window (UI:AddPage), so the three switches
        have somewhere to be pressed without a core edit;
      * a proc aura list for the core's combo/proc strip
        (Trackers:RegisterProcAuras). The list starts EMPTY on purpose: a
        guessed aura name would never light up and would look like a broken
        tracker. `/lt druid procs add <name>` stores a name the player has just
        seen in `/lt druid probe auras`;
      * DruidHUD.lua, a small form and power strip, off by default: locked against
        clicks until its cog is pressed, with a panel under it for size, opacity,
        the combo tail, the shape colour and a reset.

    Settings rows: the core's Settings page owns its layout and a plugin cannot
    add a row to it. Druid:GetOptionRows("DRUID") returns the row data (key,
    label, help, default) for a future UI, and until then the switches are
    reachable three ways: the Druid page, the commands below, and SetEnabled.

    Commands (all under the core's /lt dispatcher):
      /lt druid                  status: which switch is on, what the client says
      /lt druid on|off <key>     key is motw, thorns or form
      /lt druid diag             full report; the line to attach to a bug post
      /lt druid probe <word>     forms, power, spells, auras, slots, target, procs,
      /lt druid probe all        every probe in one run, in that order
      /lt druid procs [list]     the stored proc names and which are lit now
      /lt druid procs add <name> store a name exactly as the aura reads
      /lt druid procs clear      empty the stored list
      /lt druid page             open the toolkit window on the Druid page
      /lt druid hud on|off|lock|unlock|scale <n>|alpha <n>|combo on|off|
                   colour on|off|reset

    Level 1, measured rather than assumed: on Forever (client 1.60.1, 13:16 capture
    on Devillish, 2026-11-05) a fresh Druid's spellbook holds Wrath and Healing
    Touch, and NOT Mark of the Wild. So the honest answer for the Mark of the Wild
    switch at level 1 is "not yet", not "not available for this character": the
    spell is not in the book yet, and the switch starts answering by itself the
    moment it is learned (BuffMonitor re-runs isAvailable on every check). Every
    reminder is gated on the spell that makes its question meaningful: Thorns is
    unavailable until Thorns is learned, and the form reminder is unavailable until
    the build's preferred shape is in the spellbook. A gate needs a positive
    answer; an unreadable spellbook or aura list silences the reminder rather than
    warning from a guess.

    The plugin stores one SavedVariables table of its own,
    LunchboxToolkitDruidDB, holding the proc names and the HUD's own keys (where
    the strip sits, its size and opacity, its lock and its two switches). The
    three reminder switches live in the core's per-character options table,
    because that is the table BuffMonitor reads.
--------------------------------------------------------------------------]]

if not LunchboxToolkit then return end
local LT = LunchboxToolkit

-- A second copy of this file (an older folder left beside the new one) must not
-- register the same definitions twice: BuffMonitor would warn on every load and
-- the Druid page would be refused as a duplicate key. The first copy stays in
-- charge and the second returns before touching anything.
if type(LT.Druid) == "table" then return end

local Druid = {}
LT.Druid = Druid

Druid.PLUGIN_ID      = "lunchbox_druid"
Druid.CLASS          = "DRUID"
Druid.VERSION        = "1.0.1"
Druid.SAVED_VARIABLE = "LunchboxToolkitDruidDB"
Druid.PAGE_KEY       = "druid"

Druid.OPTION_KEYS = {
    motw   = "druidMotwReminder",
    thorns = "druidThornsReminder",
    form   = "druidFormReminder",
}

Druid.DEFINITION_IDS = {
    motw   = "druid_motw_self",
    thorns = "druid_thorns_self",
    form   = "druid_preferred_form",
}

-- One row per switch, in the order the page, the usage line and the diagnostic
-- report show them. `key` names a field of OPTION_KEYS, so the lists cannot
-- drift apart.
Druid.SWITCHES = {
    {
        key   = "motw",
        label = "Mark of the Wild",
        help  = "Warn when neither Mark of the Wild nor Gift of the Wild is on you.",
    },
    {
        key   = "thorns",
        label = "Thorns",
        help  = "Warn when Thorns is not on you.",
    },
    {
        key   = "form",
        label = "Preferred form",
        help  = "Warn when a feral build is not wearing its Preferred form (Cat or Bear).",
    },
}

local initialized = false
local announcedInactive = false

------------------------------------------------------------------------------
-- Logging and boundary guards
------------------------------------------------------------------------------

local function report(message)
    if type(LT.Print) == "function" then
        if pcall(LT.Print, LT, message) then return end
    end
    pcall(print, message)
end

local function warn(message)
    if type(LT.Warn) == "function" then
        pcall(LT.Warn, LT, message)
        return
    end
    pcall(print, message)
end

local function debug(message)
    if type(LT.Debug) == "function" then
        pcall(LT.Debug, LT, message)
    end
end

-- Never tostring, compare or do arithmetic on a value the client marks secret.
local function isSecret(value)
    if type(LT.IsSecret) == "function" then
        local ok, result = pcall(LT.IsSecret, LT, value)
        return ok and result == true
    end
    return false
end

-- A client value as text for a diagnostic line. A secret is named, never read.
local function describe(value)
    if isSecret(value) then return "secret" end
    if value == nil then return "nil" end
    if type(value) == "string" and value == "" then return "empty" end
    return tostring(value)
end

local function inCombat()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, value = pcall(InCombatLockdown)
    return ok and value == true
end

local function isDruid()
    local ok, answer = pcall(LT.IsClass, LT, Druid.CLASS)
    return ok and answer == true
end

------------------------------------------------------------------------------
-- Store (proc names plus the HUD's place, look, lock and switches)
------------------------------------------------------------------------------

-- The table the client fills from LunchboxToolkitDruidDB. Created on demand so a
-- command typed before ADDON_LOADED cannot raise; ADDON_LOADED assigns the
-- client's table and the two shapes are the same.
local function store()
    local saved = rawget(_G, Druid.SAVED_VARIABLE)
    if type(saved) ~= "table" then
        saved = {}
        rawset(_G, Druid.SAVED_VARIABLE, saved)
    end
    if type(saved.procs) ~= "table" then saved.procs = {} end
    if type(saved.hud) ~= "table" then saved.hud = {} end
    return saved
end

Druid.Store = store

------------------------------------------------------------------------------
-- Core options (the per-character table BuffMonitor reads)
------------------------------------------------------------------------------

local function options()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return nil
    end
    local ok, table_ = pcall(database.GetOptions, database)
    if not ok or type(table_) ~= "table" then return nil end
    return table_
end

-- A missing key reads as off: that is the whole default, so no seed is needed
-- anywhere in the core.
function Druid:IsEnabled(optionKey)
    local list = options()
    if not list then return false end
    return list[optionKey] == true
end

function Druid:SetEnabled(optionKey, value)
    local list = options()
    if not list then return false end
    list[optionKey] = value == true

    local database = LT.Database
    if type(database) == "table" and type(database.Save) == "function" then
        pcall(database.Save, database, "druid:" .. tostring(optionKey))
    end
    return true
end

-- The row data a settings UI would draw. Returned rather than drawn because this
-- plugin cannot add a row to the core's page; the Druid page uses the same rows.
function Druid:GetOptionRows(classToken)
    if classToken ~= nil and classToken ~= self.CLASS then return {} end

    local rows = {}
    for _, switch in ipairs(self.SWITCHES) do
        local optionKey = self.OPTION_KEYS[switch.key]
        rows[#rows + 1] = {
            key     = optionKey,
            label   = switch.label,
            help    = switch.help,
            default = false,
            class   = self.CLASS,
            get     = function() return Druid:IsEnabled(optionKey) end,
            set     = function(value) return Druid:SetEnabled(optionKey, value) end,
        }
    end
    return rows
end

local function switchByWord(word)
    if type(word) ~= "string" then return nil end
    local wanted = string.lower(word)
    for _, switch in ipairs(Druid.SWITCHES) do
        if switch.key == wanted then return switch end
    end
    return nil
end

local function switchWords()
    local words = {}
    for _, switch in ipairs(Druid.SWITCHES) do words[#words + 1] = switch.key end
    return table.concat(words, ", ")
end

------------------------------------------------------------------------------
-- Client reads (every call guarded; nil means "cannot answer")
------------------------------------------------------------------------------

-- true = the spellbook holds a spell whose name CONTAINS the pattern,
-- false = it does not, nil = the spellbook could not be read.
-- The core owns the scan (ClassData:KnowsSpellName), so the spellbook is opened
-- by one module rather than once per plugin.
local function knowsSpell(pattern)
    local data = LT.ClassData
    if type(data) ~= "table" or type(data.KnowsSpellName) ~= "function" then
        return nil
    end
    local ok, answer = pcall(data.KnowsSpellName, data, pattern)
    if not ok then return nil end
    if answer == true then return true end
    if answer == false then return false end
    return nil
end

-- The set of helpful aura names on the player, or nil when the client would not
-- answer. Trackers owns the scan, and with it the one copy of the secret
-- handling and the fallback from C_UnitAuras to UnitAura to UnitBuff.
local function helpfulAuras()
    local trackers = LT.Trackers
    if type(trackers) ~= "table" then return nil end
    if type(trackers.CollectHelpfulAuras) ~= "function" then return nil end
    local ok, auras = pcall(trackers.CollectHelpfulAuras, trackers)
    if not ok or type(auras) ~= "table" then return nil end
    return auras
end

local function hasAnyAura(auras, names)
    if type(auras) ~= "table" or type(names) ~= "table" then return false end
    for _, name in ipairs(names) do
        if auras[name] == true then return true end
    end
    return false
end

-- The buffs the two self-buff reminders look for. Mark of the Wild is the single
-- version and Gift of the Wild the group one; either satisfies the reminder,
-- because both carry the same armour, attributes and resistances on the player.
Druid.MOTW_AURAS   = { "Mark of the Wild", "Gift of the Wild" }
Druid.THORNS_AURAS = { "Thorns" }

-- Every shapeshift shape, in the order the probes print them. `key` is what the
-- build's Preferred form class option calls it; `auras` is what the client names
-- it. Cat and Bear are the only two a build can currently prefer.
local FORM_AURAS = {
    { key = "Cat",     auras = { "Cat Form" } },
    { key = "Bear",    auras = { "Bear Form", "Dire Bear Form" } },
    { key = "Travel",  auras = { "Travel Form" } },
    { key = "Aquatic", auras = { "Aquatic Form" } },
    { key = "Moonkin", auras = { "Moonkin Form" } },
    { key = "Tree",    auras = { "Tree of Life Form" } },
    { key = "Flight",  auras = { "Flight Form", "Swift Flight Form" } },
}

-- The first shape whose aura is present, as key plus the aura name that matched.
local function auraForm(auras)
    if type(auras) ~= "table" then return nil, nil end
    for _, form in ipairs(FORM_AURAS) do
        for _, name in ipairs(form.auras) do
            if auras[name] == true then return form.key, name end
        end
    end
    return nil, nil
end

-- What the client says about the current shape, from every route it offers:
--   id      GetShapeshiftFormID value (the core treats 1 as Cat)
--   index   GetShapeshiftForm value (0 = caster form)
--   name    GetShapeshiftFormInfo's name for that index, when it answers
--   auraKey/auraName  the shape found by aura, which needs no form API at all
--   route   which route answered, so a probe can say so
-- Reading more than one route is deliberate: if a client answers nothing on the
-- ID call, the aura still identifies Cat Form, which is what the reminder needs.
local function formState()
    local id, index, name, caster

    if type(GetShapeshiftFormID) == "function" then
        local ok, value = pcall(GetShapeshiftFormID)
        if ok and not isSecret(value) and type(value) == "number" and value > 0 then
            id = value
        end
    end

    if type(GetShapeshiftForm) == "function" then
        local ok, value = pcall(GetShapeshiftForm)
        if ok and not isSecret(value) and type(value) == "number" then
            -- 0 is not a missing answer: it is the client saying "no shape", which
            -- is the caster form a level-1 Druid is in. Reading it as nil made the
            -- status line say "form: no answer" for a question the client had
            -- just answered (Devillish, 13:16 capture, 2026-11-05).
            if value > 0 then
                index = value
                if type(GetShapeshiftFormInfo) == "function" then
                    local okInfo, icon, formName = pcall(GetShapeshiftFormInfo, value)
                    if okInfo and not isSecret(icon) and not isSecret(formName)
                        and type(formName) == "string" and formName ~= "" then
                        name = formName
                    end
                end
            else
                caster = true
            end
        end
    end

    local auras = helpfulAuras()
    local auraKey, auraName = auraForm(auras)
    if auraName ~= nil then caster = nil end

    local route = "none"
    if id ~= nil then
        route = "GetShapeshiftFormID"
    elseif index ~= nil then
        route = "GetShapeshiftForm"
    elseif auraName ~= nil then
        route = "aura"
    elseif caster then
        route = "GetShapeshiftForm (caster form)"
    elseif auras ~= nil then
        route = "aura (caster form)"
        caster = true
    end

    return {
        id       = id,
        index    = index,
        name     = name,
        caster   = caster,
        auraKey  = auraKey,
        auraName = auraName,
        route    = route,
    }
end

-- The shape as a word, or nil when the client answered nothing at all. "Caster"
-- means every readable route said "no shape".
local function formLabel(state)
    if type(state) ~= "table" then return nil end
    if type(state.name) == "string" and state.name ~= "" then return state.name end
    if state.auraName ~= nil then return state.auraName end
    if type(state.index) == "number" then return "form index " .. tostring(state.index) end
    if type(state.id) == "number" then return "form id " .. tostring(state.id) end
    if state.caster then return "Caster" end
    return nil
end

local POWER_LABELS = {
    [0] = "Mana",
    [1] = "Rage",
    [2] = "Focus",
    [3] = "Energy",
    [6] = "Runic Power",
}

-- The resource bar the current shape uses: a Druid has mana in caster form, rage
-- in bear form and energy in cat form, and the client swaps the power type with
-- the shape. Every value is guarded, and a secret or unreadable number is
-- reported as unknown rather than as zero.
local function powerState()
    local kind, token
    if type(UnitPowerType) == "function" then
        local ok, typeID, typeToken = pcall(UnitPowerType, "player")
        if ok then
            if not isSecret(typeID) and type(typeID) == "number" then kind = typeID end
            if not isSecret(typeToken) and type(typeToken) == "string"
                and typeToken ~= "" then
                token = typeToken
            end
        end
    end

    local current, maximum
    -- The power index is passed explicitly, the way ShamanHUD reads it: the
    -- argument-less call is the one this client refuses.
    local powerIndex = kind or 0
    if type(UnitPower) == "function" then
        local ok, value = pcall(UnitPower, "player", powerIndex)
        if not ok or isSecret(value) then
            ok, value = pcall(UnitPower, "player")
        end
        if ok and not isSecret(value) and type(value) == "number" then current = value end
    end
    if type(UnitPowerMax) == "function" then
        local ok, value = pcall(UnitPowerMax, "player", powerIndex)
        if not ok or isSecret(value) then
            ok, value = pcall(UnitPowerMax, "player")
        end
        if ok and not isSecret(value) and type(value) == "number" then maximum = value end
    end

    -- Power is a secret value while this client is in combat (first-day probe,
    -- 2026-11-05: issecretvalue=true). Knowing which of the two reasons a read
    -- failed is the difference between "the addon is broken" and "the client is
    -- hiding it until the fight ends".
    local inCombat = false
    if type(InCombatLockdown) == "function" then
        local ok, value = pcall(InCombatLockdown)
        inCombat = ok and value == true
    elseif type(UnitAffectingCombat) == "function" then
        local ok, value = pcall(UnitAffectingCombat, "player")
        inCombat = ok and value == true
    end

    return {
        id       = kind,
        token    = token,
        current  = current,
        max      = maximum,
        inCombat = inCombat,
        label    = POWER_LABELS[kind] or token or "power",
    }
end

-- The build's own "Preferred form" class option (Cat, Bear, Caster,
-- Tree/Healer), read through the public API so this plugin never reaches into
-- the profile table itself. nil when no build answers.
local function preferredForm()
    local builds = LT.Builds
    if type(builds) ~= "table" or type(builds.GetActiveIndex) ~= "function" then
        return nil
    end
    local okIndex, index = pcall(builds.GetActiveIndex, builds)
    if not okIndex or type(index) ~= "number" then return nil end

    local api = LT.PluginAPI
    if type(api) ~= "table" or type(api.GetClassOptions) ~= "function" then
        return nil
    end
    local okOptions, classOptions = pcall(api.GetClassOptions, api, index)
    if not okOptions or type(classOptions) ~= "table" then return nil end

    local form = classOptions.form
    if isSecret(form) or type(form) ~= "string" or form == "" then return nil end
    return form
end

-- The aura list a preferred form expects, or nil for a value this plugin does not
-- police: Caster and Tree/Healer have no single required shape, so both leave the
-- reminder silent instead of nagging a healer who is legitimately in caster form.
local function preferredAuras(preferred)
    for _, form in ipairs(FORM_AURAS) do
        if form.key == preferred then return form.auras end
    end
    return nil
end

-- The spell whose presence makes a preferred-form question meaningful, so a
-- level-1 Druid's build never asks about a shape it cannot take yet.
local function preferredSpell(preferred)
    if preferred == "Cat" then return "Cat Form" end
    if preferred == "Bear" then return "Bear Form" end
    return nil
end

-- Combo points for the HUD only: the core's own tracker draws these for a cat, so
-- this value is never drawn twice on the same screen.
local function comboPoints()
    local trackers = LT.Trackers
    if type(trackers) ~= "table" or type(trackers.ReadPoints) ~= "function" then
        return nil
    end
    local ok, points = pcall(trackers.ReadPoints, trackers)
    if not ok or isSecret(points) or type(points) ~= "number" then return nil end
    return points
end

------------------------------------------------------------------------------
-- Public read wrappers (DruidHUD.lua and the page use these, so the guarded
-- client reads exist once)
------------------------------------------------------------------------------

function Druid:FormState()      return formState() end
function Druid:FormLabel()      return formLabel(formState()) end
function Druid:PowerState()     return powerState() end
function Druid:PreferredForm()  return preferredForm() end
function Druid:HelpfulAuras()   return helpfulAuras() end
function Druid:KnowsSpell(name) return knowsSpell(name) end
function Druid:ComboPoints()    return comboPoints() end

-- "form: Cat Form" or "form: no answer", the string the HUD draws.
function Druid:FormLine()
    local label = formLabel(formState())
    if label == nil then return "form: no answer" end
    return "form: " .. label
end

-- "Mana: full", "Mana: 82%", "Mana: hidden in combat". Percentages match
-- ShamanHUD, so the two resource lines read the same way. A refused read says
-- which refusal it was, because "no answer" reads like a broken addon.
function Druid:PowerLine()
    local power = powerState()
    local label = power.label or "power"
    if power.current == nil then
        if power.inCombat then return label .. ": hidden in combat" end
        return label .. ": not readable"
    end
    if type(power.max) == "number" and power.max > 0 then
        if power.current >= power.max then return label .. ": full" end
        return string.format("%s: %d%%",
            label, math.floor((power.current / power.max) * 100 + 0.5))
    end
    return label .. ": " .. tostring(power.current)
end

-- "2/5" only in cat form with points, so the line never says 0/5 for a class
-- mechanic that does not apply.
function Druid:PointsLine()
    local state = formState()
    if state.auraKey ~= "Cat" then return nil end
    local points = comboPoints()
    if points == nil or points <= 0 then return nil end
    return "combo: " .. tostring(math.floor(points)) .. "/5"
end

------------------------------------------------------------------------------
-- Definitions
------------------------------------------------------------------------------

-- A definition's checkFn returns { active = true } when the player is fine,
-- { active = false } when the reminder should speak, or nil when the client would
-- not answer. nil is "no answer" and always silences the reminder: this plugin
-- never warns from a guess.
local function selfBuffCheck(wanted)
    return function()
        local auras = helpfulAuras()
        if not auras then return nil end
        return { active = hasAnyAura(auras, wanted) == true }
    end
end

-- Mark of the Wild: the spell is learned at level 1, so this reminder is
-- meaningful from the first minute of the character's life. Only the spell being
-- in the spellbook makes it available, so a Druid who never trained it never sees
-- it.
local function motwDefinition()
    return {
        id        = Druid.DEFINITION_IDS.motw,
        label     = "Druid Mark of the Wild",
        optionKey = Druid.OPTION_KEYS.motw,
        owner     = Druid.PLUGIN_ID,
        messages  = {
            missing = "Mark of the Wild is not on you.",
        },
        isAvailable = function()
            return knowsSpell("Mark of the Wild") == true
                or knowsSpell("Gift of the Wild") == true
        end,
        checkFn = selfBuffCheck(Druid.MOTW_AURAS),
    }
end

-- Thorns: learned later than Mark of the Wild, so a low-level character is never
-- asked about a spell it does not have.
local function thornsDefinition()
    return {
        id        = Druid.DEFINITION_IDS.thorns,
        label     = "Druid Thorns",
        optionKey = Druid.OPTION_KEYS.thorns,
        owner     = Druid.PLUGIN_ID,
        messages  = {
            missing = "Thorns is not on you.",
        },
        isAvailable = function()
            return knowsSpell("Thorns") == true
        end,
        checkFn = selfBuffCheck(Druid.THORNS_AURAS),
    }
end

-- Preferred form: the build's own class option decides which shape is expected.
-- The two core reminders name a fixed shape each; this one follows the build, so
-- a feral cat build and a feral bear build can share one switch.
--
-- Availability has to answer "does this question apply to this character". The
-- preferred shape is read first; when the spellbook cannot be read, the shape's
-- own aura is the proof instead (a cat in Cat Form has evidently learned Cat
-- Form), and with neither answer the reminder stays unavailable rather than
-- nagging about a form the character may not have.
local function preferredFormDefinition()
    return {
        id        = Druid.DEFINITION_IDS.form,
        label     = "Druid preferred form",
        optionKey = Druid.OPTION_KEYS.form,
        owner     = Druid.PLUGIN_ID,
        messages  = {
            missing = "Your build's Preferred form is not active.",
        },
        isAvailable = function()
            local preferred = preferredForm()
            local expected = preferredAuras(preferred)
            if not expected then return false end

            local spell = preferredSpell(preferred)
            local known = spell and knowsSpell(spell) or nil
            if known ~= nil then return known end

            local auras = helpfulAuras()
            if not auras then return false end
            return hasAnyAura(auras, expected)
        end,
        checkFn = function()
            local expected = preferredAuras(preferredForm())
            if not expected then return { active = true } end

            local auras = helpfulAuras()
            if not auras then return nil end
            return { active = hasAnyAura(auras, expected) == true }
        end,
    }
end

function Druid:BuildDefinitions(classToken)
    return {
        { classToken = classToken, definition = motwDefinition() },
        { classToken = classToken, definition = thornsDefinition() },
        { classToken = classToken, definition = preferredFormDefinition() },
    }
end

------------------------------------------------------------------------------
-- Registration, with the anti-duplication guards
------------------------------------------------------------------------------

local function registrySnapshot()
    local monitor = LT.BuffMonitor
    if type(monitor) ~= "table" or type(monitor.GetRegistry) ~= "function" then
        return nil
    end
    local ok, registry = pcall(monitor.GetRegistry, monitor)
    if not ok or type(registry) ~= "table" then return nil end
    return registry
end

-- A definition with the same id, or one already reading the same option key, is
-- the same question asked twice: BuffMonitor would speak twice for one missing
-- buff and the switch would be split between two ids. Stepping aside keeps the
-- core's copy authoritative if a future core version grows these reminders.
local function coreAlreadyOwns(registry, definitionId, optionKey)
    if type(registry) ~= "table" then return nil end
    for classToken, list in pairs(registry) do
        if type(list) == "table" then
            for _, existing in ipairs(list) do
                if existing.id == definitionId then
                    return "a definition with this id is already registered for "
                        .. tostring(classToken)
                end
                if optionKey and existing.optionKey == optionKey then
                    return "definition " .. tostring(existing.id)
                        .. " already reads " .. tostring(optionKey)
                end
            end
        end
    end
    return nil
end

local function classHasId(registry, classToken, definitionId)
    local list = type(registry) == "table" and registry[classToken] or nil
    if type(list) ~= "table" then return false end
    for _, existing in ipairs(list) do
        if existing.id == definitionId then return true end
    end
    return false
end

-- How many of this plugin's definitions a class currently holds, for the
-- diagnostic report. A class the plugin never registered for answers 0.
function Druid:RegisteredCount(classToken)
    local registry = registrySnapshot()
    local list = registry and registry[classToken or self.CLASS] or nil
    if type(list) ~= "table" then return 0 end

    local wanted = {}
    for _, key in pairs(self.DEFINITION_IDS) do wanted[key] = true end

    local count = 0
    for _, existing in ipairs(list) do
        if wanted[existing.id] then count = count + 1 end
    end
    return count
end

local function missingApi()
    if type(LT.PluginAPI) ~= "table"
        or type(LT.PluginAPI.RegisterPlugin) ~= "function" then
        return "the core's PluginAPI is not loaded"
    end
    if type(LT.BuffMonitor) ~= "table"
        or type(LT.BuffMonitor.Register) ~= "function" then
        return "the core's BuffMonitor is not loaded"
    end
    return nil
end

function Druid:Register()
    if initialized then return self:RegisteredCount() end

    local missing = missingApi()
    if missing then
        if not announcedInactive then
            announcedInactive = true
            warn("LunchboxToolkit_Druid: " .. missing
                .. ", so the plugin stays inactive.")
        end
        return 0
    end

    local registry = registrySnapshot()
    if not registry then
        warn("LunchboxToolkit_Druid: the BuffMonitor registry could not be read, "
            .. "so the plugin stays inactive.")
        return 0
    end

    local ok, plugin, reason = pcall(LT.PluginAPI.RegisterPlugin, LT.PluginAPI, {
        id          = self.PLUGIN_ID,
        name        = "Lunchbox Druid",
        version     = self.VERSION,
        author      = "Lunchbox",
        apiVersion  = 1,
        classes     = { self.CLASS },
        description = "Druid form, self-buff and proc support: Mark of the Wild, "
            .. "Thorns and a build-aware form reminder, each off by default and "
            .. "per character; a Druid page in the toolkit window; a hand-confirmed "
            .. "proc aura list for the combo strip; a small form and power HUD with "
            .. "a lock, size and opacity sliders and two switches. "
            .. "The core's own cat and bear form reminders are left alone.",
    })

    if not ok then
        warn("LunchboxToolkit_Druid: plugin registration failed: " .. tostring(plugin))
        return 0
    end
    if not plugin then
        debug("Druid: plugin registration was refused: " .. tostring(reason))
        return 0
    end

    initialized = true

    -- The Plugins page's Commands button shows this list: UI.lua's
    -- pluginCommandRows reads plugin.commands first and only then its own map of
    -- the older bundled plugins, so a plugin that says nothing gets "This plugin
    -- declares no slash commands." Publishing it here keeps the description of a
    -- command in the file that answers it.
    plugin.commands = self.COMMANDS

    local added = 0
    for _, entry in ipairs(self:BuildDefinitions(self.CLASS)) do
        local definition = entry.definition
        local skip = coreAlreadyOwns(registry, definition.id, definition.optionKey)
            or (classHasId(registry, entry.classToken, definition.id)
                and "this definition is already registered for " .. entry.classToken)

        if skip then
            debug("Druid: skipped " .. definition.id .. " — " .. skip .. ".")
        else
            local okRegister, result = pcall(
                LT.BuffMonitor.Register, LT.BuffMonitor, entry.classToken, definition)
            if not okRegister then
                warn("LunchboxToolkit_Druid: registering " .. definition.id
                    .. " failed: " .. tostring(result))
            elseif result then
                added = added + 1
            else
                debug("Druid: BuffMonitor refused " .. definition.id .. ".")
            end
        end
    end

    debug("Druid: " .. tostring(added) .. " definition(s) registered.")

    -- The core's own PLAYER_LOGIN pass has already run by the time this frame
    -- handler fires. Run one check now so an enabled reminder behaves like a
    -- bundled definition on the first login. Never touch frames in combat.
    if added > 0 and isDruid() and not inCombat() then
        local monitor = LT.BuffMonitor
        if type(monitor) == "table" and type(monitor.CheckAll) == "function" then
            pcall(monitor.CheckAll, monitor)
        end
    end

    return added
end

Druid.OnLogin = Druid.Register

------------------------------------------------------------------------------
-- Proc aura names (stored, then handed to the core's tracker)
------------------------------------------------------------------------------

function Druid:ProcNames()
    local saved = store()
    local names = {}
    for _, name in ipairs(saved.procs) do
        if type(name) == "string" and name ~= "" and not isSecret(name) then
            names[#names + 1] = name
        end
    end
    return names
end

-- Hands the stored names to the core's proc strip. An empty list changes
-- nothing, which is the point: the strip stays as the core shipped it until a
-- name has actually been seen in game.
function Druid:ApplyProcs()
    local trackers = LT.Trackers
    if type(trackers) ~= "table" or type(trackers.RegisterProcAuras) ~= "function" then
        return 0, "the core's combo tracker is not loaded"
    end

    local names = self:ProcNames()
    if #names == 0 then return 0, nil end

    local ok, added = pcall(trackers.RegisterProcAuras, trackers, self.CLASS, names)
    if not ok then return 0, tostring(added) end
    return tonumber(added) or 0, nil
end

function Druid:AddProc(name)
    if type(name) ~= "string" then return false, "a proc name must be text" end
    local trimmed = name:match("^%s*(.-)%s*$")
    if trimmed == "" then return false, "a proc name cannot be empty" end
    if isSecret(trimmed) then return false, "that name is unreadable" end

    local saved = store()
    for _, existing in ipairs(saved.procs) do
        if type(existing) == "string" and string.lower(existing) == string.lower(trimmed) then
            return false, "already stored"
        end
    end

    saved.procs[#saved.procs + 1] = trimmed
    self:ApplyProcs()
    return true, nil
end

function Druid:ClearProcs()
    local saved = store()
    local removed = #saved.procs
    saved.procs = {}
    return removed
end

------------------------------------------------------------------------------
-- Probes
--
-- Seven questions this client may or may not answer, asked from the keyboard
-- because a Druid cannot be played from here. Each probe prints only what the
-- client actually said, including "nil" and "secret", so a failed read looks like
-- a failed read instead of an empty line.
------------------------------------------------------------------------------

-- Every spellbook entry this client will name, or nil when it will not read the
-- book at all. The scan belongs to the core (Spellbook:Collect), which tries the
-- modern C_SpellBook route first and only then the tab and legacy routes.
--
-- Asking the core instead of walking the tabs here is the fix for the 13:16 probe
-- on Devillish (Forever, 2026-11-05): the tab route answered nothing on that
-- client while the modern route read the book, so a private copy of the scan
-- reported "did not let the list be read" for a book the core could read. One
-- module opens the spellbook; this one only prints what came back.
local function spellbookNames()
    local book = LT.Spellbook
    if type(book) ~= "table" or type(book.Collect) ~= "function" then
        return nil, 0, nil
    end

    local ok, entries, route = pcall(book.Collect, book)
    if not ok or type(entries) ~= "table" then return nil, 0, nil end

    local names, count = {}, 0
    for _, entry in ipairs(entries) do
        local name = type(entry) == "table" and entry.name or nil
        if not isSecret(name) and type(name) == "string" and name ~= "" then
            count = count + 1
            names[#names + 1] = name
        end
    end

    if count == 0 then return nil, 0, route end
    return names, count, route
end

-- The names a player needs in front of them to confirm an aura: the shapes and
-- anything that reads like a proc. Filtering keeps 40 lines of frostbolt ranks out
-- of the report.
local function interestingSpell(name)
    if type(name) ~= "string" then return false end
    local marked = {
        "Form", "Wild", "Thorns", "Clarity", "Mark", "Gift", "Fury", "Clearcasting",
        "Nature", "Predator", "Ravage", "Shred", "Mangle", "Faerie", "Moonkin",
    }
    for _, word in ipairs(marked) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

local PROBES = {}

PROBES.forms = {
    help = "every shapeshift route the client offers, plus the shape it reads",
    run = function(say)
        local state = formState()
        say("  route that answered: " .. tostring(state.route))
        say("  shape this plugin reads: " .. tostring(formLabel(state)))

        if type(GetShapeshiftFormID) == "function" then
            local ok, value = pcall(GetShapeshiftFormID)
            say("  GetShapeshiftFormID(): " .. (ok and describe(value) or "raised an error"))
        else
            say("  GetShapeshiftFormID: not present on this client")
        end

        if type(GetShapeshiftForm) == "function" then
            local ok, value = pcall(GetShapeshiftForm)
            say("  GetShapeshiftForm(): " .. (ok and describe(value) or "raised an error"))
        else
            say("  GetShapeshiftForm: not present on this client")
        end

        if type(GetNumShapeshiftForms) == "function" then
            local ok, value = pcall(GetNumShapeshiftForms)
            say("  GetNumShapeshiftForms(): " .. (ok and describe(value) or "raised an error"))
        end

        local auras = helpfulAuras()
        if not auras then
            say("  helpful auras: the client did not answer")
            return
        end
        for _, form in ipairs(FORM_AURAS) do
            for _, name in ipairs(form.auras) do
                if auras[name] == true then
                    say("  aura present: " .. name .. " (reads as " .. form.key .. ")")
                end
            end
        end
    end,
}

PROBES.power = {
    help = "power type, current and maximum for each Druid resource",
    run = function(say)
        if type(UnitPowerType) == "function" then
            local ok, kind, token = pcall(UnitPowerType, "player")
            say("  UnitPowerType(\"player\"): "
                .. (ok and (describe(kind) .. " / " .. describe(token)) or "raised an error"))
        else
            say("  UnitPowerType: not present on this client")
        end

        local kinds = { { "MANA", 0 }, { "RAGE", 1 }, { "ENERGY", 3 } }
        for _, entry in ipairs(kinds) do
            if type(UnitPower) == "function" then
                local ok, value = pcall(UnitPower, "player", entry[2])
                local okMax, maximum = pcall(UnitPowerMax, "player", entry[2])
                say("  " .. entry[1] .. " (" .. entry[2] .. "): current "
                    .. (ok and describe(value) or "raised an error")
                    .. ", max " .. (okMax and describe(maximum) or "raised an error"))
            end
        end

        if type(GetComboPoints) == "function" then
            local ok, points = pcall(GetComboPoints, "player", "target")
            say("  GetComboPoints(\"player\", \"target\"): "
                .. (ok and describe(points) or "raised an error"))
        end

        local points, route = nil, "unavailable"
        local trackers = LT.Trackers
        if type(trackers) == "table" and type(trackers.ReadPoints) == "function" then
            local ok, value, from = pcall(trackers.ReadPoints, trackers)
            if ok then points, route = value, tostring(from) end
        end
        say("  core combo points: " .. describe(points) .. " (route " .. route .. ")")

        say("  form line the HUD would draw: " .. Druid:FormLine())
        say("  power line the HUD would draw: " .. Druid:PowerLine())
    end,
}

PROBES.spells = {
    help = "the spells this plugin gates on, then the spellbook names worth confirming",
    run = function(say)
        local checks = {
            "Mark of the Wild", "Gift of the Wild", "Thorns", "Cat Form", "Bear Form",
            "Dire Bear Form", "Travel Form", "Aquatic Form", "Moonkin Form",
            "Tree of Life Form", "Faerie Fire", "Omen of Clarity", "Innervate",
            "Rebirth", "Feral Charge", "Mangle", "Shred", "Wrath", "Healing Touch",
        }
        say("  the core's scan matches a name that CONTAINS the pattern, so")
        say("  \"Bear Form\" answers true for Dire Bear Form as well")
        for _, name in ipairs(checks) do
            local known = knowsSpell(name)
            local text = "no answer"
            if known == true then
                text = "known"
            elseif known == false then
                text = "not known"
            end
            say("  " .. name .. ": " .. text)
        end

        local names, count, route = spellbookNames()
        if not names then
            say("  spellbook: this client did not let the list be read"
                .. (route and (" (last route tried: " .. tostring(route) .. ")") or ""))
            return
        end
        say("  spellbook: " .. tostring(count) .. " named spells, route "
            .. tostring(route))
        local shown = 0
        for _, name in ipairs(names) do
            if interestingSpell(name) then
                say("    " .. name)
                shown = shown + 1
                if shown >= 25 then
                    say("    (stopped at 25 matching names)")
                    break
                end
            end
        end
        if shown == 0 then say("    (no name matched the filter)") end
    end,
}

PROBES.auras = {
    help = "every helpful aura name on the player, which is how a proc name is confirmed",
    run = function(say)
        local auras = helpfulAuras()
        if not auras then
            say("  the client did not answer the aura scan")
            return
        end

        local names = {}
        for name in pairs(auras) do
            if type(name) == "string" and name ~= "" and not isSecret(name) then
                names[#names + 1] = name
            end
        end
        table.sort(names)

        local stored = Druid:ProcNames()

        say("  " .. tostring(#names) .. " helpful aura name(s):")
        for _, name in ipairs(names) do
            local matched = false
            for _, candidate in ipairs(stored) do
                if string.lower(candidate) == string.lower(name) then matched = true end
            end
            say("    " .. name .. (matched and "   [stored as a proc]" or ""))
        end
        if #names == 0 then
            say("    (none — cast a buff and run this again)")
        end
    end,
}

PROBES.slots = {
    help = "the inventory slot numbers, including whether this client exposes a relic slot",
    run = function(say)
        local wanted = { "RelicSlot", "RangedSlot", "HeadSlot", "MainHandSlot", "OffHandSlot" }
        if type(GetInventorySlotInfo) ~= "function" then
            say("  GetInventorySlotInfo: not present on this client")
        else
            for _, slotName in ipairs(wanted) do
                local ok, id = pcall(GetInventorySlotInfo, slotName)
                say("  GetInventorySlotInfo(\"" .. slotName .. "\"): "
                    .. (ok and describe(id) or "raised an error"))
            end
        end

        if type(GetInventoryItemLink) ~= "function" then
            say("  GetInventoryItemLink: not present on this client")
            return
        end
        for _, slot in ipairs({ 18, 17, 16 }) do
            local ok, link = pcall(GetInventoryItemLink, "player", slot)
            local text = "no answer"
            if ok then
                if isSecret(link) then
                    text = "secret"
                elseif type(link) ~= "string" or link == "" then
                    text = "empty"
                else
                    text = "an item is equipped"
                end
            end
            say("  slot " .. slot .. ": " .. text)
        end
    end,
}

PROBES.target = {
    help = "whether a target's name and debuff names can be read at all",
    run = function(say)
        if type(UnitExists) ~= "function" then
            say("  UnitExists: not present on this client")
            return
        end

        local okExists, exists = pcall(UnitExists, "target")
        say("  UnitExists(\"target\"): " .. (okExists and describe(exists) or "raised an error"))
        if not okExists or exists ~= true then
            say("  (no target: select one and run this again)")
            return
        end

        if type(UnitName) == "function" then
            local okName, name = pcall(UnitName, "target")
            say("  UnitName(\"target\"): "
                .. (okName and describe(name) or "raised an error")
                .. (okName and isSecret(name) and " (secret: no name can be printed)" or ""))
        end

        if type(UnitIsEnemy) == "function" then
            local okEnemy, enemy = pcall(UnitIsEnemy, "player", "target")
            say("  UnitIsEnemy: " .. (okEnemy and describe(enemy) or "raised an error"))
        end

        -- The debuff names matter for any future reminder that reads the target
        -- (Faerie Fire, a bear's Demoralising Roar). A secret name here means
        -- such a reminder could never work.
        if type(UnitDebuff) ~= "function" then
            say("  UnitDebuff: not present on this client")
            return
        end
        for index = 1, 6 do
            local okDebuff, name = pcall(UnitDebuff, "target", index)
            say("  target debuff " .. index .. ": "
                .. (okDebuff and describe(name) or "raised an error"))
        end
    end,
}

PROBES.procs = {
    help = "the stored proc names, which are registered, and which are lit right now",
    run = function(say)
        local stored = Druid:ProcNames()
        say("  stored names: " .. tostring(#stored))
        for _, name in ipairs(stored) do say("    " .. name) end
        if #stored == 0 then
            say("    (none: /lt druid procs add <exact aura name>)")
        end

        local activeCount = 0
        local trackers = LT.Trackers
        if type(trackers) == "table" and type(trackers.ActiveProcs) == "function" then
            local ok, active = pcall(trackers.ActiveProcs, trackers)
            if ok and type(active) == "table" then
                activeCount = #active
                for _, name in ipairs(active) do
                    say("  lit now: " .. tostring(name))
                end
            else
                say("  the core's proc scan did not answer")
            end
        else
            say("  the core's proc scan is not loaded")
        end
        say("  lit now: " .. tostring(activeCount) .. " name(s)")
    end,
}

-- Fixed order, so the usage line reads the same way every time.
local PROBE_ORDER = { "forms", "power", "spells", "auras", "slots", "target", "procs" }

function Druid:ProbeWords() return PROBE_ORDER end

function Druid:ProbeUsage()
    local parts = { "all" }
    for _, word in ipairs(PROBE_ORDER) do parts[#parts + 1] = word end
    return table.concat(parts, "|")
end

-- Runs one probe. The header names the word and the character, so a report pasted
-- from the chat log says which class and level answered it — the answer differs
-- only once the character has trained the spell.
function Druid:Probe(word)
    local key = tostring(word or ""):lower()

    -- "all" exists because asking a player for seven separate commands costs seven
    -- round trips and loses the ordering that makes the answers readable. Each
    -- section still runs on its own, so one raised error cannot swallow the rest.
    if key == "all" then
        for _, name in ipairs(PROBE_ORDER) do
            self:Probe(name)
        end
        report("probe all: " .. tostring(#PROBE_ORDER) .. " probes done")
        return true
    end

    local entry = PROBES[key]
    if not entry then
        report("usage: /lt druid probe " .. self:ProbeUsage())
        return false
    end

    local player = LT.player or {}
    report("probe " .. key .. " (" .. tostring(player.class or "?")
        .. ", level " .. tostring(player.level or "?") .. "): " .. tostring(entry.help))

    local say = function(line) report(tostring(line)) end
    local ok, err = pcall(entry.run, say)
    if not ok then
        report("  the probe stopped: " .. tostring(err))
    end
    return true
end

------------------------------------------------------------------------------
-- Status and diagnostics
------------------------------------------------------------------------------

-- One line per switch: whether it is on, whether the client makes it meaningful,
-- and what the check answers right now. "no answer" is a first-class outcome, so
-- a silent reminder can be told apart from a satisfied one.
function Druid:DescribeSwitch(switch)
    local optionKey = self.OPTION_KEYS[switch.key]
    local parts = {}
    parts[#parts + 1] = switch.label .. ": "
        .. (self:IsEnabled(optionKey) and "on" or "off")

    for _, entry in ipairs(self:BuildDefinitions(self.CLASS)) do
        local definition = entry.definition
        if definition.optionKey == optionKey then
            if type(definition.isAvailable) == "function" then
                local okAvailable, available = pcall(definition.isAvailable)
                if not okAvailable then
                    parts[#parts + 1] = "question not answerable"
                elseif available == false then
                    local _, reason = self:Availability(switch)
                    parts[#parts + 1] = reason
                else
                    parts[#parts + 1] = "ready"
                end
            end

            local okCheck, state = pcall(definition.checkFn)
            if not okCheck then
                parts[#parts + 1] = "the check raised an error"
            elseif type(state) ~= "table" then
                parts[#parts + 1] = "no answer from the client"
            elseif state.active == true then
                parts[#parts + 1] = "satisfied"
            elseif state.active == false then
                parts[#parts + 1] = "would warn"
            else
                parts[#parts + 1] = "no answer from the client"
            end
        end
    end

    return table.concat(parts, " — ")
end

-- A short readiness word, for the page: "ready" when the client makes the
-- reminder meaningful, "not yet" when the spell behind it is not learned, and
-- "unknown" when the client would not answer. This is what tells a level-1 Druid
-- why the Thorns switch does nothing yet.
function Druid:SwitchReadiness(switch)
    local optionKey = self.OPTION_KEYS[switch.key]
    for _, entry in ipairs(self:BuildDefinitions(self.CLASS)) do
        local definition = entry.definition
        if definition.optionKey == optionKey then
            if type(definition.isAvailable) ~= "function" then return "ready" end
            local ok, available = pcall(definition.isAvailable)
            if not ok then return "unknown" end
            if available == false then return "not yet" end
            return "ready"
        end
    end
    return "unknown"
end

-- Why a switch is not answering, in words the player can act on. "Not available
-- for this character" was the first wording and it was wrong twice over: it reads
-- like a bug rather than a level gate, and it never said which spell was missing.
-- The capture at 13:16 on Devillish (level 1, Forever) is the case that produced
-- it: the spellbook answered, and the honest answer was "Mark of the Wild is not
-- in it yet".
local function notYetReason(key)
    if key == "motw" then
        return "not yet — Mark of the Wild is not in your spellbook yet; "
            .. "the switch starts answering the moment it is learned"
    end
    if key == "thorns" then
        return "not yet — Thorns is not in your spellbook yet; "
            .. "the switch starts answering the moment it is learned"
    end
    if key == "form" then
        local preferred = preferredForm()
        if preferred == nil then
            return "no build answered, so there is no preferred shape to check"
        end
        if not preferredAuras(preferred) then
            return "your build prefers " .. tostring(preferred)
                .. ", which is not a single shape, so there is nothing to warn about"
        end
        return "not yet — your build prefers " .. tostring(preferred)
            .. ", and that shape is not in your spellbook yet"
    end
    return "not yet"
end

-- The switch's gate as a state plus a sentence: "ready", "not yet" (a level or
-- training gate) or "unknown" (the client would not answer). One function so the
-- page, the status lines and the diagnostic report cannot disagree.
function Druid:Availability(switch)
    local state = self:SwitchReadiness(switch)
    if state == "ready" then return state, "ready" end
    if state == "unknown" then
        return state, "unknown — the client would not answer the spellbook scan"
    end
    return state, notYetReason(switch.key)
end

function Druid:Report()
    local player = LT.player or {}
    report("LunchboxToolkit_Druid " .. self.VERSION .. " on "
        .. tostring(player.class or "?") .. " level " .. tostring(player.level or "?"))

    if not isDruid() then
        report("  This plugin is for Druid characters; nothing it registers applies here.")
    end

    report("  form: " .. tostring(self:FormLabel() or "no answer")
        .. " | " .. self:PowerLine()
        .. " | build's Preferred form: " .. tostring(self:PreferredForm() or "no answer"))
    report("  definitions registered for DRUID: "
        .. tostring(self:RegisteredCount()) .. " of 3")

    for _, switch in ipairs(self.SWITCHES) do
        report("  " .. self:DescribeSwitch(switch))
    end

    local procs = self:ProcNames()
    report("  proc names stored: " .. tostring(#procs) .. " (see /lt druid procs)")

    local hud = LT.DruidHUD
    if type(hud) == "table" and type(hud.IsEnabled) == "function" then
        local ok, on = pcall(hud.IsEnabled, hud)
        report("  form and power HUD: " .. (ok and (on and "on" or "off") or "unknown"))

        -- The lock, the look and the two switches, so a bug post that carries the
        -- report also carries what the player actually set on the strip.
        local okLocked, locked = pcall(hud.IsLocked, hud)
        local okScale, scale = pcall(hud.GetScale, hud)
        local okAlpha, alpha = pcall(hud.GetAlpha, hud)
        local okPoints, points = pcall(hud.ShowsPoints, hud)
        local okColour, colour = pcall(hud.ColoursByForm, hud)
        report("  HUD lock: " .. (okLocked and (locked and "locked" or "unlocked") or "unknown")
            .. ", size " .. ((okScale and type(scale) == "number") and string.format("%.2f", scale) or "unknown")
            .. ", opacity " .. ((okAlpha and type(alpha) == "number") and string.format("%.2f", alpha) or "unknown"))
        report("  HUD switches: combo " .. (okPoints and (points and "on" or "off") or "unknown")
            .. ", colour by shape " .. (okColour and (colour and "on" or "off") or "unknown"))
    else
        report("  form and power HUD: not loaded")
    end

    report("  switches: /lt druid on|off " .. switchWords())
    report("  probes: /lt druid probe " .. self:ProbeUsage())
end

-- The report a player attaches to a bug post: the status lines plus every client
-- read this plugin depends on, each named with the answer it gave. It never
-- prints an item name or a unit name, so nothing secret can leak into it.
function Druid:Diagnose()
    self:Report()

    report("  -- client reads --")
    local state = formState()
    report("  shapeshift route: " .. tostring(state.route)
        .. " | id: " .. describe(state.id)
        .. " | index: " .. describe(state.index)
        .. " | name: " .. describe(state.name)
        .. " | aura: " .. describe(state.auraName))

    local auras = helpfulAuras()
    if not auras then
        report("  helpful auras: the client did not answer")
    else
        local count = 0
        for _ in pairs(auras) do count = count + 1 end
        report("  helpful auras read: " .. tostring(count))
        report("  Mark of the Wild: " .. (hasAnyAura(auras, Druid.MOTW_AURAS)
            and "present" or "absent"))
        report("  Thorns: " .. (hasAnyAura(auras, Druid.THORNS_AURAS)
            and "present" or "absent"))
        local preferred = preferredForm()
        local expected = preferredAuras(preferred)
        if expected then
            report("  preferred form " .. tostring(preferred) .. ": "
                .. (hasAnyAura(auras, expected) and "present" or "absent"))
        else
            report("  preferred form: " .. tostring(preferred)
                .. " (this plugin does not police it)")
        end
    end

    report("  spellbook gates:")
    local gates = { "Mark of the Wild", "Gift of the Wild", "Thorns", "Cat Form", "Bear Form" }
    for _, name in ipairs(gates) do
        local known = knowsSpell(name)
        local text = "no answer"
        if known == true then
            text = "known"
        elseif known == false then
            text = "not known"
        end
        report("    " .. name .. ": " .. text)
    end

    -- The route matters as much as the count: the 13:16 capture showed a book the
    -- core could read while a tab-only scan reported nothing, so a bug report that
    -- names the route is the one that can be acted on.
    local bookNames, bookCount, bookRoute = spellbookNames()
    if bookNames then
        report("  spellbook: " .. tostring(bookCount) .. " named spells, route "
            .. tostring(bookRoute))
    else
        report("  spellbook: the client would not read the book")
    end

    local power = powerState()
    report("  power: type " .. describe(power.id) .. " (" .. tostring(power.token)
        .. ") current " .. describe(power.current) .. " max " .. describe(power.max)
        .. (power.inCombat and " [in combat: secret on this client]" or ""))

    report("  -- definitions in the DRUID registry --")
    local registry = registrySnapshot()
    local list = registry and registry[self.CLASS] or nil
    if type(list) ~= "table" then
        report("  the registry could not be read")
    else
        for _, definition in ipairs(list) do
            local mine = false
            for _, key in pairs(self.DEFINITION_IDS) do
                if definition.id == key then mine = true end
            end
            local owner = definition.owner and (" [plugin " .. tostring(definition.owner) .. "]")
                or " [core]"
            report("    " .. tostring(definition.id) .. owner
                .. (mine and " <- this plugin" or ""))
        end
    end

    report("  -- next --")
    report("  run every probe in one go with /lt druid probe all,")
    report("  or one at a time with /lt druid probe <" .. self:ProbeUsage() .. ">;")
    report("  'forms' answers whether GetShapeshiftFormID exists, 'power' whether")
    report("  cat Energy is readable, 'target' whether a debuff name can be read at all.")
end

------------------------------------------------------------------------------
-- The Druid page
--
-- Contributed to the core window with UI:AddPage, so the core ships with no such
-- page and no reference to this file. The tab appears only while this plugin is
-- installed. The drawer receives the page's content frame (and, in this build, a
-- cursor), and parents every widget to it so the core's clear-and-pool pass tidies
-- them up like a bundled page.
------------------------------------------------------------------------------

local pageState = { message = nil }

local function redraw()
    local ui = LT.UI
    if type(ui) == "table" and type(ui.Refresh) == "function" then
        pcall(ui.Refresh, ui)
    end
end

-- A full-width text row. The width and justification are set here because a reused
-- pooled label keeps whatever the previous page gave it.
local function drawLine(content, text, y, colour)
    local label = LT.UI:MakeLabel(content, text, "GameFontNormalSmall", colour)
    if label == nil then return y - 18 end
    label:ClearAllPoints()
    label:SetPoint("TOPLEFT", 6, y)
    label:SetWidth(math.max(120, (content:GetWidth() or 600) - 12))
    label:SetJustifyH("LEFT")
    return y - 18
end

local GREEN  = { r = 0.20, g = 1.00, b = 0.20 }
local GREY   = { r = 0.70, g = 0.70, b = 0.70 }
local YELLOW = { r = 1.00, g = 0.82, b = 0.10 }

-- One switch row: the label, then a button that says what pressing it will do.
-- Reading the option on every draw means the page never shows a stale On/Off.
local function drawSwitch(content, switch, y)
    local optionKey = Druid.OPTION_KEYS[switch.key]
    local on = Druid:IsEnabled(optionKey)
    local readiness = Druid:SwitchReadiness(switch)

    local text = switch.label
    if readiness ~= "ready" then
        text = text .. "  (" .. readiness .. ")"
    end

    local label = LT.UI:MakeLabel(content, text, "GameFontNormalSmall",
        on and GREEN or GREY)
    if label ~= nil then
        label:ClearAllPoints()
        label:SetPoint("TOPLEFT", 6, y)
        label:SetWidth(math.max(120, (content:GetWidth() or 600) - 96))
        label:SetJustifyH("LEFT")
    end

    local button = LT.UI:MakeButton(content, on and "On" or "Off", 60, 18, function()
        local nowOn = not Druid:IsEnabled(optionKey)
        Druid:SetEnabled(optionKey, nowOn)
        pageState.message = switch.label .. (nowOn and " is on." or " is off.")
        -- Pressing a switch that cannot answer yet says why, so "nothing happens"
        -- is never the whole story.
        local state, reason = Druid:Availability(switch)
        if nowOn and state ~= "ready" then
            pageState.message = pageState.message .. " " .. reason
        end
        redraw()
    end)
    if button ~= nil then
        button:SetPoint("TOPLEFT", math.max(160, (content:GetWidth() or 600) - 84), y + 2)
    end

    return y - 22
end

local function drawPage(content, cursor)
    if content == nil then return end

    local y = -6

    y = drawLine(content, "Druid", y, YELLOW)
    if not isDruid() then
        y = drawLine(content, "This page is for Druid characters. Nothing here applies "
            .. "to the character you are logged in as.", y, GREY)
        if cursor then cursor.y = y end
        return
    end

    y = drawLine(content, "Form: " .. tostring(Druid:FormLabel() or "no answer")
        .. "    " .. Druid:PowerLine()
        .. "    build's Preferred form: " .. tostring(Druid:PreferredForm() or "no answer"), y, GREY)

    local pointsLine = Druid:PointsLine()
    if pointsLine then
        y = drawLine(content, pointsLine, y, GREY)
    end

    y = y - 6
    y = drawLine(content, "Reminders (each off by default, per character):", y, GREY)

    for _, switch in ipairs(Druid.SWITCHES) do
        y = drawSwitch(content, switch, y)
        y = drawLine(content, switch.help, y, GREY)
    end

    -- The level gate, said once instead of on every row: what "not yet" means and
    -- that there is nothing to press. Devillish at level 1 is the character this
    -- was written for (2026-11-05).
    local gated = 0
    for _, switch in ipairs(Druid.SWITCHES) do
        if Druid:SwitchReadiness(switch) == "not yet" then gated = gated + 1 end
    end
    if gated > 0 then
        y = y - 2
        y = drawLine(content, "Not yet = the spell is not in your spellbook at level "
            .. tostring((LT.player or {}).level or "?")
            .. " yet. It starts working by itself once learned.", y, GREY)
    end

    y = y - 8
    local diagButton = LT.UI:MakeButton(content, "Diagnostics to chat", 160, 20, function()
        Druid:Diagnose()
        pageState.message = "Diagnostics printed to the chat frame."
        redraw()
    end)
    if diagButton ~= nil then
        diagButton:SetPoint("TOPLEFT", 6, y)
    end

    local probeButton = LT.UI:MakeButton(content, "Probe commands", 160, 20, function()
        pageState.message = "Run in chat: /lt druid probe <" .. Druid:ProbeUsage() .. ">"
        redraw()
    end)
    if probeButton ~= nil then
        probeButton:SetPoint("TOPLEFT", 176, y)
    end
    y = y - 30

    -- The strip's own two controls, so the page can turn it on and unlock it
    -- without a slash command. They are the same two doors the cog and
    -- /lt druid hud open; nothing is stored here.
    local hud = LT.DruidHUD
    if type(hud) == "table" and type(hud.Command) == "function" then
        local okOn, hudOn = pcall(hud.IsEnabled, hud)
        local okLocked, hudLocked = pcall(hud.IsLocked, hud)
        y = y - 8
        y = drawLine(content, "Form and power HUD: "
            .. (okOn and (hudOn and "on" or "off") or "unknown") .. ", "
            .. (okLocked and (hudLocked and "locked" or "unlocked") or "unknown")
            .. ". The cog in its corner is the lock; the panel under it holds the "
            .. "size and opacity sliders and the two switches.", y, GREY)

        local hudButton = LT.UI:MakeButton(content, "HUD on / off", 160, 20, function()
            local wanted = "on"
            if type(hud.IsEnabled) == "function" then
                local ok, on = pcall(hud.IsEnabled, hud)
                if ok and on == true then wanted = "off" end
            end
            pcall(hud.Command, hud, { "druid", "hud", wanted })
            redraw()
        end)
        if hudButton ~= nil then
            hudButton:SetPoint("TOPLEFT", 6, y)
        end

        local lockButton = LT.UI:MakeButton(content, "Lock / unlock", 160, 20, function()
            -- One button, two states: it always does the opposite of the strip now.
            local wanted = "unlock"
            if type(hud.IsLocked) == "function" then
                local ok, locked = pcall(hud.IsLocked, hud)
                if ok and locked == false then wanted = "lock" end
            end
            pcall(hud.Command, hud, { "druid", "hud", wanted })
            redraw()
        end)
        if lockButton ~= nil then
            lockButton:SetPoint("TOPLEFT", 176, y)
        end
        y = y - 30
    end

    local stored = Druid:ProcNames()
    y = drawLine(content, "Proc aura names for the combo strip: " .. tostring(#stored)
        .. ". Add one with /lt druid procs add <name> after reading /lt druid probe auras.",
        y, GREY)

    if pageState.message then
        y = y - 6
        y = drawLine(content, pageState.message, y, GREEN)
    end

    if cursor then cursor.y = y end
end

local pageAdded = false

function Druid:AddPage()
    if pageAdded then return true end

    local ui = LT.UI
    if type(ui) ~= "table" or type(ui.AddPage) ~= "function" then return false end
    if type(ui.MakeButton) ~= "function" or type(ui.MakeLabel) ~= "function" then
        return false
    end

    local ok, added, reason = pcall(ui.AddPage, ui, self.PAGE_KEY, "Druid", drawPage)
    if ok and added then
        pageAdded = true
        debug("Druid: page added.")
        return true
    end

    -- A refusal that says the page already exists means an earlier copy of this
    -- file registered it, which is fine: there is one tab and it is ours.
    if ok and type(reason) == "string" and reason:find("already exists", 1, true) then
        pageAdded = true
        return true
    end

    if ok and reason then
        debug("Druid: page not added: " .. tostring(reason))
    end
    return false
end

------------------------------------------------------------------------------
-- Slash surface (/lt druid …)
------------------------------------------------------------------------------

local commandRegistered = false

local function registerCommand()
    if commandRegistered then return true end

    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then
        return false
    end

    local ok, added = pcall(slash.RegisterCommand, slash, "druid",
        function(words) Druid:Command(words) end,
        "/lt druid — Druid reminders, probes and the Druid page")

    if ok and added == true then
        commandRegistered = true
        return true
    end
    return false
end

function Druid:Usage()
    return "/lt druid [status|diag|on <key>|off <key>|probe <"
        .. self:ProbeUsage() .. ">|procs [list|add <name>|clear]|page|"
        .. "hud [on|off|lock|unlock|scale <n>|alpha <n>|combo on|off|"
        .. "colour on|off|reset]]"
end

-- The list the Plugins page's Commands button shows. UI.lua's pluginCommandRows
-- reads plugin.commands before its own map of the bundled plugins, so this is the
-- one place a Druid command is described; Register() publishes it. One row per
-- command Command() below actually answers: a row for a word that would fall
-- through to the usage line would be a promise the plugin does not keep.
Druid.COMMANDS = {
    { cmd = "/lt druid", help = "Prints the status: each reminder, the form and "
        .. "power HUD, and the stored proc names." },
    { cmd = "/lt druid on|off <motw|thorns|form>", help = "Arms or disarms one "
        .. "per-character reminder: Mark of the Wild, Thorns, or the feral "
        .. "preferred-form warning. A reminder whose spell is not learned yet "
        .. "stays silent rather than warning from a guess." },
    { cmd = "/lt druid probe <" .. Druid:ProbeUsage() .. ">", help = "Reads what the "
        .. "client actually answers and prints it. The answer differs by level and "
        .. "form, so it is measured rather than assumed." },
    { cmd = "/lt druid procs", help = "Lists the hand-confirmed proc aura names "
        .. "the core's combo strip watches, and how many are lit right now." },
    { cmd = "/lt druid procs add <name>", help = "Stores one proc aura name. "
        .. "Everything after add is the name, so a name with a space survives." },
    { cmd = "/lt druid procs clear", help = "Removes every stored proc name. The "
        .. "auras the client reports are not touched." },
    { cmd = "/lt druid hud on|off", help = "Shows or hides the form and power "
        .. "strip." },
    { cmd = "/lt druid hud lock|unlock", help = "Locks the strip so it takes no "
        .. "mouse, or unlocks it to show the cog's panel." },
    { cmd = "/lt druid hud scale <n>", help = "Strip size, 0.50 to 1.60; the same "
        .. "value the panel's Size slider writes." },
    { cmd = "/lt druid hud alpha <n>", help = "Background opacity, 0.10 to 1.00. "
        .. "The text stays at full strength." },
    { cmd = "/lt druid hud combo on|off", help = "Shows or hides the combo counter "
        .. "on the strip's power line." },
    { cmd = "/lt druid hud colour on|off", help = "Paints the form line per shape, "
        .. "or leaves it in one colour." },
    { cmd = "/lt druid hud reset", help = "Puts the strip back in the middle of "
        .. "the screen." },
    { cmd = "/lt druid page", help = "Opens the toolkit window on the Druid page." },
    { cmd = "/lt druid diag", help = "Prints the status plus every client read this "
        .. "plugin depends on, each named with the answer it gave." },
}

function Druid:PrintProcs()
    local stored = self:ProcNames()
    report("Druid proc names stored: " .. tostring(#stored))
    for index, name in ipairs(stored) do
        report("  " .. tostring(index) .. ". " .. name)
    end
    if #stored == 0 then
        report("  (empty — read /lt druid probe auras, then add the exact name)")
    end

    local trackers = LT.Trackers
    if type(trackers) == "table" and type(trackers.ActiveProcs) == "function" then
        local ok, active = pcall(trackers.ActiveProcs, trackers)
        if ok and type(active) == "table" then
            report("  lit right now: " .. tostring(#active))
        end
    end
end

function Druid:Command(words)
    local action = string.lower(tostring(words and words[2] or ""))
    local argument = words and words[3]

    if action == "" or action == "status" then
        self:Report()
        return true
    end

    if action == "diag" or action == "diagnose" or action == "diagnostics" then
        self:Diagnose()
        return true
    end

    if action == "help" then
        report(self:Usage())
        for _, switch in ipairs(self.SWITCHES) do
            report("  " .. switch.key .. ": " .. switch.help)
        end
        return true
    end

    if action == "on" or action == "off" then
        local switch = switchByWord(argument)
        if not switch then
            report("usage: /lt druid " .. action .. " <" .. switchWords() .. ">")
            return true
        end
        local optionKey = self.OPTION_KEYS[switch.key]
        self:SetEnabled(optionKey, action == "on")
        report(switch.label .. " reminder " .. (action == "on" and "on." or "off."))
        return true
    end

    if action == "probe" then
        self:Probe(argument)
        return true
    end

    if action == "procs" then
        local sub = string.lower(tostring(argument or ""))
        if sub == "" or sub == "list" then
            self:PrintProcs()
            return true
        end
        if sub == "clear" then
            local removed = self:ClearProcs()
            report("Removed " .. tostring(removed) .. " stored proc name(s).")
            return true
        end
        if sub == "add" then
            -- Everything after `add`, so a name with a space survives.
            local parts = {}
            for index = 4, #words do
                if type(words[index]) == "string" then parts[#parts + 1] = words[index] end
            end
            local name = table.concat(parts, " ")
            local ok, reason = self:AddProc(name)
            if ok then
                report("Stored the proc name \"" .. name .. "\".")
            else
                report("Not stored: " .. tostring(reason) .. ".")
            end
            return true
        end
        report("usage: /lt druid procs [list|add <name>|clear]")
        return true
    end

    if action == "page" then
        local ui = LT.UI
        if type(ui) ~= "table" then
            report("The toolkit window is not loaded.")
            return true
        end
        self:AddPage()
        if type(ui.Show) == "function" then pcall(ui.Show, ui) end
        if type(ui.ShowPage) == "function" then pcall(ui.ShowPage, ui, self.PAGE_KEY) end
        return true
    end

    if action == "hud" then
        local hud = LT.DruidHUD
        if type(hud) ~= "table" or type(hud.Command) ~= "function" then
            report("The form and power HUD is not loaded (it is Druid-only).")
            return true
        end
        pcall(hud.Command, hud, words)
        return true
    end

    report(self:Usage())
    return true
end

-- Registered at file load so `/lt help` lists the word before login.
registerCommand()

------------------------------------------------------------------------------
-- Events
--
-- The plugin wires its own login frame the same way Racials and Threat do: the
-- core does not walk plugin modules through its module stage.
------------------------------------------------------------------------------

local function onAddonLoaded(name)
    if name ~= "LunchboxToolkit_Druid" then return end
    store()
    registerCommand()
    Druid:AddPage()
end

local function onPlayerLogin()
    -- Both are re-asserted at login: another addon may have replaced the slash
    -- binding, and the class is only known once the player is in the world.
    registerCommand()
    store()
    Druid:Register()
    Druid:ApplyProcs()
    Druid:AddPage()

    local hud = LT.DruidHUD
    if type(hud) == "table" and type(hud.OnLogin) == "function" then
        pcall(hud.OnLogin, hud)
    end

    if isDruid() then
        report("Lunchbox Druid ready: /lt druid lists the switches, the probes and the "
            .. "Druid page.")
    end
end

Druid.OnPlayerLogin = onPlayerLogin

local createFrame = rawget(_G, "CreateFrame")
if type(createFrame) == "function" then
    local okFrame, frame = pcall(createFrame, "Frame", "LunchboxToolkitDruidFrame")
    if okFrame and frame then
        pcall(frame.RegisterEvent, frame, "ADDON_LOADED")
        pcall(frame.RegisterEvent, frame, "PLAYER_LOGIN")
        frame:SetScript("OnEvent", function(_, event, arg1)
            if event == "ADDON_LOADED" then
                onAddonLoaded(describe(arg1))
            elseif event == "PLAYER_LOGIN" then
                onPlayerLogin()
            end
        end)
    end
end















