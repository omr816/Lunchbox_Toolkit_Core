--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Caps
    Hit / spell hit / defense / expertise style targets, calculated at the
    scoring level (level + 1 for levels 1-59, capped at 60).

    Two things are kept apart on purpose:
      * the target itself, which is a percentage or a raw rating the player
        states (hit cap 9%, expertise soft cap 6.5%, and so on)
      * the rating that target costs, which depends on the level and can only
        be calculated where a conversion exists (see Levels.lua)

    Where the conversion is unknown the cap is still reported, with the rating
    equivalent marked as unavailable rather than guessed.

    Target-aware: below the endgame threshold a cap uses the same-level target
    set (the mobs a levelling character actually fights) and at or above it the
    endgame/boss set. Both sets and the threshold are profile data
    (`profile.caps[stat].sameLevelTarget`, `profile.capsMeta.endgameLevel`); the
    `capsEndgame` option forces the endgame set at any level. A profile that has
    never been edited falls back to the defaults below.

    Caps affect weights in exactly one place — ApplyPolicy — so an enabled cap
    can never be counted twice.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Caps = {}
LT.Caps = Caps
LT.Modules.Caps = Caps

-- kind:
--   "percent"  target is a percentage of the stat (hit 9%)
--   "rating"   target is a raw rating number the player measured themselves
--   "skill"    target is a defence-skill style number; needs skillConversion
--              (rating per skill point) before a rating equivalent exists
--
-- `target` is the endgame/boss target: the value every cap has always meant.
-- `sameLevelTarget` is the target used below the endgame threshold.
--
-- WORKING ASSUMPTION, not measured in the client: while levelling, a character
-- fights mobs at its own level, so the same-level set is the one that matters
-- until the endgame set applies. 5% hit and 5 expertise are starting points for
-- that set, not Forever-verified numbers; a profile overrides either one.
local defaults = {
    hit         = { enabled = true,  kind = "percent", target = 9.0,  importance = 2.0, sameLevelTarget = 5.0 },
    spellHit    = { enabled = true,  kind = "percent", target = 16.0, importance = 1.0, sameLevelTarget = 3.0 },
    expertise   = { enabled = true,  kind = "percent", target = 6.5,  importance = 1.5, sameLevelTarget = 5.0 },
    defense     = { enabled = false, kind = "skill",   target = 0,    importance = 3.0, skillConversion = nil },
    dodge       = { enabled = false, kind = "percent", target = 0,    importance = 1.0 },
    parry       = { enabled = false, kind = "percent", target = 0,    importance = 1.0 },
    block       = { enabled = false, kind = "percent", target = 0,    importance = 1.0 },
}

Caps.order = { "hit", "spellHit", "expertise", "defense", "dodge", "parry", "block" }
Caps.defaults = defaults

-- Over-cap is useless: once a cap's aim is reached the stat drops to this
-- factor of its weight rather than staying valued. Applied at/above the aim.
Caps.OVER_AIM_FACTOR = 0.01

-- "get close enough" aim: the % of the active target a cap aims for when the
-- capGetCloseEnough option is on. Off (the default) aims for the full cap.
Caps.CLOSE_ENOUGH_AIM = 80

-- Cap-boost intensity is MODE-dependent, not a flat per-cap constant. The
-- multiplier below replaces the old `importance` value in ApplyPolicy:
--   average  PvE levelling: normal weighting, do not chase the cap
--   strong   PvP / endgame: chase the cap hard until the aim is reached
--   moderate tank levelling defence: slightly higher, not massive
--   veryHigh dungeon-tank defence (uncrittable checkbox): chase very hard
Caps.modeBoost = {
    average  = 1.0,
    strong   = 3.0,
    moderate = 1.5,
    veryHigh = 4.0,
}

-- The three-way target choice. Stored on profile.capsMeta.targetSet; the UI
-- surface reads these keys. "tanking" engages the tank defence cap below.
Caps.targetSets = { "pve", "pvp", "tanking" }

