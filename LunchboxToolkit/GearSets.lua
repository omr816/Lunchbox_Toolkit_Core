--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — GearSets
    One saved equipment snapshot per build slot.

    A snapshot records the item links worn at the moment it was taken, plus the
    level, the scoring level and the profile it was scored under. It is what a
    comparison measures against, so the PvP build is compared with the saved
    PvP gear even while tank gear is actually worn.

    Saving is not equipping: nothing here ever changes what the character wears.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local GearSets = {}
LT.GearSets = GearSets
LT.Modules.GearSets = GearSets

GearSets.SCHEMA = 1

------------------------------------------------------------------------------
-- Reading the character's equipment
------------------------------------------------------------------------------

function GearSets:GetEquippedLink(slot)
    if type(GetInventoryItemLink) ~= "function" then return nil end

    local link = GetInventoryItemLink("player", slot)
    if LT:IsSecret(link) then return nil end
    return link
end

-- One scoring entry point for this file, so a saved set and a comparison never
-- disagree about how much a weapon is worth (the Shaman imbue layer lives in
-- Score:ScoreItemWithImbue and is a no-op unless it is enabled).
local function scoreItem(itemLink, buildIndex)
    if LT.Score.ScoreItemWithImbue then
        return LT.Score:ScoreItemWithImbue(itemLink, buildIndex)
    end

    return LT.Score:ScoreItem(itemLink, buildIndex)
end

-- Slots a build is not expected to fill, so an empty one is not reported as
-- missing data. An off-hand is expected to be empty for a two-handed build.
function GearSets:IsSlotExpectedEmpty(buildIndex, slot)
    local build = LT.Builds and LT.Builds:Get(buildIndex)
    if not build then return false end

    if slot == 4 or slot == 19 then return true end   -- shirt and tabard

    local setup = LT:GetWeaponSetupDefinition(build.weaponSetup)
    if slot == 17 and setup and setup.usesOffHand == false then return true end

    return false
end

------------------------------------------------------------------------------
-- Saving
------------------------------------------------------------------------------

-- Replaces a build's snapshot. `opts.stats` is optional context for logging.
function GearSets:Save(buildIndex, opts)
    opts = opts or {}

    local build = LT.Builds and LT.Builds:Get(buildIndex)
    if not build then return nil, "That build slot does not exist." end

    local effective = LT.Profiles:GetEffective(buildIndex)
    if not effective.profile then
        return nil, "This build has no profile yet, so a snapshot could not be scored."
    end

    local rows = {}
    local empty = {}
    local total = 0

    for _, slot in ipairs(LT.InventorySlots) do
        local link = self:GetEquippedLink(slot.slot)

        if not link then
            local expected = self:IsSlotExpectedEmpty(buildIndex, slot.slot)
            table.insert(rows, {
                slot = slot.slot,
                label = slot.label,
                link = nil,
                expectedEmpty = expected,
                cosmetic = slot.cosmetic == true,
            })

            if not expected and not slot.cosmetic then
                table.insert(empty, slot.label)
            end
        else
            local score = scoreItem(link, buildIndex)

            table.insert(rows, {
                slot = slot.slot,
                label = slot.label,
                link = link,
                itemName = score.identity and score.identity.name or nil,
                score = score.ok and score.score or nil,
                scale = score.scale,
                limitations = score.limitations,
            })

            if score.ok then
                total = total + score.score
            end
        end
    end

    build.gearset = {
        schema = self.SCHEMA,
        savedAt = time and time() or 0,
        buildName = build.name,
        characterLevel = LT.Levels and LT.Levels:GetCurrentLevel() or nil,
        scoringLevel = effective.level,
        profileKey = effective.scale,
        profileName = effective.scaleName,
        totalScore = total,
        rows = rows,
        emptySlots = empty,
        savedOnRequest = opts.reason or "manual save",
    }

    LT:Fire(LT.EVENT_GEARSET, { buildIndex = buildIndex, reason = "saved" })

    return build.gearset, nil, empty
end

function GearSets:Clear(buildIndex)
    local build = LT.Builds and LT.Builds:Get(buildIndex)
    if not build then return false end

    build.gearset = nil
    LT:Fire(LT.EVENT_GEARSET, { buildIndex = buildIndex, reason = "cleared" })
    return true
end

------------------------------------------------------------------------------
-- Access
------------------------------------------------------------------------------

function GearSets:Get(buildIndex)
    local build = LT.Builds and LT.Builds:Get(buildIndex)
    return build and build.gearset or nil
