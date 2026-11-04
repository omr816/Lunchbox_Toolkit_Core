--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — ClassPacks
    The registry that every Classes\<Class>.lua file registers into.

    Decision 7 (settled 2026-10-27): class DATA lives in the core, one file per
    class, and must work with no plugin folder installed — the wizard and the
    fresh-install defaults depend on it. Class BEHAVIOUR that needs events or
    scanning (poisons, procs) is what an optional plugin is for. A pack is
    therefore data only: no frames, no event handlers, no stat weights.

    A pack may carry:
      specRoles  spec name -> role name, or -> array of role names. This is the
                 link ClassData lacks: classes[X].specs is a flat list, so
                 nothing today knows that Feral is played as tank or damage.
      templates  array of starter configurations, each a
                 { name, spec, role, context, weaponSetup, imbue } record.
                 `imbue` is optional because only a Shaman scores a weapon
                 through a weapon imbue; when present it must be a key from
                 Imbues.lua. A template never points at a profile key: the
                 bundled base profile is resolved from the class, role and
                 context it names, so a pack can never hand one player's
                 weights to another.
      buffs      array of maintenance buffs (seals, aspects, shouts, stances,
                 armour, forms). Data only: ClassData:RegisterBuffDefs builds
                 the BuffMonitor definition from an entry. One option key per
                 buff, and it must already exist in Database.defaultOptions()
                 with the same default.
      quirks     array of class scoring quirks. Each one points at a stat the
                 class already weights, or states why it cannot be valued yet.
                 A quirk never introduces a weight key or a stat channel.

    Registration is validated against ClassData and refused, not corrected, on
    an unknown value: a typo then shows up in /lt test instead of quietly
    producing an empty wizard step. A refused pack leaves the registry
    untouched. Problems are kept in ClassPacks.problems.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local ClassPacks = {}
LT.ClassPacks = ClassPacks
LT.Modules.ClassPacks = ClassPacks

ClassPacks.API_VERSION = 1

ClassPacks.packs    = {}
ClassPacks.order    = {}
ClassPacks.problems = {}

local function remember(classToken, message)
    table.insert(ClassPacks.problems, tostring(classToken) .. ": " .. tostring(message))
    LT:Warn("class pack " .. tostring(classToken) .. " refused — " .. tostring(message))
end

local function roleExists(role)
    for _, known in ipairs(LT.Roles or {}) do
        if known == role then return true end
    end
    return false
end

-- A role is only valid for a class if that class lists it. Without this, any
-- global role passes and a typo such as MAGE = { Frost = "Healer" } registers.
local function classHasRole(definition, role)
    for _, known in ipairs((definition and definition.roles) or {}) do
        if known == role then return true end
    end
    return false
end

local function contextExists(context)
    for _, known in ipairs(LT.Contexts or {}) do
        if known.key == context then return true end
    end
    return false
end

local function setupExists(setupKey)
    if not LT.GetWeaponSetupDefinition then return false end
    return LT:GetWeaponSetupDefinition(setupKey) ~= nil
end

local function specExists(definition, spec)
    if spec == "Any" then return true end
    for _, known in ipairs(definition.specs or {}) do
        if known == spec then return true end
    end
    return false
end

-- Imbues.lua loads after every class pack, so its definition table is not there
-- while packs register. ClassData's own weapon-imbue option list is the same set
-- of keys (title case) and loads before this file, so it answers the question at
-- registration time; once Imbues has loaded, its table is the authority.
local function imbueExists(imbueKey, definition)
    local key = tostring(imbueKey or ""):lower()

    if LT.Imbues and type(LT.Imbues.GetDefinition) == "function" then
        return LT.Imbues:GetDefinition(key) ~= nil
    end

    for _, option in ipairs(definition.options or {}) do
        if option.key == "weaponImbueMain" then
            for _, value in ipairs(option.values or {}) do
                if tostring(value):lower() == key then return true end
            end
        end
    end

    return false
end

