--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Builds
    Two independent build slots per character.

    A slot is a configuration, not a second character. Selecting a slot never
    equips anything, never spends a talent point and never touches the other
    slot's stored settings.

    A new slot is filled from the class definition: the class's default role and
    weapon setup, with no profile chosen, so Profiles:ResolveForBuild supplies
    the bundled profile that matches. Any class, role, spec or context can be
    changed on the Builds page afterwards, including pointing both slots at the
    same specialisation with different profiles and gear. Changing role, spec or
    context releases the slot's named profile key, so the two slots resolve by
    their own answers; renaming a slot keeps the key it was using.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Builds = {}
LT.Builds = Builds
LT.Modules.Builds = Builds

-- Two slots exist for a character that has reached the first talent point.
-- Below level 10 one default profile is the whole answer, so only slot 1 is
-- created and every loop reads the count from this field. Core:Refresh calls
-- EnsureForClass on every level change, which is what grows the count at 10.
Builds.SLOT_COUNT = 2
Builds.SCHEMA = 1

local SECOND_SLOT_LEVEL = 10
local FULL_SLOT_COUNT = 2

-- The level the character is now. Levels.lua owns the scoring level; the plain
-- unit level is the fallback for a client that cannot answer.
local function currentLevel()
    local levels = LT.Levels
    if type(levels) == "table" and type(levels.GetCurrentLevel) == "function" then
        local ok, level = pcall(levels.GetCurrentLevel, levels)
        if ok and tonumber(level) then return tonumber(level) end
    end
    return tonumber(LT.player and LT.player.level)
end

-- 1 below level 10, 2 from the first talent point on. A character that has
-- not reached level 10 is never shown a second build to configure.
function Builds:SlotCountForLevel(level)
    level = tonumber(level) or currentLevel()
    if level and level >= SECOND_SLOT_LEVEL then return FULL_SLOT_COUNT end
    return 1
end

-- A new Tank slot starts on Rockbiter: it is the threat imbue a tanking build
-- is expected to run. Every other role keeps the "none" a new slot has always
-- started on, so nothing about any other default moves.
local function blankImbueForRole(role)
    if role == "Tank" then return "rockbiter" end
    return "none"
end

-- `scoreImbue` is deliberately not written here: an absent value means the
-- Settings switch decides for this slot, which is the behaviour every slot had
-- before the switch existed.
local function blankBuild(index, classToken, role)
    return {
        schema      = Builds.SCHEMA,
        index       = index,
        name        = "Build " .. tostring(index),
        class       = classToken or "UNKNOWN",
        spec        = "Any",
        role        = role or "Damage",
        context     = "PVE",
        purpose     = "",
        weaponSetup = "2H",
        imbue       = blankImbueForRole(role),
        profileKey  = nil,
        gearset     = nil,
        pluginOptions = {},
        createdAt   = time and time() or 0,
    }
end

------------------------------------------------------------------------------
-- First-login weapon setup
--
-- A blank slot starts on the class default ("2H" for most classes), which
-- halves every comparison for a character who is actually wearing 1H + shield.
-- Only a slot the player has not touched and whose profile is not pinned is
-- derived from the equipped main hand. Once derived, the slot is still the
-- wizard's to fill: an explicit weapon choice is never overridden.
------------------------------------------------------------------------------

local function inventoryLink(slot)
    if type(GetInventoryItemLink) ~= "function" then return nil end
    local ok, link = pcall(GetInventoryItemLink, "player", slot)
    if not ok or type(link) ~= "string" or link == "" then return nil end
    if type(LT.IsSecret) == "function" and LT:IsSecret(link) then return nil end
    return link
end

-- The item's equip location ("INVTYPE_2HWEAPON", "INVTYPE_SHIELD", ...). It is
-- the ninth return of GetItemInfo; nil means the client has not cached the
-- item yet, which is not the same answer as "no weapon".
local function equipLocation(link)
    local getInfo
    if type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function" then
        getInfo = C_Item.GetItemInfo
    elseif type(GetItemInfo) == "function" then
        getInfo = GetItemInfo
    end
    if not getInfo then return nil end

    local ok, location = pcall(function() return select(9, getInfo(link)) end)
    if not ok or type(location) ~= "string" or location == "" then return nil end
    return string.upper(location)
