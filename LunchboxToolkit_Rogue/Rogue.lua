--[[--------------------------------------------------------------------------
    LunchboxToolkit_Rogue — main-hand and off-hand poison reminders

    This plugin is behaviour only. The Rogue's class data (specRoles and the
    levelling PvE templates) lives in the core at Classes\Rogue.lua, so a
    fresh install works with this folder absent.

    What it adds:
      * two BuffMonitor definitions, registered for ROGUE only, each with its
        own per-character option key and each off by default:
          - "no poison on the main hand" — rogueMainHandPoison,
            definition id rogue_main_hand_poison;
          - "no poison on the off hand"  — rogueOffHandPoison,
            definition id rogue_off_hand_poison. A separate switch, so the off
            hand can be armed without the main hand. It is unavailable while
            the off-hand slot (17) is empty, so a one-weapon Rogue never sees
            it;
      * a plugin registration carrying classes = { "ROGUE" }, so the core can
        ignore this plugin on every other class.

    Settings rows: the core's Settings page owns its layout and this plugin
    cannot add a row to it. Rogue:GetOptionRows("ROGUE") returns the row data
    (key, label, help, default) for a UI that wants to draw it, and until such
    a row exists the off-hand switch is reachable by command:
      /run LunchboxToolkit.Rogue:SetEnabled("rogueOffHandPoison", true)
    Both switches start off; a missing key reads as off.

    Poison damage is deliberately NOT scored. There is no stat key for it in
    this addon: scoring would need a real stat with a unit and a conversion
    from poison damage to that unit, which is new core work. This plugin
    therefore registers no adjustments and touches no weights.

    Detection, and what it cannot answer:
      A poison in this client is a temporary weapon enhancement. The client
      exposes the temporary-enhancement slot but not which poison it is, and a
      sharpening stone, weightstone or oil occupies the same slot. So "a
      temporary enhancement is present" is the strongest claim this plugin
      makes, and a sharpening stone on a Rogue's main hand reads as satisfied
      rather than missing. That is a deliberate false negative: a wrong "your
      poison is missing" warning would be worse than no warning. The off-hand
      reminder inherits exactly the same limit; its help text says so.

      Both hands ask C_Item.GetWeaponEnchantInfo(slot) FIRST. On this client the
      legacy GetWeaponEnchantInfo pair only reports the Classic temporary
      enchants, so it cannot see a poison at all; its "false" is never proof
      that a hand is bare while the modern call exists. The legacy pair is only
      a fallback for a hand the modern call answers nothing about, and when the
      two disagree the modern answer wins and both are printed through LT:Diag.
      When neither answers, or a value is secret, the check returns "unknown"
      and the reminder stays silent. It never warns from a guess.

    The plugin declares no SavedVariables of its own: the switches live in the
    core's per-character options table, because that is the table BuffMonitor
    reads.
--------------------------------------------------------------------------]]

if not LunchboxToolkit then return end
local LT = LunchboxToolkit

local Rogue = {}
LT.Rogue = Rogue

Rogue.PLUGIN_ID  = "lunchbox_rogue"
Rogue.CLASS      = "ROGUE"
Rogue.VERSION = "1.0.0"

Rogue.OPTION_KEYS = {
    mainHandPoison = "rogueMainHandPoison",
    offHandPoison  = "rogueOffHandPoison",
}

Rogue.DEFINITION_IDS = {
    mainHandPoison = "rogue_main_hand_poison",
    offHandPoison  = "rogue_off_hand_poison",
}

local initialized = false
local announcedInactive = false

------------------------------------------------------------------------------
-- Logging and boundary guards
------------------------------------------------------------------------------

local function report(message)
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

-- Diagnostic line, printed only while the dev switch or debugChat is on.
local function diag(message)
    if type(LT.Diag) == "function" then
        pcall(LT.Diag, LT, message)
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

local function inCombat()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, value = pcall(InCombatLockdown)
    return ok and value == true
end