-- specRoles may be written as spec = "Tank" or spec = { "Damage", "Tank" }.
-- Both are stored as arrays so callers only ever deal with one shape.
local function normalizeSpecRoles(classToken, definition, specRoles, problems)
    local normalized = {}

    for spec, roles in pairs(specRoles) do
        local list = type(roles) == "table" and roles or { roles }

        if not specExists(definition, spec) then
            table.insert(problems, "unknown spec \"" .. tostring(spec) .. "\" for " .. classToken)
        elseif #list == 0 then
            table.insert(problems, "spec \"" .. tostring(spec) .. "\" has no role")
        else
            local clean = {}
            for _, role in ipairs(list) do
                if not roleExists(role) then
                    table.insert(problems, "unknown role \"" .. tostring(role)
                        .. "\" on spec \"" .. tostring(spec) .. "\"")
                elseif not classHasRole(definition, role) then
                    table.insert(problems, "role \"" .. tostring(role) .. "\" is not one of "
                        .. classToken .. "'s roles, on spec \"" .. tostring(spec) .. "\"")
                else
                    table.insert(clean, role)
                end
            end
            if #clean > 0 then normalized[spec] = clean end
        end
    end

    return normalized
end

local function validateTemplates(classToken, definition, templates, problems)
    if type(templates) ~= "table" then
        table.insert(problems, "templates must be a list")
        return {}
    end

    for index, template in ipairs(templates) do
        local label = "template " .. tostring(index)

        if type(template) ~= "table" then
            table.insert(problems, label .. " is not a table")
        else
            if type(template.name) ~= "string" or template.name == "" then
                table.insert(problems, label .. " has no name")
            end
            if not specExists(definition, template.spec or "Any") then
                table.insert(problems, label .. " uses unknown spec \""
                    .. tostring(template.spec) .. "\"")
            end
            if template.role and not roleExists(template.role) then
                table.insert(problems, label .. " uses unknown role \""
                    .. tostring(template.role) .. "\"")
            elseif template.role and not classHasRole(definition, template.role) then
                table.insert(problems, label .. " uses role \"" .. tostring(template.role)
                    .. "\", which is not one of " .. classToken .. "'s roles")
            end
            if template.context and not contextExists(template.context) then
                table.insert(problems, label .. " uses unknown context \""
                    .. tostring(template.context) .. "\"")
            end
            if template.weaponSetup and not setupExists(template.weaponSetup) then
                table.insert(problems, label .. " uses unknown weapon setup \""
                    .. tostring(template.weaponSetup) .. "\"")
            end
            if template.imbue ~= nil and not imbueExists(template.imbue, definition) then
                table.insert(problems, label .. " uses unknown imbue \""
                    .. tostring(template.imbue) .. "\"")
            end
            -- A template must hand over a choice, never a saved profile.
            if template.profileKey ~= nil then
                table.insert(problems, label .. " must not name a profile key")
            end
        end
    end

    return templates
end

-- The `usable` block: armour/weapon types with the level each becomes usable, or
-- never = true. Validated against Usability's own subclass tables, so a typo such
-- as "Male" is refused instead of silently turning every mail item into "unknown".
local function validateUsable(usable, problems)
    if usable == nil then return {} end

    if type(usable) ~= "table" then
        table.insert(problems, "usable must be a table")
        return {}
    end

    local clean = {}

    for family, rules in pairs(usable) do
        if not (LT.Usability and LT.Usability.IsKnownSubclass) then
            table.insert(problems, "Usability is not loaded")
        elseif family ~= "armour" and family ~= "weapons" then
            table.insert(problems, "unknown usable family \"" .. tostring(family) .. "\"")
        elseif type(rules) ~= "table" then
            table.insert(problems, "usable." .. tostring(family) .. " must be a table")
        else
            clean[family] = {}

            for key, rule in pairs(rules) do
                local label = "usable." .. tostring(family) .. "." .. tostring(key)

                if not LT.Usability:IsKnownSubclass(family, key) then
                    table.insert(problems, label .. " is not a known " .. tostring(family) .. " type")
                elseif rule == true then
                    clean[family][key] = true
                elseif type(rule) ~= "table" then
                    table.insert(problems, label .. " needs true, { fromLevel = n } or { never = true }")
                elseif rule.never and rule.fromLevel then
                    table.insert(problems, label .. " cannot be both never and fromLevel")
                elseif rule.never then
                    clean[family][key] = { never = true }
                elseif tonumber(rule.fromLevel) then
                    local from = tonumber(rule.fromLevel)
                    if from < 1 or from ~= math.floor(from) then
                        table.insert(problems, label .. " needs a whole level of 1 or more")
                    else
                        clean[family][key] = { fromLevel = from }
                    end
                else
                    table.insert(problems, label .. " needs true, { fromLevel = n } or { never = true }")
                end
            end
        end
    end

    return clean
