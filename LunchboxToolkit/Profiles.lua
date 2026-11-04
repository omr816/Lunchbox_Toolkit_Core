--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Profiles
    Base weights, custom weights and effective weights.

    Three separate things, deliberately:
      base      — bundled with the addon, read only, marked provisional
      custom    — the player's own saved numbers
      effective — what the scorer actually uses, derived on demand

    The effective set is never written back into base or custom. Turning an
    adjustment (a goal, a cap policy, a plugin contribution) off removes its
    effect entirely, because it is calculated fresh every time rather than
    baked into a stored table.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Profiles = {}
LT.Profiles = Profiles
LT.Modules.Profiles = Profiles

Profiles.revision = 0
Profiles.cache = {}

local function emptyGoals()
    return {
        preset = "Balanced",
        primaryStat = nil,
        secondaryStat = nil,
        deprioritisedStats = {},
        primaryMultiplier = 1.00,
        secondaryMultiplier = 1.00,
        deprioritisedMultiplier = 1.00,
    }
end

Profiles.emptyGoals = emptyGoals

local function emptyProfile(name, classToken)
    return {
        key = nil,
        name = name or "New profile",
        class = classToken or (LT.player and LT.player.class) or "UNKNOWN",
        spec = "Any",
        role = "Damage",
        context = "PVE",
        weights = {},
        goals = emptyGoals(),
        caps = {},
        capsMeta = {},
        classOptions = {},
        source = LT.SOURCE_MANUAL,
        provisional = false,
        assumptions = "",
        createdAt = time and time() or 0,
    }
end

------------------------------------------------------------------------------
-- Reading
------------------------------------------------------------------------------

function Profiles:Invalidate()
    self.revision = self.revision + 1
    self.cache = {}
end

-- Target-aware caps added fields without a schema bump: an older custom profile
-- simply has no `capsMeta` / `sameLevelTarget` yet. This fills the missing
-- fields from Caps' data defaults the first time the profile is read. A profile
-- that already has them is untouched, and a base profile is never written to —
-- Caps falls back to the same defaults for those. Safe to call on every read.
function Profiles:EnsureCapDefaults(profile)
    if type(profile) ~= "table" then return profile end
    if profile.kind == "base" then return profile end

    if type(profile.capsMeta) ~= "table" then
        profile.capsMeta = {}
    end

    local capsModule = LT.Caps
    local metaDefaults = capsModule and capsModule.capMetaDefaults
    if not tonumber(profile.capsMeta.endgameLevel)
        and metaDefaults and tonumber(metaDefaults.endgameLevel) then
        profile.capsMeta.endgameLevel = tonumber(metaDefaults.endgameLevel)
    end

    local caps = profile.caps
    if type(caps) ~= "table" then return profile end

    local statDefaults = capsModule and capsModule.defaults
    for stat, entry in pairs(caps) do
        if type(entry) == "table" and entry.sameLevelTarget == nil then
            local base = statDefaults and statDefaults[stat]
            local sameLevel = base and tonumber(base.sameLevelTarget)
            if sameLevel then
                entry.sameLevelTarget = sameLevel
            end
        end
    end

    return profile
end

-- Optional alternate home for custom profiles. nil means the character record,
-- which is the behaviour every shipped install has. A local addon may hand over
-- its own saved table so custom profiles live elsewhere; the caller keeps
-- ownership of that table and may revert at any time.
local customStore = nil

function Profiles:GetCustomTable()
    if customStore then return customStore end

    local db = LT.Database and LT.Database.character
    if not db then return {} end

    db.customProfiles = db.customProfiles or {}
    return db.customProfiles
end

-- nil restores the character record. Existing profiles are not migrated here:
-- moving data between stores is the caller's job, because only the caller knows
-- what its own saved shape should be.
function Profiles:SetCustomStore(store)
    if store ~= nil and type(store) ~= "table" then
        return false, "A custom store must be a table, or nil to use the character record."
    end

    customStore = store

    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "custom store" })

    return true
end

-- The external store, or nil when custom profiles are in the character record.
function Profiles:GetCustomStore()
    return customStore
end

function Profiles:IsUsingCustomStore()
    return customStore ~= nil
end

-- Every profile the character can choose from: bundled bases plus custom ones.
function Profiles:GetAll()
    local rows = {}

    for _, base in ipairs((LT.ClassData and LT.ClassData:GetBaseProfiles()) or {}) do
        local copy = LT:Copy(base)
        copy.kind = "base"
        copy.editable = false
        table.insert(rows, copy)
    end

    -- Profiles supplied by an optional local addon. They are only offered while
    -- that addon says they are visible, and a key that already exists as a saved
    -- custom profile is not listed twice: the editable copy is the one shown.
    for _, definition in ipairs((LT.PrivateProfiles and LT.PrivateProfiles:Get()) or {}) do
        if not self:GetCustomTable()[definition.key] then
            local copy = LT:Copy(definition)
            copy.kind = "base"
            copy.editable = false
            table.insert(rows, copy)
        end
    end

    for key, custom in pairs(self:GetCustomTable()) do
        local copy = LT:Copy(custom)
        copy.key = key
        copy.kind = "custom"
        copy.editable = true
        table.insert(rows, copy)
    end

    table.sort(rows, function(a, b)
        if a.kind ~= b.kind then return a.kind == "base" end
        return (a.name or "") < (b.name or "")
    end)

    return rows
end

