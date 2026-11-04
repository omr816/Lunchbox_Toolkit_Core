--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Imbues
    Shaman weapon imbues, as a scoring layer on the weapon itself.

    A weapon's worth is not only in its stat block: a Windfury weapon is worth
    more the harder it swings, while Flametongue and Frostbrand gain from
    striking more often. This module holds that knowledge as data — one entry
    per imbue, each with weapon coefficients and a speed rule — and applies it
    to a weapon's weaponDPS / weaponAvgDamage / weaponSpeed channels before the
    profile's weights are applied.

    Three boundaries are deliberate:

      * it is off by default for non-Shamans, and it only ever runs when the
        character is a Shaman and either the build slot being scored has its
        own switch on or, for a slot that has not set one, the player has
        ticked the option (Settings -> "Score weapons using the chosen imbue");
      * it changes nothing that is stored: the adjusted values live in the
        score result, never in the item cache or the profile;
      * every number below is a starting point, marked provisional. They are
        preferences about which weapon to pick, not measured game mechanics.

    Which imbue applies is chosen per build slot, because the tank and the 2H
    PvP build want different ones.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Imbues = {}
LT.Imbues = Imbues
LT.Modules.Imbues = Imbues

Imbues.order = { "windfury", "flametongue", "frostbrand", "rockbiter", "none" }

-- The words the Settings option uses for itself. The Builds page repeats them
-- on each slot row so a slot's switch reads as the option it overrides, and
-- both places read this one string.
Imbues.SCORING_LABEL = "Score weapons using the chosen imbue"

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

-----------------------------------------------------------------------------
-- Definitions
--
-- weapon.dps / weapon.avgDamage multiply the channel before weighting.
-- speed describes the preference:
--   prefer = "slow"  step per second above `reference`, clamped
--   prefer = "fast"  step per second below `reference`, clamped
--   prefer = "band"  bonus inside low..high, penalty per second outside
-- `provisional = true` on all of them: these are stated preferences.
-----------------------------------------------------------------------------

Imbues.definitions = {
    windfury = {
        key = "windfury",
        label = "Windfury Weapon",
        summary = "Extra attacks scale from the swing, so weapon damage and slow speed rival strength.",
        weapon = { dps = 1.35, avgDamage = 2.45 },
        speed = { prefer = "slow", reference = 2.6, step = 0.20, min = 0.75, max = 1.30 },
        provisional = true,
        assumptions = "Windfury is modelled as a premium on weapon damage and DPS that "
            .. "grows with swing time, tuned so a slow weapon's per-hit damage reads "
            .. "roughly equal to one point of strength. The proc itself is not simulated.",
    },

    flametongue = {
        key = "flametongue",
        label = "Flametongue Weapon",
        summary = "Bonus fire damage per swing, so more swings means more damage.",
        weapon = { dps = 1.15, avgDamage = 0.95 },
        speed = { prefer = "fast", reference = 2.2, step = 0.06, min = 0.80, max = 1.20 },
        provisional = true,
        assumptions = "Flametongue is modelled as a per-swing bonus, so faster weapons "
            .. "gain and very slow weapons lose. The fire damage figure itself is not read "
            .. "from the client.",
    },

    frostbrand = {
        key = "frostbrand",
        label = "Frostbrand Weapon",
        summary = "Chance of Frost damage and a snare; a moderate speed is preferred.",
        weapon = { dps = 1.05, avgDamage = 1.00 },
        speed = { prefer = "band", low = 1.8, high = 2.3, step = 0.10, min = 0.70, max = 1.10 },
        provisional = true,
        assumptions = "Frostbrand is given a 1.8-2.3 second preference band, which is a "
            .. "stated preference and not a measured proc optimum: whether the proc chance "
            .. "is fixed per hit or adjusted for weapon speed is unknown on this client.",
    },

    rockbiter = {
        key = "rockbiter",
        label = "Rockbiter Weapon",
        summary = "Flat threat and attack power; no speed preference either way.",
        weapon = { dps = 1.20, avgDamage = 1.20 },
        speed = nil,
        provisional = true,
        assumptions = "Rockbiter is modelled as a flat weapon premium with no speed "
            .. "preference, because its threat is not derived from swing timing here.",
    },

    none = {
        key = "none",
        label = "No imbue",
        summary = "Score the weapon exactly as the client reports it.",
        weapon = { dps = 1.00, avgDamage = 1.00 },
        speed = nil,
        provisional = false,
        assumptions = "",
    },
}

function Imbues:GetDefinition(key)
    return self.definitions[tostring(key or ""):lower()] or nil
end