-- The core owns the hand numbers (16 main, 17 off) in ClassData:WeaponSlot;
-- asking it keeps one copy of them in the addon. nil means the core's table is
-- missing, which every caller reads as "cannot answer".
local function weaponSlot(which)
    local classData = LT.ClassData
    if type(classData) ~= "table" or type(classData.WeaponSlot) ~= "function" then
        return nil
    end
    local ok, slot = pcall(classData.WeaponSlot, classData, which)
    if ok and type(slot) == "number" then return slot end
    return nil
end

------------------------------------------------------------------------------
-- Client reads (every call guarded; nil means "cannot answer")
------------------------------------------------------------------------------

local function mainHandSlot() return weaponSlot("MAINHAND") end
local function offHandSlot()  return weaponSlot("OFFHAND") end

-- true = a weapon is in the slot, false = empty, nil = cannot tell.
local function slotHasWeapon(slot)
    if type(slot) ~= "number" then return nil end
    if type(GetInventoryItemLink) ~= "function" then return nil end
    local ok, link = pcall(GetInventoryItemLink, "player", slot)
    if not ok then return nil end
    if isSecret(link) then return nil end
    if link == nil then return false end
    if type(link) ~= "string" or link == "" then return false end
    return true
end

-- true = a weapon is in the main hand, false = empty, nil = cannot tell.
local function mainHandHasWeapon()
    return slotHasWeapon(mainHandSlot())
end

-- true = a weapon is in the off hand, false = empty, nil = cannot tell.
local function offHandHasWeapon()
    return slotHasWeapon(offHandSlot())
end

-- True when this client exposes the modern slot call. Used to decide whether a
-- legacy "false" can be trusted: it cannot while the modern call exists.
local function modernSlotEnchantAvailable()
    return type(C_Item) == "table" and type(C_Item.GetWeaponEnchantInfo) == "function"
end

-- Modern shape: C_Item.GetWeaponEnchantInfo(slot) returns hasEnchant,
-- enchantType and timeLeft, either as one record or as a list of records.
-- This plugin cannot use enchantType (it cannot tell a poison from a
-- sharpening stone either way), so presence alone is the answer.
-- Returns present, precise. present == nil means the call failed.
local function modernSlotEnchant(slot)
    if type(slot) ~= "number" then return nil, false end
    if not modernSlotEnchantAvailable() then return nil, false end

    local ok, result = pcall(C_Item.GetWeaponEnchantInfo, slot)
    if not ok then return nil, false end
    if isSecret(result) then return nil, true end
    -- nil is "answered nothing", not "nothing applied": only an explicit
    -- boolean or record may claim the hand is bare.
    if result == nil then return nil, true end
    if result == false then return false, true end
    -- Some builds answer hasEnchant as a bare boolean rather than a record.
    if result == true then return true, true end
    if type(result) ~= "table" then return nil, false end

    -- The shape test compares two client fields; a secret field must never be
    -- compared, so it is read and checked first. Secret means "unknown", which
    -- silences the reminder instead of guessing.
    local hasField = result.hasEnchant
    if isSecret(hasField) then return nil, true end
    local kindField = result.enchantType
    if isSecret(kindField) then return nil, true end

    local list = result
    if hasField ~= nil or kindField ~= nil then
        list = { result }
    end

    for _, entry in pairs(list) do
        if type(entry) == "table" then
            local has = entry.hasEnchant
            if isSecret(has) then return nil, true end
            if has == true then return true, true end
        end
    end

    -- A table with no readable record is "nothing applied", the same answer the
    -- reference shape gives for an empty list.
    return false, true
end

-- Legacy shape: GetWeaponEnchantInfo() returns the main-hand group first.
-- It says only that an enhancement is applied, never which kind it is.
local function legacyMainHandEnchant()
    if type(GetWeaponEnchantInfo) ~= "function" then return nil end

    local ok, hasMain = pcall(GetWeaponEnchantInfo)
    if not ok then return nil end
    if isSecret(hasMain) then return nil end
    return hasMain == true
end