-- Relevance filter: a cap is only shown / scored for a build that follows it.
-- Pure casters use spellHit, physical builds use hit + expertise, and only a
-- tank gets defense/dodge/parry/block. Hybrids resolve by spec, with a class
-- default for "Any" / nil.
local physicalClasses = { WARRIOR = true, ROGUE = true, HUNTER = true }
local casterClasses   = { MAGE = true, WARLOCK = true, PRIEST = true }
local hybridChannels  = {
    SHAMAN  = { default = "physical", Enhancement = "physical", Elemental = "caster", Restoration = "caster" },
    DRUID   = { default = "physical", Feral = "physical", Balance = "caster", Restoration = "caster" },
    PALADIN = { default = "physical", Retribution = "physical", Holy = "caster", Protection = "physical" },
}
Caps.relevance = {
    physicalClasses = physicalClasses,
    casterClasses   = casterClasses,
    hybridChannels  = hybridChannels,
}

-- Role-aware defence cap ("uncrittable"). Forever publishes no uncrittable
-- value, so the absolute defence-skill target below is DERIVED from the
-- Classic crit-immunity rule and marked PROVISIONAL: 5 defence skill per mob
-- level, plus 125 removes the mob's 5% crit chance. The mob level is the
-- player's level + 4 while levelling and + 3 at 60 (level-63 bosses), per the
-- player's ruling. Re-measure in the client before trusting the number.
Caps.defenseCap = {
    role             = "Tank",
    endgameLevel     = 60,   -- at/above this level the +3 branch applies
    levelingOffset   = 4,    -- levelling (below 60): uncrittable vs level+4 mobs
    endgameOffset    = 3,    -- at 60: uncrittable vs level+3 (level-63 bosses)
    skillPerMobLevel = 5,    -- provisional (Classic base defence skill per mob level)
    critImmunity     = 125,  -- provisional (removes the 5% mob crit chance)
    fullAimLevel     = 55,   -- at/above this level the tank aims for the full target
    levelingAim      = 90,   -- % of the uncrittable target to aim for while levelling
    fullAim          = 100,  -- % of the uncrittable target to aim for from 55 on
}

-- class + role + spec -> cap channel. See the relevance tables above.
function Caps:ResolveChannels(profile)
    local class = string.upper(tostring(profile and profile.class or ""))
    local role  = profile and profile.role or "Damage"
    local spec  = profile and profile.spec or "Any"

    local rel = self.relevance
    local channel
    if rel.physicalClasses[class] then
        channel = "physical"
    elseif rel.casterClasses[class] then
        channel = "caster"
    else
        local hybrid = rel.hybridChannels[class]
        channel = (hybrid and (hybrid[spec] or hybrid.default or "physical")) or "physical"
    end

    if role == "Healer" then channel = "caster" end
    if role == "Tank" then channel = "physical" end

    return { isPhysical = channel == "physical", isCaster = channel == "caster", isTank = role == "Tank" }
end

-- Is a cap relevant to this build at all? Irrelevant caps are hidden and never
-- scored (see GetEnabled / GetReport / ApplyPolicy).
function Caps:IsRelevant(stat, profile)
    local channels = self:ResolveChannels(profile)
    if stat == "defense" or stat == "dodge" or stat == "parry" or stat == "block" then
        return channels.isTank
    end
    if stat == "spellHit" then return channels.isCaster end
    if stat == "hit" or stat == "expertise" then return channels.isPhysical end
    return true
end

-- "aim for uncrittable (defence)" endgame override (capsUncrittable option).
function Caps:IsUncrittableForced()
    if not (LT.Database and LT.Database.GetOptions) then return false end
    local options = LT.Database:GetOptions()
    if type(options) ~= "table" then return false end
    return options.capsUncrittable == true
end

-- "get close enough" toggle (capGetCloseEnough option).
function Caps:IsCloseEnough()
    if not (LT.Database and LT.Database.GetOptions) then return false end
    local options = LT.Database:GetOptions()
    if type(options) ~= "table" then return false end
    return options.capGetCloseEnough == true
end

-- "keep boosting caps whose current value is unknown" (capBoostUnknown option).
-- Default false: an unmeasured cap is not chased blind.
function Caps:IsCapBoostUnknown()
    if not (LT.Database and LT.Database.GetOptions) then return false end
    local options = LT.Database:GetOptions()
    if type(options) ~= "table" then return false end
    return options.capBoostUnknown == true
end

