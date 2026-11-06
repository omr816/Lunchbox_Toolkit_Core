--[[--------------------------------------------------------------------------
    LunchboxToolkit_WeaponBuffs — buff definitions the core does not carry

    Registers itself with the core's PluginAPI at PLAYER_LOGIN, then adds one or
    two BuffMonitor definitions:

      * shaman_offhand_imbue         — Shaman only: off-hand weapon with no imbue
                                       (or an imbue close to expiry)
      * temporary_weapon_enhancement — sharpening stone, weightstone or oil on
                                       a weapon the client reports

    The second definition is not registered for Shaman or Rogue. A weapon imbue
    (Shaman) or a poison (Rogue) occupies the enhancement slot that a stone,
    weightstone or oil would use, so that reminder could never be satisfied on
    those classes. Their switch, if a settings row shows one, changes nothing
    there; the off-hand imbue reminder exists for Shaman only.

    Nothing here is copied from the core's ClassData: before either definition
    is registered, its id (and option key) is checked against the core's own
    BuffMonitor registry and skipped with a debug line when already present.

    Both switches live in the core's per-character option table, so BuffMonitor
    and the Settings page read the same value. They are absent by default,
    which BuffMonitor reads as "off"; LT.WeaponBuffs:SetEnabled() is the write
    side for a settings row and GetEnabled() the read side.

    The TOC declares no SavedVariables of its own: the reminder switches live
    in the core's per-character option table, which is the table BuffMonitor
    reads, and this plugin owns no saved state.

    Missing PluginAPI or BuffMonitor is not an error: the plugin loads, says so
    once, and registers nothing.
--------------------------------------------------------------------------]]

if not LunchboxToolkit then return end
local LT = LunchboxToolkit

local WeaponBuffs = {}
LT.WeaponBuffs = WeaponBuffs

WeaponBuffs.PLUGIN_ID = "lunchbox_weaponbuffs"
WeaponBuffs.VERSION = "1.0.1"

local OPTION_KEYS = {
    offHandImbue    = "weaponBuffsOffHandImbue",
    tempEnhancement = "weaponBuffsTempEnhancement",
}
WeaponBuffs.OPTION_KEYS = OPTION_KEYS

local DEFINITION_IDS = {
    offHandImbue    = "shaman_offhand_imbue",
    tempEnhancement = "temporary_weapon_enhancement",
}
WeaponBuffs.DEFINITION_IDS = DEFINITION_IDS

local EXPIRING_THRESHOLD = 5 * 60 * 1000

local IMBUE_IDS = { 8017, 8024, 8033, 8232 }

-- A weapon imbue (Shaman) or a poison (Rogue) fills the slot a temporary
-- enhancement would use, so that reminder can never be satisfied there.
local TEMP_ENHANCEMENT_EXCLUDED_CLASSES = {
    SHAMAN = true,
    ROGUE  = true,
}

local initialized = false
local announcedInactive = false

------------------------------------------------------------------------------
-- Logging and secret-value guards
------------------------------------------------------------------------------

local function report(message)
    if type(LT.Warn) == "function" then
        if pcall(LT.Warn, LT, message) then return end
    end
    if type(LT.Print) == "function" then
        if pcall(LT.Print, LT, message) then return end
    end
    pcall(print, message)
end

local function debug(message)
    if type(LT.Debug) == "function" then
        pcall(LT.Debug, LT, message)
    end
end

-- Diagnostic line, printed only in a dev build (LT.DEBUG).
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
    if type(issecretvalue) == "function" then
        local ok, result = pcall(issecretvalue, value)
        return ok and result == true
    end
    return false
end

local function inCombat()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, value = pcall(InCombatLockdown)
    return ok and value == true
end

local function enumNumber(group, key, fallback)
    local enum = Enum
    if type(enum) ~= "table" then return fallback end
    local values = enum[group]
    if type(values) ~= "table" then return fallback end
    local value = values[key]
    if isSecret(value) then return fallback end
    if type(value) == "number" then return value end
    return fallback
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

local function mainHandSlot() return weaponSlot("MAINHAND") end
local function offHandSlot()  return weaponSlot("OFFHAND") end

------------------------------------------------------------------------------
-- Client reads (every call guarded; nil means "cannot answer")
------------------------------------------------------------------------------

