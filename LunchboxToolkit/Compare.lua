--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Compare
    Configuration-aware equipment comparison.

    A two-handed weapon is not a straight swap for the main hand of a
    one-handed-plus-shield setup: it replaces both hands at once. For a build
    configured around one-handed weapons the addon scores it as a whole-set
    package against the main hand and off hand added together, and labels the
    result so it is never read as a slot delta. A tank build still refuses it,
    because a tank needs a shield. Where the addon cannot evaluate a swap, it
    says so instead of producing a number that looks like an answer.

    Comparison statuses:
      upgrade       candidate scores higher than the saved item
      downgrade     candidate scores lower
      equal         same score within rounding
      incomparable  the comparison needs a model the addon does not have yet
      incomplete    the saved equipment set is missing the data needed
      ineligible    the character cannot use the item, or it does not fit the
                    build's weapon configuration (a shield tank with a
                    two-handed weapon, an off-hand item in a two-handed build,
                    a melee weapon in a ranged build)
      unscorable    the item could not be read, or has no weighted stats
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Compare = {}
LT.Compare = Compare
LT.Modules.Compare = Compare

local weaponLocations = {
    INVTYPE_WEAPON = true,
    INVTYPE_2HWEAPON = true,
    INVTYPE_WEAPONMAINHAND = true,
    INVTYPE_WEAPONOFFHAND = true,
    INVTYPE_RANGED = true,
    INVTYPE_RANGEDRIGHT = true,
    INVTYPE_THROWN = true,
}

Compare.weaponLocations = weaponLocations

-- The name a tooltip or header shows for a build slot. The player's own word:
-- show the resolved profile name ("Lunchbox Tank", "Lunchbox 2h WF PVP"), not
-- the stored slot label ("Build 1"). A slot without a profile falls back to its
-- own name, then to "Build N". Pure enough to run outside the client.
local function buildDisplayName(build, buildIndex)
    if type(LT.Profiles) == "table" and type(LT.Profiles.ResolveSlot) == "function" then
        local ok, resolved = pcall(LT.Profiles.ResolveSlot, LT.Profiles, buildIndex)
        if ok and type(resolved) == "table" and type(resolved.name) == "string"
            and resolved.name ~= "" then
            return resolved.name
        end
    end

    if type(build) == "table" and type(build.name) == "string" and build.name ~= "" then
        return build.name
    end

    return "Build " .. tostring(buildIndex)
end

-- A candidate that does not suit the build's weapon setup is still scored, but
-- at half value: a two-hander on a shield tank, or a shield on a two-hander
-- build, ranks below an item that suits. The penalty changes the score, it is
-- not a refusal, and the reason rides with the candidate so the tooltip can say
-- why. A copy is returned so the cached score is never corrupted.
local PENALTY_FACTOR = 0.5

local function penalizeCandidate(candidate, reason)
    local copy = LT:Copy(candidate)
    copy.score = (copy.score or 0) * PENALTY_FACTOR
    copy.penalized = true
    copy.limitations = copy.limitations or {}
    table.insert(copy.limitations,
        "Does not suit this build's weapon setup (score halved): " .. tostring(reason))
    return copy
end

------------------------------------------------------------------------------
-- Cache
--
-- One hover asks for the same comparison more than once: the post-call hook and
-- the tooltip's own handler both draw the panel, and the Shift detail asks for
-- the candidate again. Scoring an item is the expensive part of that (stats,
-- tooltip lines, effective weights), so every result is kept under what it was
-- calculated from: which reference it was measured against, the item link, the
-- build slot, the profile rule set that produced the weights, the level they
-- were applied at, and this module's own revision.
--
-- Nothing here holds a reference to the character, a secret value or a frame,
-- and the table is bounded: a session must not grow a table with every item the
-- pointer ever crossed.
------------------------------------------------------------------------------

Compare.CACHE_LIMIT = 400

Compare.cache = {}
Compare.revision = 0

-- Insertion order of the keys in Compare.cache, oldest first. Eviction takes
-- from the front, so the table never holds more than CACHE_LIMIT entries.
local cacheOrder = {}

local function cacheStore(key, value)
    if Compare.cache[key] == nil then
        table.insert(cacheOrder, key)
    end

    Compare.cache[key] = value

    while #cacheOrder > Compare.CACHE_LIMIT do
        local oldest = table.remove(cacheOrder, 1)
        Compare.cache[oldest] = nil
    end
end

-- The level scores are calculated at, read the same way Profiles reads it. A
-- missing or failing Levels module only costs a coarser key: the revision still
-- changes whenever anything that feeds the weights does.
local function scoringLevel()
    local levels = LT.Levels

    if type(levels) == "table" and type(levels.GetScoringLevel) == "function" then
        local ok, level = pcall(levels.GetScoringLevel, levels)
        if ok and tonumber(level) then return tonumber(level) end
    end

    return 0
end

-- A secret link is never turned into a key: that would be arithmetic on a
-- restricted value. `cached` skips the cache entirely for one.
local function cacheKey(kind, itemLink, buildIndex)
    local profiles = LT.Profiles

    return tostring(kind) .. "|" .. tostring(itemLink) .. "|" .. tostring(buildIndex)
        .. "|" .. tostring(profiles and profiles.revision or 0)
        .. "|" .. tostring(scoringLevel())
        .. "|" .. tostring(Compare.revision)
end

-- The one way into the cache. `compute` runs at most once per key while the
-- entry is held, and returns value plus whether it is worth keeping: an answer
-- the client could not give yet (the item is not cached on the first request,
-- or no build exists) is retried on the next hover instead of frozen in place.
local function cached(kind, itemLink, buildIndex, compute)
    if not itemLink or LT:IsSecret(itemLink) then
        return (compute())
    end

    local key = cacheKey(kind, itemLink, buildIndex)
    local hit = Compare.cache[key]

    if hit ~= nil then return hit end

    local value, keep = compute()
    if value ~= nil and keep ~= false then
        cacheStore(key, value)
    end

    return value
