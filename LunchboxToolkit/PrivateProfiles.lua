--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — PrivateProfiles
    A registry for profile definitions supplied by an optional, local addon.

    Nothing in this shipped core registers into it. On a normal install the
    registry stays empty, so no profile list, picker, slash command, settings
    row or debug line changes: the module is loaded and never used.

    Visibility is decided by whoever registered the definitions, through
    SetUnlocked. That state is deliberately NOT persisted here — this addon
    keeps no record of it, so its saved variables carry no trace of which
    profiles a local addon provides.

    A registered definition has the same shape as a base profile and is read
    only: copy it to edit it. A key that already exists as a custom profile is
    not listed twice, so an edited saved copy always wins over the registered
    one (Profiles:Get checks custom profiles first).
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local PrivateProfiles = {}
LT.PrivateProfiles = PrivateProfiles
LT.Modules.PrivateProfiles = PrivateProfiles

PrivateProfiles.entries  = {}      -- ordered list of definitions
PrivateProfiles.byKey    = {}      -- key -> definition
PrivateProfiles.unlocked = false

local function invalidate()
    if LT.Profiles then LT.Profiles:Invalidate() end
end

-----------------------------------------------------------------------------
-- Registration
-----------------------------------------------------------------------------

-- Registering does not make a definition visible. Even while unlocked it is
-- only ever offered alongside the bundled profiles; it never becomes a slot's
-- default, and no bundled template may point at it (checked by SelfTest).
function PrivateProfiles:Register(classToken, definition)
    if type(definition) ~= "table" then
        return nil, "A private profile must be a table."
    end

    if type(definition.key) ~= "string" or definition.key == "" then
        return nil, "A private profile needs a stable string key."
    end

    if type(classToken) ~= "string" or classToken == "" then
        return nil, "A private profile needs a class token."
    end

    if self.byKey[definition.key] then
        return nil, "Profile key \"" .. definition.key .. "\" is already registered."
    end

    -- Shadowing a shipped key would make the same key mean two things.
    if LT.ClassData and LT.ClassData.GetBaseProfile
        and LT.ClassData:GetBaseProfile(definition.key) then
        return nil, "Profile key \"" .. definition.key .. "\" is a bundled profile key."
    end

    definition.class = definition.class or classToken
    definition.private = true
    if definition.provisional == nil then definition.provisional = true end
    definition.source = definition.source or LT.SOURCE_MANUAL

    table.insert(self.entries, definition)
    self.byKey[definition.key] = definition
    invalidate()

    return definition
end

-- Used when a local addon is disabled or reloads its definitions.
function PrivateProfiles:Forget(key)
    local definition = key and self.byKey[key]
    if not definition then return false end

    self.byKey[key] = nil

    for index, entry in ipairs(self.entries) do
        if entry == definition then
            table.remove(self.entries, index)
            break
        end
    end

    invalidate()
    return true
end

-----------------------------------------------------------------------------
-- Visibility
-----------------------------------------------------------------------------

function PrivateProfiles:SetUnlocked(flag)
    self.unlocked = flag == true
    invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "private_visibility" })
    return self.unlocked
end

function PrivateProfiles:IsUnlocked()
    return self.unlocked == true
end

-- Definitions to offer in a list, for one class or for every class. Empty
-- until unlocked, which is what keeps a locked key out of every picker.
function PrivateProfiles:Get(classToken)
    local rows = {}
    if not self.unlocked then return rows end

    for _, definition in ipairs(self.entries) do
        if not classToken
            or definition.class == classToken
            or definition.class == "ANY" then
            table.insert(rows, definition)
        end
    end

    return rows
end

-- Always resolves, locked or not: a slot that already points at one of these
-- must keep scoring the same way. Visibility is what locking changes, never
-- the arithmetic behind an existing slot.
function PrivateProfiles:Resolve(key)
    if not key then return nil end
    return self.byKey[key]
end

function PrivateProfiles:IsPrivate(key)
    return key ~= nil and self.byKey[key] ~= nil
end

function PrivateProfiles:Count()
    return #self.entries
end

-----------------------------------------------------------------------------
-- Checks used by SelfTest
-----------------------------------------------------------------------------

function PrivateProfiles:Validate()
    local problems = {}

    for _, definition in ipairs(self.entries) do
        if type(definition.weights) ~= "table" then
            table.insert(problems, definition.key .. " has no weights table.")
        else
            for stat in pairs(definition.weights) do
                if not (LT.StatLabels and LT.StatLabels[stat]) then
                    table.insert(problems, definition.key .. " uses unknown stat \""
                        .. tostring(stat) .. "\".")
                end
            end
        end

        if definition.class == "ANY" then
            table.insert(problems, definition.key
                .. " is class ANY; a private profile belongs to one class.")
        end
    end

    return problems
end