end

function GearSets:HasSnapshot(buildIndex)
    local snapshot = self:Get(buildIndex)
    return snapshot ~= nil and type(snapshot.rows) == "table"
end

function GearSets:GetRow(buildIndex, slot)
    local snapshot = self:Get(buildIndex)
    if not snapshot or not snapshot.rows then return nil end

    for _, row in ipairs(snapshot.rows) do
        if row.slot == slot then return row end
    end

    return nil
end

-- Re-scores a saved item at the build's *current* weights, so the reference
-- side of a comparison never drifts when a profile is edited.
function GearSets:GetReferenceScore(buildIndex, slot)
    local row = self:GetRow(buildIndex, slot)
    if not row then
        local build = LT.Builds and LT.Builds:Get(buildIndex)
        local slotLabel = LT.ItemStats:GetSlotLabel(slot)
        return nil, "The saved " .. (build and build.name or "build")
            .. " equipment set has no item in " .. slotLabel .. "."
    end

    if not row.link then
        return nil, "The saved " .. LT.ItemStats:GetSlotLabel(slot)
            .. " slot is empty in this build's equipment set."
    end

    local score = scoreItem(row.link, buildIndex)
    if not score.ok then
        return nil, "The saved item in " .. LT.ItemStats:GetSlotLabel(slot)
            .. " could not be read: " .. table.concat(score.limitations or {}, " ")
    end

    return score, nil
end

------------------------------------------------------------------------------
-- Health reporting
------------------------------------------------------------------------------

-- Anything that would make a comparison misleading is described here rather
-- than hidden: a missing snapshot, empty slots, a profile change since the
-- snapshot was taken, or equipment that has since changed.
function GearSets:GetStatus(buildIndex)
    local build = LT.Builds and LT.Builds:Get(buildIndex)
    local snapshot = self:Get(buildIndex)

    local status = {
        buildIndex = buildIndex,
        buildName = build and build.name or nil,
        hasSnapshot = snapshot ~= nil,
        limitations = {},
        emptySlots = {},
        changedSinceSave = {},
    }

    if not snapshot then
        table.insert(status.limitations,
            "No saved equipment set for this build yet. Save one to enable comparisons.")
        status.usable = false
        return status
    end

    status.savedAt = snapshot.savedAt
    status.scoringLevel = snapshot.scoringLevel
    status.profileName = snapshot.profileName

    local effective = LT.Profiles:GetEffective(buildIndex)
    if effective.scale and snapshot.profileKey and effective.scale ~= snapshot.profileKey then
        table.insert(status.limitations,
            "This equipment set was saved under \"" .. tostring(snapshot.profileName)
            .. "\" and the build now uses \"" .. tostring(effective.scaleName)
            .. "\". The saved items are re-scored with the current profile, so the "
            .. "original numbers no longer apply.")
    end

    for _, row in ipairs(snapshot.rows or {}) do
        if not row.expectedEmpty and not row.cosmetic and not row.link then
            table.insert(status.emptySlots, row.label)
        end

        local current = self:GetEquippedLink(row.slot)
        if row.link and current ~= row.link then
            table.insert(status.changedSinceSave, row.label)
        end
    end

    if #status.emptySlots > 0 then
        table.insert(status.limitations,
            "The saved set has nothing in: " .. table.concat(status.emptySlots, ", ")
            .. ". Comparisons for those slots cannot be calculated.")
    end

    status.usable = #status.emptySlots == 0

    return status
end

function GearSets:Describe(buildIndex)
    local snapshot = self:Get(buildIndex)
    local status = self:GetStatus(buildIndex)

    if not snapshot then
        return "no equipment set saved"
    end

    local when = "unknown time"
    if snapshot.savedAt and snapshot.savedAt > 0 then
        when = date and date("%Y-%m-%d %H:%M", snapshot.savedAt) or "recorded"
    end

    local parts = {
        "saved " .. when,
        "level " .. tostring(snapshot.characterLevel or "?"),
        "scored at level " .. tostring(snapshot.scoringLevel or "?"),
        tostring(#(snapshot.rows or {})) .. " slots",
    }

    if #status.changedSinceSave > 0 then
        table.insert(parts, tostring(#status.changedSinceSave) .. " slot(s) changed since")
    end

    return table.concat(parts, ", ")
end

function GearSets:GetRows(buildIndex)
    local snapshot = self:Get(buildIndex)
    return snapshot and snapshot.rows or {}
end