end

-- The one entry point for "everything scored earlier is now wrong". The
-- revision is part of every key, so an entry that eviction has not reached yet
-- can never be handed out after this.
function Compare:Invalidate()
    self.revision = (tonumber(self.revision) or 0) + 1
    self.cache = {}
    cacheOrder = {}
end

-- Every score in a comparison goes through here, so the candidate and the item
-- it replaces are always measured with the same rules — including the Shaman
-- weapon-imbue layer, which only changes weapon channels when it is enabled.
-- Kept per item and build: the tooltip's score line and its Shift detail score
-- the same candidate, and the worn items are rescored against both.
local function scoreItem(itemLink, buildIndex)
    return cached("score", itemLink, buildIndex, function()
        local scored

        if LT.Score.ScoreItemWithImbue then
            scored = LT.Score:ScoreItemWithImbue(itemLink, buildIndex)
        else
            scored = LT.Score:ScoreItem(itemLink, buildIndex)
        end

        -- No identity means the client did not answer for this link yet.
        return scored, type(scored) == "table" and scored.identity ~= nil
    end)
end

local function result(status, reason, extra)
    local output = {
        status = status,
        reason = reason,
        notes = {},
        limitations = {},
    }

    for key, value in pairs(extra or {}) do
        output[key] = value
    end

    return output
end

-- The comparison a whole-set candidate produces: one score for the candidate,
-- one for both hands of the reference added together. The row and the result
-- carry `wholeSet`, so a panel can say "replaces both hands" instead of
-- presenting the figure as a single-slot delta. Pure apart from the slot
-- labels: the caller supplies both scores and what was summed.
local function wholeSetResult(itemLink, buildIndex, build, identity, candidate,
    referenceScore, referenceLabel, versus)
    local difference = candidate.score - referenceScore
    local percent = (referenceScore ~= 0)
        and (difference / math.abs(referenceScore) * 100)
        or nil
    local status = difference > 0 and "upgrade"
        or (difference < 0 and "downgrade" or "equal")

    local row = {
        slot = 16,
        slotLabel = referenceLabel,
        referenceScore = referenceScore,
        candidateScore = candidate.score,
        difference = difference,
        percent = percent,
        status = status,
        wholeSet = true,
        reason = "replaces both hands",
    }

    local comparison = result(status, "replaces both hands", {
        itemLink = itemLink,
        buildIndex = buildIndex,
        buildName = buildDisplayName(build, buildIndex),
        itemName = identity.name,
        candidate = candidate,
        rows = { row },
        headline = row,
        difference = difference,
        percent = percent,
        referenceScore = referenceScore,
        candidateScore = candidate.score,
        referenceSlot = 16,
        referenceSlotLabel = referenceLabel,
        weaponSetup = build.weaponSetup,
        scoringLevel = candidate.scoringLevel,
        scaleName = candidate.scaleName,
        wholeSet = true,
        vs = versus,
    })

    table.insert(comparison.limitations,
        "The difference is a change in weighted item score, not a prediction of "
        .. "damage, healing or survivability.")

    if identity.canUse == nil then
        table.insert(comparison.limitations,
            "This client did not report whether the character can use the item, so "
            .. "eligibility could not be checked.")
    end

    for _, limitation in ipairs(candidate.limitations or {}) do
        table.insert(comparison.limitations, limitation)
    end

    return comparison
end

------------------------------------------------------------------------------
-- Which slots a candidate would replace in a given build
------------------------------------------------------------------------------

-- The classes whose tanks tank behind a shield. The Druid is the one modelled
-- class that tanks with a two-handed weapon and cannot use a shield at all, so
-- it is deliberately absent here: the shield rule must not be applied to it.
local shieldTankClasses = {
    WARRIOR = true,
    PALADIN = true,
    SHAMAN = true,
}

-- Is this build a shield tank? Pure: reads only build.role and build.class, so
-- it can be run outside the client. Only the listed classes are treated as
-- shield tanks; an unreadable class keeps the shield requirement rather than
-- being exempted.
function Compare.IsShieldTank(build)
    if type(build) ~= "table" or build.role ~= "Tank" then return false end

    local class = string.upper(tostring(build.class or ""))
    if shieldTankClasses[class] then return true end

    return class == "" or class == "UNKNOWN"
end

-- Is the candidate a two-handed weapon replacing a configuration that fills
-- the hands separately (1H, 1H+shield or dual wield)? Such a candidate is not
-- a slot swap: the comparison functions score it against both hands added
-- together. Pure: reads only build.weaponSetup and identity.equipLoc.
function Compare.IsWholeSetSwap(build, identity)
    if type(build) ~= "table" or type(identity) ~= "table" then return false end
    if identity.equipLoc ~= "INVTYPE_2HWEAPON" then return false end

    local setup = build.weaponSetup
    return setup == "1H" or setup == "1H_SHIELD" or setup == "DUAL_WIELD"
end