-- The three-way target choice: "pve" / "pvp" / "tanking".
function Caps:GetTargetSet(profile)
    local meta = profile and profile.capsMeta
    if type(meta) == "table" and meta.targetSet then return meta.targetSet end
    if (profile and profile.role) == "Tank" then return "tanking" end
    if (profile and profile.context) == "PVP" then return "pvp" end
    return "pve"
end

-- Is the tank's uncrittable defence cap in force for this profile?
function Caps:IsDefenseCapEngaged(profile)
    if (profile and profile.role) ~= "Tank" then return false end
    if self:IsUncrittableForced() then return true end
    return self:GetTargetSet(profile) == "tanking"
end

-- Provisional uncrittable defence-skill target: (mob level x 5) + 125, where
-- the mob level is the character's level + 4 (levelling) or + 3 (at 60).
function Caps:GetDefenseTarget(profile, level)
    local realLevel = tonumber(self:GetTargetLevel(level)) or LT.MAX_LEVEL
    local cap = self.defenseCap
    local mobLevel = (realLevel >= cap.endgameLevel)
        and (realLevel + cap.endgameOffset)
        or  (realLevel + cap.levelingOffset)
    return mobLevel * cap.skillPerMobLevel + cap.critImmunity
end

-- Role-aware defence aim: 90% of the uncrittable target while levelling, the
-- full target from level 55 on. Returns nil for a non-tank.
function Caps:GetDefenseAim(profile)
    if (profile and profile.role) ~= "Tank" then return nil end
    local realLevel = tonumber(self:GetTargetLevel()) or 60
    local cap = self.defenseCap
    if realLevel >= cap.fullAimLevel then return cap.fullAim end
    return cap.levelingAim
end

-- The aim % for one cap: the defence cap uses the role-aware aim above; every
-- other cap aims for the full target, or CLOSE_ENOUGH_AIM when the
-- "get close enough" toggle is on.
function Caps:GetAimPercent(profile, stat)
    if stat == "defense" then
        return self:GetDefenseAim(profile) or 0
    end
    if self:IsCloseEnough() then return self.CLOSE_ENOUGH_AIM end
    return 100
end

-- Mode-dependent boost (replaces the flat `importance` per cap). `targetKind`
-- is the resolved hit-cap kind from GetDefinition, already decided at the real
-- level, so this never re-asks the level module.
function Caps:GetModeBoost(profile, stat, targetKind)
    if stat == "defense" then
        if (profile and profile.role) ~= "Tank" then return self.modeBoost.average, "levelling" end
        if self:IsUncrittableForced() then return self.modeBoost.veryHigh, "uncrittable chase" end
        return self.modeBoost.moderate, "tank levelling"
    end

    if targetKind == "pvp" then return self.modeBoost.strong, "PvP chase" end
    if targetKind == "endgame" then return self.modeBoost.strong, "endgame chase" end
    return self.modeBoost.average, "levelling"
end

-- One string describing every cap-policy input, so Profiles can cache the
-- right answer and re-compute when any of them changes.
function Caps:GetPolicySignature(profile)
    return table.concat({
        tostring(self:GetTargetSet(profile)),
        tostring(self:GetTargetKind(profile)),
        tostring(self:GetEndgameLevel(profile)),
        tostring(self:IsUncrittableForced()),
        tostring(self:IsCloseEnough()),
        tostring(self:IsCapBoostUnknown()),
    }, "@")
end

-- Profile-level cap configuration. A profile may override any of these fields
-- (`profile.capsMeta.endgameLevel`); the values here are only what a profile
-- that has never been edited falls back to. Moving a server's endgame
-- threshold is therefore a data edit, not a code edit.
Caps.capMetaDefaults = {
    -- Player's ruling 2026-10-27: boss targets come into force at 59, not at the
    -- cap itself, so the last level before 60 still reads as levelling.
    endgameLevel = 59,
}

-- Decision 5: runtime cap adjustments registered by plugins/racials.
-- Each entry: { stat, delta, source, reason }
-- Positive delta = cap reduced (plugin gives free rating toward the cap).
Caps.adjustments = {}