-- Off-hand group of the same legacy call. Two return shapes exist here:
--   5 values: hasMain, mainExpiration, mainCharges, hasOff, offExpiration
--   8 values: hasMain, mainExpiration, mainCharges, mainEnchantID,
--             hasOff, offExpiration, offCharges, offEnchantID
-- The 4th value tells them apart: a boolean on the 5-value shape, the
-- main-hand enchant id (a number, or nil) on the 8-value shape. It is a
-- fallback only: the modern slot call is asked first, and a legacy "false"
-- proves nothing while that call exists.
-- Returns has, expiration; has == nil means this client cannot tell.
local function legacyOffHandPair()
    if type(GetWeaponEnchantInfo) ~= "function" then return nil end

    local ok, hasMain, mainExpiration, mainCharges, fourth, fifth, sixth
        = pcall(GetWeaponEnchantInfo)
    if not ok then return nil end

    local has, expiration
    if type(fourth) == "boolean" then
        -- 5-value shape: the off-hand flag and expiry are the 4th and 5th.
        has, expiration = fourth, fifth
    else
        -- 8-value shape: the off-hand flag and expiry are the 5th and 6th.
        has, expiration = fifth, sixth
    end

    if has == nil then return nil end
    if isSecret(has) or isSecret(expiration) then return nil end
    return has == true, expiration
end

-- true = some temporary enhancement is applied to the main hand,
-- false = none, nil = cannot tell.
local function mainHandTemporaryEnhancement()
    local present, precise = modernSlotEnchant(mainHandSlot())
    if precise and present ~= nil then return present end

    -- The modern call answered nothing. A legacy "true" still proves something
    -- is applied; a legacy "false" only means "none" when the modern call does
    -- not exist on this client.
    local has = legacyMainHandEnchant()
    if has == true then return true end
    if has == false and not modernSlotEnchantAvailable() then return false end
    return nil
end

------------------------------------------------------------------------------
-- The check
------------------------------------------------------------------------------

-- true only when a main-hand weapon exists and carries no temporary
-- enhancement. A return of nil is "unknown" and silences the reminder.
local function checkMainHandPoison()
    local equipped = mainHandHasWeapon()
    if equipped == false then
        -- Unarmed: there is no weapon to poison, so this is not a failure.
        return { active = true }
    end
    if equipped == nil then return nil end

    local enhanced = mainHandTemporaryEnhancement()
    if enhanced == nil then return nil end

    return { active = enhanced }
end

-- true only when an off-hand weapon exists and carries no temporary
-- enhancement. The modern slot call is asked first; the legacy pair only
-- reports the Classic temporary enchants on this client, so it cannot see a
-- poison. When both answer and disagree the modern answer is used and both are
-- printed through LT:Diag. nil is "unknown" and silences the reminder.
-- active = false is returned only when the client positively says the off hand
-- carries no enhancement.
local function checkOffHandPoison()
    local equipped = offHandHasWeapon()
    if equipped == false then
        -- No off-hand weapon: not a dual-wield setup, so not a failure.
        return { active = true }
    end
    if equipped == nil then return nil end

    local present, precise = modernSlotEnchant(offHandSlot())

    if precise and present ~= nil then
        local legacyHas = legacyOffHandPair()
        if legacyHas ~= nil and legacyHas ~= present then
            diag("off-hand poison: C_Item.GetWeaponEnchantInfo(slot) says "
                .. (present and "enhanced" or "none")
                .. ", legacy GetWeaponEnchantInfo says "
                .. (legacyHas and "enhanced" or "none")
                .. "; the modern answer is used.")
        end
        return { active = present }
    end

    -- The modern call answered nothing. A legacy "true" is usable; a legacy
    -- "false" is not proof of absence while the modern call exists.
    local legacyHas = legacyOffHandPair()
    if legacyHas == true then
        return { active = true }
    end
    if legacyHas == false and not modernSlotEnchantAvailable() then
        return { active = false }
    end

    return nil
end

------------------------------------------------------------------------------
-- Definitions
------------------------------------------------------------------------------