-- Base profiles for the character's own class come first in the picker.
function Profiles:GetSuggested(classToken)
    local rows = {}

    for _, profile in ipairs(self:GetAll()) do
        if profile.class == classToken or profile.class == "ANY" then
            table.insert(rows, profile)
        end
    end

    return rows
end

function Profiles:Get(key)
    if not key then return nil end

    local custom = self:GetCustomTable()[key]
    if custom then
        custom.key = key
        custom.kind = "custom"
        -- Decision 3: editable = false when locked, true otherwise
        custom.editable = not (custom.locked == true)
        custom.locked   = custom.locked == true   -- normalise to bool
        self:EnsureCapDefaults(custom)
        return custom
    end

    local base = LT.ClassData and LT.ClassData:GetBaseProfile(key)
    if base then
        local copy = LT:Copy(base)
        copy.kind = "base"
        copy.editable = false
        return copy
    end

    -- A profile from an optional local addon. It resolves even when it is not
    -- being offered anywhere, so a slot that already points at one keeps
    -- scoring identically; whether it may be *assigned* is a separate question,
    -- answered by Profiles:Assignable.
    local private = LT.PrivateProfiles and LT.PrivateProfiles:Resolve(key)
    if private then
        local copy = LT:Copy(private)
        copy.kind = "base"
        copy.editable = false
        return copy
    end

    return nil
end

-- Where a profile key comes from, in the words the Profiles page shows. Kept
-- separate from `kind`, because a local addon's profile deliberately resolves
-- with kind "base" so no editing path accepts it; the page still has to tell the
-- player the key came from their own addon rather than from the bundle. This is
-- about the key's home, not about a profile's own `source` provenance field.
function Profiles:KeySource(key)
    if not key then return nil end
    if self:GetCustomTable()[key] then return "custom" end
    if LT.ClassData and LT.ClassData:GetBaseProfile(key) then return "bundled" end
    if LT.PrivateProfiles and LT.PrivateProfiles:Resolve(key) then return "private" end
    return nil
end

-- Whether a key may be put on a slot right now. Custom and bundled profiles
-- always may; a local addon's profile only while that addon has it unlocked.
-- Nothing else in the addon needs to know where a key came from.
function Profiles:Assignable(key)
    if not key then return false end
    if self:GetCustomTable()[key] then return true end
    if LT.ClassData and LT.ClassData:GetBaseProfile(key) then return true end
    if LT.PrivateProfiles
        and LT.PrivateProfiles:IsUnlocked()
        and LT.PrivateProfiles:Resolve(key) then
        return true
    end
    return false
end

-- The first bundled profile matching a class, role and context. `spec` limits
-- the search to one specialisation; nil accepts any spec, which is the
-- role-level fallback.
local function findBaseProfile(classToken, spec, role, context)
    local data = LT.ClassData
    if type(data) ~= "table" or type(data.GetBaseProfiles) ~= "function" then
        return nil
    end

    local ok, profiles = pcall(data.GetBaseProfiles, data)
    if not ok or type(profiles) ~= "table" then return nil end

    for _, candidate in ipairs(profiles) do
        if type(candidate) == "table"
            and candidate.class == classToken
            and candidate.role == role
            and candidate.context == context
            and (spec == nil or candidate.spec == spec) then
            return candidate
        end
    end
    return nil
end

local function asBaseCopy(candidate)
    local copy = LT:Copy(candidate)
    copy.kind = "base"
    copy.editable = false
    return copy
end

-- Public and pure: the bundled profile for one class / spec / role / context,
-- with no character record, build slot or cache involved. ResolveForBuild is
-- this lookup used twice, so the audits and the self test that ask "does this
-- class have weights at level 1-9" ask the same question the resolver does
-- instead of re-deriving it. `spec` may be "Any" for the role-level fallback.
function Profiles.FindBaseProfile(classToken, spec, role, context)
    return findBaseProfile(classToken, spec, role, context)
end

-- True only for a key that lives in the bundled ClassData set. A custom or
-- local-addon key is an explicit assignment and is never second-guessed here.
local function isBundledKey(key)
    if type(key) ~= "string" or key == "" then return false end

    local data = LT.ClassData
    if type(data) ~= "table" or type(data.GetBaseProfile) ~= "function" then
        return false
    end

    local ok, profile = pcall(data.GetBaseProfile, data, key)
    return ok and type(profile) == "table"
end

-- Whether a bundled key still describes this slot. Class and context are the
-- parts that say where the profile came from and what it is for; a bundled key
-- left over from another context must not keep scoring after the slot's own
-- answer changed. Role and spec are deliberately not compared: a broad
-- role-level profile is a valid answer for a narrower slot.
--
-- This is enforced for bundled keys only. A custom profile was assigned by the
-- player on purpose, so an explicit choice is honoured even when its labels are
-- broader or older than the slot; changing the slot's context still releases
-- it in Builds:SetField, which is what re-resolves it.
function Profiles:ProfileFitsBuild(profile, build)
    if type(profile) ~= "table" or type(build) ~= "table" then return false end

    local classToken = build.class
    if type(classToken) == "string" and classToken ~= "" and classToken ~= "UNKNOWN"
        and type(profile.class) == "string" and profile.class ~= ""
        and profile.class ~= "UNKNOWN" and profile.class ~= "ANY"
        and profile.class ~= classToken then
        return false
    end

    if type(build.context) == "string" and build.context ~= ""
        and type(profile.context) == "string" and profile.context ~= ""
        and profile.context ~= build.context then
        return false
    end

    return true