-- RegisterAdjustment(stat, delta, source, reason)
-- Overwrites any existing entry for the same stat+source combination, so
-- re-registering at PLAYER_LOGIN is safe.
function Caps:RegisterAdjustment(stat, delta, source, reason)
    if not defaults[stat] then
        LT:Warn("Caps:RegisterAdjustment — unknown stat \"" .. tostring(stat) .. "\".")
        return false
    end
    -- Remove any previous registration from the same source for this stat.
    for i = #self.adjustments, 1, -1 do
        local entry = self.adjustments[i]
        if entry.stat == stat and entry.source == source then
            table.remove(self.adjustments, i)
        end
    end
    table.insert(self.adjustments, {
        stat   = stat,
        delta  = tonumber(delta) or 0,
        source = tostring(source or "unknown"),
        reason = tostring(reason or ""),
    })
    if LT.Profiles then LT.Profiles:Invalidate() end
    return true
end

-- Returns the sum of all registered deltas for a stat (positive = cap reduced).
function Caps:GetTotalAdjustment(stat)
    local total = 0
    local sources = {}
    for _, entry in ipairs(self.adjustments) do
        if entry.stat == stat then
            total = total + entry.delta
            table.insert(sources, entry.source .. ": " .. entry.reason
                .. " (" .. LT:FormatNumber(entry.delta, 2) .. ")")
        end
    end
    return total, sources
end

local capNotes = {
    hit = "Hit cap targets and the rating they cost come from the profile; the "
        .. "9% default is a common target, not a Forever-verified number.",
    spellHit = "Spell hit target in percent. Forever's spell hit rating "
        .. "conversion has to be measured before a rating equivalent can be shown.",
    expertise = "Expertise target as a dodge/parry reduction percentage.",
    defense = "For a tank this is the uncrittable defence cap. The target is "
        .. "provisional: Forever publishes no uncrittable value, so it is derived "
        .. "from the Classic rule (mobs level+4, level+3 at 60). It needs the "
        .. "rating-per-skill conversion before a rating equivalent can be shown.",
    dodge = "Dodge target as a percentage of total dodge.",
    parry = "Parry target as a percentage of total parry.",
    block = "Block target as a percentage of total block.",
}

function Caps:GetNote(stat)
    return capNotes[stat] or ""
end

------------------------------------------------------------------------------
-- Target sets
--
-- One question, answered here:
--   capsEndgame option on            -> endgame
--   level >= the profile's threshold -> endgame
--   below it                         -> sameLevel
--
-- The threshold is profile data (`profile.capsMeta.endgameLevel`). When it
-- cannot be read the policy keeps the endgame set: an unanswered question must
-- not silently change a score.
------------------------------------------------------------------------------

-- The level a target-set decision is made at: the character's real level, not
-- the scoring level (+1), so a level-59 character is still treated as levelling.
function Caps:GetTargetLevel(level)
    local explicit = tonumber(level)
    if explicit then return explicit end

    if LT.Levels and LT.Levels.GetTargetLevel then
        local fromLevels = LT.Levels:GetTargetLevel()
        if fromLevels then return fromLevels end
    end

    if LT.Levels and LT.Levels.GetScoringLevel then
        return LT.Levels:GetScoringLevel()
    end

    return nil
end

-- The endgame threshold in force for a profile.
function Caps:GetEndgameLevel(profile)
    local meta = profile and profile.capsMeta
    local configured = type(meta) == "table" and tonumber(meta.endgameLevel) or nil
    if configured and configured >= 1 then
        return configured
    end

    local fallback = tonumber(self.capMetaDefaults and self.capMetaDefaults.endgameLevel)
    if fallback and fallback >= 1 then
        return fallback
    end

    return tonumber(LT.MAX_LEVEL)
end

-- The capsEndgame option (Database options, additive default false). Read
-- through GetOptions so a character record saved before the option existed
-- keeps the off default.
function Caps:IsEndgameForced()
    if not (LT.Database and LT.Database.GetOptions) then return false end

    local options = LT.Database:GetOptions()
    if type(options) ~= "table" then return false end
    return options.capsEndgame == true
end