-- True only when the character's spellbook holds a Shaman weapon imbue. Spell
-- *existence* (GetSpellInfo) is not knowledge: the client resolves every imbue
-- name for every character, so it cannot answer this. Prefer IsPlayerSpell and
-- fall back to IsSpellKnown; with neither, return nil (unknown) and let the
-- definition suppress its warning.
local function knowsAnyImbue()
    local api = (type(IsPlayerSpell) == "function" and IsPlayerSpell)
        or (type(IsSpellKnown) == "function" and IsSpellKnown)
        or nil
    if not api then return nil end

    for _, id in ipairs(IMBUE_IDS) do
        local ok, known = pcall(api, id)
        if not ok then return nil end
        if isSecret(known) then return nil end
        if known == nil then return nil end
        if known then return true end
    end

    return false
end

local function mainHandHasWeapon()
    local slot = mainHandSlot()
    if type(slot) ~= "number" then return nil end
    if type(GetInventoryItemLink) ~= "function" then return nil end
    local ok, link = pcall(GetInventoryItemLink, "player", slot)
    if not ok then return nil end
    if link == nil then return false end
    if isSecret(link) then return nil end
    if type(link) ~= "string" or link == "" then return false end
    return true
end

-- True only when the off hand holds a one-handed weapon, which is what
-- "dual wield" means here. Shields and held-in-off-hand frills are not.
local function offHandWeaponEquipped()
    local slot = offHandSlot()
    if type(slot) ~= "number" then return nil end
    if type(GetInventoryItemLink) ~= "function" then return nil end
    local ok, link = pcall(GetInventoryItemLink, "player", slot)
    if not ok then return nil end
    if link == nil then return false end
    if isSecret(link) then return nil end
    if type(link) ~= "string" or link == "" then return false end

    if not (type(C_Item) == "table" and type(C_Item.GetItemInfoInstant) == "function") then
        return nil
    end

    local okInfo, _, _, _, equipLoc = pcall(C_Item.GetItemInfoInstant, link)
    if not okInfo or equipLoc == nil then return nil end
    if isSecret(equipLoc) then return nil end
    if equipLoc == "INVTYPE_WEAPON" or equipLoc == "INVTYPE_WEAPONOFFHAND" then
        return true
    end
    return false
end

-- True when this client exposes the modern slot call. Used to decide whether a
-- legacy "false" can be trusted: it cannot while the modern call exists.
local function modernEnchantApiAvailable()
    return type(C_Item) == "table" and type(C_Item.GetWeaponEnchantInfo) == "function"
end

-- Modern shape: C_Item.GetWeaponEnchantInfo(slot) returns a record (or a list
-- of records) with hasEnchant, enchantType and timeLeft in milliseconds.
local function modernEnchantRecords(slot)
    if type(slot) ~= "number" then return nil, false end
    if not modernEnchantApiAvailable() then return nil, false end

    local ok, result = pcall(C_Item.GetWeaponEnchantInfo, slot)
    if not ok then return nil, false end
    if isSecret(result) then return nil, true end
    -- nil is "answered nothing", not "an empty list": only an explicit record
    -- may claim the slot is bare.
    if result == nil then return nil, true end
    if type(result) ~= "table" then return nil, false end

    -- Some builds answer one table with named hands rather than one record per
    -- slot. Pick the hand the caller asked for; do not read the main hand twice.
    if type(result.mainHand) == "table" or type(result.offHand) == "table" then
        local entry = (slot == offHandSlot()) and result.offHand or result.mainHand
        if type(entry) ~= "table" then return {}, true end
        result = entry
    end

    -- The shape test compares two client fields; a secret field must never be
    -- compared, so it is read and checked first. Secret means "unknown".
    local hasField = result.hasEnchant
    if isSecret(hasField) then return nil, true end
    local kindField = result.enchantType
    if isSecret(kindField) then return nil, true end

    local list = result
    if hasField ~= nil or kindField ~= nil then
        list = { result }
    end

    local records = {}
    for _, entry in pairs(list) do
        if type(entry) == "table" then
            local has = entry.hasEnchant
            if isSecret(has) then return nil, true end
            if has then
                local kind = entry.enchantType
                local left = entry.timeLeft
                if isSecret(kind) or isSecret(left) then return nil, true end
                records[#records + 1] = {
                    kind     = tonumber(kind),
                    timeLeft = tonumber(left),
                }
            end
        end
    end

    return records, true