end

-- Shield / one-hander / two-hander / dual wield, read from what is worn now.
-- Anything else (an empty main hand, a ranged-only kit) keeps the class
-- default.
local function equippedWeaponSetup()
    local main = equipLocation(inventoryLink(16))
    if not main then return nil end
    if main == "INVTYPE_2HWEAPON" then return "2H" end
    if main ~= "INVTYPE_WEAPON" and main ~= "INVTYPE_WEAPONMAINHAND"
        and main ~= "INVTYPE_WEAPONOFFHAND" then
        return nil
    end

    local off = equipLocation(inventoryLink(17))
    if off == "INVTYPE_SHIELD" then return "1H_SHIELD" end
    if off == "INVTYPE_WEAPON" or off == "INVTYPE_WEAPONOFFHAND" then
        return "DUAL_WIELD"
    end
    if main == "INVTYPE_WEAPONOFFHAND" then return nil end
    return "1H"
end

-- The wizard owns the untouched-slot rule; this module uses the same answer so
-- a hand-tuned slot is not re-fitted behind the player's back.
local function slotIsUntouched(index)
    local wizard = LT.Wizard
    if type(wizard) == "table" and type(wizard.IsSlotUntouched) == "function" then
        local ok, untouched = pcall(wizard.IsSlotUntouched, wizard, index)
        if ok then return untouched == true end
    end

    local build = Builds:Get(index)
    if type(build) ~= "table" then return false end
    if build.profileKey ~= nil or build.gearset ~= nil then return false end
    if build.spec ~= "Any" or build.purpose ~= "" then return false end
    if build.name ~= ("Build " .. tostring(index)) then return false end
    for _ in pairs(build.pluginOptions or {}) do return false end
    return true
end

function Builds:DeriveWeaponSetup(index)
    local build = self:Get(index)
    if type(build) ~= "table" then return false end
    -- `weaponSetupChosen` is set by SetWeaponSetup; `weaponSetupDerived` marks
    -- a slot this function already answered, so a later inventory change does
    -- not keep rewriting it.
    if build.weaponSetupChosen == true or build.weaponSetupDerived == true then
        return false
    end
    -- A pinned profile is a deliberate decision; the slot is not a blank.
    if build.profileKey ~= nil then return false end
    if not slotIsUntouched(index) then return false end

    local setup = equippedWeaponSetup()
    if not setup then return false end
    if build.weaponSetup ~= setup then build.weaponSetup = setup end
    build.weaponSetupDerived = true
    return true
end

------------------------------------------------------------------------------
-- Slot creation
------------------------------------------------------------------------------

-- Fills in missing slots for the character's class. Existing slots are never
-- rewritten, so a slot already configured keeps every choice it holds.
function Builds:EnsureForClass(classToken)
    local db = LT.Database and LT.Database.character
    if not db then return nil end

    self.SLOT_COUNT = self:SlotCountForLevel()

    db.builds = db.builds or {}
    local classDefinition = LT.ClassData and LT.ClassData:GetClass(classToken)

    for index = 1, self.SLOT_COUNT do
        local build = db.builds[index]
        if type(build) ~= "table" then
            local role = classDefinition and classDefinition.defaultRole or "Damage"

            -- The starting imbue follows the role, so a Tank slot begins on
            -- Rockbiter while every other role begins on "none".
            build = blankBuild(index, classToken, role)

            build.role = role
            build.weaponSetup = classDefinition and classDefinition.defaultSetup or "2H"
            -- A new slot is never pointed at a profile by name here. ResolveForBuild
            -- falls back to the bundled profile matching the slot's role and context,
            -- and a class pack supplies its own starter when one is installed. That
            -- keeps one player's personal weights out of everyone else's defaults.
            build.profileKey = nil

            db.builds[index] = build
        end

        self:Normalize(build)
        -- First login on a blank slot: the worn main hand is a better answer
        -- than the class default. A nil answer (item not cached, nothing worn)
        -- simply leaves the default for a later refresh to revisit.
        self:DeriveWeaponSetup(index)
    end

    db.activeBuild = db.activeBuild or 1
    return db.builds