local function mainHandPoisonDefinition()
    return {
        id        = Rogue.DEFINITION_IDS.mainHandPoison,
        label     = "Rogue main-hand poison",
        optionKey = Rogue.OPTION_KEYS.mainHandPoison,
        owner     = Rogue.PLUGIN_ID,
        messages  = {
            missing = "No poison detected on the main-hand weapon. Apply the intended poison.",
        },
        isAvailable = function()
            -- Only a readable weapon makes the question meaningful. Unknown
            -- (nil) suppresses the reminder instead of guessing.
            return mainHandHasWeapon() == true
        end,
        checkFn = checkMainHandPoison,
    }
end

local function offHandPoisonDefinition()
    return {
        id        = Rogue.DEFINITION_IDS.offHandPoison,
        label     = "Rogue off-hand poison",
        optionKey = Rogue.OPTION_KEYS.offHandPoison,
        owner     = Rogue.PLUGIN_ID,
        messages  = {
            missing = "Off-hand weapon has no poison. Apply the intended poison.",
        },
        isAvailable = function()
            -- A one-weapon Rogue has no off-hand question, so the reminder is
            -- unavailable rather than satisfied. Unknown (nil) suppresses it.
            return offHandHasWeapon() == true
        end,
        checkFn = checkOffHandPoison,
    }
end

-- Exposed for the harness and for a UI that wants to describe what will be
-- registered. Nothing here touches the client until a checkFn is called.
function Rogue:BuildDefinitions(classToken)
    if classToken ~= self.CLASS then return {} end
    return {
        {
            classToken = classToken,
            definition = mainHandPoisonDefinition(),
        },
        {
            classToken = classToken,
            definition = offHandPoisonDefinition(),
        },
    }
end

------------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------------

local function missingApi()
    local api = LT.PluginAPI
    if type(api) ~= "table" or type(api.RegisterPlugin) ~= "function" then
        return "PluginAPI"
    end

    local monitor = LT.BuffMonitor
    if type(monitor) ~= "table"
        or type(monitor.Register) ~= "function"
        or type(monitor.GetRegistry) ~= "function" then
        return "BuffMonitor"
    end

    return nil
end

local function registrySnapshot()
    local monitor = LT.BuffMonitor
    local ok, registry = pcall(monitor.GetRegistry, monitor)
    if not ok or type(registry) ~= "table" then return nil end
    return registry
end

-- The core's PLAYER_LOGIN handler normally fills this in first. If a load
-- order ever puts the plugin first, ask the client rather than skipping.
local function playerClassToken()
    local token = LT.player and LT.player.class
    if type(token) == "string" and token ~= "" and token ~= "UNKNOWN" then
        return token
    end
    if type(UnitClass) == "function" then
        local ok, _, classToken = pcall(UnitClass, "player")
        if ok and type(classToken) == "string" and classToken ~= "" then
            return classToken
        end
    end
    return nil
end

local function classHasId(registry, classToken, id)
    local list = registry[classToken]
    if type(list) ~= "table" then return false end
    for _, definition in ipairs(list) do
        if type(definition) == "table" and definition.id == id then return true end
    end
    return false
end

local function coreAlreadyOwns(registry, id, optionKey)
    for _, list in pairs(registry) do
        if type(list) == "table" then
            for _, definition in ipairs(list) do
                if type(definition) == "table" then
                    if definition.id == id then return "the core already carries the id " .. id end
                    if type(definition.optionKey) == "string"
                        and definition.optionKey == optionKey then
                        return "the option key " .. optionKey .. " is already in use"
                    end
                end
            end
        end
    end
    return nil
end