end

-- Legacy shape: GetWeaponEnchantInfo() returns main-hand and off-hand groups.
-- It cannot say whether the enchant is an imbue, a poison or a temporary one.
--
-- Two return shapes exist: 5 values (hasMain, mainExp, mainCharges, hasOff, offExp)
-- and 8 values (.., mainEnchantID, hasOff, offExp, offCharges, offEnchantID). The
-- 4th value tells them apart: boolean on the old shape, the enchant id on the new.
local function legacyHands()
    if type(GetWeaponEnchantInfo) ~= "function" then return nil end

    local ok, hasMain, mainExpiration, mainCharges, fourth, fifth, sixth = pcall(GetWeaponEnchantInfo)
    if not ok then return nil end

    if type(fourth) == "boolean" then
        return hasMain, mainExpiration, fourth, fifth
    end

    return hasMain, mainExpiration, fifth, sixth
end

local function legacyEnchantRecords(slot)
    local hasMain, mainExpiration, hasOff, offExpiration = legacyHands()
    if hasMain == nil then return nil end

    local has, expiration
    if slot == offHandSlot() then
        has, expiration = hasOff, offExpiration
    else
        has, expiration = hasMain, mainExpiration
    end

    if isSecret(has) or isSecret(expiration) then return nil end
    if not has then return {} end

    return { { kind = nil, timeLeft = tonumber(expiration) } }
end

local function weaponEnchantState(slot)
    if type(slot) ~= "number" then return nil end

    local records, precise = modernEnchantRecords(slot)
    if precise and records ~= nil then
        return { records = records, precise = true }
    end

    -- The modern call answered nothing: the legacy pair is the only remaining
    -- answer, and its records carry kind = nil (the kind is not exposed).
    local legacy = legacyEnchantRecords(slot)
    if legacy == nil then return nil end
    return { records = legacy, precise = false }
end

------------------------------------------------------------------------------
-- Checks
------------------------------------------------------------------------------

-- Legacy API, read for its HAND answer only: it returns the main-hand group
-- first and the off-hand group second. It is a fallback now: the modern slot
-- call is asked first, and a legacy "false" proves nothing while it exists.
local function legacyOffHandEnchant()
    local _, _, hasOff, offExpiration = legacyHands()
    if hasOff == nil then return nil end   -- this client does not answer for the off hand
    if isSecret(hasOff) or isSecret(offExpiration) then return nil end

    return hasOff == true, tonumber(offExpiration)
end

-- Diagnostic for /lt imbues: the two hand answers and the slot numbers used.
function WeaponBuffs:HandState()
    local main = weaponEnchantState(mainHandSlot())
    local off = weaponEnchantState(offHandSlot())
    return {
        main = main, off = off,
        mainSlot = mainHandSlot(), offSlot = offHandSlot(),
    }
end

local function checkOffHandImbue()
    local equipped = offHandWeaponEquipped()
    if equipped == false then return { active = true } end -- not a dual-wield setup
    if equipped == nil then return nil end                -- cannot tell

    -- The modern slot call is asked first: on this client the legacy pair only
    -- reports the Classic temporary enchants, so its "false" cannot rule out an
    -- imbue. The pair stays as a fallback for a slot the modern call answers
    -- nothing about, and a disagreement prefers the modern answer.
    local records, precise = modernEnchantRecords(offHandSlot())
    local legacyHas, legacyExpiration = legacyOffHandEnchant()

    if precise and records ~= nil then
        local modernHas = #records > 0
        if legacyHas ~= nil and legacyHas ~= modernHas then
            diag("off-hand imbue: C_Item.GetWeaponEnchantInfo(slot) says "
                .. (modernHas and "enhanced" or "none")
                .. ", legacy GetWeaponEnchantInfo says "
                .. (legacyHas and "enhanced" or "none")
                .. "; the modern answer is used.")
        end
        if not modernHas then return { active = false } end
    else
        -- The modern call answered nothing. A legacy "true" is usable; a legacy
        -- "false" is not proof of absence while the modern call exists.
        if legacyHas == true then
            return { active = true, timeLeft = legacyExpiration, precise = false }
        end
        if legacyHas == false and not modernEnchantApiAvailable() then
            return { active = false }
        end
        return nil
    end

    local state = { records = records, precise = true }

    local imbueType = enumNumber("ItemEnchantType", "Imbue", 3)
    local sawImbue, sawUnknown, timeLeft = false, false, nil

    for _, record in ipairs(state.records) do
        if record.kind == imbueType then
            sawImbue = true
            if record.timeLeft and (not timeLeft or record.timeLeft < timeLeft) then
                timeLeft = record.timeLeft
            end
        elseif record.kind == nil then
            if not state.precise then
                -- Legacy API: any off-hand enchant may be the imbue we want.
                return { active = true, timeLeft = record.timeLeft, precise = false }
            end
            sawUnknown = true
        end
    end

    if sawImbue then
        return { active = true, timeLeft = timeLeft, precise = state.precise }
    end
    if sawUnknown then return nil end

    return { active = false }