end

------------------------------------------------------------------------------
-- Buffs and quirks (Decision 9)
--
-- Both blocks are data, and both are validated here rather than at the point of
-- use: a buff that cannot become a BuffMonitor definition is refused while the
-- pack is being registered, and a quirk can only name a stat this class already
-- scores. Nothing in either block can create a weight key or a stat channel.
------------------------------------------------------------------------------

local function copyList(list)
    local out = {}
    for index, value in ipairs(list or {}) do
        out[index] = value
    end
    return out
end

local function isNonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

-- Option keys are per character, not per class: two packs sharing one would
-- switch two reminders with one checkbox. The keys already in the registry are
-- the ones to avoid; the pack being validated is not in it yet.
local function rememberedOptionKeys()
    local used = {}
    for _, orderToken in ipairs(ClassPacks.order) do
        local stored = ClassPacks.packs[orderToken]
        for _, buff in ipairs((stored and stored.buffs) or {}) do
            used[buff.optionKey] = orderToken
        end
    end
    return used
end

local function defaultOptionsTable()
    if type(LT.Database) == "table" and type(LT.Database.defaultOptions) == "function" then
        return LT.Database.defaultOptions()
    end
    return nil
end

local function validateBuffs(buffs, problems)
    if buffs == nil then return {} end

    if type(buffs) ~= "table" then
        table.insert(problems, "buffs must be a table")
        return {}
    end

    local defaults = defaultOptionsTable()
    local usedByOtherPacks = rememberedOptionKeys()
    local clean = {}
    local seenIds, seenKeys = {}, {}

    for index, entry in ipairs(buffs) do
        local label = "buffs[" .. tostring(index) .. "]"

        if type(entry) ~= "table" then
            table.insert(problems, label .. " must be a table")
        else
            local id = entry.id
            if not isNonEmptyString(id) then
                table.insert(problems, label .. " needs an id")
            elseif seenIds[id] then
                table.insert(problems, label .. " repeats the id \"" .. id .. "\"")
            else
                seenIds[id] = true
            end

            if not isNonEmptyString(entry.label) then
                table.insert(problems, label .. " needs a label")
            end

            local optionKey = entry.optionKey
            if not isNonEmptyString(optionKey) then
                table.insert(problems, label .. " needs an optionKey")
            elseif seenKeys[optionKey] then
                table.insert(problems, label .. " repeats the option key \"" .. optionKey .. "\"")
            elseif usedByOtherPacks[optionKey] then
                table.insert(problems, label .. " uses the option key \"" .. optionKey
                    .. "\", which " .. tostring(usedByOtherPacks[optionKey]) .. " already owns")
                seenKeys[optionKey] = true
            else
                seenKeys[optionKey] = true
                -- The key must already exist in the options table, with the same
                -- default. The database is the single owner of option keys, so a
                -- pack can never introduce one by itself.
                if defaults then
                    if defaults[optionKey] == nil then
                        table.insert(problems, label .. " option key \"" .. optionKey
                            .. "\" is not in Database.defaultOptions()")
                    elseif entry.default ~= nil and defaults[optionKey] ~= entry.default then
                        table.insert(problems, label .. " default for \"" .. optionKey
                            .. "\" disagrees with Database.defaultOptions()")
                    end
                end
            end

            if not isNonEmptyString(entry.help) then
                table.insert(problems, label .. " needs a help line")
            end
            if not isNonEmptyString(entry.message) then
                table.insert(problems, label .. " needs a message")
            end

            local auras = entry.auras
            if auras ~= nil then
                if type(auras) ~= "table" then
                    table.insert(problems, label .. ".auras must be a table")
                    auras = nil
                else
                    for auraIndex, aura in ipairs(auras) do
                        if not isNonEmptyString(aura) then
                            table.insert(problems, label .. ".auras[" .. tostring(auraIndex)
                                .. "] must be a non-empty string")
                        end
                    end
                end
            end

            local spells = entry.spells
            if spells ~= nil then
                if type(spells) ~= "table" then
                    table.insert(problems, label .. ".spells must be a table")
                    spells = nil
                else
                    for spellIndex, spell in ipairs(spells) do
                        -- An id is only ever trusted when it is a positive whole
                        -- number: nothing that could be a guess is accepted.
                        if type(spell) ~= "number" or spell <= 0 or spell ~= math.floor(spell) then
                            table.insert(problems, label .. ".spells[" .. tostring(spellIndex)
                                .. "] must be a positive whole spell id")
                        end
                    end
                end
            end

            if type(entry.expiringThreshold) ~= "number" or entry.expiringThreshold <= 0 then
                table.insert(problems, label .. " needs a positive expiringThreshold in ms")
            end
            if type(entry.default) ~= "boolean" then
                table.insert(problems, label .. " needs default = true or false")
            end

            table.insert(clean, {
                id                = id,
                label             = entry.label,
                optionKey         = optionKey,
                help              = entry.help,
                auras             = copyList(auras),
                spells            = copyList(spells),
                message           = entry.message,
                expiringThreshold = entry.expiringThreshold,
                default           = entry.default,
            })
        end
    end

    return clean