end

-- The profile a build actually uses, falling back to the class default so a
-- new slot is never left without scoring weights.
--
-- Order: a named key that still fits the slot, then the exact spec + role +
-- context starting point, then any bundled profile for the role and context.
-- A slot whose spec is "Any" can only meet a role-level profile in the exact
-- pass (spec-level profiles name a real specialisation), so it keeps resolving
-- the profile it resolved before; where a class has no role-level profile for
-- that role, the fallback below is the same single pass this function used to
-- run.
function Profiles:ResolveForBuild(buildIndex)
    local builds = LT.Builds
    local build
    if type(builds) == "table" and type(builds.Get) == "function" then
        local ok, value = pcall(builds.Get, builds, buildIndex)
        if ok then build = value end
    end
    if type(build) ~= "table" then return nil end

    local profile
    if build.profileKey then
        local ok, value = pcall(self.Get, self, build.profileKey)
        if ok then profile = value end
    end

    -- A bundled key that no longer fits the slot is treated as absent, so a
    -- saved build whose context was changed on the Builds page resolves the
    -- profile for its current answers instead of the one it used to point at.
    -- A custom or local-addon key stays: the player put it there, and Builds
    -- releases it when the slot's role, spec or context actually changes.
    if profile and (not isBundledKey(build.profileKey)
        or self:ProfileFitsBuild(profile, build)) then
        return profile
    end

    local exact = findBaseProfile(build.class, build.spec or "Any",
        build.role, build.context)
    if exact then return asBaseCopy(exact) end

    -- The fallback must be the role-level profile only. Passing nil here would
    -- match any spec, so a slot left on "Any" could silently borrow the first
    -- spec profile in name order.
    local fallback = findBaseProfile(build.class, "Any", build.role, build.context)
    if fallback then return asBaseCopy(fallback) end

    return nil
end

-- What a slot resolves to, in one place, so the Profiles page row and the
-- Weights window cannot disagree: the profile itself, its key and name, and
-- where that key came from. `profile.key` is not `build.profileKey` when a slot
-- has never been pointed at a profile — the fallback above answers instead.
function Profiles:ResolveSlot(buildIndex)
    local profile = self:ResolveForBuild(buildIndex)

    if not profile then
        return { buildIndex = buildIndex, profile = nil, key = nil, name = nil, source = nil }
    end

    return {
        buildIndex = buildIndex,
        profile = profile,
        key = profile.key,
        name = profile.name,
        source = self:KeySource(profile.key),
    }
end

function Profiles:GetStoredWeights(profile)
    if not profile then return {} end
    return LT:Copy(profile.weights or {})
end


------------------------------------------------------------------------------
-- Custom profile management
------------------------------------------------------------------------------

local function uniqueKey(name)
    local baseKey = "custom_" .. tostring(name):lower():gsub("%s+", "_"):gsub("[^%w_]", "")
    if baseKey == "custom_" then baseKey = "custom_profile" end

    local table_ = Profiles:GetCustomTable()
    local key = baseKey
    local index = 2
    while table_[key] do
        key = baseKey .. "_" .. tostring(index)
        index = index + 1
    end

    return key
end

-- Creates a custom profile. `fromKey` copies an existing base or custom
-- profile's weights; omitting it produces an empty custom profile.
function Profiles:Create(name, fromKey)
    if type(name) ~= "string" or name == "" then
        return nil, "A profile name is required."
    end

    local table_ = self:GetCustomTable()
    for _, existing in pairs(table_) do
        if existing.name == name then
            return nil, "A custom profile called \"" .. name .. "\" already exists."
        end
    end

    local source = fromKey and self:Get(fromKey)
    local profile = emptyProfile(name, source and source.class or (LT.player and LT.player.class))

    if source then
        profile.weights = LT:Copy(source.weights or {})
        profile.goals = LT:Copy(source.goals or emptyGoals())
        profile.caps = LT:Copy(source.caps or {})
        profile.capsMeta = LT:Copy(source.capsMeta or {})
        profile.classOptions = LT:Copy(source.classOptions or {})
        profile.spec = source.spec
        profile.role = source.role
        profile.context = source.context
        profile.origin = "copied from " .. tostring(source.name)
        profile.assumptions = "A copy of \"" .. tostring(source.name) .. "\". "
            .. "Editing this profile does not change the profile it came from."
    else
        profile.caps = {}
        profile.classOptions = LT.ClassData and LT.ClassData:GetDefaultClassOptions(profile.class) or {}
        profile.origin = "created empty"
    end

    profile.provisional = source and source.provisional or false
    if source and source.assumptions and profile.provisional then
        profile.assumptions = profile.assumptions .. " " .. tostring(source.assumptions)
    end

    local key = uniqueKey(name)
    profile.key = key
    table_[key] = profile

    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "created", key = key })
    return key
end

-- Copying a base profile is the supported way to edit shipped weights.
function Profiles:CopyProfile(sourceKey, newName)
    local source = self:Get(sourceKey)
    if not source then return nil, "The profile to copy no longer exists." end

    return self:Create(newName or (source.name .. " (copy)"), sourceKey)
end