end

local function checkTemporaryEnhancement()
    if mainHandHasWeapon() == false then return { active = true } end

    local temporaryType = enumNumber("ItemEnchantType", "Temporary", 2)
    local sawTemporary, sawUnknown, answered = false, false, false
    local timeLeft, precise = nil, true

    local function scan(slot)
        local state = weaponEnchantState(slot)
        if not state then return end
        answered = true

        for _, record in ipairs(state.records) do
            if record.kind == temporaryType then
                sawTemporary = true
                if not state.precise then precise = false end
                if record.timeLeft and (not timeLeft or record.timeLeft < timeLeft) then
                    timeLeft = record.timeLeft
                end
            elseif record.kind == nil then
                if state.precise then
                    sawUnknown = true
                else
                    -- Legacy API: an enchant exists, but its kind is not exposed.
                    sawTemporary = true
                    precise = false
                    if record.timeLeft and (not timeLeft or record.timeLeft < timeLeft) then
                        timeLeft = record.timeLeft
                    end
                end
            end
        end
    end

    scan(mainHandSlot())
    -- A shield or held-in-off-hand item is not a weapon to enhance. When the
    -- item type cannot be read (nil), keep the off-hand answer rather than
    -- suppressing a real temporary enchant.
    if offHandWeaponEquipped() ~= false then
        scan(offHandSlot())
    end

    if sawTemporary then
        return { active = true, timeLeft = timeLeft, precise = precise }
    end
    if sawUnknown or not answered then return nil end
    return { active = false }
end

------------------------------------------------------------------------------
-- Definitions
------------------------------------------------------------------------------

local function offHandImbueDefinition()
    return {
        id      = DEFINITION_IDS.offHandImbue,
        label   = "Shaman off-hand weapon imbue",
        optionKey = OPTION_KEYS.offHandImbue,
        owner   = WeaponBuffs.PLUGIN_ID,
        expiringThreshold = EXPIRING_THRESHOLD,
        messages = {
            missing  = "No off-hand Shaman imbue detected. Apply the intended imbue.",
            expiring = "Off-hand imbue expiring in about {minutes} minute(s).",
        },
        isAvailable = function()
            if offHandWeaponEquipped() == false then return false end
            -- Only an explicit "knows an imbue" keeps the reminder live; nil is
            -- unknown and suppresses it rather than firing a warning.
            return knowsAnyImbue() == true
        end,
        checkFn = checkOffHandImbue,
    }
end

local function temporaryEnhancementDefinition()
    return {
        id      = DEFINITION_IDS.tempEnhancement,
        label   = "Temporary weapon enhancement",
        optionKey = OPTION_KEYS.tempEnhancement,
        owner   = WeaponBuffs.PLUGIN_ID,
        expiringThreshold = EXPIRING_THRESHOLD,
        messages = {
            missing  = "No temporary weapon enhancement (sharpening stone, weightstone or oil) detected.",
            expiring = "Temporary weapon enhancement expiring in about {minutes} minute(s).",
        },
        isAvailable = function()
            if mainHandHasWeapon() == false then return false end
            return true
        end,
        checkFn = checkTemporaryEnhancement,
    }