end

-- True when this class already weights the stat somewhere, in a role table or a
-- spec table. That is the whole rule for a valued quirk: point at a channel the
-- scorer already scores for this class, never at a new one.
local function classWeightsStat(classToken, stat)
    local definition = LT.ClassData and LT.ClassData:GetClass(classToken)
    if type(definition) ~= "table" then return false end

    local function named(weights)
        return type(weights) == "table" and weights[stat] ~= nil
    end

    for _, weights in pairs(definition.weights or {}) do
        if named(weights) then return true end
    end
    for _, roles in pairs(definition.specWeights or {}) do
        if type(roles) == "table" then
            for _, weights in pairs(roles) do
                if named(weights) then return true end
            end
        end
    end
    return false
end

local function validateQuirks(classToken, quirks, problems)
    if quirks == nil then return {} end

    if type(quirks) ~= "table" then
        table.insert(problems, "quirks must be a table")
        return {}
    end

    local clean = {}
    local seenIds = {}

    for index, entry in ipairs(quirks) do
        local label = "quirks[" .. tostring(index) .. "]"

        if type(entry) ~= "table" then
            table.insert(problems, label .. " must be a table")
        else
            if not isNonEmptyString(entry.id) then
                table.insert(problems, label .. " needs an id")
            elseif seenIds[entry.id] then
                table.insert(problems, label .. " repeats the id \"" .. entry.id .. "\"")
            else
                seenIds[entry.id] = true
            end

            if not isNonEmptyString(entry.label) then
                table.insert(problems, label .. " needs a label")
            end
            if not isNonEmptyString(entry.note) then
                table.insert(problems, label .. " needs a note")
            end

            local hasStat = entry.stat ~= nil
            local hasUnvalued = entry.unvalued ~= nil

            if hasStat == hasUnvalued then
                table.insert(problems, label .. " must carry exactly one of stat or unvalued")
            elseif hasStat then
                if not isNonEmptyString(entry.stat) then
                    table.insert(problems, label .. ".stat must be a stat key")
                elseif not classWeightsStat(classToken, entry.stat) then
                    table.insert(problems, label .. " names \"" .. tostring(entry.stat)
                        .. "\", which " .. classToken .. " does not weight")
                elseif LT.StatLabels ~= nil and LT.StatLabels[entry.stat] == nil then
                    table.insert(problems, label .. " names \"" .. tostring(entry.stat)
                        .. "\", which is not a channel the scorer knows")
                end
            elseif not isNonEmptyString(entry.unvalued) then
                table.insert(problems, label .. ".unvalued must say why it cannot be valued")
            end

            table.insert(clean, {
                id       = entry.id,
                label    = entry.label,
                spec     = isNonEmptyString(entry.spec) and entry.spec or nil,
                stat     = hasStat and entry.stat or nil,
                unvalued = hasUnvalued and entry.unvalued or nil,
                note     = entry.note,
            })
        end
    end

    return clean
end