function Profiles:Rename(key, newName)
    local profile = self:GetCustomTable()[key]
    if not profile then return false, "Only custom profiles can be renamed." end
    if profile.locked then return false, "This profile is locked. Unlock it to rename it." end
    if type(newName) ~= "string" or newName == "" then
        return false, "A profile name is required."
    end

    profile.name = newName
    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "renamed", key = key })
    return true
end

function Profiles:Delete(key)
    local table_ = self:GetCustomTable()
    if not table_[key] then return false, "Only custom profiles can be deleted." end

    -- Refuse while a build still points at it, for the same reason the build
    -- picker refuses: silently reassigning a build's weights would change
    -- every score that build produces.
    for index = 1, (LT.Builds and LT.Builds.SLOT_COUNT or 2) do
        local build = LT.Builds and LT.Builds:Get(index)
        if build and build.profileKey == key then
            return false, "Build " .. tostring(index) .. " (" .. tostring(build.name)
                .. ") still uses this profile."
        end
    end

    table_[key] = nil
    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "deleted", key = key })
    return true
end

------------------------------------------------------------------------------
-- Weight and option editing (custom profiles only)
------------------------------------------------------------------------------

-- Decision 3: toggle the locked flag on a custom profile.
function Profiles:SetLocked(key, value)
    local profile = self:GetCustomTable()[key]
    if not profile then return false, "Only custom profiles can be locked." end

    profile.locked = value and true or nil   -- nil = unlocked (saves space)
    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "locked_changed", key = key })
    return true
end

function Profiles:SetWeight(key, stat, value)
    local profile = self:GetCustomTable()[key]
    if not profile then
        return false, "Base profiles cannot be edited. Copy it to a custom profile first."
    end
    if profile.locked then
        return false, "This profile is locked. Unlock it to make changes."
    end

    local number = tonumber(value)
    if not number then return false, "That is not a number." end

    profile.weights = profile.weights or {}
    profile.weights[stat] = number

    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "weight_changed", key = key, stat = stat })
    return true
end

-- Replaces every weight of a custom profile in one step. The profile editor
-- writes a weight at a time because each row commits on its own; the Weights
-- window has a whole draft to store, and firing one event per stat would rebuild
-- the page thirty-odd times for one save.
function Profiles:SetWeights(key, weights)
    local profile = self:GetCustomTable()[key]
    if not profile then
        return false, "Base profiles cannot be edited. Copy it to a custom profile first."
    end
    if profile.locked then
        return false, "This profile is locked. Unlock it to make changes."
    end
    if type(weights) ~= "table" then
        return false, "There are no weights to store."
    end

    local stored = {}
    for stat, value in pairs(weights) do
        local number = tonumber(value)
        if number then stored[stat] = number end
    end

    profile.weights = stored

    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "weights_changed", key = key })
    return true
end

function Profiles:SetGoal(key, field, value)
    local profile = self:GetCustomTable()[key]
    if not profile then return false, "Only custom profiles can be edited." end
    if profile.locked then return false, "This profile is locked. Unlock it to make changes." end

    profile.goals = profile.goals or emptyGoals()
    profile.goals[field] = value

    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "goal_changed", key = key, field = field })
    return true
end

function Profiles:SetGoalPreset(key, presetName)
    local preset = LT.GoalPresets[presetName]
    local profile = self:GetCustomTable()[key]
    if not profile then return false, "Only custom profiles can be edited." end
    if profile.locked then return false, "This profile is locked. Unlock it to make changes." end
    if not preset then return false, "Unknown goal preset." end

    profile.goals = profile.goals or emptyGoals()
    profile.goals.preset = presetName
    profile.goals.primaryMultiplier = preset.primaryMultiplier
    profile.goals.secondaryMultiplier = preset.secondaryMultiplier
    profile.goals.deprioritisedMultiplier = preset.deprioritisedMultiplier

    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "goal_preset", key = key })
    return true
end

function Profiles:SetClassOption(key, optionKey, value)
    local profile = self:GetCustomTable()[key]
    if not profile then return false, "Only custom profiles can be edited." end
    if profile.locked then return false, "This profile is locked. Unlock it to make changes." end

    profile.classOptions = profile.classOptions or {}
    profile.classOptions[optionKey] = value

    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "class_option", key = key })
    return true
end

function Profiles:SetCap(key, stat, field, value)
    local profile = self:GetCustomTable()[key]
    if not profile then return false, "Only custom profiles can be edited." end
    if profile.locked then return false, "This profile is locked. Unlock it to make changes." end

    profile.caps = profile.caps or {}
    profile.caps[stat] = profile.caps[stat] or {}
    profile.caps[stat][field] = value

    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "cap_changed", key = key, stat = stat })
    return true
end

------------------------------------------------------------------------------
-- Level bands
--
-- PROVISIONAL, UNMEASURED. Below 60 the mix that matters while levelling is
-- not the endgame mix, so a small set of weights is scaled per band. These
-- numbers are conservative starting points, not client-measured facts:
-- survival stats (stamina) and white damage (weaponDPS) count a little more,
-- and the endgame hit/expertise/spell-hit targets count a little less, with
-- each band closer to the unmodified weights than the one before. Caps
-- themselves are never edited here; only the weights that feed the score.
Profiles.LEVEL_BANDS = {
    { name = "1-9",   min = 1,  max = 9,
      factors = { stamina = 1.10, weaponDPS = 1.08, hit = 0.85, expertise = 0.80, spellHit = 0.90 } },
    { name = "10-29", min = 10, max = 29,
      factors = { stamina = 1.08, weaponDPS = 1.06, hit = 0.90, expertise = 0.85, spellHit = 0.92 } },
    { name = "30-44", min = 30, max = 44,
      factors = { stamina = 1.05, weaponDPS = 1.03, hit = 0.95, expertise = 0.92, spellHit = 0.95 } },
    { name = "45-59", min = 45, max = 59,
      factors = { stamina = 1.02, weaponDPS = 1.01, hit = 0.97, expertise = 0.96, spellHit = 0.97 } },
}