-- Does a candidate fit the build's whole weapon configuration?
--
-- Pure: reads only build.weaponSetup, build.role/class and identity.equipLoc,
-- so it can be run outside the client. Returns true, or false plus the
-- requirement the candidate cannot satisfy.
--
-- A two-handed weapon in a build that fills the hands separately is a
-- whole-set swap: it fits every role except a shield tank, because a tank
-- cannot tank without a shield. The comparison functions then score it against
-- both hands added together (IsWholeSetSwap) rather than as one slot. The
-- reverse direction — an off-hand item against a two-handed build — is still
-- refused; that package comparison is T-46.
--
-- Same-configuration swaps are unaffected: 1H to 1H, shield to shield, a
-- two-handed weapon to a two-handed weapon, and off-hand to off-hand in a dual
-- wield build. Armour and other slots never depend on the weapon setup.
function Compare:SetupFits(build, identity)
    local setup = build and build.weaponSetup
    local equipLoc = identity and identity.equipLoc

    -- Nothing to judge against: the slot mapping reports the unreadable item.
    if not setup or not equipLoc then return true end

    local isTwoHanded = equipLoc == "INVTYPE_2HWEAPON"
    local isOneHanded = equipLoc == "INVTYPE_WEAPON"
        or equipLoc == "INVTYPE_WEAPONMAINHAND"
        or equipLoc == "INVTYPE_WEAPONOFFHAND"
    local isMainHandWeapon = equipLoc == "INVTYPE_WEAPON"
        or equipLoc == "INVTYPE_WEAPONMAINHAND"
    local isOffHandWeapon = equipLoc == "INVTYPE_WEAPONOFFHAND"
    local isShield = equipLoc == "INVTYPE_SHIELD"
    local isHeldItem = equipLoc == "INVTYPE_HOLDABLE"
    local isRanged = equipLoc == "INVTYPE_RANGED"
        or equipLoc == "INVTYPE_RANGEDRIGHT"
        or equipLoc == "INVTYPE_THROWN"
    local isMelee = isOneHanded or isTwoHanded

    if setup == "1H_SHIELD" then
        if isTwoHanded then
            if Compare.IsShieldTank(build) then
                return false, "A tank build needs a shield, so a two-handed weapon does "
                    .. "not fit its weapon configuration."
            end
            return true
        end
        if isOffHandWeapon then
            return false, "This build needs a shield in the off hand, so an off-hand "
                .. "weapon does not fit."
        end
        if isHeldItem then
            return false, "This build needs a shield in the off hand, so a held item "
                .. "does not fit."
        end
        if isRanged then
            return false, "This build uses a one-handed weapon and a shield, so a ranged "
                .. "weapon does not fit."
        end
        return true
    end

    if setup == "2H" then
        if isTwoHanded or isMainHandWeapon then
            return true
        end
        if isShield or isHeldItem or isOffHandWeapon then
            return false, "This build uses a two-handed weapon, so a shield or an "
                .. "off-hand item does not fit its configuration."
        end
        return true
    end

    if setup == "DUAL_WIELD" then
        if isTwoHanded then
            if Compare.IsShieldTank(build) then
                return false, "A tank build needs a shield, so a two-handed weapon does "
                    .. "not fit its weapon configuration."
            end
            return true
        end
        if isShield then
            return false, "This build is a dual-wield build, which leaves no shield slot."
        end
        if isHeldItem then
            return false, "This build is a dual-wield build, so both hands are weapons "
                .. "and a held item does not fit."
        end
        return true
    end

    if setup == "1H" then
        if isTwoHanded then
            if Compare.IsShieldTank(build) then
                return false, "A tank build needs a shield, so a two-handed weapon does "
                    .. "not fit its weapon configuration."
            end
            return true
        end
        if isShield then
            return false, "This build is a one-handed build, which leaves no shield slot."
        end
        if isOffHandWeapon then
            return false, "This build is a one-handed build, so an off-hand weapon does "
                .. "not fit."
        end
        return true
    end

    if setup == "RANGED" then
        if isMelee then
            return false, "This build is a ranged build, so a melee weapon does not fit."
        end
        if isShield then
            return false, "This build is a ranged build, which leaves no shield slot."
        end
        if isHeldItem then
            return false, "This build is a ranged build, so a held item does not fit."
        end
        return true
    end

    -- Unknown configuration: GetTargetSlots names it rather than guessing.
    return true
end

-- Returns: slots table, reason (when the configuration cannot be evaluated).
--
-- This maps a same-configuration swap. A two-handed weapon against a 1H,
-- 1H+shield or dual-wield build is a whole-set package: the comparison
-- functions detect it first (IsWholeSetSwap) and never ask for a slot, because
-- the answer is both hands added together rather than one slot's delta.
function Compare:GetTargetSlots(buildIndex, identity)
    local build = LT.Builds and LT.Builds:Get(buildIndex)
    if not build then
        return nil, "That build slot does not exist."
    end

    local equipLoc = identity.equipLoc

    -- Weapons and shields are judged against the build's whole weapon
    -- configuration, not just the slot the item type maps to.
    if weaponLocations[equipLoc] or equipLoc == "INVTYPE_SHIELD" or equipLoc == "INVTYPE_HOLDABLE" then
        local isTwoHanded = equipLoc == "INVTYPE_2HWEAPON"
        local isOffHandWeapon = equipLoc == "INVTYPE_WEAPONOFFHAND"
        local isShield = equipLoc == "INVTYPE_SHIELD"
        local isHeldItem = equipLoc == "INVTYPE_HOLDABLE"
        local isRanged = equipLoc == "INVTYPE_RANGED"
            or equipLoc == "INVTYPE_RANGEDRIGHT"
            or equipLoc == "INVTYPE_THROWN"

        -- Ranged weapons always live in the ranged slot.
        if isRanged then return { 18 }, nil end

        -- A two-handed weapon replaces the main hand. Against a build that
        -- fills the hands separately it is a whole-set package, detected by
        -- IsWholeSetSwap before this is asked.
        if isTwoHanded then return { 16 }, nil end

        -- An off-hand item (off-hand weapon, shield, held item) replaces the
        -- off hand. It may be penalised elsewhere for not suiting the build,
        -- but it always has a slot to be scored against.
        if isOffHandWeapon or isShield or isHeldItem then
            return { 17 }, nil
        end

        -- A one-handed main-hand weapon. Dual wield may replace either hand,
        -- so both are evaluated.
        if build.weaponSetup == "DUAL_WIELD" then
            return { 16, 17 }, nil
        end

        return { 16 }, nil
    end

    -- Everything else maps to the slot(s) its equip location covers.
    local slots = LT.ItemStats:GetEquippableSlots(equipLoc)
    if not slots then
        return nil, "Forever did not report where this item is worn, so there is no slot "
            .. "to compare it against."
    end

    return slots, nil