end

-- Exposed for the harness and for a UI that wants to describe what will be
-- registered; nothing here touches the client until a checkFn is called.
function WeaponBuffs:BuildDefinitions(classToken)
    local entries = {}

    if classToken == "SHAMAN" then
        entries[#entries + 1] = {
            classToken = classToken,
            definition = offHandImbueDefinition(),
        }
    end

    if type(classToken) == "string" and classToken ~= "" and classToken ~= "UNKNOWN"
        and not TEMP_ENHANCEMENT_EXCLUDED_CLASSES[classToken] then
        entries[#entries + 1] = {
            classToken = classToken,
            definition = temporaryEnhancementDefinition(),
        }
    end

    return entries
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

function WeaponBuffs:Register()
    if initialized then
        debug("WeaponBuffs: already registered; a second registration is skipped.")
        return 0
    end

    local missing = missingApi()
    if missing then
        if not announcedInactive then
            announcedInactive = true
            report("LunchboxToolkit_WeaponBuffs: " .. missing
                .. " is not available, so the plugin stays inactive.")
        end
        return 0
    end

    local classToken = playerClassToken()
    if not classToken then
        debug("WeaponBuffs: the player class is unknown; no definitions registered.")
        return 0
    end

    local registry = registrySnapshot()
    if not registry then
        report("LunchboxToolkit_WeaponBuffs: the BuffMonitor registry could not be read, "
            .. "so the plugin stays inactive.")
        return 0
    end

    local meta = {
        id          = WeaponBuffs.PLUGIN_ID,
        name        = "Lunchbox Weapon Buffs",
        version     = WeaponBuffs.VERSION,
        author      = "Lunchbox",
        apiVersion  = 1,
        description = "Off-hand Shaman imbue and temporary weapon enhancement "
            .. "(sharpening stone, weightstone, oil) reminders for the core buff monitor. "
            .. "Each definition has its own per-character switch, off by default.",
    }

    local ok, plugin, reason = pcall(LT.PluginAPI.RegisterPlugin, LT.PluginAPI, meta)
    if not ok then
        report("LunchboxToolkit_WeaponBuffs: plugin registration failed: " .. tostring(plugin))
        return 0
    end
    if not plugin then
        debug("WeaponBuffs: plugin registration was refused: " .. tostring(reason))
        return 0
    end

    initialized = true

    -- Snapshot what the core already carries before adding anything: a
    -- definition with one of our ids, or one of our option keys, belongs to the
    -- core and must not be registered a second time.
    local existingIds, existingKeys = {}, {}
    for _, list in pairs(registry) do
        if type(list) == "table" then
            for _, definition in ipairs(list) do
                if type(definition) == "table" then
                    if type(definition.id) == "string" then
                        existingIds[definition.id] = true
                    end
                    if type(definition.optionKey) == "string" then
                        existingKeys[definition.optionKey] = true
                    end
                end
            end
        end
    end

    local claimedKeys = {}
    local added = 0

    for _, entry in ipairs(WeaponBuffs:BuildDefinitions(classToken)) do
        local definition = entry.definition
        local skip

        if existingIds[definition.id] then
            skip = "the core already carries the id \"" .. definition.id .. "\""
        elseif existingKeys[definition.optionKey] then
            skip = "the option key \"" .. definition.optionKey .. "\" is already in use"
        elseif claimedKeys[definition.optionKey] then
            skip = "the option key \"" .. definition.optionKey .. "\" is used twice by this plugin"
        elseif classHasId(registry, entry.classToken, definition.id) then
            skip = "\"" .. definition.id .. "\" is already registered for " .. entry.classToken
        end

        if skip then
            debug("WeaponBuffs: skipped " .. definition.id .. " — " .. skip .. ".")
        else
            local okRegister, result = pcall(
                LT.BuffMonitor.Register, LT.BuffMonitor, entry.classToken, definition)
            if not okRegister then
                report("LunchboxToolkit_WeaponBuffs: registering \"" .. definition.id
                    .. "\" failed: " .. tostring(result))
            elseif result then
                claimedKeys[definition.optionKey] = true
                added = added + 1
            else
                debug("WeaponBuffs: BuffMonitor refused \"" .. definition.id .. "\".")
            end
        end
    end

    debug("WeaponBuffs: " .. tostring(added) .. " definition(s) registered.")

    -- The core's own PLAYER_LOGIN pass has already run by the time a plugin
    -- frame handler fires, so run one check now to give an enabled reminder
    -- the same first-login behaviour as the core's definitions.
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
WeaponBuffs.OnLogin = WeaponBuffs.Register