-- The same checks Register makes, made without touching the registry: nothing is
-- stored, nothing is written to chat and no problem is recorded. /lt test uses it
-- to prove a bad pack is refused without leaving a probe pack behind.
--
-- Returns ok, message, problems, clean — where `problems` is always a table and
-- `clean` (specRoles / templates / usable / buffs / quirks, normalized) is only
-- set when ok.
function ClassPacks:Validate(classToken, pack)
    if type(classToken) ~= "string" or classToken == "" then
        return false, "a pack needs a class token", {}
    end
    if type(pack) ~= "table" then
        return false, "the pack for " .. classToken .. " is not a table", {}
    end
    if pack.apiVersion and pack.apiVersion ~= self.API_VERSION then
        return false, "apiVersion " .. tostring(pack.apiVersion) .. " is not "
            .. tostring(self.API_VERSION), {}
    end
    if not (LT.ClassData and LT.ClassData.GetClass) then
        return false, "ClassData is not loaded", {}
    end

    local definition = LT.ClassData:GetClass(classToken)
    if not definition then
        return false, "no class definition for " .. classToken, {}
    end

    local problems = {}
    local specRoles = normalizeSpecRoles(classToken, definition,
        type(pack.specRoles) == "table" and pack.specRoles or {}, problems)
    local templates = validateTemplates(classToken, definition, pack.templates or {}, problems)
    local usable = validateUsable(pack.usable, problems)
    local buffs = validateBuffs(pack.buffs, problems)
    local quirks = validateQuirks(classToken, pack.quirks, problems)

    if #problems > 0 then
        return false, problems[1], problems
    end

    return true, nil, problems, {
        specRoles = specRoles,
        templates = templates,
        usable    = usable,
        buffs     = buffs,
        quirks    = quirks,
    }
end

function ClassPacks:Register(classToken, pack)
    if type(classToken) == "string" and self.packs[classToken] then
        return false, "a pack for " .. classToken .. " is already registered"
    end

    local ok, message, problems, clean = self:Validate(classToken, pack)

    -- Refused as a whole: a half-registered pack would be worse than none.
    if not ok then
        for _, entry in ipairs(problems) do
            remember(classToken, entry)
        end
        return false, message
    end

    self.packs[classToken] = {
        class      = classToken,
        apiVersion = self.API_VERSION,
        specRoles  = clean.specRoles,
        templates  = clean.templates,
        usable     = clean.usable,
        buffs      = clean.buffs,
        quirks     = clean.quirks,
    }
    table.insert(self.order, classToken)

    return true
end

function ClassPacks:Get(classToken)
    return self.packs[classToken]
end

function ClassPacks:GetOrder()
    return self.order
end

function ClassPacks:GetProblems()
    return self.problems
end

-- Every role the pack allows a spec to be played as, as an array.
-- nil means the pack says nothing about that spec.
function ClassPacks:GetRolesForSpec(classToken, spec)
    local pack = self.packs[classToken]
    local roles = pack and pack.specRoles and pack.specRoles[spec]
    return roles
end

function ClassPacks:GetSpecRoles(classToken)
    local pack = self.packs[classToken]
    return pack and pack.specRoles or nil
end

function ClassPacks:GetTemplates(classToken)
    local pack = self.packs[classToken]
    return pack and pack.templates or {}
end

-- The starter a class pack recommends for levelling. Derived from the list the
-- pack already ships rather than authored a second time, so a pack that gains
-- or reorders a starter moves the recommendation with it: a template whose name
-- begins with "Levelling" wins (the Rogue pack names its three that way), then
-- the first PvE starter for a damage role, then the first PvE starter at all.
-- Returns the template table itself (name, spec, role, context, weaponSetup),
-- or nil when the pack ships no PvE starter. Nothing is invented here: the
-- answer is always a row the pack already carries.
function ClassPacks:GetLevelling(classToken)
    local damage, any

    for _, template in ipairs(self:GetTemplates(classToken)) do
        if type(template) == "table"
            and (template.context == nil or template.context == "PVE") then
            local name = type(template.name) == "string" and template.name:lower() or ""
            if name:sub(1, 9) == "levelling" then return template end
            if not damage and template.role == "Damage" then damage = template end
            if not any then any = template end
        end
    end

    return damage or any
end

function ClassPacks:GetUsable(classToken)
    local pack = self.packs[classToken]
    return pack and pack.usable or nil
end

-- The maintenance buffs a class declared, in registration order. An empty array
-- (never nil) keeps callers from branching on a missing block.
function ClassPacks:GetBuffs(classToken)
    local pack = self.packs[classToken]
    return (pack and pack.buffs) or {}
end

-- The scoring quirks a class declared, in registration order.
function ClassPacks:GetQuirks(classToken)
    local pack = self.packs[classToken]
    return (pack and pack.quirks) or {}
end

-- Whether this class already weights the stat somewhere. Public so the
-- self-test hook asks the same question validation asked: a quirk may only
-- point at a channel the class already scores.
function ClassPacks:StatIsWeighted(classToken, stat)
    return classWeightsStat(classToken, stat)
end