end

------------------------------------------------------------------------------
-- Empty slots
------------------------------------------------------------------------------

-- Pure slot test: `readLink(slot)` returns the link worn there, or nil/"" when
-- the slot is empty. A reader that raises, and a restricted link, both count as
-- occupied: "unknown" must never be reported as a free slot. Exported so the
-- ring and trinket "either slot is enough" rule can be checked without a
-- character or a client.
function Compare.AnySlotEmpty(slots, readLink)
    if type(slots) ~= "table" or type(readLink) ~= "function" then return false end

    for _, slot in ipairs(slots) do
        local ok, link = pcall(readLink, slot)

        if ok then
            if LT:IsSecret(link) then
                -- A secret link belongs to an item; it is not an empty slot and
                -- must not be inspected further.
            elseif link == nil or link == "" then
                return true
            end
        end
    end

    return false
end

-- Is at least one of the slots this item would occupy empty right now? Rings and
-- trinkets map to two slots, so either one being free is enough. Every client
-- read is guarded, and a client without the inventory API answers "not empty",
-- which keeps the ordinary grey refusal rather than inventing an exception.
function Compare:HasEmptySlotFor(identity)
    if type(identity) ~= "table" then return false end

    local itemStats = LT.ItemStats
    if type(itemStats) ~= "table"
        or type(itemStats.GetEquippableSlots) ~= "function" then
        return false
    end

    local okSlots, slots = pcall(itemStats.GetEquippableSlots, itemStats, identity.equipLoc)
    if not okSlots or type(slots) ~= "table" then return false end

    if type(GetInventoryItemLink) ~= "function" then return false end

    return Compare.AnySlotEmpty(slots, function(slot)
        return GetInventoryItemLink("player", slot)
    end)
end

------------------------------------------------------------------------------
-- Comparison
------------------------------------------------------------------------------

-- Whether the client's own "no" is the final answer. C_PlayerInfo.CanUseItem
-- answers "can this be equipped right now", which lumps together two very
-- different items: one the class can never use, and one that is usable later
-- (an untrained weapon proficiency, mail before 40, an item above the player's
-- level). Usability already tells those apart, so a deferred item is scored and
-- painted green instead of being blanked as ineligible.
--
-- Anything uncertain keeps today's refusal: no Usability module, no verdict, an
-- error in the call, or a verdict this addon does not know. The optional second
-- argument exists so /lt test can hand in a verdict it built itself rather than
-- depending on the character's real trained skills.
function Compare:RefusalIsFinal(identity, verdict)
    if type(identity) ~= "table" then return true end

    local usability = LT.Usability

    if type(verdict) ~= "table" then
        if not usability or type(usability.GetVerdict) ~= "function" then return true end

        local ok, answer = pcall(usability.GetVerdict, usability, identity.link,
            { identity = identity })

        if not ok or type(answer) ~= "table" then return true end
        verdict = answer
    end

    if usability and verdict.verdict == usability.DEFERRED then return false end

    return true
end