-- Roles the bands apply to. A hybrid profile's weights are left alone: its
-- role changes with the chosen spec, so a single band answer would be a guess.
local bandRoles = { Damage = true, Healer = true, Tank = true }

-- Pure: the band that owns a scoring level, or nil at/above 60 (or bad input).
function Profiles.LevelBand(level)
    local number = tonumber(level)
    if not number then return nil end
    number = math.floor(number)
    for _, band in ipairs(Profiles.LEVEL_BANDS) do
        if number >= band.min and number <= band.max then return band end
    end
    return nil
end

-- Pure: the multiplier a level band applies to one stat's weight. 1 when the
-- level is outside every band or the stat is not listed in it.
function Profiles.LevelBandFactor(level, stat)
    local band = Profiles.LevelBand(level)
    if not band then return 1 end
    return band.factors[stat] or 1
end

-- levellingBands option. Read through GetOptions so a record saved before the
-- option existed keeps its default.
function Profiles:IsLevellingBands()
    if not (LT.Database and LT.Database.GetOptions) then return false end
    local options = LT.Database:GetOptions()
    if type(options) ~= "table" then return false end
    return options.levellingBands == true
end

------------------------------------------------------------------------------
-- Effective weights
--
-- The one place a score's weights come from. Order is fixed and reported:
--   stored weights -> goal multipliers -> level bands -> cap policy
--   -> plugin adjustments
------------------------------------------------------------------------------

-- opts.level overrides the scoring level (used by tests and the UI preview).
function Profiles:GetEffective(buildIndex, opts)
    opts = opts or {}

    local build = LT.Builds and LT.Builds:Get(buildIndex)
    local profile = self:ResolveForBuild(buildIndex)

    if not build or not profile then
        return {
            weights = {},
            trace = {},
            limitations = { "No build or profile is configured yet." },
            profile = nil,
            build = build,
            scale = nil,
            provisional = true,
        }
    end

    local level = opts.level
        or (LT.Levels and LT.Levels:GetScoringLevel())
        or 1

    -- The target set is part of the answer: toggling capsEndgame (or a profile's
    -- threshold) must not reuse a result computed with the other set.
    local capsSignature = "none"
    if LT.Caps and LT.Caps.GetPolicySignature then
        capsSignature = LT.Caps:GetPolicySignature(profile)
    end

    local cacheKey = tostring(buildIndex) .. "|" .. tostring(profile.key) .. "|"
        .. tostring(level) .. "|" .. tostring(self.revision) .. "|" .. capsSignature
        .. "|" .. (self:IsLevellingBands() and "bands" or "no-bands")

    if not opts.noCache and self.cache[cacheKey] then
        return self.cache[cacheKey]
    end

    local weights = LT:Copy(profile.weights or {})
    local trace = {}
    local limitations = {}

    for stat, value in pairs(weights) do
        table.insert(trace, {
            stage = profile.kind == "custom" and "custom" or "base",
            stat = stat,
            value = value,
            note = profile.name,
        })
    end

    -- 1. Goals: a deliberate emphasis, applied as a multiplier.
    local goals = profile.goals or emptyGoals()
    local multiplierFields = {
        { stat = goals.primaryStat, multiplier = goals.primaryMultiplier, label = "primary" },
        { stat = goals.secondaryStat, multiplier = goals.secondaryMultiplier, label = "secondary" },
    }

    for _, entry in ipairs(multiplierFields) do
        if entry.stat and weights[entry.stat] and tonumber(entry.multiplier) ~= 1 then
            local before = weights[entry.stat]
            weights[entry.stat] = before * (tonumber(entry.multiplier) or 1)
            table.insert(trace, {
                stage = "goal",
                stat = entry.stat,
                from = before,
                value = weights[entry.stat],
                note = "goal " .. entry.label .. " x"
                    .. LT:FormatNumber(entry.multiplier, 2)
                    .. " (preset " .. tostring(goals.preset or "Custom") .. ")",
            })
        end
    end

    for stat, enabled in pairs(goals.deprioritisedStats or {}) do
        if enabled and weights[stat] and tonumber(goals.deprioritisedMultiplier) ~= 1 then
            local before = weights[stat]
            weights[stat] = before * (tonumber(goals.deprioritisedMultiplier) or 1)
            table.insert(trace, {
                stage = "goal",
                stat = stat,
                from = before,
                value = weights[stat],
                note = "deliberately de-prioritised x"
                    .. LT:FormatNumber(goals.deprioritisedMultiplier, 2),
            })
        end
    end

    -- 2. Level bands: the scoring level in the profile decides the band, and
    -- only Damage/Healer/Tank profiles are scaled. Caps run afterwards, so no
    -- cap target or cap status is touched here. PROVISIONAL numbers, see
    -- Profiles.LEVEL_BANDS.
    if self:IsLevellingBands() and bandRoles[profile.role] then
        local band = Profiles.LevelBand(level)
        if band then
            for stat, value in pairs(weights) do
                local factor = band.factors[stat]
                if factor and factor ~= 1 then
                    local before = value
                    weights[stat] = value * factor
                    table.insert(trace, {
                        stage = "band",
                        stat = stat,
                        from = before,
                        value = weights[stat],
                        note = "level band " .. band.name .. " x"
                            .. LT:FormatNumber(factor, 2),
                    })
                end
            end
        end
    end

    -- 3. Cap policy — the only place caps are allowed to touch a weight.
    local capResult
    if LT.Caps then
        capResult = LT.Caps:ApplyPolicy(weights, profile, level)
        for _, entry in ipairs((capResult and capResult.trace) or {}) do
            table.insert(trace, entry)
        end
        for _, limitation in ipairs((capResult and capResult.limitations) or {}) do
            table.insert(limitations, limitation)
        end
    end

    -- 4. Plugin adjustments, ordered and de-duplicated by the plugin API.
    local pluginResult
    if LT.PluginAPI then
        pluginResult = LT.PluginAPI:CollectAdjustments({
            build = build,
            buildIndex = buildIndex,
            profile = profile,
            level = level,
            weights = weights,     -- plugins adjust the weights built so far
        })

        weights = pluginResult.weights or weights
        for _, entry in ipairs(pluginResult.trace or {}) do
            table.insert(trace, entry)
        end
        for _, limitation in ipairs(pluginResult.limitations or {}) do
            table.insert(limitations, limitation)
        end
    end

    -- Provisional data is flagged here so every surface that shows a score can
    -- say so without repeating the logic.
    if profile.provisional then
        table.insert(limitations,
            "\"" .. tostring(profile.name) .. "\" is a provisional starting profile, "
            .. "not validated against Forever's combat maths.")
    end
    if profile.assumptions and profile.assumptions ~= "" then
        table.insert(limitations, profile.assumptions)
    end

    local result = {
        weights = weights,
        trace = trace,
        limitations = limitations,
        profile = profile,
        build = build,
        level = level,
        scale = profile.key,          -- scores are only comparable within a scale
        scaleName = profile.name,
        provisional = profile.provisional == true,
        pluginsApplied = (pluginResult and pluginResult.applied) or {},
        capStatus = capResult,
    }

    if not opts.noCache then
        self.cache[cacheKey] = result
    end

    LT:Fire(LT.EVENT_WEIGHTS, { buildIndex = buildIndex, profileKey = profile.key })

    return result
