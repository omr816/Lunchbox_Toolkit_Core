--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Score
    Weighted stat scoring with a visible breakdown.

    What this produces is a weighted item score. It is NOT a prediction of
    damage, healing or survivability, and a score that is 10% higher is not
    "10% more damage". Scores are also only comparable inside one profile:
    two different profiles use different scales, so Score:CompareScales
    refuses to rank them against each other.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Score = {}
LT.Score = Score
LT.Modules.Score = Score

------------------------------------------------------------------------------
-- Core maths
------------------------------------------------------------------------------

-- stats: canonical channel -> number. buildIndex selects the effective weights.
function Score:ScoreStats(stats, buildIndex, opts)
    opts = opts or {}

    local effective = LT.Profiles:GetEffective(buildIndex, opts)
    local weights = effective.weights or {}

    local result = {
        ok = true,
        score = 0,
        breakdown = {},
        unsupported = {},
        limitations = LT:Copy(effective.limitations or {}),
        scale = effective.scale,
        scaleName = effective.scaleName,
        profileName = effective.profile and effective.profile.name or nil,
        buildIndex = buildIndex,
        buildName = effective.build and effective.build.name or nil,
        scoringLevel = effective.level,
        provisional = effective.provisional,
        weightsUsed = weights,
    }

    if not effective.profile then
        result.ok = false
        table.insert(result.limitations, "This build has no profile, so no weights were applied.")
        return result
    end

    if type(stats) ~= "table" then
        result.ok = false
        table.insert(result.limitations, "No readable stats for this item.")
        return result
    end

    local total = 0
    local rows = {}

    for stat, amount in pairs(stats) do
        local value = tonumber(amount)
        if value and value ~= 0 then
            local weight = tonumber(weights[stat])
            local row = {
                stat = stat,
                label = LT:Label(stat),
                amount = value,
                weight = weight,
                contribution = nil,
                note = nil,
            }

            if weight then
                row.contribution = value * weight
                total = total + row.contribution
                if weight == 0 then
                    row.note = "weighted at zero in this profile"
                end
            else
                row.note = "no weight for this stat in this profile"
                table.insert(result.unsupported, {
                    stat = stat,
                    label = row.label,
                    amount = value,
                    reason = "The profile has no weight for this stat, so it contributed nothing.",
                })
            end

            table.insert(rows, row)
        end
    end

    table.sort(rows, function(a, b)
        return math.abs(a.contribution or 0) > math.abs(b.contribution or 0)
    end)

    result.score = total
    result.breakdown = rows

    if #result.unsupported > 0 then
        local names = {}
        for _, entry in ipairs(result.unsupported) do
            table.insert(names, entry.label)
        end
        table.insert(result.limitations,
            "Not counted (no weight in this profile): " .. table.concat(names, ", "))
    end

    if total == 0 then
        table.insert(result.limitations,
            "Every stat on this item is weighted at zero in this profile, so the "
            .. "score cannot tell you whether it is an upgrade.")
    end

    return result
end

-- Scores an item link: stats + identity + limitations come from ItemStats.
function Score:ScoreItem(itemLink, buildIndex, opts)
    opts = opts or {}

    local stats, identity, itemLimitations = LT.ItemStats:Get(itemLink, opts)

    if not stats then
        return {
            ok = false,
            score = nil,
            breakdown = {},
            unsupported = {},
            limitations = LT:Copy(itemLimitations or { "This item could not be read." }),
            itemLink = itemLink,
            scale = nil,
            buildIndex = buildIndex,
        }
    end

    local result = self:ScoreStats(stats, buildIndex, opts)

    result.itemLink = itemLink
    result.identity = identity
    result.stats = stats

    for _, limitation in ipairs(itemLimitations or {}) do
        table.insert(result.limitations, limitation)
    end

    if identity and identity.canUse == false then
        result.usable = false
        table.insert(result.limitations,
            "This character cannot use this item, so its score is informational only.")
    else
        result.usable = true
    end

    return result