-- opts.vs "saved" (default) — compare with the build's saved equipment set.
local function computeAgainstBuild(self, itemLink, buildIndex)
    local build = LT.Builds and LT.Builds:Get(buildIndex)
    if not build then
        return result("incomplete", "That build slot does not exist.")
    end

    local candidate = scoreItem(itemLink, buildIndex)
    local identity = candidate.identity

    if not identity then
        return result("unscorable",
            "The client did not return any item information for this link.",
            { itemLink = itemLink, buildIndex = buildIndex })
    end

    local wholeSet = Compare.IsWholeSetSwap(build, identity)

    -- A hard refusal: the class cannot use this item at all. Grey, regardless
    -- of the build's weapon configuration.
    if identity.canUse == false and self:RefusalIsFinal(identity) then
        return result("ineligible",
            "This character cannot use this item, so it is not an upgrade for any build.",
            {
                itemLink = itemLink,
                buildIndex = buildIndex,
                buildName = buildDisplayName(build, buildIndex),
                itemName = identity.name,
                candidate = candidate,
            })
    end

    -- A configuration mismatch: the class can use the item, but it does not
    -- suit the build's weapon setup. Score it anyway, halved, so a two-hander
    -- still ranks on a shield tank and a shield still ranks on a two-hander
    -- build — just below an item that suits.
    local fits, fitReason = self:SetupFits(build, identity)
    if not fits then
        candidate = penalizeCandidate(candidate, fitReason)
    end

    if not candidate.ok then
        return result("unscorable",
            "This item could not be scored for " .. buildDisplayName(build, buildIndex) .. ".",
            {
                itemLink = itemLink,
                buildIndex = buildIndex,
                buildName = buildDisplayName(build, buildIndex),
                itemName = identity.name,
                candidate = candidate,
                limitations = candidate.limitations,
            })
    end

    -- A two-handed weapon against a build that fills the hands separately is
    -- measured on the whole set: the candidate against the saved main hand and
    -- off hand added together, never against one of them alone.
    if wholeSet then
        if not LT.GearSets:HasSnapshot(buildIndex) then
            return result("incomplete",
                "No equipment set has been saved for " .. buildDisplayName(build, buildIndex)
                .. ", so there is nothing to compare against.",
                {
                    itemLink = itemLink,
                    buildIndex = buildIndex,
                    buildName = buildDisplayName(build, buildIndex),
                    itemName = identity.name,
                    candidate = candidate,
                    wholeSet = true,
                    weaponSetup = build.weaponSetup,
                })
        end

        local total = 0

        for _, slot in ipairs({ 16, 17 }) do
            local reference, referenceReason = LT.GearSets:GetReferenceScore(buildIndex, slot)

            if reference then
                total = total + reference.score
            else
                -- An empty off hand adds nothing; a saved item that exists but
                -- cannot be read leaves the package incomplete, and is never
                -- silently dropped from the sum.
                local row = LT.GearSets.GetRow and LT.GearSets:GetRow(buildIndex, slot)
                local savedItem = row and row.link ~= nil
                local expectedEmpty = LT.GearSets:IsSlotExpectedEmpty(buildIndex, slot)

                if savedItem or not expectedEmpty then
                    return result("incomplete", referenceReason
                            or "The saved weapon slots could not be read.", {
                        itemLink = itemLink,
                        buildIndex = buildIndex,
                        buildName = buildDisplayName(build, buildIndex),
                        itemName = identity.name,
                        candidate = candidate,
                        wholeSet = true,
                        weaponSetup = build.weaponSetup,
                    })
                end
            end
        end

        local comparison = wholeSetResult(itemLink, buildIndex, build, identity,
            candidate, total,
            LT.ItemStats:GetSlotLabel(16) .. " + " .. LT.ItemStats:GetSlotLabel(17),
            "saved")

        local status = LT.GearSets:GetStatus(buildIndex)
        for _, limitation in ipairs(status.limitations or {}) do
            table.insert(comparison.limitations, limitation)
        end

        return comparison
    end

    local slots, slotReason = self:GetTargetSlots(buildIndex, identity)
    if not slots then
        return result("incomparable", slotReason, {
            itemLink = itemLink,
            buildIndex = buildIndex,
            buildName = buildDisplayName(build, buildIndex),
            itemName = identity.name,
            candidate = candidate,
            weaponSetup = build.weaponSetup,
        })
    end

    if not LT.GearSets:HasSnapshot(buildIndex) then
        return result("incomplete",
            "No equipment set has been saved for " .. buildDisplayName(build, buildIndex)
            .. ", so there is nothing to compare against.",
            {
                itemLink = itemLink,
                buildIndex = buildIndex,
                buildName = buildDisplayName(build, buildIndex),
                itemName = identity.name,
                candidate = candidate,
            })
    end

    local rows = {}
    local usable = false

    for _, slot in ipairs(slots) do
        local reference, referenceReason = LT.GearSets:GetReferenceScore(buildIndex, slot)

        if reference then
            usable = true
            local difference = candidate.score - reference.score
            local percent = (reference.score ~= 0)
                and (difference / math.abs(reference.score) * 100)
                or nil

            table.insert(rows, {
                slot = slot,
                slotLabel = LT.ItemStats:GetSlotLabel(slot),
                reference = reference,
                referenceScore = reference.score,
                referenceLink = reference.itemLink,
                candidateScore = candidate.score,
                difference = difference,
                percent = percent,
                status = difference > 0 and "upgrade"
                    or (difference < 0 and "downgrade" or "equal"),
            })
        else
            table.insert(rows, {
                slot = slot,
                slotLabel = LT.ItemStats:GetSlotLabel(slot),
                status = "incomplete",
                reason = referenceReason,
            })
        end
    end

    if not usable then
        local reasons = {}
        for _, row in ipairs(rows) do
            if row.reason then table.insert(reasons, row.reason) end
        end

        return result("incomplete", table.concat(reasons, " "), {
            itemLink = itemLink,
            buildIndex = buildIndex,
            buildName = buildDisplayName(build, buildIndex),
            itemName = identity.name,
            candidate = candidate,
            rows = rows,
        })
    end

    -- Headline: the slot where the item helps most. For a ring or trinket that
    -- is the weaker of the two worn items, which is the one you would replace.
    local headline = rows[1]
    for _, row in ipairs(rows) do
        if row.difference and (not headline.difference or row.difference > headline.difference) then
            headline = row
        end
    end

    local comparison = result(headline.status, nil, {
        itemLink = itemLink,
        buildIndex = buildIndex,
        buildName = buildDisplayName(build, buildIndex),
        itemName = identity.name,
        candidate = candidate,
        rows = rows,
        headline = headline,
        difference = headline.difference,
        percent = headline.percent,
        referenceScore = headline.referenceScore,
        candidateScore = candidate.score,
        referenceSlot = headline.slot,
        referenceSlotLabel = headline.slotLabel,
        weaponSetup = build.weaponSetup,
        scoringLevel = candidate.scoringLevel,
        scaleName = candidate.scaleName,
    })

    if #rows > 1 then
        table.insert(comparison.notes,
            "This item can replace more than one slot, so each was evaluated. "
            .. "The figure shown is the best case (" .. tostring(headline.slotLabel) .. ").")
    end

    table.insert(comparison.limitations,
        "The difference is a change in weighted item score, not a prediction of "
        .. "damage, healing or survivability.")

    if identity.canUse == nil then
        table.insert(comparison.limitations,
            "This client did not report whether the character can use the item, so "
            .. "eligibility could not be checked.")
    end

    for _, limitation in ipairs(candidate.limitations or {}) do
        table.insert(comparison.limitations, limitation)
    end

    local status = LT.GearSets:GetStatus(buildIndex)
    for _, limitation in ipairs(status.limitations or {}) do
        table.insert(comparison.limitations, limitation)
    end

    return comparison
end

-- opts.vs "saved" (default) — compare with the build's saved equipment set.
-- One computation per item, build, profile revision and level: a second hover
-- of the same item reads the result instead of scoring it again.
function Compare:AgainstBuild(itemLink, buildIndex, opts)
    opts = opts or {}

    return cached("saved", itemLink, buildIndex, function()
        local comparison = computeAgainstBuild(self, itemLink, buildIndex)

        -- A result that never reached a scored candidate is the client not
        -- having answered for this item yet: asked again next time, not kept.
        return comparison, comparison ~= nil and comparison.candidate ~= nil
    end)
end

------------------------------------------------------------------------------
-- Comparison against what the character is wearing right now
------------------------------------------------------------------------------