------------------------------------------------------------------------------
-- Removal (the core offers no unregister, so remove our own ids by name)
------------------------------------------------------------------------------

function WeaponBuffs:Unregister()
    local removed = 0
    local monitor = LT.BuffMonitor

    if type(monitor) == "table" and type(monitor.GetRegistry) == "function" then
        local ok, registry = pcall(monitor.GetRegistry, monitor)
        if ok and type(registry) == "table" then
            local ours = {
                [DEFINITION_IDS.offHandImbue]    = true,
                [DEFINITION_IDS.tempEnhancement] = true,
            }

            for _, list in pairs(registry) do
                if type(list) == "table" then
                    for index = #list, 1, -1 do
                        local definition = list[index]
                        if type(definition) == "table"
                            and ours[definition.id]
                            and definition.owner == WeaponBuffs.PLUGIN_ID then
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
        pcall(api.UnregisterPlugin, api, WeaponBuffs.PLUGIN_ID)
    end

    initialized = false
    return removed
end

function WeaponBuffs:IsRegistered(definitionId)
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
    return key == OPTION_KEYS.offHandImbue or key == OPTION_KEYS.tempEnhancement
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
function WeaponBuffs:GetEnabled(optionKey)
    if not isOurOptionKey(optionKey) then return false end
    local options = optionsTable()
    return options ~= nil and options[optionKey] == true
end

function WeaponBuffs:SetEnabled(optionKey, enabled)
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
        pcall(database.Save, database, "weaponbuffs:" .. optionKey)
    end

    local monitor = LT.BuffMonitor
    if not inCombat() and type(monitor) == "table" and type(monitor.CheckAll) == "function" then
        pcall(monitor.CheckAll, monitor)
    end

    return true
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
                WeaponBuffs:Register()
            end)
        end
    end
end

------------------------------------------------------------------------------
-- Windfury records popup (Shaman only)
------------------------------------------------------------------------------

-- Windfury is a Shaman weapon imbue, so every record and alert below is
-- Shaman-only. The core's player record answers first; a load-order miss asks
-- the client, and an unreadable class reads as "not a Shaman".
local function isShaman()
    local player = LT.player
    if type(player) == "table" and type(player.class) == "string"
        and player.class ~= "" and player.class ~= "UNKNOWN" then
        return player.class == "SHAMAN"
    end
    if type(UnitClass) == "function" then
        local ok, _, token = pcall(UnitClass, "player")
        if ok and type(token) == "string" then return token == "SHAMAN" end
    end
    return false
end

