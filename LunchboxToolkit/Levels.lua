--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Levels
    Level-aware rating conversions.

    Rules requested by the player:
      * levels 1-59  -> everything that depends on level is calculated as if
                        the character were one level higher (level + 1)
      * level 60      -> calculated at 60 (the cap), never 61

    Why level + 1: gear scored today is gear you keep while you level, so the
    rating a percentage point costs you tomorrow is the honest yardstick.

    Rating -> percent conversion factors are client data, not an API. Forever
    does not expose a per-level table (nothing in the verified API surface
    returns one), so this module:
      1. measures the conversion at the player's current level whenever the
         client will tell us (rating divided by the returned percentage),
      2. stores every measurement per level, permanently, in saved variables,
      3. falls back to a player-entered value,
      4. and otherwise reports "conversion unknown for level N" instead of
         guessing a number.

    A measurement is only possible while the character actually has some rating
    in that stat, so the table fills in as you play and level up.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Levels = {}
LT.Levels = Levels
LT.Modules.Levels = Levels

-- Combat rating ids exposed by the client. Anything not listed here is simply
-- not measurable through this route.
local ratingIds = {
    hit          = "CR_HIT_MELEE",
    hitRanged    = "CR_HIT_RANGED",
    spellHit     = "CR_HIT_SPELL",
    crit         = "CR_CRIT_MELEE",
    critRanged   = "CR_CRIT_RANGED",
    spellCrit    = "CR_CRIT_SPELL",
    haste        = "CR_HASTE_MELEE",
    spellHaste   = "CR_HASTE_SPELL",
    defense      = "CR_DEFENSE_SKILL",
    dodge        = "CR_DODGE",
    parry        = "CR_PARRY",
    block        = "CR_BLOCK",
    expertise    = "CR_EXPERTISE",
    armorPen     = "CR_ARMOR_PENETRATION",
}

------------------------------------------------------------------------------
-- Level helpers
------------------------------------------------------------------------------

function Levels:GetCurrentLevel()
    local level = LT.player and tonumber(LT.player.level)
    if not level or level < 1 then
        level = tonumber(UnitLevel("player")) or 1
    end

    if level < 1 then level = 1 end
    if level > LT.MAX_LEVEL then level = LT.MAX_LEVEL end
    return level
end

-- The level every level-dependent calculation is performed at.
function Levels:GetScoringLevel()
    local level = self:GetCurrentLevel()
    if level >= LT.MAX_LEVEL then
        return LT.MAX_LEVEL
    end
    return level + 1
end

-- The level cap targets are chosen against. The scoring level is one level
-- ahead, which would put a level-59 character on the endgame targets a level
-- early; a cap is about what the character fights now, so this is the real
-- level.
function Levels:GetTargetLevel()
    return self:GetCurrentLevel()
end

-- Pure: has this level reached an endgame threshold? `threshold` is profile
-- data. nil means the question cannot be answered, and callers keep the
-- behaviour they had before target-aware caps existed.
function Levels.IsEndgame(level, threshold)
    level = tonumber(level)
    threshold = tonumber(threshold)
    if not level or not threshold then return nil end
    return level >= threshold
end

function Levels:DescribeScoringLevel()
    local current = self:GetCurrentLevel()
    local scoring = self:GetScoringLevel()

    if scoring == current then
        return "calculated at level " .. tostring(scoring) .. " (cap)"
    end

    return "calculated at level " .. tostring(scoring)
        .. " (" .. tostring(current) .. " + 1)"
end

------------------------------------------------------------------------------
-- Rating id lookup
------------------------------------------------------------------------------

function Levels:GetRatingId(stat)
    local globalName = ratingIds[stat]
    if not globalName then return nil end

    local id = _G[globalName]
    if type(id) ~= "number" then return nil end
    return id
end

------------------------------------------------------------------------------
-- Live readings
------------------------------------------------------------------------------

-- Raw rating the character currently has in a stat, straight from the client.
function Levels:GetLiveRating(stat)
    local id = self:GetRatingId(stat)
    if not id or type(GetCombatRating) ~= "function" then return nil end

    local value, err = LT:Safe(GetCombatRating, id)
    value = tonumber(value)
    if not value or value <= 0 then return nil, err end
    return value
end

-- Percentage the client currently attributes to that rating, at the
-- character's real level.
function Levels:GetLivePercent(stat)
    local id = self:GetRatingId(stat)
    if not id or type(GetCombatRatingBonus) ~= "function" then return nil end

    local value, err = LT:Safe(GetCombatRatingBonus, id)
    value = tonumber(value)
    if not value or value <= 0 then return nil, err end
    return value
end

------------------------------------------------------------------------------
-- Conversion table ("how much rating buys one percent, at level N")
------------------------------------------------------------------------------

function Levels:GetCharTable()
    local db = LT.Database and LT.Database.character
    if not db then return nil end

    db.conversions = db.conversions or {}
    return db.conversions
end

-- value: rating required for one percent of the stat at that level.
function Levels:SetConversion(stat, level, value, source)
    local conversions = self:GetCharTable()
    if not conversions then return false end

    level = tonumber(level) or self:GetCurrentLevel()
    value = tonumber(value)
    if not value or value <= 0 then return false end

    conversions[level] = conversions[level] or {}
    local existing = conversions[level][stat]

    -- A measurement beats anything the player typed; a manual entry beats
    -- nothing. Never let a weaker source overwrite a stronger one.
    local rank = { bundled = 1, manual = 2, measured = 3 }
    if existing and (rank[existing.source] or 0) > (rank[source] or 0) then
        return false
    end

    conversions[level][stat] = {
        value  = value,
        source = source or LT.SOURCE_MANUAL,
        at     = time and time() or 0,
    }

    LT:Fire(LT.EVENT_LEVEL, { conversionsChanged = true })
    return true