function Caps:GetTargetKind(profile, level)
    local set = self:GetTargetSet(profile)
    if set == "pvp" then return "pvp" end
    -- "tanking" falls through: hit/expertise still follow the level-aware pve
    -- logic; the defence cap is engaged separately (IsDefenseCapEngaged).

    if self:IsEndgameForced() then return "endgame" end

    if not (LT.Levels and LT.Levels.IsEndgame) then
        -- Cannot ask the level module: keep today's set rather than guess.
        return "endgame"
    end

    local endgame = LT.Levels.IsEndgame(self:GetTargetLevel(level), self:GetEndgameLevel(profile))
    if endgame == nil then return "endgame" end
    return endgame and "endgame" or "sameLevel"
end

-- level is the level whose target set is wanted; it defaults to the character's
-- real level (see GetTargetLevel). `target` keeps its old meaning — the stored
-- endgame/boss target, so the profile editor still edits what it always did —
-- and `activeTarget` is the one this level's policy uses.
function Caps:GetDefinition(profile, stat, level)
    local fromProfile = profile and profile.caps and profile.caps[stat]
    local base = defaults[stat] or {}

    local definition = {}
    for key, value in pairs(base) do
        definition[key] = value
    end

    for key, value in pairs(fromProfile or {}) do
        definition[key] = value
    end

    definition.stat = stat
    definition.label = LT:Label(stat)
    definition.provisional = true          -- every cap default is a starting point
    definition.note = self:GetNote(stat)
    definition.relevant = self:IsRelevant(stat, profile)

    -- Role-aware defence cap ("uncrittable"): Tank only. A tank aiming for the
    -- tanking set (or the uncrittable override) gets a derived, provisional
    -- defence-skill target; every other role keeps the defence cap off.
    if stat == "defense" then
        if (profile and profile.role) ~= "Tank" then
            definition.enabled = false
        elseif self:IsDefenseCapEngaged(profile) then
            definition.enabled = true
            definition.roleAwareDefense = true
            -- A player-measured defence target wins; otherwise use the derived,
            -- provisional uncrittable value (level+4 / level+3).
            local storedTarget = tonumber(definition.target)
            if not storedTarget or storedTarget <= 0 then
                definition.target = self:GetDefenseTarget(profile, level)
                definition.defenseTargetDerived = true
            end
            definition.defenseAim = self:GetDefenseAim(profile)
            definition.provisional = true
        end
    end

    local targetKind = self:GetTargetKind(profile, level)
    local endgameTarget = tonumber(definition.target) or 0
    local sameLevelTarget = tonumber(definition.sameLevelTarget) or 0

    definition.targetKind = targetKind
    definition.endgameLevel = self:GetEndgameLevel(profile)
    definition.targetLevel = self:GetTargetLevel(level)
    definition.endgameTarget = endgameTarget
    definition.sameLevelTarget = sameLevelTarget

    if stat == "defense" and definition.roleAwareDefense then
        definition.activeTarget = endgameTarget
    elseif targetKind == "sameLevel" or targetKind == "pvp" then
        definition.activeTarget = sameLevelTarget
    else
        definition.activeTarget = endgameTarget
    end

    definition.boost, definition.mode = self:GetModeBoost(profile, stat, targetKind)

    -- Decision 5: apply registered adjustments. adjustedTarget = activeTarget -
    -- totalDelta (positive delta = plugin gives free rating, so the cap is lower).
    local totalDelta, adjustmentSources = self:GetTotalAdjustment(stat)
    if totalDelta ~= 0 then
        definition.adjustedTarget = definition.activeTarget - totalDelta
        definition.adjustmentSources = adjustmentSources
    else
        definition.adjustedTarget = definition.activeTarget
        definition.adjustmentSources = {}
    end

    return definition
end

function Caps:GetEnabled(profile)
    local rows = {}

    for _, stat in ipairs(self.order) do
        local definition = self:GetDefinition(profile, stat)
        if definition.enabled and definition.relevant then
            table.insert(rows, definition)
        end
    end

    return rows
end

------------------------------------------------------------------------------
-- Current state
------------------------------------------------------------------------------

-- What the client says right now, at the character's real level.
function Caps:GetCurrent(stat)
    if not LT.Levels then return nil end

    local rating = LT.Levels:GetLiveRating(stat)
    local percent = LT.Levels:GetLivePercent(stat)

    if not rating and not percent then return nil end

    return {
        rating = rating,
        percent = percent,
        level = LT.Levels:GetCurrentLevel(),
    }