end

-- ADDON_LOADED runs before the class is known, so the slots are created here,
-- once, at PLAYER_LOGIN: a slot created while the class was UNKNOWN would be a
-- generic "Build 1" and would never be corrected, because existing slots are
-- never rewritten.
function Builds:Initialize()
    self.SLOT_COUNT = self:SlotCountForLevel()
    local class = LT.player and LT.player.class
    if class and class ~= "UNKNOWN" then
        self:EnsureForClass(class)
    end
end

function Builds:Normalize(build)
    if type(build) ~= "table" then return build end

    build.index       = tonumber(build.index) or 1
    build.name        = build.name or ("Build " .. tostring(build.index))
    build.class       = build.class or (LT.player and LT.player.class) or "UNKNOWN"
    build.spec        = build.spec or "Any"
    build.role        = build.role or "Damage"
    build.context     = build.context or "PVE"
    build.purpose     = build.purpose or ""
    build.weaponSetup = build.weaponSetup or "2H"
    -- Additive field, normalised on read: nil (absent) means the Settings
    -- switch decides for this slot, and anything that is not a boolean is
    -- treated the same way rather than as a truthy override. No existing
    -- field is rewritten.
    if type(build.scoreImbue) ~= "boolean" then build.scoreImbue = nil end
    build.pluginOptions = build.pluginOptions or {}
    build.schema      = self.SCHEMA

    return build
end

------------------------------------------------------------------------------
-- Reading
------------------------------------------------------------------------------

function Builds:GetAll()
    local db = LT.Database and LT.Database.character
    if not db then return {} end
    return db.builds or {}
end

function Builds:Get(index)
    index = tonumber(index) or self:GetActiveIndex()
    local db = LT.Database and LT.Database.character
    local build = db and db.builds and db.builds[index]
    if not build then return nil end
    return self:Normalize(build)
end

function Builds:GetActiveIndex()
    local db = LT.Database and LT.Database.character
    if not db then return 1 end

    local index = tonumber(db.activeBuild) or 1
    if index < 1 or index > self.SLOT_COUNT then index = 1 end
    return index
end

function Builds:GetActive()
    return self:Get(self:GetActiveIndex())
end

function Builds:SetActive(index)
    local db = LT.Database and LT.Database.character
    if not db then return false end

    index = tonumber(index)
    if not index or index < 1 or index > self.SLOT_COUNT then return false end

    db.activeBuild = index
    LT:Fire(LT.EVENT_BUILDS, { reason = "active_changed", index = index })
    return true
end

function Builds:GetWeaponSetup(index)
    local build = self:Get(index)
    return build and build.weaponSetup or nil
end

function Builds:UsesOffHand(index)
    local setup = LT:GetWeaponSetupDefinition(self:GetWeaponSetup(index))
    return setup and setup.usesOffHand or false
end

------------------------------------------------------------------------------
-- Writing
--
-- Every setter touches one field of one slot. Nothing here rebuilds a build
-- from defaults, so a change to slot 1 cannot disturb slot 2.
------------------------------------------------------------------------------

local editableFields = {
    "name", "spec", "role", "context", "purpose", "weaponSetup", "profileKey",
    "imbue", "scoreImbue",
}

-- Fields that decide which bundled profile a slot resolves to. Renaming a slot
-- is not an identity change: it keeps the profile it was using.
local identityFields = {
    spec = true,
    role = true,
    context = true,
}

function Builds:SetField(index, field, value)
    local build = self:Get(index)
    if not build then return false end

    local allowed = false
    for _, name in ipairs(editableFields) do
        if name == field then allowed = true end
    end
    if not allowed then return false end

    local previous = build[field]
    build[field] = value

    -- A profile key names the weights the slot had under its old answer. Once
    -- the role, spec or context changes, that key no longer describes the
    -- slot: release it so Profiles:ResolveForBuild picks the profile for the
    -- new answer. This is what keeps two slots with different contexts on
    -- different profile keys, and it leaves SetName alone.
    if identityFields[field] and previous ~= value and build.profileKey ~= nil then
        build.profileKey = nil
    end

    LT:Fire(LT.EVENT_BUILDS, { reason = "field_changed", index = index, field = field })

    if LT.Profiles then LT.Profiles:Invalidate() end
    return true