end

-- Scores an item with the Shaman weapon-imbue layer applied.
-- The layer only touches weapon channels (DPS, average damage, speed), only for
-- a Shaman with the option ticked, and only for the weapon itself: armour and
-- every other stat pass through untouched. The adjustments are reported in the
-- result so the tooltip and /lt score can say what was applied.
-- `stats` on the result is the adjusted set, so a caller measuring "what changed
-- between two items" compares like with like.
function Score:ScoreItemWithImbue(itemLink, buildIndex, opts)
    opts = opts or {}

    local stats, identity, itemLimitations = LT.ItemStats:Get(itemLink, opts)

    if not stats then
        return self:ScoreItem(itemLink, buildIndex, opts)
    end

    local adjusted, notes = stats, {}
    if LT.Imbues and LT.Imbues.AdjustStats then
        adjusted, notes = LT.Imbues:AdjustStats(stats, buildIndex)
    end

    if adjusted == stats then
        return self:ScoreItem(itemLink, buildIndex, opts)
    end

    local result = self:ScoreStats(adjusted, buildIndex, opts)

    result.itemLink = itemLink
    result.identity = identity
    result.stats = adjusted
    result.rawStats = stats
    result.imbueNotes = notes

    for _, limitation in ipairs(itemLimitations or {}) do
        table.insert(result.limitations, limitation)
    end

    if identity and identity.canUse == false then
        result.usable = false
        table.insert(result.limitations,
            "This character cannot use this item, so its score is informational only.")
    else
        result.usable = true
    end

    return result
end

------------------------------------------------------------------------------
-- Scale separation
------------------------------------------------------------------------------

-- Two scores are only comparable when they share a scale (the same profile).
function Score:CompareScales(a, b)
    if not a or not b then
        return false, "One of the two scores is missing."
    end

    if not a.scale or not b.scale then
        return false, "One of the two scores has no profile attached to it."
    end

    if a.scale ~= b.scale then
        return false, "These scores come from different profiles (\""
            .. tostring(a.scaleName) .. "\" and \"" .. tostring(b.scaleName)
            .. "\"), which are separate scales and must not be ranked against each other."
    end

    if a.scoringLevel ~= b.scoringLevel then
        return false, "These scores were calculated at different scoring levels ("
            .. tostring(a.scoringLevel) .. " and " .. tostring(b.scoringLevel) .. ")."
    end

    return true
end

function Score:GetDifference(candidate, reference)
    local comparable, reason = self:CompareScales(candidate, reference)
    if not comparable then
        return nil, reason
    end

    local difference = candidate.score - reference.score

    return {
        difference = difference,
        percent = (reference.score ~= 0) and (difference / math.abs(reference.score) * 100) or nil,
        comparable = true,
    }
end

------------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------------

function Score:FormatBreakdown(result, limit)
    local lines = {}

    for index, row in ipairs(result.breakdown or {}) do
        if limit and index > limit then
            table.insert(lines, "... " .. tostring(#result.breakdown - limit) .. " more")
            break
        end

        table.insert(lines, "  " .. row.label .. " " .. LT:FormatNumber(row.amount, 2)
            .. " x " .. (row.weight and LT:FormatNumber(row.weight, 3) or "no weight")
            .. " = " .. (row.contribution and LT:FormatNumber(row.contribution, 2) or "0")
            .. (row.note and (" — " .. row.note) or ""))
    end

    return lines
end

function Score:FormatResult(result, options)
    options = options or {}
    local parts = {}

    if not result or not result.ok then
        return "no score"
    end

    table.insert(parts, LT:FormatNumber(result.score, 1))

    if options.withProfile and result.scaleName then
        table.insert(parts, "(" .. tostring(result.scaleName) .. ")")
    end

    if options.withLevel and result.scoringLevel then
        table.insert(parts, "at level " .. tostring(result.scoringLevel))
    end

    return table.concat(parts, " ")
end