function Rogue:Register()
    if initialized then
        debug("Rogue: already registered; a second registration is skipped.")
        return 0
    end

    local classToken = playerClassToken()
    if classToken ~= self.CLASS then
        -- Nothing on another class: no plugin record, no definition, no option.
        debug("Rogue: player class is " .. tostring(classToken) .. "; nothing registered.")
        return 0
    end

    local missing = missingApi()
    if missing then
        if not announcedInactive then
            announcedInactive = true
            report("LunchboxToolkit_Rogue: " .. missing
                .. " is not available, so the plugin stays inactive.")
        end
        return 0
    end

    local registry = registrySnapshot()
    if not registry then
        report("LunchboxToolkit_Rogue: the BuffMonitor registry could not be read, "
            .. "so the plugin stays inactive.")
        return 0
    end

    local ok, plugin, reason = pcall(LT.PluginAPI.RegisterPlugin, LT.PluginAPI, {
        id          = self.PLUGIN_ID,
        name        = "Lunchbox Rogue",
        version     = self.VERSION,
        author      = "Lunchbox",
        apiVersion  = 1,
        classes     = { self.CLASS },
        description = "Main-hand and off-hand poison reminders for Rogues. Detection "
            .. "reads the client's temporary weapon enhancement; poison damage is not "
            .. "scored because no stat key models it. Each switch is off by default "
            .. "and per character.",
    })

    if not ok then
        report("LunchboxToolkit_Rogue: plugin registration failed: " .. tostring(plugin))
        return 0
    end
    if not plugin then
        debug("Rogue: plugin registration was refused: " .. tostring(reason))
        return 0
    end

    initialized = true

    local added = 0
    for _, entry in ipairs(self:BuildDefinitions(classToken)) do
        local definition = entry.definition
        local skip = coreAlreadyOwns(registry, definition.id, definition.optionKey)
            or (classHasId(registry, entry.classToken, definition.id)
                and "this definition is already registered for " .. entry.classToken)

        if skip then
            debug("Rogue: skipped " .. definition.id .. " — " .. skip .. ".")
        else
            local okRegister, result = pcall(
                LT.BuffMonitor.Register, LT.BuffMonitor, entry.classToken, definition)
            if not okRegister then
                report("LunchboxToolkit_Rogue: registering " .. definition.id
                    .. " failed: " .. tostring(result))
            elseif result then
                added = added + 1
            else
                debug("Rogue: BuffMonitor refused " .. definition.id .. ".")
            end
        end
    end

    debug("Rogue: " .. tostring(added) .. " definition(s) registered.")

    -- The core's own PLAYER_LOGIN pass has already run by the time this frame
    -- handler fires. Run one check now so an enabled reminder behaves like the
    -- bundled definitions on first login. Never build a frame in combat.
    if added > 0 and not inCombat() then
        local monitor = LT.BuffMonitor
        if type(monitor.CheckAll) == "function" then
            pcall(monitor.CheckAll, monitor)
        end
    end

    return added
end

-- Compatibility for callers that name the login step: the event below calls
-- Register, and this alias makes the same entry point available to a harness.
Rogue.OnLogin = Rogue.Register

------------------------------------------------------------------------------
-- Removal (the core offers no unregister, so remove our own id by name)
------------------------------------------------------------------------------

local function isOurDefinitionId(id)
    return id == Rogue.DEFINITION_IDS.mainHandPoison
        or id == Rogue.DEFINITION_IDS.offHandPoison
end

function Rogue:Unregister()
    local removed = 0
    local monitor = LT.BuffMonitor

    if type(monitor) == "table" and type(monitor.GetRegistry) == "function" then
        local ok, registry = pcall(monitor.GetRegistry, monitor)
        if ok and type(registry) == "table" then
            for _, list in pairs(registry) do
                if type(list) == "table" then
                    for index = #list, 1, -1 do
                        local definition = list[index]
                        if type(definition) == "table"
                            and isOurDefinitionId(definition.id)
                            and definition.owner == self.PLUGIN_ID then
                            table.remove(list, index)
                            removed = removed + 1
                        end
                    end
                end
            end
        end
    end

    local api = LT.PluginAPI
    if type(api) == "table" and type(api.UnregisterPlugin) == "function" then
        pcall(api.UnregisterPlugin, api, self.PLUGIN_ID)
    end

    initialized = false
    return removed
end