end

-- Returns: value, meta.  value is rating-per-percent, or nil with a reason.
function Levels:GetConversion(stat, level)
    level = tonumber(level) or self:GetScoringLevel()

    local conversions = self:GetCharTable()
    local entry = conversions and conversions[level] and conversions[level][stat]

    if entry and entry.value then
        return entry.value, {
            source      = entry.source,
            level       = level,
            provisional = entry.source == LT.SOURCE_BUNDLED,
        }
    end

    local reason = "no rating conversion recorded for " .. LT:Label(stat)
        .. " at level " .. tostring(level)

    if level == self:GetCurrentLevel() then
        reason = reason .. " — equip an item with " .. LT:Label(stat)
            .. " rating and run /lt capture"
    else
        reason = reason
            .. " — Forever does not expose a per-level conversion table, "
            .. "so it has to be measured or entered with /lt divisor"
    end

    return nil, { level = level, reason = reason, provisional = true }
end

function Levels:GetKnownLevels(stat)
    local conversions = self:GetCharTable()
    local rows = {}

    if not conversions then return rows end

    for level, stats in pairs(conversions) do
        local entry = stats[stat]
        if entry and entry.value then
            table.insert(rows, {
                level  = tonumber(level) or 0,
                value  = entry.value,
                source = entry.source,
            })
        end
    end

    table.sort(rows, function(a, b) return a.level < b.level end)
    return rows
end

------------------------------------------------------------------------------
-- Conversions
------------------------------------------------------------------------------

-- How much rating a percentage target costs at a level. nil when unknown.
function Levels:RatingForPercent(stat, percent, level)
    local conversion, meta = self:GetConversion(stat, level)
    local target = tonumber(percent)
    if not conversion or not target then return nil, meta end
    return conversion * target, meta
end

-- What a rating amount is worth as a percentage at a level. nil when unknown.
function Levels:PercentForRating(stat, rating, level)
    local conversion = self:GetConversion(stat, level)
    local amount = tonumber(rating)
    if not conversion or not amount then return nil end
    return amount / conversion
end

------------------------------------------------------------------------------
-- Measurement
------------------------------------------------------------------------------

-- Reads the client's own rating -> percent relationship at the character's
-- current level. Only possible for stats with a non-zero rating right now.
function Levels:CaptureCurrentLevel(reason)
    local level = self:GetCurrentLevel()
    local captured, skipped = {}, {}

    for stat in pairs(ratingIds) do
        local rating = self:GetLiveRating(stat)
        local percent = self:GetLivePercent(stat)

        if rating and percent then
            local conversion = rating / percent
            if conversion > 0 then
                if self:SetConversion(stat, level, conversion, LT.SOURCE_MEASURED) then
                    table.insert(captured, {
                        stat    = stat,
                        rating  = rating,
                        percent = percent,
                        value   = conversion,
                    })
                end
            end
        else
            table.insert(skipped, stat)
        end
    end

    return captured, skipped, level
end

function Levels:CaptureAndReport()
    local captured, skipped, level = self:CaptureCurrentLevel("manual")

    if #captured == 0 then
        LT:Print("No rating conversion could be measured at level " .. tostring(level)
            .. ": the character has no rating in any measurable stat right now.")
        LT:Print("Equip something with hit, crit, defense, dodge, parry, block or expertise"
            .. " rating, then run /lt capture again — or enter a known value with"
            .. " /lt divisor <stat> <rating per percent>.")
        return false
    end

    LT:Print("Measured rating conversion at level " .. tostring(level) .. ":")
    for _, row in ipairs(captured) do
        LT:Print("  " .. LT:Label(row.stat) .. ": "
            .. LT:FormatNumber(row.value, 3) .. " rating per 1%"
            .. " (" .. LT:FormatNumber(row.rating, 0) .. " rating = "
            .. LT:FormatNumber(row.percent, 2) .. "%)")
    end

    if #skipped > 0 then
        LT:Debug("no rating to measure for: " .. table.concat(skipped, ", "))
    end

    return true
end

-- Called on login and on every level up: level ups are the cheap moments to
-- collect a data point before gear changes.
function Levels:OnPlayerLogin()
    self:CaptureCurrentLevel("login")
end

function Levels:OnEnterWorld()
    self:CaptureCurrentLevel("zone")
end

LT:On("PLAYER_LEVEL_UP", function(payload)
    Levels:CaptureCurrentLevel("level_up")
    LT:Debug("level up to " .. tostring(payload and payload.level))
end)

-- Reporting -----------------------------------------------------------------

function Levels:GetReport()
    local rows = {}

    for stat in pairs(ratingIds) do
        local conversion, meta = self:GetConversion(stat, self:GetScoringLevel())
        table.insert(rows, {
            stat        = stat,
            label       = LT:Label(stat),
            level       = self:GetScoringLevel(),
            value       = conversion,
            source      = conversion and meta.source or nil,
            provisional = conversion == nil or meta.provisional,
            reason      = conversion == nil and meta.reason or nil,
            known       = self:GetKnownLevels(stat),
        })
    end

    table.sort(rows, function(a, b) return a.label < b.label end)
    return rows
end