end

-- Fully described state of one cap for one profile at the scoring level.
-- `level` selects the conversion level (the scoring level by default); the
-- target set follows the character's real level, decided in GetDefinition.
function Caps:GetStatus(profile, stat, level)
    local definition = self:GetDefinition(profile, stat)
    if not definition.enabled then
        return {
            enabled = false,
            stat = stat,
            definition = definition,
            targetKind = definition.targetKind,
            relevant = definition.relevant,
        }
    end

    level = level or (LT.Levels and LT.Levels:GetScoringLevel()) or 1

    local current = self:GetCurrent(stat)
    local currentRating = current and current.rating or nil
    local currentPercent = current and current.percent or nil

    -- Decision 5: use adjustedTarget if adjustments have been registered.
    -- adjustedTarget is built from activeTarget, so it follows the target set.
    local effectiveTarget = tonumber(definition.adjustedTarget or definition.activeTarget
        or definition.target) or 0

    local status = {
        enabled = true,
        stat = stat,
        label = definition.label,
        kind = definition.kind,
        target = effectiveTarget,
        targetKind = definition.targetKind,
        targetLevel = definition.targetLevel,
        endgameTarget = definition.endgameTarget,
        sameLevelTarget = definition.sameLevelTarget,
        endgameLevel = definition.endgameLevel,
        importance = tonumber(definition.importance) or 0,
        level = level,
        current = current,
        currentRating = currentRating,
        currentPercent = currentPercent,
        provisional = true,
        definition = definition,
        adjustmentSources = definition.adjustmentSources or {},
        relevant = definition.relevant,
        aimPercent = self:GetAimPercent(profile, stat),
        -- The multiplier is MODE-dependent (see GetModeBoost). Reading
        -- definition.boost left it nil on every cap, and ApplyPolicy multiplies a
        -- nil by 1, so caps never boosted at all until the self test caught it.
        boost = nil,
        mode = nil,
        limitations = {},
    }

    status.boost, status.mode = self:GetModeBoost(profile, stat, status.targetKind)

    if status.target <= 0 then
        status.known = false
        table.insert(status.limitations,
            "No target is set for " .. status.label .. ". Set one in the profile first.")
        return status
    end

    if definition.kind == "percent" then
        status.targetPercent = status.target

        local ratingTarget, meta = LT.Levels and LT.Levels:RatingForPercent(stat, status.target, level)
        if ratingTarget then
            status.targetRating = ratingTarget
            status.ratingSource = meta and meta.source or nil
        else
            status.ratingUnavailable = meta and meta.reason
                or ("No conversion recorded for " .. status.label .. " at level " .. tostring(level) .. ".")
        end

        if currentPercent then
            status.percentAtScoringLevel = currentRating
                and (LT.Levels and LT.Levels:PercentForRating(stat, currentRating, level))
                or nil

            -- Without a conversion for this level there is no honest way to say
            -- how much of the cap is left, so say that instead of assuming none.
            if status.percentAtScoringLevel then
                status.remainingPercent = math.max(status.target - status.percentAtScoringLevel, 0)
            else
                table.insert(status.limitations,
                    "Current " .. status.label .. " can be read, but no rating conversion is "
                    .. "recorded for level " .. tostring(level)
                    .. ", so how much is still needed cannot be calculated.")
            end
        else
            table.insert(status.limitations,
                "The client is not reporting current " .. status.label
                .. ", so how much is still needed cannot be calculated.")
        end
    elseif definition.kind == "rating" then
        status.targetRating = status.target
        if currentRating then
            status.remainingRating = math.max(status.target - currentRating, 0)
        else
            table.insert(status.limitations,
                "The client is not reporting current " .. status.label .. " rating.")
        end
    elseif definition.kind == "skill" then
        status.targetSkill = status.target
        local conversion = tonumber(definition.skillConversion)
        if conversion and conversion > 0 then
            status.targetRating = status.target * conversion
            status.ratingSource = LT.SOURCE_MANUAL
        else
            status.ratingUnavailable = "Defence-style targets need the rating-per-point "
                .. "conversion before a rating equivalent can be calculated. Set it on "
                .. "the profile, or switch the cap to a rating or percentage target."
        end

        if currentRating then
            status.remainingRating = status.targetRating
                and math.max(status.targetRating - currentRating, 0)
                or nil
        end
    end

    if status.targetRating and currentRating then
        status.remainingRating = status.remainingRating
            or math.max(status.targetRating - currentRating, 0)
        status.capped = status.remainingRating <= 0
        status.known = true
    elseif status.remainingPercent then
        status.capped = status.remainingPercent <= 0
        status.known = true
    else
        status.known = false
        status.capped = false
    end

    -- A cap with neither a rating conversion for its target nor a current
    -- reading is simply not measured yet. Collapse it to one state instead of
    -- letting the UI draw a failing 0/N row; the UI reads `measured`.
    if status.known then
        status.measured = true
    elseif not status.targetRating and not currentRating and not currentPercent then
        status.measured = false
        status.measuredLabel = "not measured yet"
    end

    -- Aim threshold: "met" under the policy means current >= aim% of the active
    -- target, not current >= the full target. Over-aim is then near-zero.
    local aim = tonumber(status.aimPercent)
    if status.known and aim and aim > 0 then
        local aimFactor = aim / 100
        if status.percentAtScoringLevel then
            status.aimTargetPercent = (status.targetPercent or status.target or 0) * aimFactor
            status.reachedAim = status.percentAtScoringLevel >= status.aimTargetPercent
        elseif status.targetRating and status.currentRating then
            status.aimTargetRating = status.targetRating * aimFactor
            status.reachedAim = status.currentRating >= status.aimTargetRating
        else
            status.reachedAim = false
        end
    else
        status.reachedAim = false
    end

    return status
