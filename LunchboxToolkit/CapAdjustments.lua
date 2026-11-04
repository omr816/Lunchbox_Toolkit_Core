--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — CapAdjustments
    Tooltip-first reader for cap-moving talents and racials.

    A talent or racial that reduces a hit / expertise / weapon-skill cap is
    registered through Caps:RegisterAdjustment so patch changes are reflected
    from the live tooltip, not from a re-scraped static table. The effect is
    read from the spell's tooltip text (C_Spell.GetSpellDescription, then the
    GetSpellDescription global, with a GameTooltip:SetSpellByID scan fallback)
    and detected by three patterns:

      hit           "+N% ... hit"  (a percent chance-to-hit bonus; the spell
                     variant maps to the spellHit channel)
      expertise     "+N expertise" / "expertise rating"
      weapon skill  "+N ... skill"  (converted: 1 skill = 0.04% hit and 0.04%
                     expertise reduction)

    English locale assumed (enUS). Every client read is pcall'd and
    secret-guarded; a missing API degrades to nil rather than guessing.

    The static effect mapping is intentionally absent here: it is only used by
    the Racials plugin for the one effect the tooltip hides (passive weapon
    skill with no number in its text). See the report for the full fallback
    list.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local CapAdjustments = {}
LT.CapAdjustments = CapAdjustments
LT.Modules = LT.Modules or {}
LT.Modules.CapAdjustments = CapAdjustments

-- 1 weapon skill point reduces the miss chance (hit) and the dodge/parry
-- chance (expertise) by 0.04% each. This is the standard Classic conversion;
-- it is not measured in this client.
CapAdjustments.SKILL_TO_PERCENT = 0.04
CapAdjustments.LOCALE = "enUS"

CapAdjustments.TALENT_SOURCE_PREFIX = "talent:"
CapAdjustments.RACIAL_SOURCE_PREFIX = "racial:"

------------------------------------------------------------------------------
-- Guards
------------------------------------------------------------------------------

local function isSecret(value)
    if type(LT.IsSecret) == "function" then
        local ok, result = pcall(LT.IsSecret, LT, value)
        if ok and result == true then return true end
        return false
    end
    local checker = rawget(_G, "issecretvalue")
    if type(checker) ~= "function" then return false end
    local ok, result = pcall(checker, value)
    return ok and result == true
end

local function safeText(value)
    if type(value) ~= "string" or value == "" then return nil end
    if isSecret(value) then return nil end
    return value
end

local function toNumber(value)
    if value == nil or isSecret(value) then return nil end
    -- A sentence period can end up inside a [%d%.]+ capture ("by 3."), so strip
    -- trailing dots before converting; this also keeps "3.5." readable as 3.5.
    if type(value) == "string" then
        value = value:gsub("%.+$", "")
    end
    return tonumber(value)
end

------------------------------------------------------------------------------
-- Pure parsing
------------------------------------------------------------------------------

-- Fold newlines into spaces and collapse whitespace so the patterns below can
-- match a phrase that wraps across lines but can never leak past a line break
-- into an unrelated sentence.
local function flatten(text)
    if type(text) ~= "string" then return "" end
    return text:gsub("[\r\n]+", " "):gsub("%s+", " ")
end

local function lower(text)
    if type(text) ~= "string" then return "" end
    return text:lower()
end

-- "hit ... by N%" — "chance to hit by 3%", "hit chance by 3%",
-- "chance to hit with off-hand attacks by 10%". Falls back to "N% ... hit".
local function findHitPercent(t)
    local value = t:match("hit[^%%]*by%s+([%d%.]+)%%")
    if value then return toNumber(value), t:find("spells?") ~= nil end
    value = t:match("([%d%.]+)%%[^%%]*hit")
    return toNumber(value), value and (t:find("spells?") ~= nil)
end

-- "+N expertise", "N expertise", "expertise rating N", "expertise by N".
local function findExpertise(t)
    return toNumber(t:match("([%d%.]+)%s+expertise")                     -- "+N expertise"
        or t:match("expertise%s+rating%s+[%+%-]*%s*([%d%.]+)")           -- "expertise rating N"
        or t:match("expertise%s+rating[^%%]*by%s+([%d%.]+)")             -- "expertise rating ... by N"
        or t:match("expertise%s+by%s+([%d%.]+)"))                        -- "expertise by N"
end

-- Weapon skill: "skill with <weapons> by N" (unambiguous), then "N skill" and
-- "skill ... by N". "Defense Skill" is the defence cap, not weapon skill, so it
-- is rejected wherever the phrasing is generic.
local function findWeaponSkill(t)
    local value = t:match("skill%s+with[^%%]*by%s+([%d%.]+)")
    if value then return toNumber(value) end

    local defenseSkill = t:find("defen[cs]e%s+skill") ~= nil

    value = t:match("([%d%.]+)%s+[%a%s%-']*skill")
    if value and not defenseSkill then return toNumber(value) end

    value = t:match("skill[^%%]*by%s+([%d%.]+)")
    if value and not defenseSkill then return toNumber(value) end

    return nil