-- Score of whatever is worn in `slot`, at the build's current weights. An empty
-- slot scores 0, so a usable item there is a pure gain.
local function scoreWornSlot(buildIndex, slot)
    local link = LT.GearSets:GetEquippedLink(slot)

    if not link then
        return { score = 0, empty = true, slot = slot }, nil
    end

    local score = scoreItem(link, buildIndex)
    if not score.ok then
        return nil, "The item worn in " .. LT.ItemStats:GetSlotLabel(slot)
            .. " could not be read: " .. table.concat(score.limitations or {}, " ")
    end

    return { score = score.score, empty = false, slot = slot, link = link }, nil
end

local function wornIsTwoHanded()
    local link = LT.GearSets:GetEquippedLink(16)
    if not link then return false end

    local identity = LT.ItemStats:GetIdentity(link)
    return identity ~= nil and identity.equipLoc == "INVTYPE_2HWEAPON"
end

-- Which worn slots a candidate would replace. Each target is
-- { slot = <headline slot>, worn = { slots whose scores are summed } }.
-- Returns: targets, reason (when the swap cannot be evaluated).
function Compare:GetEquippedTargets(identity)
    local equipLoc = identity.equipLoc

    if equipLoc == "INVTYPE_2HWEAPON" then
        -- A two-handed weapon replaces the main hand and whatever is in the off hand.
        return { { slot = 16, worn = { 16, 17 } } }, nil
    end

    if equipLoc == "INVTYPE_WEAPON" then
        if wornIsTwoHanded() then
            return { { slot = 16, worn = { 16 } } }, nil
        end

        local canDual = true
        if type(CanDualWield) == "function" then
            local ok, value = pcall(CanDualWield)
            if ok and value == false then canDual = false end
        end

        if not canDual then
            return { { slot = 16, worn = { 16 } } }, nil
        end

        -- The off hand is only a candidate when it holds a weapon (or is empty and
        -- the character can dual wield). A shield or held item is never replaced
        -- by a one-handed weapon in this comparison.
        local offLink = LT.GearSets:GetEquippedLink(17)
        local offIdentity = offLink and LT.ItemStats:GetIdentity(offLink) or nil
        local offIsWeapon = offIdentity ~= nil and weaponLocations[offIdentity.equipLoc] == true

        if offIsWeapon or not offLink then
            return { { slot = 16, worn = { 16 } }, { slot = 17, worn = { 17 } } }, nil
        end

        return { { slot = 16, worn = { 16 } } }, nil
    end

    if equipLoc == "INVTYPE_WEAPONMAINHAND" then
        return { { slot = 16, worn = { 16 } } }, nil
    end

    if equipLoc == "INVTYPE_WEAPONOFFHAND" or equipLoc == "INVTYPE_SHIELD"
        or equipLoc == "INVTYPE_HOLDABLE" then
        if wornIsTwoHanded() then
            return nil, "A two-handed weapon is equipped. Wearing this would mean "
                .. "unequipping it, which is a different comparison than one slot swap."
        end
        return { { slot = 17, worn = { 17 } } }, nil
    end

    if equipLoc == "INVTYPE_RANGED" or equipLoc == "INVTYPE_RANGEDRIGHT"
        or equipLoc == "INVTYPE_THROWN" then
        return { { slot = 18, worn = { 18 } } }, nil
    end

    local slots = LT.ItemStats:GetEquippableSlots(equipLoc)
    if not slots then
        return nil, "Forever did not report where this item is worn, so there is no slot "
            .. "to compare it against."
    end

    local targets = {}
    for _, slot in ipairs(slots) do
        table.insert(targets, { slot = slot, worn = { slot } })
    end

    return targets, nil
end