end

function Caps:GetAllStatus(profile, level)
    local rows = {}
    for _, stat in ipairs(self.order) do
        table.insert(rows, self:GetStatus(profile, stat, level))
    end
    return rows
end

------------------------------------------------------------------------------
-- Policy
--
-- One documented rule, applied once, to each RELEVANT cap (see IsRelevant):
--
--   current below aim% of the active target
--       ->  weight x mode boost
--   current unknown
--       ->  weight unchanged, unless capBoostUnknown is on (then the boost
--           above applies rather than being chased blind)
--   current at/above aim% of the active target
--       ->  weight x OVER_AIM_FACTOR   (over-cap is useless)
--
-- The boost is MODE-dependent (see Caps.modeBoost / GetModeBoost), not a flat
-- per-cap constant: average while PvE levelling, strong for PvP / endgame,
-- moderate for tank levelling defence and very high for the dungeon-tank
-- uncrittable chase. The aim is 100% of the cap by default, CLOSE_ENOUGH_AIM
-- when the "get close enough" toggle is on, and the role-aware 90%/100% for a
-- tank's uncrittable defence cap.
------------------------------------------------------------------------------

function Caps:ApplyPolicy(weights, profile, level)
    local trace = {}
    local limitations = {}
    local statuses = {}
    local boostUnknown = self:IsCapBoostUnknown()

    for _, stat in ipairs(self.order) do
        local status = self:GetStatus(profile, stat, level)
        table.insert(statuses, status)

        if status.enabled and status.relevant and weights[stat] then
            local before = weights[stat]
            local boost = tonumber(status.boost) or 1
            local mode = tostring(status.mode or "levelling")
            local aim = tonumber(status.aimPercent) or 100

            if status.known and status.reachedAim then
                weights[stat] = before * self.OVER_AIM_FACTOR

                table.insert(trace, {
                    stage = "cap",
                    stat = stat,
                    from = before,
                    value = weights[stat],
                    note = "cap reached (" .. LT:FormatNumber(aim, 0) .. "% aim) — "
                        .. "over-cap is useless, value x"
                        .. LT:FormatNumber(self.OVER_AIM_FACTOR, 2),
                })
            else
                -- An unknown current value is not a reason to chase a cap
                -- blind: unless capBoostUnknown is on, the weight is left as it
                -- is. A known value keeps the old boost behaviour.
                local unknown = not status.known
                local ignored = unknown and not boostUnknown
                local applied = ignored and 1 or boost

                weights[stat] = before * applied

                local note = "cap " .. (status.known and "unmet"
                    or (ignored and "not measured" or "state unknown"))
                if ignored then
                    note = note .. " — weight unchanged (capBoostUnknown is off)"
                else
                    note = note .. " — " .. mode .. ", aim " .. LT:FormatNumber(aim, 0)
                        .. "%, boost x" .. LT:FormatNumber(applied, 2)
                end

                if status.known and status.targetRating then
                    note = note .. ", target " .. LT:FormatNumber(status.targetRating, 1)
                        .. " rating at level " .. tostring(level)
                elseif status.targetPercent then
                    note = note .. ", target " .. LT:FormatNumber(status.targetPercent, 2) .. "%"
                end

                if status.targetKind == "sameLevel" then
                    note = note .. " (same-level)"
                elseif status.targetKind == "pvp" then
                    note = note .. " (PvP)"
                end

                if ignored then
                    if status.measured == false then
                        table.insert(limitations, status.label .. " cap: "
                            .. tostring(status.measuredLabel or "not measured yet")
                            .. " — no rating conversion and no current value, so it is not scored.")
                    else
                        table.insert(limitations, status.label
                            .. " cap: current value unknown, so the mode boost is ignored.")
                    end
                elseif unknown then
                    table.insert(limitations, status.label
                        .. " cap: current value unknown, but capBoostUnknown is on, so the full mode boost is applied.")
                end
                if not status.targetRating and status.kind == "percent"
                    and status.measured ~= false then
                    table.insert(limitations, status.label
                        .. ": rating equivalent unavailable — " .. tostring(status.ratingUnavailable or ""))
                end

                table.insert(trace, {
                    stage = "cap",
                    stat = stat,
                    from = before,
                    value = weights[stat],
                    note = note,
                })
            end
        end
    end

    local targetKind = self:GetTargetKind(profile)
    if targetKind == "sameLevel" then
        table.insert(limitations, "Boss cap targets are not used while levelling; "
            .. "same-level targets apply until level "
            .. tostring(self:GetEndgameLevel(profile)) .. ".")
    end

    return {
        weights = weights,
        trace = trace,
        limitations = limitations,
        statuses = statuses,
        level = level,
        targetKind = targetKind,
    }