end

-- Pure: parse tooltip text into cap deltas. Returns nil, or an array of
-- { stat, delta, detail } where delta is positive = cap reduced. Weapon skill
-- produces two entries (hit and expertise).
function CapAdjustments.ParseText(text)
    local flat = flatten(safeText(text) or "")
    if flat == "" then return nil end
    local t = lower(flat)

    local results = {}
    local seen = {}

    local function add(stat, delta, detail)
        if not stat or delta == nil then return end
        delta = toNumber(delta)
        if not delta or delta <= 0 then return end
        if seen[stat] then return end
        seen[stat] = true
        results[#results + 1] = { stat = stat, delta = delta, detail = detail or stat }
    end

    -- 1. hit / spell hit
    local hitValue, hitIsSpell = findHitPercent(t)
    if hitValue then
        if hitIsSpell then
            add("spellHit", hitValue, "+" .. tostring(hitValue) .. "% spell hit")
        else
            add("hit", hitValue, "+" .. tostring(hitValue) .. "% hit")
        end
    end

    -- 2. expertise
    local expertise = findExpertise(t)
    if expertise then
        add("expertise", expertise, "+" .. tostring(expertise) .. " expertise")
    end

    -- 3. weapon skill -> hit + expertise
    local skill = findWeaponSkill(t)
    if skill then
        local each = skill * CapAdjustments.SKILL_TO_PERCENT
        local note = "+" .. tostring(skill)
            .. " weapon skill (1 skill = 0.04% hit / 0.04% expertise)"
        add("hit", each, note)
        add("expertise", each, note)
    end

    if #results == 0 then return nil end
    return results
end

------------------------------------------------------------------------------
-- Tooltip reading
------------------------------------------------------------------------------

local function scanTooltipLines(tooltip)
    local numOk, numLines = pcall(function() return tooltip:NumLines() end)
    if not numOk then return nil end

    local count = toNumber(numLines) or 0
    if count <= 0 then return nil end

    local lines = {}
    for i = 1, math.min(count, 30) do
        for _, side in ipairs({ "Left", "Right" }) do
            local region = rawget(_G, "GameTooltipText" .. side .. i)
            if type(region) == "table" and type(region.GetText) == "function" then
                local ok, text = pcall(region.GetText, region)
                text = safeText(text)
                if ok and text then lines[#lines + 1] = text end
            end
        end
    end

    if #lines == 0 then return nil end
    return table.concat(lines, "\n")
end

-- Returns the tooltip text for a spell id, or nil when no API answers.
local function readTooltip(spellID)
    local id = toNumber(spellID)
    if not id then return nil end

    -- Primary: C_Spell.GetSpellDescription, then the global.
    local getDescription
    if type(C_Spell) == "table" and type(C_Spell.GetSpellDescription) == "function" then
        getDescription = C_Spell.GetSpellDescription
    elseif type(GetSpellDescription) == "function" then
        getDescription = GetSpellDescription
    end
    if type(getDescription) == "function" then
        local ok, text = pcall(getDescription, id)
        text = safeText(text)
        if ok and text then return text end
    end

    -- Fallback: GameTooltip:SetSpellByID + scan lines.
    local tooltip = rawget(_G, "GameTooltip")
    if type(tooltip) == "table" and type(tooltip.SetSpellByID) == "function" then
        local okSet = pcall(tooltip.SetSpellByID, tooltip, id)
        if okSet then
            local lines = scanTooltipLines(tooltip)
            if type(tooltip.Hide) == "function" then pcall(tooltip.Hide, tooltip) end
            if lines then return lines end
        end
    end

    return nil
end

-- Returns nil, or an array of { stat, delta, source, reason } for a spell id.
function CapAdjustments:Detect(spellID, source)
    local text = readTooltip(spellID)
    if not text then return nil end

    local parsed = CapAdjustments.ParseText(text)
    if not parsed then return nil end

    local sourceText = tostring(source or ("spell:" .. tostring(spellID)))
    local out = {}
    for _, entry in ipairs(parsed) do
        out[#out + 1] = {
            stat   = entry.stat,
            delta  = entry.delta,
            source = sourceText,
            reason = "tooltip: " .. tostring(entry.detail),
        }
    end
    return out
end

------------------------------------------------------------------------------
-- Registration through Caps
------------------------------------------------------------------------------

-- Register a list of { stat, delta, source, reason } and remove any prior entry
-- whose source begins with `prefix`. The removal is what makes a respec that
-- drops a talent (or a changed racial) leave no stale cap reduction behind.
function CapAdjustments:RegisterList(list, prefix)
    local caps = LT.Caps
    if type(caps) ~= "table" or type(caps.RegisterAdjustment) ~= "function" then
        return 0
    end

    prefix = tostring(prefix or "")
    local changed = false

    if prefix ~= "" and type(caps.adjustments) == "table" then
        for i = #caps.adjustments, 1, -1 do
            local entry = caps.adjustments[i]
            if type(entry) == "table" and type(entry.source) == "string"
                and entry.source:sub(1, #prefix) == prefix then
                table.remove(caps.adjustments, i)
                changed = true
            end
        end
    end

    local count = 0
    for _, adj in ipairs(list or {}) do
        if type(adj) == "table" then
            if caps:RegisterAdjustment(adj.stat, adj.delta, adj.source, adj.reason) then
                count = count + 1
            end
        end
    end

    -- RegisterAdjustment invalidates on every add; a removal-only pass must
    -- invalidate once itself so the cached cap targets are rebuilt.
    if changed and LT.Profiles and type(LT.Profiles.Invalidate) == "function" then
        pcall(LT.Profiles.Invalidate, LT.Profiles)
    end

    return count
end

------------------------------------------------------------------------------
-- Talent side (core)
------------------------------------------------------------------------------

local function normalizeName(name)
    if type(name) ~= "string" then return "" end
    return name:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- class token -> normalised name -> spell id (first match wins, as in
-- TalentValuation).
local function buildSpellIndex(classToken)
    local tv = LT.TalentValues
    if type(tv) ~= "table" or type(tv.classes) ~= "table" then return nil end
    local classData = tv.classes[classToken]
    if type(classData) ~= "table" or type(classData.trees) ~= "table" then return nil end

    local index = {}
    for _, tree in ipairs(classData.trees) do
        if type(tree) == "table" and type(tree.talents) == "table" then
            for _, talent in ipairs(tree.talents) do
                if type(talent) == "table" and type(talent.spell) == "number" then
                    local key = normalizeName(talent.name)
                    if key ~= "" and index[key] == nil then
                        index[key] = talent.spell
                    end
                end
            end
        end
    end
    return index
end

local function readClassToken()
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

-- Read the chosen talents, run each learned talent's tooltip through the
-- parser, and register every cap-moving effect via Caps:RegisterAdjustment.
-- Returns the number of adjustments registered, and nil on success or a reason
-- on failure.
function CapAdjustments:RegisterTalents()
    local caps = LT.Caps
    if type(caps) ~= "table" or type(caps.RegisterAdjustment) ~= "function" then
        return 0, "Caps is not available"
    end

    local classToken = readClassToken()
    if not classToken then return 0, "no class token" end

    local trees, source
    if type(LT.SpecAdvisor) == "table" and type(LT.SpecAdvisor.Read) == "function" then
        local ok, a, b = pcall(LT.SpecAdvisor.Read, LT.SpecAdvisor)
        if not ok then return 0, "SpecAdvisor:Read failed: " .. tostring(a) end
        trees, source = a, b
    end
    if type(trees) ~= "table" then
        return 0, "no talent trees (" .. tostring(source) .. ")"
    end

    local index = buildSpellIndex(classToken)
    if not index then return 0, "no TalentValues data for " .. tostring(classToken) end

    local list = {}
    for _, tree in ipairs(trees) do
        if type(tree) == "table" and type(tree.talents) == "table" then
            for _, talent in ipairs(tree.talents) do
                if type(talent) == "table" and type(talent.name) == "string" then
                    local rank = toNumber(talent.rank) or 0
                    if rank > 0 then
                        local spellID = index[normalizeName(talent.name)]
                        if spellID then
                            local found = self:Detect(spellID, self.TALENT_SOURCE_PREFIX .. talent.name)
                            if found then
                                for _, adj in ipairs(found) do
                                    list[#list + 1] = adj
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return self:RegisterList(list, self.TALENT_SOURCE_PREFIX), nil
end

function CapAdjustments:Refresh()
    local count, err = self:RegisterTalents()
    if err then
        LT:Debug("CapAdjustments: " .. tostring(err))
    elseif count > 0 then
        LT:Debug("CapAdjustments: registered " .. tostring(count) .. " talent cap adjustment(s).")
    end
end

function CapAdjustments:OnPlayerLogin()
    self:Refresh()
end

function CapAdjustments:OnEnterWorld()
    self:Refresh()
end

-- A respec or a spent/refunded point re-runs the read. Registration is
-- idempotent (stale sources are cleared first), so extra runs are harmless.
if type(LT.On) == "function" then
    pcall(LT.On, LT, "TALENTS_CHANGED", function() CapAdjustments:Refresh() end, "CapAdjustments")
end