-- Cycles the definitions in a fixed order, for buttons and commands.
function Imbues:Next(key)
    local order = self.order
    local current = tostring(key or ""):lower()

    for position, candidate in ipairs(order) do
        if candidate == current then
            return order[(position % #order) + 1]
        end
    end

    return order[1]
end

function Imbues:Describe(key)
    local definition = self:GetDefinition(key)
    if not definition then return "no imbue" end
    return definition.label .. " — " .. definition.summary
end

-----------------------------------------------------------------------------
-- Eligibility
-----------------------------------------------------------------------------

-- Whether this slot scores its weapon through its imbue: the slot's own switch
-- first, then the Settings option. The second return says which one decided
-- ("slot" or "global") so the Builds page can show it without guessing again.
-- A nil build index means the active slot, the same as Builds:Get.
function Imbues:ResolveScoring(buildIndex)
    local build = LT.Builds and LT.Builds:Get(buildIndex)

    if build and type(build.scoreImbue) == "boolean" then
        return build.scoreImbue, "slot"
    end

    local options = LT.Database and LT.Database:GetOptions()
    return (options ~= nil and options.shamanImbueScoring == true), "global"
end

-- The full gate for one slot: the class requirement is absolute, and the
-- switch is the slot's own first, then the Settings option.
function Imbues:IsEnabledFor(buildIndex)
    local class = LT.player and LT.player.class
    if class ~= "SHAMAN" then return false end

    local scoring = self:ResolveScoring(buildIndex)
    return scoring == true
end

-- The same gate for the active slot, for commands and reminders that ask about
-- "the build in use" rather than about one slot.
function Imbues:IsEnabled()
    return self:IsEnabledFor(nil)
end

-- One line per build slot for the Builds page: whether that slot scores the
-- imbue, which imbue, and what decided it. The first words are the Settings
-- option's own wording, because that is the switch a slot overrides.
function Imbues:DescribeScoring(buildIndex)
    local scoring, source = self:ResolveScoring(buildIndex)
    local definition = self:ForKey(buildIndex)

    local state = scoring and "on" or "off"
    local origin
    if source == "slot" then
        origin = "set on this slot"
    else
        origin = "following the Settings switch"
    end

    return self.SCORING_LABEL .. " — " .. state .. ": "
        .. tostring(definition.label) .. " (" .. origin .. ")."
end

-- The imbue a build is scored with: its own choice first, then the option
-- default, then "none" so an unconfigured build behaves exactly as before.
function Imbues:ForKey(buildIndex)
    local build = LT.Builds and LT.Builds:Get(buildIndex)
    local key = build and build.imbue

    if not key then
        local options = LT.Database and LT.Database:GetOptions()
        key = options and options.shamanDefaultImbue
    end

    return self:GetDefinition(key) or self.definitions.none
end

function Imbues:SpeedMultiplier(definition, speed)
    local rule = definition and definition.speed
    if not rule then return 1 end

    local value = tonumber(speed)
    if not value or value <= 0 then return 1 end

    local step = rule.step or 0
    local multiplier = 1

    if rule.prefer == "slow" then
        multiplier = 1 + step * (value - (rule.reference or value))
    elseif rule.prefer == "fast" then
        multiplier = 1 + step * ((rule.reference or value) - value)
    elseif rule.prefer == "band" then
        local low = rule.low or 0
        local high = rule.high or low

        if value < low then
            multiplier = 1 - step * (low - value)
        elseif value > high then
            multiplier = 1 - step * (value - high)
        else
            multiplier = 1 + step * ((high - low) / 2)
        end
    end

    return clamp(multiplier, rule.min or 0.5, rule.max or 1.5)
end

-----------------------------------------------------------------------------
-- Applying it
-----------------------------------------------------------------------------

-- Returns a copy of the item's stat channels with the weapon ones adjusted, plus
-- the explanation lines the tooltip and /lt score print. An item with no weapon
-- channels is returned untouched, so the caller never has to know whether the
-- link was a weapon.
function Imbues:AdjustStats(stats, buildIndex)
    local notes = {}

    if type(stats) ~= "table" then return stats, notes end
    if not self:IsEnabledFor(buildIndex) then return stats, notes end

    if stats.weaponDPS == nil and stats.weaponAvgDamage == nil then
        return stats, notes
    end

    local definition = self:ForKey(buildIndex)
    if not definition or definition.key == "none" then return stats, notes end

    local coefficients = definition.weapon or {}
    local adjusted = {}
    for stat, value in pairs(stats) do adjusted[stat] = value end

    if adjusted.weaponDPS then
        adjusted.weaponDPS = adjusted.weaponDPS * (coefficients.dps or 1)
    end

    if adjusted.weaponAvgDamage then
        adjusted.weaponAvgDamage = adjusted.weaponAvgDamage * (coefficients.avgDamage or 1)
    end

    local speedMultiplier = self:SpeedMultiplier(definition, adjusted.weaponSpeed)
    if speedMultiplier ~= 1 then
        -- The speed rule is expressed as a premium or penalty on weapon damage:
        -- speed itself is a property of the weapon, not something the player
        -- gains, so it must not be scored directly.
        if adjusted.weaponAvgDamage then
            adjusted.weaponAvgDamage = adjusted.weaponAvgDamage * speedMultiplier
        elseif adjusted.weaponDPS then
            adjusted.weaponDPS = adjusted.weaponDPS * speedMultiplier
        end
    end

    table.insert(notes, LT.Palette:Wrap("muted", "  imbue: " .. tostring(definition.label)
        .. " — weapon DPS x" .. LT:FormatNumber(coefficients.dps or 1, 2)
        .. ", weapon damage x" .. LT:FormatNumber(coefficients.avgDamage or 1, 2)
        .. (speedMultiplier ~= 1
            and (", speed x" .. LT:FormatNumber(speedMultiplier, 2))
            or "")
        .. (definition.provisional and " (provisional)" or "")))

    return adjusted, notes
end