end

------------------------------------------------------------------------------
-- Reporting
------------------------------------------------------------------------------

function Caps:GetReport(profile, level)
    local rows = {}

    for _, status in ipairs(self:GetAllStatus(profile, level)) do
        -- Irrelevant caps are hidden, not dimmed: they do not appear at all.
        if status.relevant then
            -- Disabled caps come back from GetStatus with only `definition`, so
            -- fall back to it for fields the UI concatenates.
            local definition = status.definition or {}
            table.insert(rows, {
                stat = status.stat,
                label = status.label or definition.label or LT:Label(status.stat),
                enabled = status.enabled,
                kind = status.kind or definition.kind,
                target = status.target or definition.adjustedTarget or definition.activeTarget
                    or definition.target,
                targetKind = status.targetKind or definition.targetKind,
                endgameTarget = status.endgameTarget or definition.endgameTarget,
                sameLevelTarget = status.sameLevelTarget or definition.sameLevelTarget,
                endgameLevel = status.endgameLevel or definition.endgameLevel,
                targetRating = status.targetRating,
                currentRating = status.currentRating,
                currentPercent = status.currentPercent,
                remainingRating = status.remainingRating,
                remainingPercent = status.remainingPercent,
                capped = status.capped,
                known = status.known,
                measured = status.measured,
                measuredLabel = status.measuredLabel,
                provisional = status.provisional,
                relevant = status.relevant,
                aimPercent = status.aimPercent,
                reachedAim = status.reachedAim,
                aimTargetPercent = status.aimTargetPercent,
                aimTargetRating = status.aimTargetRating,
                boost = status.boost,
                mode = status.mode,
                roleAwareDefense = definition.roleAwareDefense,
                defenseTargetDerived = definition.defenseTargetDerived,
                limitations = status.limitations,
                ratingUnavailable = status.ratingUnavailable,
                -- Decision 5: expose adjustment sources in the report
                adjustmentSources = status.adjustmentSources or {},
            })
        end
    end

    return rows
end