-- Compares an item with the gear the character is wearing at this moment, scored
-- with the given build's weights. Nothing here reads or changes a saved set.
local function computeAgainstEquipped(self, itemLink, buildIndex)
    local build = LT.Builds and LT.Builds:Get(buildIndex)
    if not build then
        return result("incomplete", "That build slot does not exist.", { vs = "equipped" })
    end

    local candidate = scoreItem(itemLink, buildIndex)
    local identity = candidate.identity

    if not identity then
        return result("unscorable",
            "The client did not return any item information for this link.",
            { itemLink = itemLink, buildIndex = buildIndex, vs = "equipped" })
    end

    local wholeSet = Compare.IsWholeSetSwap(build, identity)

    local base = {
        itemLink = itemLink,
        buildIndex = buildIndex,
        buildName = buildDisplayName(build, buildIndex),
        itemName = identity.name,
        candidate = candidate,
        vs = "equipped",
    }

    -- A hard refusal: the class cannot use this item at all. Grey, regardless
    -- of the build's weapon configuration.
    if identity.canUse == false and self:RefusalIsFinal(identity) then
        return result("ineligible",
            "This character cannot use this item, so it is not an upgrade for any build.", base)
    end

    -- A configuration mismatch is scored, halved, not refused.
    local fits, fitReason = self:SetupFits(build, identity)
    if not fits then
        candidate = penalizeCandidate(candidate, fitReason)
    end

    if not candidate.ok then
        base.limitations = candidate.limitations
        return result("unscorable",
            "This item could not be scored for " .. buildDisplayName(build, buildIndex) .. ".", base)
    end

    -- The same package rule as the saved comparison, measured on the hands the
    -- character is wearing right now: a shield or an off-hand weapon is part of
    -- the reference, not left behind.
    if wholeSet then
        local total = 0

        for _, slot in ipairs({ 16, 17 }) do
            local worn, reason = scoreWornSlot(buildIndex, slot)
            if not worn then
                base.limitations = candidate.limitations
                base.wholeSet = true
                return result("incomplete", reason, base)
            end

            total = total + worn.score
        end

        return wholeSetResult(itemLink, buildIndex, build, identity, candidate,
            total,
            LT.ItemStats:GetSlotLabel(16) .. " + " .. LT.ItemStats:GetSlotLabel(17),
            "equipped")
    end

    local targets

    -- A two-hander is worn but this build is not a two-hander build: the worn
    -- weapon does not represent the build. This matters only for weapon, shield
    -- and held items — armour and rings compare against their own worn slot no
    -- matter what the hands hold. Prefer the saved set; without one, the build's
    -- own slot is empty, so the item scores as a pure gain rather than being
    -- refused or measured against the two-hander.
    local isWeaponSlot = weaponLocations[identity.equipLoc]
        or identity.equipLoc == "INVTYPE_SHIELD"
        or identity.equipLoc == "INVTYPE_HOLDABLE"

    if isWeaponSlot and wornIsTwoHanded() and build.weaponSetup ~= "2H" then
        if LT.GearSets and LT.GearSets:HasSnapshot(buildIndex) then
            return self:AgainstBuild(itemLink, buildIndex)
        end

        local buildTargets = self:GetTargetSlots(buildIndex, identity)
        if not buildTargets then
            return result("incomparable",
                "the build's weapon configuration could not be evaluated", base)
        end

        targets = {}
        for _, slot in ipairs(buildTargets) do
            targets[#targets + 1] = { slot = slot, worn = {} }
        end
    else
        targets = self:GetEquippedTargets(identity)
        if not targets then
            return self:AgainstBuild(itemLink, buildIndex)
        end
    end

    local rows = {}
    local usable = false

    for _, target in ipairs(targets) do
        local total = 0
        local failure
        local labels = {}

        for _, wornSlot in ipairs(target.worn) do
            local worn, reason = scoreWornSlot(buildIndex, wornSlot)
            if worn then
                total = total + worn.score
                table.insert(labels, LT.ItemStats:GetSlotLabel(wornSlot))
            else
                failure = reason
                break
            end
        end

        local slotLabel = table.concat(labels, " + ")
        if slotLabel == "" then slotLabel = LT.ItemStats:GetSlotLabel(target.slot) end

        if failure then
            table.insert(rows, {
                slot = target.slot,
                slotLabel = slotLabel,
                status = "incomplete",
                reason = failure,
            })
        else
            usable = true
            local difference = candidate.score - total
            local percent = (total ~= 0) and (difference / math.abs(total) * 100) or nil

            table.insert(rows, {
                slot = target.slot,
                slotLabel = slotLabel,
                referenceScore = total,
                candidateScore = candidate.score,
                difference = difference,
                percent = percent,
                status = difference > 0 and "upgrade"
                    or (difference < 0 and "downgrade" or "equal"),
            })
        end
    end

    if not usable then
        local reasons = {}
        for _, row in ipairs(rows) do
            if row.reason then table.insert(reasons, row.reason) end
        end
        base.rows = rows
        return result("incomplete", table.concat(reasons, " "), base)
    end

    -- Headline: the swap that helps most. For rings and trinkets that is the
    -- weaker worn item, which is the one you would actually replace.
    local headline
    for _, row in ipairs(rows) do
        if row.difference and (not headline or row.difference > headline.difference) then
            headline = row
        end
    end

    local comparison = result(headline.status, nil, {
        itemLink = itemLink,
        buildIndex = buildIndex,
        buildName = buildDisplayName(build, buildIndex),
        itemName = identity.name,
        candidate = candidate,
        rows = rows,
        headline = headline,
        difference = headline.difference,
        percent = headline.percent,
        referenceScore = headline.referenceScore,
        candidateScore = candidate.score,
        referenceSlot = headline.slot,
        referenceSlotLabel = headline.slotLabel,
        scoringLevel = candidate.scoringLevel,
        scaleName = candidate.scaleName,
        vs = "equipped",
    })

    if #rows > 1 then
        table.insert(comparison.notes,
            "This item can replace more than one slot, so each was evaluated. "
            .. "The figure shown is the best case (" .. tostring(headline.slotLabel) .. ").")
    end

    table.insert(comparison.limitations,
        "The difference is a change in weighted item score, not a prediction of "
        .. "damage, healing or survivability.")

    if identity.canUse == nil then
        table.insert(comparison.limitations,
            "This client did not report whether the character can use the item, so "
            .. "eligibility could not be checked.")
    end

    for _, limitation in ipairs(candidate.limitations or {}) do
        table.insert(comparison.limitations, limitation)
    end

    return comparison
end

-- Same shape as AgainstBuild, measured against the worn items: kept per item,
-- build, profile revision and level so a redrawn panel does not rescore.
function Compare:AgainstEquipped(itemLink, buildIndex)
    return cached("equipped", itemLink, buildIndex, function()
        local comparison = computeAgainstEquipped(self, itemLink, buildIndex)

        return comparison, comparison ~= nil and comparison.candidate ~= nil
    end)
end

-- The comparison the tooltip uses: live equipped gear unless the player has
-- switched back to the saved equipment set in Settings.
function Compare:ForBuild(itemLink, buildIndex)
    local options = (LT.Database and LT.Database:GetOptions()) or {}

    if options.tooltipCompareEquipped ~= false then
        return self:AgainstEquipped(itemLink, buildIndex)
    end

    return self:AgainstBuild(itemLink, buildIndex)
end

function Compare:ForAllBuilds(itemLink, opts)
    local rows = {}

    for index = 1, (LT.Builds and LT.Builds.SLOT_COUNT or 2) do
        table.insert(rows, self:AgainstBuild(itemLink, index, opts))
    end

    return rows
end

-- Which stats changed, and by how much, for the swap the tooltip headlines:
-- the candidate's stats minus the stats of the worn item(s) it would replace.
-- Each row also carries the weighted impact, so the reason reads in the order
-- the score actually cares about rather than by raw amount (15 armor is not a
-- bigger deal than 2 stamina):
--   { { stat = "stamina", label = "Stamina", amount = 2, impact = 2 }, ... }
-- An empty list means the two items carry the same known stats, so the score
-- difference comes from something this addon does not model. Report nothing
-- rather than invent a reason.
local function computeStatDeltas(self, itemLink, buildIndex)
    local candidate = scoreItem(itemLink, buildIndex)
    if not candidate.ok or not candidate.stats or not candidate.identity then
        return {}, false
    end

    -- A candidate the build refuses has no swap to describe: listing stat
    -- changes for a two-handed weapon in a shield build would read like an
    -- upgrade the score just declined to give.
    local build = LT.Builds and LT.Builds:Get(buildIndex)
    if not build or not self:SetupFits(build, candidate.identity) then
        return {}, false
    end

    -- The reason describes the item stat blocks the player can read on the two
    -- tooltips, so it is measured on the raw stats. The imbue layer is part of
    -- the score, not part of the printed "+2 Stamina", and mixing the two would
    -- report a weapon DPS premium as if the item itself carried the change.
    local candidateStats = candidate.rawStats or candidate.stats

    local targets = self:GetEquippedTargets(candidate.identity)
    if not targets then return {} end

    local effective = LT.Profiles:GetEffective(buildIndex)
    local weights = (effective and effective.weights) or {}

    local chosen
    local chosenDifference

    for _, target in ipairs(targets) do
        local wornStats = {}
        local wornScore = 0

        for _, wornSlot in ipairs(target.worn) do
            local link = LT.GearSets:GetEquippedLink(wornSlot)
            if link then
                local stats = LT.ItemStats:Get(link)
                if type(stats) == "table" then
                    local scored = scoreItem(link, buildIndex)
                    wornScore = wornScore + ((scored.ok and scored.score) or 0)

                    for stat, amount in pairs(stats) do
                        local value = tonumber(amount)
                        if value then
                            wornStats[stat] = (wornStats[stat] or 0) + value
                        end
                    end
                end
            end
        end

        local deltas = {}
        local seen = {}

        local function add(stat, change)
            if change == 0 then return end

            local weight = tonumber(weights[stat])

            table.insert(deltas, {
                stat = stat,
                label = LT:Label(stat),
                amount = change,
                impact = weight and (change * weight) or change,
                weight = weight,
            })
        end

        for stat, amount in pairs(candidateStats) do
            local value = tonumber(amount)
            if value then
                seen[stat] = true
                add(stat, value - (wornStats[stat] or 0))
            end
        end

        -- A stat the new item simply does not have is a loss, and has to be
        -- named, otherwise "it is an upgrade because of stamina" hides the
        -- intellect it quietly took away.
        for stat, amount in pairs(wornStats) do
            if not seen[stat] then add(stat, -amount) end
        end

        table.sort(deltas, function(a, b)
            local left, right = math.abs(a.impact), math.abs(b.impact)
            if left ~= right then return left > right end
            return math.abs(a.amount) > math.abs(b.amount)
        end)

        -- The headline swap, matching the one the comparison reports.
        local difference = candidate.score - wornScore
        if not chosenDifference or difference > chosenDifference then
            chosen = deltas
            chosenDifference = difference
        end
    end

    return chosen or {}, true
end

-- Kept per item, build, profile revision and level: the tooltip's Shift detail
-- asks for the same candidate its score line already had scored.
function Compare:StatDeltas(itemLink, buildIndex)
    return cached("deltas", itemLink, buildIndex, function()
        return computeStatDeltas(self, itemLink, buildIndex)
    end)
end

------------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------------

function Compare:Describe(comparison, options)
    options = options or {}
    if not comparison then return "no comparison" end

    local buildName = comparison.buildName or "build"

    if comparison.status == "incomparable" or comparison.status == "incomplete"
        or comparison.status == "unscorable" or comparison.status == "ineligible" then
        return buildName .. ": " .. tostring(comparison.reason or "not comparable")
    end

    local text = buildName .. ": "
        .. LT:FormatSigned(comparison.difference, 1) .. " score vs "
        .. (comparison.vs == "equipped" and "equipped " or "saved ")
        .. tostring(comparison.referenceSlotLabel)

    if comparison.percent then
        text = text .. " (" .. LT:FormatSigned(comparison.percent, 1) .. "%)"
    end

    if options.withStatus then
        text = text .. " — " .. tostring(comparison.status)
    end

    return text
end

-- The colour of a score word, from the palette, so the word and the tooltip
-- border always agree. The three camps are deliberately distinct:
--   stop    — grey: the character can never use it, or it is a downgrade. A
--             verdict the player acts on, so it is not red;
--   unknown — red: the add-on cannot answer (incomplete, incomparable,
--             unscorable data). A gap in the data, shown plainly rather than
--             hidden in dead text;
--   muted   — "Even" is not a verdict at all, so it is de-emphasised chrome.
function Compare:StatusColour(status)
    local palette = LT.Palette

    if status == "upgrade" then return palette.hex.go end
    if status == "downgrade" then return palette.hex.stop end
    if status == "equal" then return palette.hex.muted end
    if status == "ineligible" then return palette.hex.stop end
    if status == "incomparable" or status == "incomplete" then return palette.hex.unknown end
    if status == "unscorable" then return palette.hex.unknown end
    return palette.hex.text
end

------------------------------------------------------------------------------
-- Invalidation
--
-- Every input a stored comparison was calculated from already announces its own
-- change, so nothing here waits for the next hover to notice. LEVEL changes the
-- scoring level, BUILDS the weapon configuration and the build names, PROFILE
-- the weights and caps, GEARSET the saved set a build is measured against. The
-- worn set is announced separately, and an item's own stats can only change
-- when the client re-reads the character's gear or inventory.
------------------------------------------------------------------------------

for _, event in ipairs({
    LT.EVENT_LEVEL, LT.EVENT_BUILDS, LT.EVENT_PROFILE, LT.EVENT_GEARSET,
    "EQUIPMENT_CHANGED", "INVENTORY_CHANGED",
}) do
    LT:On(event, function()
        Compare:Invalidate()
    end, "Compare")
end