function Rogue:IsRegistered(definitionId)
    local monitor = LT.BuffMonitor
    if type(monitor) ~= "table" or type(monitor.GetRegistry) ~= "function" then
        return false
    end
    local ok, registry = pcall(monitor.GetRegistry, monitor)
    if not ok or type(registry) ~= "table" then return false end

    for _, list in pairs(registry) do
        if type(list) == "table" then
            for _, definition in ipairs(list) do
                if type(definition) == "table" and definition.id == definitionId then
                    return true
                end
            end
        end
    end
    return false
end

------------------------------------------------------------------------------
-- Option access, per character (the core character record owns the table)
------------------------------------------------------------------------------

local function isOurOptionKey(key)
    return key == Rogue.OPTION_KEYS.mainHandPoison
        or key == Rogue.OPTION_KEYS.offHandPoison
end

local function optionsTable()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return nil
    end
    local ok, options = pcall(database.GetOptions, database)
    if ok and type(options) == "table" then return options end
    return nil
end

-- Off by default: an absent key is not true, which is exactly what the core's
-- BuffMonitor:isEnabled() reads.
function Rogue:GetEnabled(optionKey)
    if not isOurOptionKey(optionKey) then return false end
    local options = optionsTable()
    return options ~= nil and options[optionKey] == true
end

function Rogue:SetEnabled(optionKey, enabled)
    if not isOurOptionKey(optionKey) then
        return false, "unknown option key"
    end
    if type(enabled) ~= "boolean" then
        return false, "enabled must be a boolean"
    end

    local options = optionsTable()
    if not options then
        return false, "the character options are not available"
    end

    options[optionKey] = enabled

    local database = LT.Database
    if type(database.Save) == "function" then
        pcall(database.Save, database, "rogue:" .. optionKey)
    end

    local monitor = LT.BuffMonitor
    if not inCombat() and type(monitor) == "table" and type(monitor.CheckAll) == "function" then
        pcall(monitor.CheckAll, monitor)
    end

    return true
end

-- Row data for a Settings page that wants to draw these switches. Data and
-- callbacks only: no widgets are created here, and this plugin draws nothing
-- itself. The core's page currently carries one hard-coded Rogue row and does
-- not read this list, so the off-hand switch is also reachable by command:
--   /run LunchboxToolkit.Rogue:SetEnabled("rogueOffHandPoison", true)
function Rogue:GetOptionRows(classToken)
    if classToken ~= self.CLASS then return {} end
    local plugin = self
    return {
        {
            key     = self.OPTION_KEYS.mainHandPoison,
            label   = "Warn when the main hand has no poison",
            help    = "Rogue only. One warning when the main hand carries no temporary "
                .. "enhancement. A sharpening stone or oil counts as present, and an "
                .. "unreadable main hand stays silent, so this never warns from a "
                .. "guess. Nothing is applied. Off by default.",
            default = false,
            get     = function() return plugin:GetEnabled(plugin.OPTION_KEYS.mainHandPoison) end,
            apply   = function(value) plugin:SetEnabled(plugin.OPTION_KEYS.mainHandPoison, value) end,
        },
        {
            key     = self.OPTION_KEYS.offHandPoison,
            label   = "Warn when the off hand has no poison",
            help    = "Rogue only, and only while an off-hand weapon is equipped. One "
                .. "warning when the off-hand weapon carries no temporary enhancement. "
                .. "A temporary enhancement cannot be distinguished from a sharpening "
                .. "stone, weightstone or oil, so a sharpened or oiled off hand counts "
                .. "as satisfied, and an unreadable off hand stays silent. Nothing is "
                .. "applied. Off by default.",
            default = false,
            get     = function() return plugin:GetEnabled(plugin.OPTION_KEYS.offHandPoison) end,
            apply   = function(value) plugin:SetEnabled(plugin.OPTION_KEYS.offHandPoison, value) end,
        },
    }
end

------------------------------------------------------------------------------
-- PLAYER_LOGIN
------------------------------------------------------------------------------

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
                Rogue:Register()
            end)
        end
    end
end