end

-- A short human summary of everything that moved a weight away from its
-- stored value, for the expanded tooltip and the debug page.
function Profiles:ExplainEffective(buildIndex, opts)
    local effective = self:GetEffective(buildIndex, opts)
    local lines = {}

    for _, entry in ipairs(effective.trace or {}) do
        if entry.stage ~= "base" and entry.stage ~= "custom" then
            table.insert(lines, LT:Label(entry.stat) .. ": "
                .. LT:FormatNumber(entry.from or entry.value, 3) .. " -> "
                .. LT:FormatNumber(entry.value, 3) .. " (" .. tostring(entry.note) .. ")")
        end
    end

    return lines
end

-----------------------------------------------------------------------------
-- Import / export
--
-- One profile becomes one line of text, so it can be printed to chat, pasted
-- into a text editor, edited by hand and pasted back with /lt import. The
-- format is versioned and self-describing:
--
--   LBT1;name=Enhancement 2H PvP;class=SHAMAN;spec=Enhancement;role=Damage;
--   context=PVP;locked=0;preset=Balanced;primary=agility;secondary=crit;
--   multipliers=1,1,1;deprioritised=none;weights=stamina:1.5,strength:0.75;
--   caps=hit:1:percent:9:2
--
-- The separators are ; = , : and %, and each of them inside a value is escaped
-- as %3B %3D %2C %3A %25. Weights and caps are always written in the addon's
-- own stat order, so exporting one profile twice produces identical text and a
-- text diff only shows real changes.
--
-- Import never overwrites anything: it always creates a new custom profile,
-- because an imported string is external data and could otherwise destroy the
-- profile the player is comparing against.
-----------------------------------------------------------------------------

Profiles.IO_PREFIX = "LBT1"

local IO_SEPARATOR = ";"