end

function Builds:SetName(index, name)
    if type(name) ~= "string" or name == "" then return false end
    return self:SetField(index, "name", name)
end

function Builds:SetSpec(index, spec)
    return self:SetField(index, "spec", spec or "Any")
end

function Builds:SetRole(index, role)
    return self:SetField(index, "role", role or "Damage")
end

function Builds:SetContext(index, context)
    return self:SetField(index, "context", context or "PVE")
end

function Builds:SetWeaponSetup(index, setup)
    if not LT:GetWeaponSetupDefinition(setup) then return false end
    -- An explicit choice outranks the first-login derivation and is never
    -- revisited, even for a value that happens to equal the worn one.
    local build = self:Get(index)
    if type(build) == "table" then
        build.weaponSetupChosen = true
        build.weaponSetupDerived = nil
    end
    return self:SetField(index, "weaponSetup", setup)
end

function Builds:SetProfile(index, profileKey)
    return self:SetField(index, "profileKey", profileKey)
end

-- The weapon imbue this slot is scored with. Only meaningful for a Shaman, and
-- only used when this slot's own switch (or the Settings option, for a slot
-- with no switch of its own) has scoring on. Storing it per slot is what lets
-- the tanking build and the PvP build value the same weapon differently.
function Builds:SetImbue(index, imbue)
    local key = tostring(imbue or "none"):lower()

    if LT.Imbues and LT.Imbues.GetDefinition and not LT.Imbues:GetDefinition(key) then
        return false
    end

    return self:SetField(index, "imbue", key)
end

function Builds:GetImbue(index)
    local build = self:Get(index)
    return build and build.imbue or nil
end

-- Whether this slot scores its weapon through its imbue. nil clears the slot's
-- own switch so the Settings option decides again; true or false pins it here,
-- which is what lets Build 1 score and Build 2 ignore the same imbue.
function Builds:SetScoreImbue(index, value)
    if value ~= nil and type(value) ~= "boolean" then return false end
    return self:SetField(index, "scoreImbue", value)
end

-- nil means "no switch of its own": the caller falls back to the Settings
-- option rather than treating the slot as switched off.
function Builds:GetScoreImbue(index)
    local build = self:Get(index)
    if not build or type(build.scoreImbue) ~= "boolean" then return nil end
    return build.scoreImbue
end

function Builds:SetPluginEnabled(index, pluginId, enabled)
    local build = self:Get(index)
    if not build then return false end

    build.pluginOptions = build.pluginOptions or {}
    build.pluginOptions[pluginId] = enabled and true or false

    LT:Fire(LT.EVENT_PLUGINS, { reason = "toggled", pluginId = pluginId, enabled = enabled })
    if LT.Profiles then LT.Profiles:Invalidate() end
    return true
end

function Builds:IsPluginEnabled(index, pluginId)
    local build = self:Get(index)
    if not build then return false end

    local options = build.pluginOptions or {}
    if options[pluginId] == nil then return true end
    return options[pluginId] == true
end

------------------------------------------------------------------------------
-- Descriptions used by the UI and tooltips
------------------------------------------------------------------------------

function Builds:Describe(index)
    local build = self:Get(index)
    if not build then return "No build" end

    local setup = LT:GetWeaponSetupDefinition(build.weaponSetup)
    local parts = { build.spec or "Any", build.role or "Damage", build.context or "PVE" }

    if setup then table.insert(parts, setup.label) end

    return build.name .. " — " .. table.concat(parts, ", ")
end

function Builds:DescribeAll()
    local rows = {}
    for index = 1, self.SLOT_COUNT do
        table.insert(rows, self:Describe(index))
    end
    return rows
end