-- Reads the top-5 list the core's damage log fills in. The window is created
-- once and reused; every line is one record in the player's own words.
function WeaponBuffs:ShowRecords()
    if not isShaman() then
        report("Windfury records are Shaman only.")
        return
    end
    if type(createFrame) ~= "function" then return end

    local window = self.recordsWindow
    if not window then
        local ok, created = pcall(createFrame, "Frame", "LunchboxToolkitWindfuryRecords", UIParent)
        if not ok or not created then return end
        window = created
        window:SetSize(380, 340)
        window:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        window:SetFrameStrata("DIALOG")
        window:SetMovable(true)
        window:EnableMouse(true)
        window:RegisterForDrag("LeftButton")
        window:SetScript("OnDragStart", function(self) self:StartMoving() end)
        window:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

        -- Same chrome and font as the totems page (ShamanHUD).
        if LT.Chrome and type(LT.Chrome.Window) == "function" then
            pcall(LT.Chrome.Window, window)
        end

        local function brandTint(label)
            if LT.Palette and type(LT.Palette.Colour) == "function" then
                local okc, colour = pcall(LT.Palette.Colour, LT.Palette, "brand")
                if okc and type(colour) == "table" then
                    label:SetTextColor(colour[1], colour[2], colour[3])
                end
            end
        end

        local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        title:SetPoint("TOPLEFT", 10, -8)
        title:SetText("Windfury Records")
        brandTint(title)

        local closeBtn = CreateFrame("Button", nil, window, "UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT", window, "TOPRIGHT", -4, -4)
        closeBtn:SetScript("OnClick", function() window:Hide() end)

        local function addHeader(text, y)
            local header = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            header:SetPoint("TOPLEFT", 10, y)
            header:SetText(text)
            brandTint(header)
            return header
        end

        addHeader("2H", -28)
        addHeader("DW", -158)

        window.rows = {}
        window.lines = {}
        for section = 0, 1 do
            for i = 1, 5 do
                local n = section * 5 + i
                local y = -42 - section * 130 - (i - 1) * 22
                local row = window:CreateTexture(nil, "ARTWORK", nil, -1)
                row:SetPoint("TOPLEFT", window, "TOPLEFT", 6, y)
                row:SetPoint("TOPRIGHT", window, "TOPRIGHT", -6, y)
                row:SetHeight(20)
                if i % 2 == 0 then
                    row:SetColorTexture(0.04, 0.04, 0.06, 0.55)
                else
                    row:SetColorTexture(0.10, 0.10, 0.13, 0.55)
                end
                window.rows[n] = row

                local line = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                line:SetPoint("TOPLEFT", 10, y - 2)
                line:SetPoint("TOPRIGHT", -10, y - 2)
                line:SetHeight(20)
                line:SetJustifyH("LEFT")
                line:SetJustifyV("MIDDLE")
                window.lines[n] = line
            end
        end

        local moveBtn = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        moveBtn:SetSize(110, 22)
        moveBtn:SetPoint("BOTTOMLEFT", 10, 10)
        moveBtn:SetText("Move alert")
        moveBtn:SetScript("OnClick", function()
            if not isShaman() then return end
            if LT.Trackers and type(LT.Trackers.FlashWindfury) == "function" then
                LT.Trackers:FlashWindfury("Windfury! (drag me)", 60, true)
            end
        end)

        local warnBtn = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
        warnBtn:SetSize(130, 22)
        warnBtn:SetPoint("BOTTOMRIGHT", -10, 10)
        warnBtn:SetScript("OnClick", function(self)
            local store = LunchboxToolkitDB
            if not store then return end
            store.windfuryAlertOn = not (store.windfuryAlertOn ~= false)
            local on = not (store.windfuryAlertOn == false)
            self:SetText(on and "Warnings: on" or "Warnings: off")
        end)
        window.warnBtn = warnBtn

        if type(UISpecialFrames) == "table" then
            pcall(table.insert, UISpecialFrames, "LunchboxToolkitWindfuryRecords")
        end
        self.recordsWindow = window
    end

    if window.warnBtn then
        local store = LunchboxToolkitDB
        local on = not (store and store.windfuryAlertOn == false)
        window.warnBtn:SetText(on and "Warnings: on" or "Warnings: off")
    end

    local trackers = LT.Trackers
    local lineIndex = 0
    for _, setup in ipairs({ "2H", "DW" }) do
        local store = {}
        if type(trackers) == "table" and type(trackers.WindfuryRecords) == "function" then
            local ok, records = pcall(trackers.WindfuryRecords, trackers, setup)
            if ok and type(records) == "table" then store = records end
        end
        for i = 1, 5 do
            lineIndex = lineIndex + 1
            local line = window.lines[lineIndex]
            local entry = store[i]
            if line then
                if entry then
                    local crit = entry.crit and " |cffff3030CRIT|r" or ""
                    -- A secret field must never be formatted or compared; the
                    -- hard-coded "?" is used instead of reading it.
                    local target = "?"
                    if not isSecret(entry.target) then
                        target = tostring(entry.target or "?")
                    end
                    line:SetText(string.format("%d. Lvl %d vs %d %s — %s %d!%s",
                        i, tonumber(entry.level) or 0, tonumber(entry.targetLevel) or 0,
                        target, entry.ss and "SS-WF" or "WF",
                        math.floor(tonumber(entry.amount) or 0), crit))
                elseif i == 1 then
                    line:SetText("No records yet.")
                else
                    line:SetText("")
                end
            end
        end
    end
    window:Show()
end