local function trimText(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function escapeField(value)
    local text = tostring(value == nil and "" or value)
    text = text:gsub("%%", "%%25")
    text = text:gsub(";", "%%3B")
    text = text:gsub("=", "%%3D")
    text = text:gsub(",", "%%2C")
    text = text:gsub(":", "%%3A")
    return text
end

local function unescapeField(value)
    local text = tostring(value == nil and "" or value)
    text = text:gsub("%%3B", ";")
    text = text:gsub("%%3D", "=")
    text = text:gsub("%%2C", ",")
    text = text:gsub("%%3A", ":")
    text = text:gsub("%%25", "%%")
    return text
end

local function splitOn(text, pattern)
    local parts = {}
    for part in tostring(text or ""):gmatch(pattern or "[^;]+") do
        table.insert(parts, part)
    end
    return parts
end

-- "0.7500" -> "0.75", so hand editing stays readable. Rounding is to four
-- places, which is finer than any weight the addon uses.
local function numberText(value)
    local number = tonumber(value)
    if not number then return nil end
    return tostring(LT:Round(number, 4))
end

function Profiles:SerializeWeights(profile)
    local weights = (profile and profile.weights) or {}
    local parts = {}
    local written = {}

    local function addStat(stat)
        local value = numberText(weights[stat])
        if value then
            written[stat] = true
            table.insert(parts, stat .. ":" .. value)
        end
    end

    for _, stat in ipairs(LT.StatOrder or {}) do addStat(stat) end

    -- A stat key this build does not know about is still carried, so importing
    -- a profile from a newer version never silently drops data.
    local extra = {}
    for stat in pairs(weights) do
        if not written[stat] then table.insert(extra, stat) end
    end
    table.sort(extra)
    for _, stat in ipairs(extra) do addStat(stat) end

    if #parts == 0 then return "none" end
    return table.concat(parts, ",")
end

function Profiles:SerializeCaps(profile)
    local caps = (profile and profile.caps) or {}
    local parts = {}
    local written = {}

    local function addCap(stat)
        local entry = caps[stat]
        if type(entry) ~= "table" then return end

        written[stat] = true

        local fields = {
            stat,
            entry.enabled and "1" or "0",
            tostring(entry.kind or "percent"),
            numberText(entry.target) or "0",
            numberText(entry.importance) or "0",
        }

        local conversion = numberText(entry.skillConversion)
        if conversion then table.insert(fields, conversion) end

        table.insert(parts, table.concat(fields, ":"))
    end

    for _, stat in ipairs((LT.Caps and LT.Caps.order) or {}) do addCap(stat) end

    local extra = {}
    for stat in pairs(caps) do
        if not written[stat] then table.insert(extra, stat) end
    end
    table.sort(extra)
    for _, stat in ipairs(extra) do addCap(stat) end

    if #parts == 0 then return "none" end
    return table.concat(parts, ",")
end

-- Profile -> one importable line. Base profiles export too: that is the
-- supported way to start a custom profile from a text editor.
function Profiles:Serialize(key)
    local profile = self:Get(key)
    if not profile then
        return nil, "There is no profile called \"" .. tostring(key) .. "\"."
    end

    local goals = profile.goals or emptyGoals()
    local fields = { self.IO_PREFIX }

    local function add(name, value)
        table.insert(fields, name .. "=" .. escapeField(value))
    end

    add("name", profile.name or "Imported profile")
    add("class", profile.class or "UNKNOWN")
    add("spec", profile.spec or "Any")
    add("role", profile.role or "Damage")
    add("context", profile.context or "PVE")
    add("locked", profile.locked and "1" or "0")
    add("preset", goals.preset or "Balanced")
    add("primary", goals.primaryStat or "none")
    add("secondary", goals.secondaryStat or "none")
    add("multipliers", table.concat({
        numberText(goals.primaryMultiplier) or "1",
        numberText(goals.secondaryMultiplier) or "1",
        numberText(goals.deprioritisedMultiplier) or "1",
    }, ","))

    local deprioritised = {}
    for stat, enabled in pairs(goals.deprioritisedStats or {}) do
        if enabled then table.insert(deprioritised, tostring(stat)) end
    end
    table.sort(deprioritised)
    add("deprioritised", #deprioritised > 0 and table.concat(deprioritised, ",") or "none")

    add("weights", self:SerializeWeights(profile))
    add("caps", self:SerializeCaps(profile))

    return table.concat(fields, IO_SEPARATOR)
end

-- Every profile, base and custom, one line each, in the order /lt profiles
-- lists them: { { key = ..., name = ..., text = ... }, ... }
function Profiles:SerializeAll()
    local rows = {}

    for _, profile in ipairs(self:GetAll()) do
        local text = self:Serialize(profile.key)
        if text then
            table.insert(rows, { key = profile.key, name = profile.name, text = text })
        end
    end

    return rows
end

-- Text -> profile data. Returns data, or nil and a reason.
-- Unknown stat keys are kept and listed in data.unknownStats, so the caller can
-- warn about them instead of dropping them silently.
function Profiles:Parse(text)
    local source = trimText(text)
    if source == "" then return nil, "There is nothing to import." end

    local fields = splitOn(source, "[^;]+")
    local prefix = trimText(fields[1] or "")

    if prefix ~= self.IO_PREFIX then
        return nil, "That is not a Lunchbox Toolkit profile string: it must start with \""
            .. self.IO_PREFIX .. "\" (the current format version)."
    end

    local values = {}
    for index = 2, #fields do
        local name, value = tostring(fields[index]):match("^([^=]+)=(.*)$")
        if name then
            values[trimText(name)] = value or ""
        end
    end

    local data = { unknownStats = {}, warnings = {} }

    data.name = unescapeField(values.name or "")
    if data.name == "" then data.name = "Imported profile" end

    data.class = unescapeField(values.class or "UNKNOWN")
    data.spec = unescapeField(values.spec or "Any")
    data.role = unescapeField(values.role or "Damage")
    data.context = unescapeField(values.context or "PVE")
    data.locked = (values.locked == "1" or values.locked == "true")

    local goals = emptyGoals()
    goals.preset = unescapeField(values.preset or "Balanced")

    local primary = unescapeField(values.primary or "none")
    goals.primaryStat = (primary ~= "" and primary ~= "none") and primary or nil

    local secondary = unescapeField(values.secondary or "none")
    goals.secondaryStat = (secondary ~= "" and secondary ~= "none") and secondary or nil

    local multipliers = splitOn(unescapeField(values.multipliers or ""), "[^,]+")
    goals.primaryMultiplier = tonumber(multipliers[1]) or 1
    goals.secondaryMultiplier = tonumber(multipliers[2]) or 1
    goals.deprioritisedMultiplier = tonumber(multipliers[3]) or 1

    local deprioritised = unescapeField(values.deprioritised or "")
    if deprioritised ~= "" and deprioritised ~= "none" then
        for _, stat in ipairs(splitOn(deprioritised, "[^,]+")) do
            goals.deprioritisedStats[trimText(stat)] = true
        end
    end

    data.goals = goals

    local weights = {}
    local weightsText = unescapeField(values.weights or "")
    if weightsText ~= "" and weightsText ~= "none" then
        for _, entry in ipairs(splitOn(weightsText, "[^,]+")) do
            local stat, value = tostring(entry):match("^([^:]+):(.*)$")
            stat = trimText(stat or "")

            if stat ~= "" then
                local number = tonumber(value)
                if number then
                    weights[stat] = number
                    if not LT.StatLabels[stat] then
                        table.insert(data.unknownStats, stat)
                    end
                else
                    table.insert(data.warnings, "\"" .. stat
                        .. "\" has no numeric weight and was skipped.")
                end
            end
        end
    end

    data.weights = weights

    local caps = {}
    local capsText = unescapeField(values.caps or "")
    if capsText ~= "" and capsText ~= "none" then
        for _, entry in ipairs(splitOn(capsText, "[^,]+")) do
            local parts = splitOn(tostring(entry), "[^:]+")
            local stat = trimText(parts[1] or "")

            if stat ~= "" then
                caps[stat] = {
                    enabled = (parts[2] == "1" or parts[2] == "true"),
                    kind = (parts[3] and parts[3] ~= "") and parts[3] or "percent",
                    target = tonumber(parts[4]) or 0,
                    importance = tonumber(parts[5]) or 0,
                }

                local conversion = tonumber(parts[6])
                if conversion then caps[stat].skillConversion = conversion end

                if not LT.StatLabels[stat] then
                    table.insert(data.unknownStats, stat)
                end
            end
        end
    end

    data.caps = caps

    return data
end
-- A name that does not collide with an existing custom profile, so importing the
-- same line twice gives "Name", "Name (2)" and so on instead of a clash.
local function uniqueName(name)
    local table_ = Profiles:GetCustomTable()
    local taken = {}

    for _, existing in pairs(table_) do
        taken[existing.name] = true
    end

    local candidate = name
    local index = 2
    while taken[candidate] do
        candidate = name .. " (" .. tostring(index) .. ")"
        index = index + 1
    end

    return candidate
end

-- Import text as a new custom profile. Always a copy: nothing already saved is
-- rewritten, and the imported profile is left unlocked so it can be edited.
-- Returns key, data or nil, reason.
function Profiles:Import(text)
    local data, err = self:Parse(text)
    if not data then return nil, err end

    local name = uniqueName(data.name)
    local key = uniqueKey(name)

    local profile = emptyProfile(name, data.class)
    profile.key = key
    profile.class = data.class
    profile.spec = data.spec
    profile.role = data.role
    profile.context = data.context
    profile.weights = data.weights
    profile.goals = data.goals
    profile.caps = data.caps
    profile.classOptions = (LT.ClassData and LT.ClassData:GetDefaultClassOptions(data.class)) or {}
    profile.source = LT.SOURCE_MANUAL
    profile.provisional = false
    profile.locked = nil         -- an imported profile is meant to be edited
    profile.origin = "imported" .. (date and (" " .. date("%Y-%m-%d %H:%M")) or "")

    self:GetCustomTable()[key] = profile

    self:Invalidate()
    LT:Fire(LT.EVENT_PROFILE, { reason = "imported", key = key })

    return key, data
end



-----------------------------------------------------------------------------
-- Export storage
--
-- A WoW addon cannot write a text file. Saved variables are the only file the
-- client produces, and they are written on logout / reload, so /lt export
-- copies each profile string into character.exports. The player then opens
--   WTF/Account/<account>/SavedVariables/LunchboxToolkitDB.lua
-- edits a string there by hand, and /lt import <n> reads it back after /reload.
-- Nothing else in the addon reads or writes this table.
-----------------------------------------------------------------------------

function Profiles:GetExports()
    local db = LT.Database and LT.Database.character
    if not db then return {} end

    db.exports = db.exports or {}
    return db.exports
end

-- Keeps every export, numbered, newest last, so an edited entry is never lost
-- by exporting again. Returns the index of the new entry.
function Profiles:StoreExport(text, name)
    local exports = self:GetExports()

    local entry = {
        name = tostring(name or "profile"),
        text = tostring(text or ""),
        at = time and time() or 0,
    }

    table.insert(exports, entry)
    return #exports, entry
end

function Profiles:GetExport(index)
    local exports = self:GetExports()
    return exports[tonumber(index) or 0]
end

function Profiles:GetLastExport()
    local exports = self:GetExports()
    return exports[#exports]
end

function Profiles:DescribeExports()
    local rows = {}

    for index, entry in ipairs(self:GetExports()) do
        local when = "unknown time"
        if entry.at and entry.at > 0 and date then
            when = date("%Y-%m-%d %H:%M", entry.at)
        end

        table.insert(rows, tostring(index) .. ". " .. tostring(entry.name)
            .. "  (" .. when .. ", " .. tostring(#tostring(entry.text or "")) .. " characters)")
    end

    return rows
end