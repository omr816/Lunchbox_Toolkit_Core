--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Wizard
    The build setup wizard: Role -> Spec -> Context -> Starter build.

    Four rules shape this window:

      * Only this character's class is offered anything. Roles and specs come
        from that class's ClassPacks entry; the class definition supplies the
        fallback when a pack has not authored specRoles yet. No other class's
        value can reach the list.
      * There is no "what level are you" step. Levels:GetScoringLevel() already
        knows, so the default context follows the level the score uses.
      * The window is its own frame and is built on the first open, never in
        combat. EVENT_PROFILE refreshes do not touch it, so a half-finished
        answer cannot be torn down by a profile change. Its name is
        LunchboxToolkitWizardFrame, the title band reads "Lunchbox Toolkit",
        and the red X in that band closes this window and nothing else.
      * The context step draws only the contexts the bundled profiles cover for
        the chosen role and spec, and a starter row is filtered by the context
        answer, so a starter can never silently undo it.
      * Closing unanswered writes nothing. Build 1 is written exactly once,
        when Save build 1 is pressed; build 2 exactly once, when Save build 2
        is pressed (or Yes is chosen on the same-starter question). Close,
        Escape and No on the second-build question never write.

    The first login on a character with no answers shows an introduction in
    this same window: what the toolkit does, tooltips and scoring, quest
    rewards, bags, the switches it can set (tooltip lines, quest-reward marking,
    bag warnings, vendor auto-sell, upgrade toast, diagnostic lines, the class's
    imbue reminder), the levelling direction, then the ranks board and the
    /join command for its channel (printed into the chat box, never run for the
    player). Finish writes those answers, marks setupPrompted and opens the main
    window's rail; closing before Finish writes nothing. Every character is
    offered the tour once, whether or not it has been played before; /lt setup
    reopens it at any time.

    The BUILD wizard opens once at level 10 - no talent point needs to be spent.
    Below 10 the character has one default profile and the second build is not
    offered.
    A talent or specialisation change that differs from the current build's
    spec opens it once more, with the active spec preselected, unless the
    profile is pinned; a build is never rewritten without the player pressing
    Save.

    The flow is two-phase. Slot 1 walks the four questions; Save build 1 writes
    slot 1 and then asks "Set up a second build?". Yes starts the same four
    questions for slot 2 and Save build 2 writes slot 2 and closes. No thanks
    closes immediately: build 1 is already saved and slot 2 is left alone.
    When both builds resolve to the same class-pack starter the wizard asks
    once before writing slot 2, from where the player can go back to the slot-2
    starter list instead. The Builds page opens the wizard for slot 2 alone:
    four steps ending in Save build 2, never slot 1 and never the question.
    Close only hides this window; it never hides or retargets UI.lua.

    Stored answers live in character.setup and are read back when the wizard is
    opened again. The shape is:

      character.setup = { version, role, spec, context, dualSpec, offSpec,
                          offRole, offContext, template, offTemplate,
                          completedAt }

    `offRole` and `offContext` are additive (v2 records without them still
    read back); they let slot 2 keep its own role and context, which the
    two-phase questionnaire asks for.

    `context` is the wizard's answer ("LEVELING", "PVE" or "PVP"); a build slot
    only understands "PVE" and "PVP", so "LEVELING" is written to a slot as
    "PVE" while the answer itself is kept as given. `completedAt` is a number
    from the client's time(), or 0 when the client cannot answer.

    `template` and `offTemplate` name the class-pack starter configuration each
    slot was chosen from, using the template's `key` when it has one and its
    `name` otherwise. They are only hints: the plan applies a template while it
    is still registered and falls back to the role/spec/context lookup when the
    pack no longer ships it. The second slot may name the same spec as the
    first; what makes it a different build is the role, context or weapon.

    The introduction's answers live outside `setup`. `character.direction` is
    { spec, role, context, at }: the levelling direction the tour picked, which
    points slot 1 at that spec so the score is right below level 10. It is a
    separate field on purpose — `character.setup` means "the build questions are
    answered" and would silence the level-10 prompt. The tour writes a build
    slot only while the slot is untouched, and a slot holding exactly the
    recorded direction still counts as untouched, so the level-10 questions
    still fill slot 1. Nothing the tour can set — the switches, the direction,
    the leaderboard ask — is written before Finish.

    Colours come from Palette.lua, and the label/button/checkbox/info shapes
    are the ones UI.lua already draws. A fallback exists only for a client
    where the template frame is missing.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Wizard = {}
LT.Wizard = Wizard
LT.Modules = LT.Modules or {}
LT.Modules.Wizard = Wizard

-- v2 added template / offTemplate, and the two-phase flow added the optional
-- offRole / offContext. Older records are read as before: the added fields are
-- optional, so no conversion is needed and the version stays 2.
Wizard.SETUP_VERSION = 2

local WIDTH         = 560
local PADDING       = 16
local CONTENT_WIDTH = WIDTH - (PADDING * 2)
local ROW_HEIGHT    = 24
local ROW_GAP       = 4
local LINE_FALLBACK = 12

-- The title band names the addon, not just the page inside it. The frame keeps
-- the name it has always had (LunchboxToolkitWizardFrame), so Escape and any
-- outside reference still find the same window.
local WINDOW_TITLE  = "Lunchbox Toolkit"
local CLOSE_SIZE    = 20

-- The canonical context answers and their labels. This is the vocabulary, not
-- the list the context step draws: Wizard:ContextOptions offers only the ones
-- the bundled profiles actually cover for the chosen role and spec, so a
-- context that would leave a slot without weights has no row. `slot` is what a
-- build slot is allowed to store; the wizard's own answer keeps the key.
Wizard.CONTEXTS = {
    { key = "LEVELING", label = "Levelling", slot = "PVE" },
    { key = "PVE",      label = "PvE",       slot = "PVE" },
    { key = "PVP",      label = "PvP",       slot = "PVP" },
}

local STEP_TITLES = { "Role", "Spec", "Context", "Starter build" }

local frame
local contentFrame
local titleLabel
local stepLabel
local backButton
local nextButton
local applyButton
local closeButton

------------------------------------------------------------------------------
-- Small guarded helpers
------------------------------------------------------------------------------

local function combatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

local function timeNow()
    if type(time) == "function" then
        local ok, value = pcall(time)
        if ok and tonumber(value) then return tonumber(value) end
    end
    return 0
end

-- A number from a client value, preferring LT:Number when it exists because a
-- secret value must answer nil rather than raising.
local function numberOf(value)
    local fn = LT.Number
    if type(fn) == "function" then
        local ok, result = pcall(fn, LT, value)
        if ok and type(result) == "number" then return result end
        return nil
    end
    if type(value) == "number" then return value end
    local ok, result = pcall(tonumber, value)
    if ok and type(result) == "number" then return result end
    return nil
end

local function rgb(key)
    local palette = LT.Palette
    if type(palette) == "table" and type(palette.RGB) == "function" then
        local ok, colour = pcall(palette.RGB, palette, key)
        if ok and type(colour) == "table" then return colour end
    end
    return { r = 1, g = 1, b = 1 }
end

local function colourOf(key)
    local palette = LT.Palette
    if type(palette) == "table" and type(palette.Colour) == "function" then
        local ok, colour = pcall(palette.Colour, palette, key)
        if ok and type(colour) == "table" then return colour end
    end
    return { 1, 1, 1, 1 }
end

local function has(list, value)
    for _, entry in ipairs(list or {}) do
        if entry == value then return true end
    end
    return false
end

local function copyList(list)
    local out = {}
    for index, value in ipairs(list or {}) do out[index] = value end
    return out
end

-- Font strings report their wrapped height on this client, but not on every
-- client, so a fallback keeps the window from collapsing. Every measured row
-- is added only after its text exists.
local function measure(fontString, fallback)
    if fontString and type(fontString.GetStringHeight) == "function" then
        local ok, height = pcall(fontString.GetStringHeight, fontString)
        if ok and type(height) == "number" and height > 0 then return height end
    end
    return fallback or LINE_FALLBACK
end

-- Every row in this window is one line. A client that cannot turn wrapping off
-- still gets a width at least as wide as the strings this file writes.
local function oneLine(label)
    if label and type(label.SetWordWrap) == "function" then
        pcall(label.SetWordWrap, label, false)
    end
    return label
end

------------------------------------------------------------------------------
-- Class-scoped options
--
-- The pack is the first source. A pack with specRoles answers exactly which
-- spec may be played as which role. A pack that has not authored specRoles yet
-- still names the class's own specs and roles in ClassData, so the wizard can
-- offer those instead of an empty step. Nothing from another class is read.
------------------------------------------------------------------------------

local function classDefinition()
    local data = LT.ClassData
    local classToken = LT.player and LT.player.class
    if type(data) ~= "table" or type(data.GetClass) ~= "function" then return nil end
    if type(classToken) ~= "string" or classToken == "UNKNOWN" then return nil end

    local ok, definition = pcall(data.GetClass, data, classToken)
    if ok and type(definition) == "table" then return definition end
    return nil
end

local function classPack()
    local packs = LT.ClassPacks
    local classToken = LT.player and LT.player.class
    if type(packs) ~= "table" or type(packs.Get) ~= "function" then return nil end
    if type(classToken) ~= "string" or classToken == "UNKNOWN" then return nil end

    local ok, pack = pcall(packs.Get, packs, classToken)
    if ok and type(pack) == "table" then return pack end
    return nil
end

-- The dominant talent tree, mapped to one of this class's own spec names.
-- SpecAdvisor already reads both talent APIs behind pcall; reusing it means
-- this file invents no client call. A tree name that does not match one of the
-- class's specs is not guessed at — nil means "cannot answer".
local function activeSpecName()
    local advisor = LT.SpecAdvisor
    if type(advisor) ~= "table" or type(advisor.Read) ~= "function" then return nil end

    local ok, trees = pcall(advisor.Read, advisor)
    if not ok or type(trees) ~= "table" then return nil end

    local bestName, bestPoints
    for _, tree in ipairs(trees) do
        if type(tree) == "table" then
            local points = numberOf(tree.pointsSpent)
            if not points then
                points = 0
                for _, talent in ipairs(tree.talents or {}) do
                    points = points + (numberOf(talent.rank) or 0)
                end
            end
            if type(tree.name) == "string" and points > 0
                and (not bestPoints or points > bestPoints) then
                bestName, bestPoints = tree.name, points
            end
        end
    end
    if not bestName then return nil end

    local definition = classDefinition()
    for _, spec in ipairs((definition and definition.specs) or {}) do
        if string.lower(tostring(spec)) == string.lower(bestName) then return spec end
    end
    return nil
end

-- Roles in the class's own declared order first, then anything a pack adds that
-- the class list did not mention (a refused pack never reaches here).
local function orderRoles(definition, found)
    local ordered = {}
    local seen = {}

    for _, role in ipairs(definition.roles or {}) do
        if found[role] and not seen[role] then
            ordered[#ordered + 1] = role
            seen[role] = true
        end
    end

    for role in pairs(found) do
        if not seen[role] then
            ordered[#ordered + 1] = role
            seen[role] = true
        end
    end

    return ordered
end

local function specOrder(definition, mapping)
    local ordered = {}
    local seen = {}

    for _, spec in ipairs(definition.specs or {}) do
        if mapping[spec] and not seen[spec] then
            ordered[#ordered + 1] = spec
            seen[spec] = true
        end
    end

    for spec in pairs(mapping) do
        if not seen[spec] then
            ordered[#ordered + 1] = spec
            seen[spec] = true
        end
    end

    return ordered
end

-- Returns roles, specs, specsByRole, defaultRole and defaultSpec. The caller
-- never sees a spec that cannot be played by at least one of this class's own
-- roles.
function Wizard:ClassOptions()
    local definition = classDefinition()
    if not definition then
        return { roles = {}, specs = {}, specsByRole = {}, defaultRole = nil, defaultSpec = nil }
    end

    local pack = classPack()
    local mapping = pack and pack.specRoles or nil
    local specsByRole = {}
    local rolesFound = {}
    local mappingUsed = false

    if type(mapping) == "table" then
        for spec, roles in pairs(mapping) do
            if type(roles) == "table" and #roles > 0 then
                specsByRole[spec] = copyList(roles)
                for _, role in ipairs(roles) do rolesFound[role] = true end
                mappingUsed = true
            end
        end
    end

    if not mappingUsed then
        -- No authored spec -> role link yet: every class spec may be played by
        -- every class role. That is the honest fallback and still class-only.
        local classRoles = copyList(definition.roles or {})
        if #classRoles == 0 and definition.defaultRole then
            classRoles = { definition.defaultRole }
        end
        for _, spec in ipairs(definition.specs or {}) do
            specsByRole[spec] = copyList(classRoles)
        end
        for _, role in ipairs(classRoles) do rolesFound[role] = true end
    end

    local roles = orderRoles(definition, rolesFound)
    local specs = specOrder(definition, specsByRole)

    local defaultRole = definition.defaultRole
    if not has(roles, defaultRole) then defaultRole = roles[1] end

    local defaultSpec
    for _, spec in ipairs(specs) do
        if has(specsByRole[spec], defaultRole) then
            defaultSpec = spec
            break
        end
    end
    if not defaultSpec then defaultSpec = specs[1] end

    return {
        roles       = roles,
        specs       = specs,
        specsByRole = specsByRole,
        defaultRole = defaultRole,
        defaultSpec = defaultSpec,
        definition  = definition,
    }
end

------------------------------------------------------------------------------
-- Stored answers and the live draft
------------------------------------------------------------------------------

function Wizard:ReadSetup()
    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return nil end
    if type(character.setup) ~= "table" then return nil end
    return character.setup
end

-- The tour's levelling direction, as the character record holds it. It is not
-- stored in character.setup on purpose: that table means "the build questions
-- are answered", and writing it there would silence the level-10 prompt.
local function directionAnswer()
    local database = LT.Database
    local character = database and database.character
    local direction = type(character) == "table" and character.direction or nil
    if type(direction) ~= "table" then return nil end
    if type(direction.spec) ~= "string" or direction.spec == "" then return nil end
    return direction
end

local function validContext(key)
    for _, entry in ipairs(Wizard.CONTEXTS) do
        if entry.key == key then return entry end
    end
    return nil
end

local function contextForSlot(key)
    local entry = validContext(key)
    return entry and entry.slot or "PVE"
end

local function contextLabel(key)
    local entry = validContext(key)
    return entry and entry.label or tostring(key or "PvE")
end

-- Two answers land on the same build slot context when they store the same
-- thing: Levelling and PvE both write "PVE".
local function sameSlotContext(first, second)
    return contextForSlot(first) == contextForSlot(second)
end

-- The level the character is now. Levels.lua owns the scoring level; the
-- plain unit level is the fallback for a client that cannot answer.
local function playerLevel()
    local levels = LT.Levels
    local level = LT.player and tonumber(LT.player.level)

    if type(levels) == "table" and type(levels.GetCurrentLevel) == "function" then
        local ok, current = pcall(levels.GetCurrentLevel, levels)
        if ok and tonumber(current) then level = tonumber(current) end
    end

    return level
end

local function defaultContext()
    local level = playerLevel()
    if level and level < (LT.MAX_LEVEL or 60) then return "LEVELING" end
    return "PVE"
end

local function hasContext(rows, key)
    for _, entry in ipairs(rows or {}) do
        if entry.key == key then return true end
    end
    return false
end

-- The context rows this class can actually score for one role and spec. The
-- answer comes from the bundled profiles, never from a hand-written list: a
-- context with no profile for this class, role and spec would resolve to no
-- weights at all, so no row is drawn for it. "Levelling" shares the PvE
-- profile and is offered exactly where PvE is.
--
-- A bundle that cannot be read leaves the canonical list untouched: an
-- unreadable repository is not proof that a profile is missing.
function Wizard:ContextOptions(role, spec)
    local data = LT.ClassData
    local classToken = LT.player and LT.player.class

    if type(data) ~= "table" or type(data.GetBaseProfiles) ~= "function"
        or type(classToken) ~= "string" or classToken == "UNKNOWN" then
        return copyList(Wizard.CONTEXTS)
    end

    local ok, profiles = pcall(data.GetBaseProfiles, data)
    if not ok or type(profiles) ~= "table" then
        return copyList(Wizard.CONTEXTS)
    end

    local function covered(context)
        for _, profile in ipairs(profiles) do
            if type(profile) == "table"
                and profile.class == classToken
                and profile.context == context
                and (profile.role == nil or profile.role == "Any" or profile.role == role)
                and (profile.spec == nil or profile.spec == "Any"
                    or spec == nil or spec == "Any" or profile.spec == spec) then
                return true
            end
        end
        return false
    end

    local hasPve = covered("PVE")
    local hasPvp = covered("PVP")
    local rows = {}

    for _, entry in ipairs(Wizard.CONTEXTS) do
        if entry.key == "LEVELING" then
            if hasPve then rows[#rows + 1] = entry end
        elseif entry.key == "PVE" then
            if hasPve then rows[#rows + 1] = entry end
        elseif entry.key == "PVP" then
            if hasPvp then rows[#rows + 1] = entry end
        end
    end

    return rows
end

-- Whether one context answer is on offer for this role and spec. Used by the
-- choice setters, so a stored or scripted answer cannot pick a context the
-- window refused to draw.
function Wizard:OffersContext(role, spec, key)
    return hasContext(self:ContextOptions(role, spec), key)
end

-- The context to use when an answer is missing or no longer offered: the
-- level-aware default when it has a profile, otherwise PvE, otherwise the
-- first row this class does have.
function Wizard:ContextFallback(role, spec)
    local rows = self:ContextOptions(role, spec)
    local preferred = defaultContext()

    if hasContext(rows, preferred) then return preferred end
    if hasContext(rows, "PVE") then return "PVE" end
    return rows[1] and rows[1].key or "PVE"
end

-- Keeps both stored answers inside the rows the window can draw. Called after
-- a role or spec changes and after a draft is built, never from a choice the
-- player just made: a rejected row is refused there instead of moved.
function Wizard:ClampDraftContexts(draft)
    if type(draft) ~= "table" then return end

    if not self:OffersContext(draft.role, draft.spec, draft.context) then
        draft.context = self:ContextFallback(draft.role, draft.spec)
    end

    if draft.offSpec ~= nil
        and not self:OffersContext(draft.offRole, draft.offSpec, draft.offContext) then
        draft.offContext = draft.context
        if not self:OffersContext(draft.offRole, draft.offSpec, draft.offContext) then
            draft.offContext = self:ContextFallback(draft.offRole, draft.offSpec)
        end
    end
end

local function specsForRole(options, role)
    local list = {}
    for _, spec in ipairs(options.specs or {}) do
        if has(options.specsByRole[spec], role) then list[#list + 1] = spec end
    end
    return list
end

local function roleForSpec(options, spec, preferred)
    local roles = options.specsByRole[spec] or {}
    if has(roles, preferred) then return preferred end
    if has(roles, "Damage") then return "Damage" end
    return roles[1]
end

------------------------------------------------------------------------------
-- Starter configurations shipped by the class pack
--
-- A template is a starter record, never a saved profile. The wizard offers the
-- templates of this class only: slot 1 lists those matching the chosen spec,
-- slot 2 lists all of them with the same spec first. Nothing is remembered by
-- table position, so a pack may reorder or add templates freely.
------------------------------------------------------------------------------

local function templates()
    local packs = LT.ClassPacks
    local classToken = LT.player and LT.player.class
    if type(packs) ~= "table" or type(packs.GetTemplates) ~= "function" then return {} end
    if type(classToken) ~= "string" or classToken == "UNKNOWN" then return {} end

    local ok, list = pcall(packs.GetTemplates, packs, classToken)
    if ok and type(list) == "table" then return list end
    return {}
end

-- The stable handle stored in character.setup. A pack that authors a `key`
-- gets that; every other pack is identified by the template's own name.
local function templateId(template)
    if type(template) ~= "table" then return nil end
    if type(template.key) == "string" and template.key ~= "" then return template.key end
    if type(template.name) == "string" and template.name ~= "" then return template.name end
    return nil
end

local function templateById(id)
    if type(id) ~= "string" or id == "" then return nil end
    for _, template in ipairs(templates()) do
        if type(template) == "table" and templateId(template) == id then
            return template
        end
    end
    return nil
end

-- A starter belongs to one role and context as well as one spec. Rows are
-- filtered by the answers given on the earlier steps, so choosing one can
-- never quietly undo the context question: a Warrior's PvE-only starter is not
-- offered once PvP has been chosen.
local function templateFits(template, role, slotContext, spec)
    if type(template) ~= "table" then return false end
    if spec ~= nil and template.spec ~= nil and template.spec ~= "Any"
        and template.spec ~= spec then
        return false
    end
    if role ~= nil and template.role ~= nil and template.role ~= role then
        return false
    end
    if slotContext ~= nil and template.context ~= nil
        and contextForSlot(template.context) ~= slotContext then
        return false
    end
    return true
end

local function templatesForSpec(spec, role, contextKey)
    local list = {}
    if type(spec) ~= "string" then return list end

    local slotContext = contextKey and contextForSlot(contextKey) or nil
    for _, template in ipairs(templates()) do
        if templateFits(template, role, slotContext, spec) then
            list[#list + 1] = template
        end
    end
    return list
end

-- Slot 2 may repeat the slot-1 spec, so the matching spec comes first, then
-- every other starter that fits the same role and context.
local function templatesForSecondSlot(spec, role, contextKey)
    local ordered = {}
    local rest = {}
    local slotContext = contextKey and contextForSlot(contextKey) or nil

    for _, template in ipairs(templates()) do
        if templateFits(template, role, slotContext, nil) then
            if template.spec == spec then
                ordered[#ordered + 1] = template
            else
                rest[#rest + 1] = template
            end
        end
    end
    for _, template in ipairs(rest) do ordered[#ordered + 1] = template end
    return ordered
end

-- The picker row must answer "which weapon setup" at a glance: 2H, DW and
-- 1H+shield are the three the class packs ship, and none of them is spelled as
-- a full sentence that could wrap.
local SETUP_SHORT = {
    ["2H"]        = "2H",
    ["1H_SHIELD"] = "1H+shield",
    ["DUAL_WIELD"] = "DW",
    ["1H"]        = "1H",
    ["RANGED"]    = "Ranged",
}

local function setupShortLabel(key)
    if SETUP_SHORT[key] then return SETUP_SHORT[key] end
    if type(LT.GetWeaponSetupDefinition) == "function" then
        local ok, definition = pcall(LT.GetWeaponSetupDefinition, LT, key)
        if ok and type(definition) == "table" and definition.label then
            return tostring(definition.label)
        end
    end
    return tostring(key or "?")
end

-- One line, so the row height never depends on the window guessing a wrap. The
-- context is only added when the template's own name does not already carry
-- it: "Enhancement Tank — PvE · Tank · 1H + shield", not "... · PvE · PvE ...".
local function variantLabel(template)
    local name = tostring(template.name or "Starter")
    local parts = { name }
    if template.role then parts[#parts + 1] = tostring(template.role) end
    if template.context then
        local context = contextLabel(template.context)
        if not name:find(context, 1, true) then parts[#parts + 1] = context end
    end
    if template.weaponSetup then parts[#parts + 1] = setupShortLabel(template.weaponSetup) end
    return table.concat(parts, " · ")
end

-- The role, spec and context a template answers with. Missing or class-foreign
-- fields fall back to what the draft already holds instead of being trusted.
local function templateAnswer(template, options, fallbackSpec)
    local spec = template.spec
    if type(spec) ~= "string" or spec == "Any" or not has(options.specs or {}, spec) then
        spec = fallbackSpec or options.defaultSpec
    end

    local role = template.role
    if not has(options.roles or {}, role) then
        role = roleForSpec(options, spec, template.role)
    end

    local context
    if validContext(template.context) then context = template.context end

    return role, spec, context
end

-- Choosing a variant sets the fields it names; the template id is only the
-- memory of which starter the answer came from. Slot 2 is the same operation
-- and is what allows two builds of one spec.
function Wizard:ChooseTemplate(index, id)
    index = tonumber(index)
    if index ~= 1 and index ~= 2 then return false end

    local template = templateById(id)
    if not template then return false end

    if not self.draft then self:ResetDraft() end
    local options = self:ClassOptions()
    local draft = self.draft
    local key = templateId(template)
    if not key then return false end

    if index == 1 then
        local role, spec, context = templateAnswer(template, options, draft.spec)
        draft.template = key
        draft.role = role or draft.role
        draft.spec = spec or draft.spec
        -- The context answer was given before this list and stays authoritative.
        -- Rows are filtered to it, so this only guards a stored or scripted
        -- choice whose starter belongs to a different context.
        if context and sameSlotContext(context, draft.context) then
            draft.context = context
        end
        return true
    end

    local role, spec, context = templateAnswer(template, options,
        draft.offSpec or draft.spec)
    draft.dualSpec = true
    draft.offTemplate = key
    draft.offRole = role or draft.offRole
    draft.offSpec = spec or draft.offSpec or draft.spec
    local currentContext = draft.offContext or draft.context
    if context and sameSlotContext(context, currentContext) then
        draft.offContext = context
    end
    return true
end

-- Builds the draft from the stored answers when they still fit this class, and
-- from the class defaults otherwise. Nothing is written to saved variables.
function Wizard:ResetDraft()
    local options = self:ClassOptions()
    local stored = self:ReadSetup()

    local draft = {
        role        = options.defaultRole,
        spec        = options.defaultSpec,
        context     = defaultContext(),
        -- The second-build question is asked fresh on every visit, so a stored
        -- dualSpec answer no longer pre-ticks anything.
        dualSpec    = false,
        offRole     = nil,
        offSpec     = nil,
        offContext  = nil,
        template    = nil,
        offTemplate = nil,
    }

    -- The tour's levelling direction is the answer these questions start from:
    -- a player who said "Enhancement, first" at level 1 confirms rather than
    -- re-picks at 10. A completed setup below overrides it, because that is the
    -- set of answers the player actually saved.
    local direction = directionAnswer()
    if direction then
        if has(options.roles, direction.role) then draft.role = direction.role end
        if has(specsForRole(options, draft.role), direction.spec) then
            draft.spec = direction.spec
        end
    end

    if stored then
        if has(options.roles, stored.role) then draft.role = stored.role end

        local allowed = specsForRole(options, draft.role)
        draft.spec = has(allowed, stored.spec) and stored.spec
            or allowed[1] or options.defaultSpec

        if validContext(stored.context) then draft.context = stored.context end

        -- The template is restored only while it still agrees with the stored
        -- role, spec and context. A starter from a different context is not the
        -- answer the player kept: dropping it lets the stored fields stand and
        -- the lookup fallback resolve the real profile for this context. A
        -- template the pack no longer ships is dropped the same way.
        local mainTemplate = templateById(stored.template)
        if templateFits(mainTemplate, draft.role, contextForSlot(draft.context), draft.spec) then
            local role, spec, context = templateAnswer(mainTemplate, options, draft.spec)
            draft.template = templateId(mainTemplate)
            draft.role = role or draft.role
            draft.spec = spec or draft.spec
            if context and sameSlotContext(context, draft.context) then
                draft.context = context
            end
        end

        if has(options.roles, stored.offRole) then
            draft.offRole = stored.offRole
        end
        if has(options.specs, stored.offSpec) then
            draft.offSpec = stored.offSpec
        end
        if validContext(stored.offContext) then
            draft.offContext = stored.offContext
        end

        -- Slot 2's starter is read back even when the stored record predates
        -- the two-phase flow: opening the wizard for slot 2 alone should show
        -- the answers that slot was last given. Like slot 1, it is only kept
        -- while it still agrees with those answers.
        local offTemplate = templateById(stored.offTemplate)
        local offContextKey = draft.offContext or draft.context
        if templateFits(offTemplate, draft.offRole, contextForSlot(offContextKey),
            draft.offSpec) then
            local role, spec, context = templateAnswer(offTemplate, options,
                draft.offSpec or draft.spec)
            draft.offTemplate = templateId(offTemplate)
            draft.offRole = role or draft.offRole
            draft.offSpec = spec or draft.offSpec
            if context and sameSlotContext(context, offContextKey) then
                draft.offContext = context
            end
        end
    end

    -- A second slot may repeat the first slot's spec: two builds of one spec
    -- differing by role, context or weapon are exactly what the picker is for.
    if not draft.offSpec then
        for _, spec in ipairs(options.specs or {}) do
            if spec ~= draft.spec then
                draft.offSpec = spec
                break
            end
        end
        draft.offSpec = draft.offSpec or draft.spec
    end

    -- Slot 2 got its own role and context with the two-phase flow. A stored
    -- record without them keeps the old behaviour: the spec decides the role,
    -- and the second build shares build 1's context.
    if not has(options.roles, draft.offRole) then
        draft.offRole = roleForSpec(options, draft.offSpec, draft.role) or draft.role
    end
    if not validContext(draft.offContext) then
        draft.offContext = draft.context
    end

    -- A spec-change prompt opens the wizard with the character's active
    -- specialisation preselected. It is a suggestion, not a write: pressing
    -- Save is still what changes the slot.
    if self.suggestedSpec and has(options.specs or {}, self.suggestedSpec) then
        draft.spec = self.suggestedSpec
        draft.template = nil
        local roles = options.specsByRole and options.specsByRole[draft.spec] or {}
        if not has(roles, draft.role) then
            draft.role = roles[1] or draft.role
        end
    end

    -- A context the bundled profiles do not cover for the final role and spec
    -- cannot be drawn on step 3, so the draft falls back to one that is. This
    -- compares against the same rows the window draws.
    self:ClampDraftContexts(draft)

    self.draft = draft
    self.step = 1
    self.overrides = { [1] = false, [2] = false }

    return self.draft
end

function Wizard:GetDraft()
    local draft = self.draft
    return {
        role        = draft and draft.role,
        spec        = draft and draft.spec,
        context     = draft and draft.context,
        dualSpec    = draft and draft.dualSpec == true,
        offRole     = draft and draft.offRole,
        offSpec     = draft and draft.offSpec,
        offContext  = draft and draft.offContext,
        template    = draft and draft.template,
        offTemplate = draft and draft.offTemplate,
    }
end

-- Changing a step invalidates only the choices that depend on it. A manual
-- role, spec or context answer also lets go of the starter variant it came
-- from, so the plan can never apply a template the player has just overridden.
function Wizard:SetChoice(field, value)
    if not self.draft then self:ResetDraft() end

    local options = self:ClassOptions()
    local draft = self.draft

    if field == "role" then
        if not has(options.roles, value) then return false end
        draft.role = value
        draft.template = nil

        local allowed = specsForRole(options, value)
        if not has(allowed, draft.spec) then draft.spec = allowed[1] end
        if not draft.offSpec then draft.offSpec = draft.spec end
        self:ClampDraftContexts(draft)
        return true
    end

    if field == "spec" then
        if not has(specsForRole(options, draft.role), value) then return false end
        draft.spec = value
        draft.template = nil
        if not draft.offSpec then draft.offSpec = value end
        self:ClampDraftContexts(draft)
        return true
    end

    if field == "context" then
        if not validContext(value) then return false end
        if not self:OffersContext(draft.role, draft.spec, value) then return false end
        draft.context = value
        draft.template = nil
        return true
    end

    if field == "dualSpec" then
        if value == true and not draft.offSpec then return false end
        draft.dualSpec = value == true
        return true
    end

    -- Slot 2 is not filtered against slot 1: the same spec is a valid answer.
    if field == "offSpec" then
        if not has(options.specs, value) then return false end
        draft.offSpec = value
        draft.offTemplate = nil
        draft.dualSpec = true

        local roles = options.specsByRole[value] or {}
        if not has(roles, draft.offRole) then
            draft.offRole = roleForSpec(options, value, draft.role)
        end
        return true
    end

    if field == "offRole" then
        if not has(options.roles, value) then return false end
        draft.offRole = value
        draft.offTemplate = nil
        draft.dualSpec = true

        local allowed = specsForRole(options, value)
        if not has(allowed, draft.offSpec) then draft.offSpec = allowed[1] end
        return true
    end

    if field == "offContext" then
        if not validContext(value) then return false end
        if not self:OffersContext(draft.offRole, draft.offSpec, value) then return false end
        draft.offContext = value
        draft.offTemplate = nil
        draft.dualSpec = true
        return true
    end

    if field == "template" then
        return self:ChooseTemplate(1, value)
    end

    if field == "offTemplate" then
        return self:ChooseTemplate(2, value)
    end

    return false
end

function Wizard:SetOverride(index, enabled)
    index = tonumber(index)
    if index ~= 1 and index ~= 2 then return false end
    self.overrides = self.overrides or {}
    self.overrides[index] = enabled == true
    self:Render()
    return true
end

------------------------------------------------------------------------------
-- Planning the two slots
------------------------------------------------------------------------------

-- A template is a starter record, never a saved profile. Prefer an exact spec,
-- then an exact role, then an exact context; "Any" and absent fields are
-- wildcards. A pack with no templates simply leaves the class defaults.
local function findTemplate(spec, role, slotContext)
    local best, bestScore
    local list = templates()

    for _, template in ipairs(list) do
        if type(template) == "table" then
            local specMatch = template.spec == nil or template.spec == "Any"
                or template.spec == spec
            local roleMatch = template.role == nil or template.role == role
            local contextMatch = template.context == nil or template.context == slotContext

            if specMatch and roleMatch and contextMatch then
                local score = 0
                if template.spec == spec then score = score + 4 end
                if template.role == role then score = score + 2 end
                if template.context == slotContext then score = score + 1 end

                if not best or score > bestScore then
                    best, bestScore = template, score
                end
            end
        end
    end

    return best
end

local function blankImbue(role)
    if role == "Tank" then return "rockbiter" end
    return "none"
end

local function classDefaults(definition, index)
    local role = definition and definition.defaultRole or "Damage"
    local setup = definition and definition.defaultSetup or "2H"

    return {
        index       = index,
        name        = "Build " .. tostring(index),
        spec        = "Any",
        role        = role,
        context     = "PVE",
        weaponSetup = setup,
        imbue       = blankImbue(role),
    }
end

local function planForTemplate(template, index, fallback)
    local fields = {
        index       = index,
        name        = (template and template.name) or fallback.name,
        spec        = (template and template.spec and template.spec ~= "Any"
                       and template.spec) or fallback.spec,
        role        = (template and template.role) or fallback.role,
        -- The context answer given on step 3 is what the slot is scored as.
        -- A starter only says which weight set it came from; it never rewrites
        -- the answer the player has already chosen.
        context     = fallback.context,
        weaponSetup = (template and template.weaponSetup) or fallback.weaponSetup,
        imbue       = (template and template.imbue) or fallback.imbue,
        -- Which starter actually produced this slot, chosen or looked up. The
        -- same-template question compares these two handles, never a name.
        templateKey = template and templateId(template) or nil,
    }

    if type(fields.name) ~= "string" or fields.name == "" then
        fields.name = "Build " .. tostring(index)
    end
    if type(fields.imbue) ~= "string" or fields.imbue == "" then
        fields.imbue = blankImbue(fields.role)
    end

    return fields
end

-- The rows the picker shows for one slot. Slot 1 offers the templates of the
-- chosen spec; slot 2 offers every template with that spec first, because a
-- second build may use the same spec as the first.
function Wizard:TemplateChoices(index)
    local draft = self.draft or {}
    if tonumber(index) == 2 then
        return templatesForSecondSlot(draft.offSpec or draft.spec, draft.offRole,
            draft.offContext or draft.context)
    end
    return templatesForSpec(draft.spec, draft.role, draft.context)
end

-- What the wizard would write, without writing anything. A chosen template is
-- applied exactly while the pack still ships it; a missing one falls back to
-- the role/spec/context lookup this wizard has always used.
function Wizard:Plan()
    local options = self:ClassOptions()
    local draft = self.draft or self:ResetDraft()
    local definition = options.definition

    local slotContext = contextForSlot(draft.context)
    local offContextKey = draft.offContext or draft.context
    local slotContext2 = contextForSlot(offContextKey)
    local mainFallback = classDefaults(definition, 1)
    mainFallback.spec = draft.spec or mainFallback.spec
    mainFallback.role = draft.role or mainFallback.role
    mainFallback.context = slotContext

    local slots = {}
    local chosenMain = templateById(draft.template)
    if chosenMain then
        slots[1] = planForTemplate(chosenMain, 1, mainFallback)
    else
        slots[1] = planForTemplate(
            findTemplate(draft.spec, draft.role, slotContext), 1, mainFallback)
    end

    if draft.dualSpec and draft.offSpec then
        local offFallback = classDefaults(definition, 2)
        offFallback.spec = draft.offSpec
        offFallback.context = slotContext2

        local offRole = draft.offRole
        if not has(options.roles or {}, offRole) then
            offRole = roleForSpec(options, draft.offSpec, draft.role)
        end
        offFallback.role = offRole or offFallback.role

        local chosenOff = templateById(draft.offTemplate)
        if chosenOff then
            slots[2] = planForTemplate(chosenOff, 2, offFallback)
        else
            slots[2] = planForTemplate(
                findTemplate(draft.offSpec, offRole, slotContext2), 2, offFallback)
        end
    else
        slots[2] = classDefaults(definition, 2)
    end

    local untouched = {}
    for index = 1, 2 do
        untouched[index] = self:IsSlotUntouched(index)
    end

    return {
        slots      = slots,
        untouched  = untouched,
        context    = draft.context,
        offContext = offContextKey,
        dualSpec   = draft.dualSpec == true,
    }
end

-- A slot is untouched only while it still holds exactly the blank the Builds
-- module created for this class. Any name, spec, profile, equipment set,
-- purpose, plugin choice or non-default role/context/weapon makes it
-- hand-tuned, and then Apply leaves it alone. A caller may still force it
-- through the overrides argument; the window itself draws no such row.
function Wizard:IsSlotUntouched(index)
    local builds = LT.Builds
    if type(builds) ~= "table" or type(builds.Get) ~= "function" then return true end

    local ok, build = pcall(builds.Get, builds, index)
    if not ok or type(build) ~= "table" then return true end

    local definition = classDefinition()
    local defaultRole = definition and definition.defaultRole or "Damage"
    local defaultSetup = definition and definition.defaultSetup or "2H"

    -- The introduction's levelling direction is the tour's starting answer, not
    -- a player edit: a slot holding exactly that spec and role is still the
    -- wizard's to fill, so the level-10 questions write slot 1 as they always
    -- did. Any other spec, or a direction that has since moved on, is a real
    -- choice and takes the slot out of the wizard's reach.
    local direction = directionAnswer()

    if build.spec ~= "Any"
        and not (direction and direction.spec == build.spec) then
        return false
    end
    if build.name ~= ("Build " .. tostring(index)) then return false end
    if build.role ~= defaultRole
        and not (direction and direction.role == build.role) then
        return false
    end
    if build.context ~= "PVE" then return false end
    -- A weapon setup derived from the worn main hand at first login is not a
    -- player edit: the slot is still the wizard's to fill.
    if build.weaponSetup ~= defaultSetup and build.weaponSetupDerived ~= true then
        return false
    end
    if build.profileKey ~= nil then return false end
    if build.gearset ~= nil then return false end
    if build.purpose ~= nil and build.purpose ~= "" then return false end
    if build.imbue ~= blankImbue(defaultRole) then return false end

    for _ in pairs(build.pluginOptions or {}) do return false end

    return true
end

------------------------------------------------------------------------------
-- Applying and storing
------------------------------------------------------------------------------

local function writeField(index, method, value)
    if value == nil then return end
    local builds = LT.Builds
    local fn = builds and builds[method]
    if type(fn) ~= "function" then return end
    pcall(fn, builds, index, value)
end

local function writeSlot(index, fields)
    local builds = LT.Builds
    if type(builds) ~= "table" then return false end

    -- A template never names a profile; replacing a slot therefore clears the
    -- profile the old build pointed at instead of leaving a borrowed one behind.
    if type(builds.SetProfile) == "function" then
        pcall(builds.SetProfile, builds, index, nil)
    end

    writeField(index, "SetSpec", fields.spec)
    writeField(index, "SetRole", fields.role)
    writeField(index, "SetContext", fields.context)
    writeField(index, "SetWeaponSetup", fields.weaponSetup)
    writeField(index, "SetName", fields.name)
    writeField(index, "SetImbue", fields.imbue)

    return true
end

local function saveSetup(draft)
    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return false end

    character.setup = {
        version     = Wizard.SETUP_VERSION,
        role        = draft.role,
        spec        = draft.spec,
        context     = draft.context,
        dualSpec    = draft.dualSpec == true,
        offRole     = draft.dualSpec and draft.offRole or nil,
        offSpec     = draft.dualSpec and draft.offSpec or nil,
        offContext  = draft.dualSpec and draft.offContext or nil,
        template    = draft.template,
        offTemplate = draft.dualSpec and draft.offTemplate or nil,
        completedAt = timeNow(),
    }

    if type(database.Save) == "function" then
        pcall(database.Save, database, "wizard")
    end

    return true
end

-- `overrides` is kept for callers: overrides[1] / overrides[2] (or the older
-- replace1 / replace2 / useBuild2 aliases) force a hand-tuned slot to be
-- overwritten. The wizard draws no row for them any more; its two save buttons
-- pass an explicit mode and honour IsSlotUntouched.
--
-- `mode` is the single-slot save: "first" writes slot 1 only and "second"
-- writes slot 2 only. A bare Apply still considers both untouched slots, so
-- callers outside the window see the same behaviour as before; the wizard's
-- own buttons always pass a mode, which is why one press cannot reach the
-- same slot twice.
function Wizard:Apply(overrides, mode)
    local options = self:ClassOptions()
    if not options.definition then
        return false, "This character's class is not known yet."
    end

    local allow
    if mode == "first" then
        allow = { [1] = true }
    elseif mode == "second" then
        allow = { [2] = true }
    end

    local builds = LT.Builds
    if type(builds) ~= "table" then
        return false, "The builds module is not loaded."
    end

    if type(builds.EnsureForClass) == "function" then
        pcall(builds.EnsureForClass, builds, LT.player and LT.player.class)
    end

    local plan = self:Plan()
    local applied = {}
    local slotLimit = tonumber(builds.SLOT_COUNT) or 2

    for index = 1, slotLimit do
        local replace = type(overrides) == "table" and (
            overrides[index] == true
            or (index == 1 and overrides.replace1 == true)
            or (index == 2 and overrides.replace2 == true)
            or (index == 2 and overrides.useBuild2 == true)
        )
        local fields = plan.slots[index]

        if (not allow or allow[index]) and fields
            and (plan.untouched[index] or replace) then
            if writeSlot(index, fields) then applied[#applied + 1] = index end
        end
    end

    -- The answers are stored even when both slots were hand-tuned and nothing
    -- was written: the player answered the questions, and reopening prefills.
    saveSetup(self.draft)

    return true, applied, plan
end

------------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------------

local function makeLabel(parent, text, font, colour)
    local ui = LT.UI
    if type(ui) == "table" and type(ui.MakeLabel) == "function" then
        local ok, label = pcall(ui.MakeLabel, ui, parent, text, font, colour)
        if ok and label then return label end
    end

    local ok, label = pcall(parent.CreateFontString, parent, nil, "OVERLAY",
        font or "GameFontNormalSmall")
    if not ok or not label then return nil end

    label:SetText(tostring(text))
    if colour then label:SetTextColor(colour.r, colour.g, colour.b) end
    return label
end

local function makeButton(parent, text, width, height, onClick)
    local ui = LT.UI
    if type(ui) == "table" and type(ui.MakeButton) == "function" then
        local ok, button = pcall(ui.MakeButton, ui, parent, text, width, height, onClick)
        if ok and button then return button end
    end

    local ok, button = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if ok and button and button.SetText then
        button:SetSize(width, height)
        button:SetText(tostring(text))
        button:SetScript("OnClick", onClick)
        return button
    end

    if not ok or not button then
        button = CreateFrame("Button", nil, parent)
    end
    button:SetSize(width, height)

    local idle = colourOf("buttonBg")
    local hot = colourOf("buttonHot")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(true)
    background:SetColorTexture(idle[1], idle[2], idle[3], idle[4])

    local caption = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    caption:SetPoint("CENTER")
    caption:SetText(tostring(text))
    button.label = caption

    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function()
        background:SetColorTexture(hot[1], hot[2], hot[3], hot[4])
    end)
    button:SetScript("OnLeave", function()
        background:SetColorTexture(idle[1], idle[2], idle[3], idle[4])
    end)

    return button
end

-- The same hover target UI.lua draws: one visible "?", a game tooltip on hover,
-- and a click that repeats it for clients where hovering is awkward.
local function makeInfo(parent, title, text)
    if type(text) ~= "string" or text == "" then return nil end

    local ok, button = pcall(CreateFrame, "Button", nil, parent)
    if not ok or not button then return nil end

    button:SetSize(16, 16)

    local glyph = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    glyph:SetAllPoints(true)
    glyph:SetJustifyH("CENTER")
    glyph:SetText("?")

    local brand = rgb("brand")
    local hover = rgb("text")
    glyph:SetTextColor(brand.r, brand.g, brand.b)

    local function show()
        if not GameTooltip or type(GameTooltip.SetOwner) ~= "function" then return end
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:AddLine(tostring(title or "Lunchbox Toolkit"),
            brand.r, brand.g, brand.b, true)
        GameTooltip:AddLine(tostring(text), hover.r, hover.g, hover.b, true)
        GameTooltip:Show()
    end

    button:SetScript("OnEnter", function()
        glyph:SetTextColor(hover.r, hover.g, hover.b)
        show()
    end)
    button:SetScript("OnLeave", function()
        glyph:SetTextColor(brand.r, brand.g, brand.b)
        if GameTooltip then GameTooltip:Hide() end
    end)
    button:SetScript("OnClick", show)

    return button
end

-- The close control in the title band: the same neutral cross the main window
-- wears, one glyph wide, at the same size it always was. Red is a verdict in this
-- add-on, so nothing that closes a window wears it; the glyph is `muted` at rest
-- and `text` under the cursor, and the face and edge do not move at all. Its
-- click runs the same Wizard:Hide() as Escape and the footer Close, so nothing
-- here can hide or retarget UI.lua.
local function makeClose(parent)
    local button = makeButton(parent, "X", CLOSE_SIZE, CLOSE_SIZE,
        function() Wizard:Hide() end)
    if not button then return nil end

    local glyph

    if type(button.GetFontString) == "function" then
        local ok, fontString = pcall(button.GetFontString, button)
        if ok and fontString then glyph = fontString end
    end
    if not glyph then glyph = button.label end

    -- UI.lua owns the one edge key every control's border comes from, but this
    -- window also builds without it on a client that refused it, so the key is
    -- read defensively rather than indexed blind.
    local ui = LT.UI
    local edgeKey = "cardEdge"
    if type(ui) == "table" and type(ui.buttonEdge) == "string" then
        edgeKey = ui.buttonEdge
    end

    LT.Chrome.Card(button, {
        edge = LT.Palette.chrome[edgeKey],
        fill = LT.Palette.chrome.buttonBg,
        bevelMode = "raised",
    })

    local rest = rgb("muted")
    local lit = rgb("text")

    if glyph then
        oneLine(glyph)
        pcall(glyph.SetTextColor, glyph, rest.r, rest.g, rest.b)
    end

    -- Some panel-button templates expose their caption only through the
    -- button's own font-colour setter. Both paths are guarded.
    if type(button.SetNormalFontColor) == "function" then
        pcall(button.SetNormalFontColor, button, rest.r, rest.g, rest.b, 1)
    end

    -- The shared button lights its own face on hover; a close control does not,
    -- so these two scripts are replaced rather than extended.
    button:SetScript("OnEnter", function()
        if glyph then pcall(glyph.SetTextColor, glyph, lit.r, lit.g, lit.b) end
    end)
    button:SetScript("OnLeave", function()
        if glyph then pcall(glyph.SetTextColor, glyph, rest.r, rest.g, rest.b) end
    end)

    -- A marker for this window's own close control, so a test can tell it from
    -- the footer Close without depending on the caption text.
    button.ltWizardClose = true

    return button
end

------------------------------------------------------------------------------
-- Layout
--
-- The window is measured from the font strings after they exist: each label is
-- created, filled, then its height is added to the cursor. Buttons are one row
-- each and have a fixed height because their template does.
------------------------------------------------------------------------------

local function clearContent()
    if not contentFrame then return 0 end

    local children = { contentFrame:GetChildren() }
    for index = 1, select("#", unpack(children)) do
        local child = children[index]
        if child then
            child:Hide()
            child:SetParent(UIParent)
        end
    end

    local pool = contentFrame.lunchboxLabelPool
    if pool then
        local regions = { contentFrame:GetRegions() }
        for index = 1, select("#", unpack(regions)) do
            local region = regions[index]
            if region and type(region.GetObjectType) == "function"
                and region:GetObjectType() == "FontString"
                and not region.lunchboxFree then
                region:Hide()
                region:ClearAllPoints()
                region:SetText("")
                region.lunchboxFree = true
                table.insert(pool, region)
            end
        end
    end

    return 0
end

local function addLabel(cursor, text, font, colourKey)
    local label = makeLabel(contentFrame, text, font or "GameFontNormalSmall",
        rgb(colourKey or "text"))
    if not label then return cursor end

    label:SetWidth(CONTENT_WIDTH)
    oneLine(label)
    label:SetJustifyH("LEFT")
    label:SetPoint("TOPLEFT", 0, -cursor)

    return cursor + measure(label, LINE_FALLBACK) + 4
end

-- The introduction paragraphs are sentences, not one-line answers, so they
-- wrap. The height is read back after the width is set, which is why the row
-- grows correctly on a client that measures wrapped strings.
local function addParagraph(cursor, text, colourKey)
    local label = makeLabel(contentFrame, text, "GameFontNormalSmall",
        rgb(colourKey or "text"))
    if not label then return cursor end

    label:SetWidth(CONTENT_WIDTH)
    if type(label.SetWordWrap) == "function" then
        pcall(label.SetWordWrap, label, true)
    end
    label:SetJustifyH("LEFT")
    label:SetPoint("TOPLEFT", 0, -cursor)

    return cursor + measure(label, LINE_FALLBACK) + 8
end

local function addHeading(cursor, text, infoTitle, infoText)
    local label = makeLabel(contentFrame, text, "GameFontNormal", rgb("brand"))
    if not label then return cursor end

    oneLine(label)
    label:SetJustifyH("LEFT")

    -- The marker sits after the words, not after a full-width box, so the
    -- heading is measured before the "?" is attached.
    local width = CONTENT_WIDTH - 24
    if type(label.GetStringWidth) == "function" then
        local ok, measured = pcall(label.GetStringWidth, label)
        if ok and type(measured) == "number" and measured > 0 then
            width = math.min(width, measured + 2)
        end
    end
    label:SetWidth(width)
    label:SetPoint("TOPLEFT", 0, -cursor)

    local info = makeInfo(contentFrame, infoTitle or text, infoText)
    if info then info:SetPoint("LEFT", label, "RIGHT", 6, 0) end

    return cursor + measure(label, 16) + 6
end

local function addChoice(cursor, text, selected, onClick)
    local marker = selected and "[x] " or "[ ] "
    local button = makeButton(contentFrame, marker .. text, CONTENT_WIDTH,
        ROW_HEIGHT, onClick)
    if not button then return cursor end

    -- Variant labels carry the template's name, role, context and weapon; a
    -- template button that wrapped would make the row taller than measured.
    if type(button.GetFontString) == "function" then
        local ok, fontString = pcall(button.GetFontString, button)
        if ok and fontString then oneLine(fontString) end
    end
    if button.label then oneLine(button.label) end

    button:SetPoint("TOPLEFT", 0, -cursor)
    return cursor + ROW_HEIGHT + ROW_GAP
end

local function build()
    local ok, created = pcall(CreateFrame, "Frame", "LunchboxToolkitWizardFrame", UIParent)
    if not ok or not created then
        LT:Error("The build wizard window could not be created on this client.")
        return nil
    end

    local window = created
    window:SetSize(WIDTH, 160)

    local dim = CreateFrame("Frame", nil, UIParent)
    dim:SetAllPoints(UIParent)
    dim:SetFrameStrata("FULLSCREEN_DIALOG")
    dim:SetFrameLevel(0)
    dim:EnableMouse(true)
    dim:SetScript("OnMouseDown", function() end)
    local shade = dim:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints(dim)
    shade:SetColorTexture(0, 0, 0, 0.55)
    dim:Hide()
    window.lunchboxDim = dim
    window:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    if window.SetFrameStrata then window:SetFrameStrata("FULLSCREEN_DIALOG")
    window:SetFrameLevel(10) end
    window:SetClampedToScreen(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    pcall(window.RegisterForDrag, window, "LeftButton")
    window:SetScript("OnDragStart", function(self) self:StartMoving() end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        Wizard:SavePlacement()
    end)

    -- The same edge as the main window, drawn by the module that owns chrome.
    LT.Chrome.Window(window)

    -- The title band names the addon and the window, then gives way on the
    -- right to the red X. The title is measured again on every render, so a
    -- taller client font pushes the first question down instead of under it.
    titleLabel = makeLabel(window, WINDOW_TITLE, "GameFontNormal", rgb("brand"))
    if titleLabel then
        oneLine(titleLabel)
        titleLabel:SetWidth(CONTENT_WIDTH - CLOSE_SIZE - 8)
        titleLabel:SetJustifyH("LEFT")
        titleLabel:SetPoint("TOPLEFT", PADDING, -PADDING)
    end

    closeButton = makeClose(window)
    if closeButton then
        closeButton:SetPoint("TOPRIGHT", -PADDING, -PADDING)
    end

    stepLabel = makeLabel(window, "", "GameFontNormalSmall", rgb("muted"))
    if stepLabel then
        stepLabel:SetWidth(CONTENT_WIDTH)
        oneLine(stepLabel)
        stepLabel:SetJustifyH("LEFT")
        stepLabel:SetPoint("TOPLEFT", PADDING, -PADDING - 22)
    end

    contentFrame = CreateFrame("Frame", nil, window)
    contentFrame.lunchboxLabelPool = {}
    contentFrame:SetPoint("TOPLEFT", PADDING, -PADDING - 44)
    contentFrame:SetWidth(CONTENT_WIDTH)

    backButton = makeButton(window, "Back", 80, 20, function() Wizard:GoBack() end)
    backButton:SetPoint("BOTTOMLEFT", PADDING, PADDING)

    nextButton = makeButton(window, "Next", 80, 20, function() Wizard:GoNext() end)
    nextButton:SetPoint("BOTTOMLEFT", PADDING + 88, PADDING)

    applyButton = makeButton(window, "Save build 2", 110, 20,
        function() Wizard:Finish("second") end)
    applyButton:SetPoint("BOTTOMLEFT", PADDING + 88, PADDING)

    local close = makeButton(window, "Close", 70, 20, function() Wizard:Hide() end)
    close:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)

    -- Escape closes this window; it never closes the main UI window. The flow
    -- state is dropped here too, so Escape leaves the same clean start as the
    -- Close button.
    if type(UISpecialFrames) == "table" then
        table.insert(UISpecialFrames, "LunchboxToolkitWizardFrame")
    end
    window:SetScript("OnHide", function()
        if window.lunchboxDim then window.lunchboxDim:Hide() end
        Wizard.target = nil
        Wizard.phase = nil
        Wizard.question = nil
        Wizard.confirmedSameTemplate = nil
        Wizard.firstWritten = nil
        Wizard.intro = nil
        Wizard.introStep = nil
    end)

    frame = window
    window:Hide()
    return window
end

------------------------------------------------------------------------------
-- Remembered place: fractions of the UI area from its bottom-left, the same
-- shape UI.lua uses for its own window. A resolution change lands in the same
-- relative spot and the clamp below keeps the window reachable.
------------------------------------------------------------------------------

local function windowRecord()
    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return nil end
    if type(character.window) ~= "table" then character.window = {} end
    return character.window
end

local function screenSize()
    if not UIParent or type(UIParent.GetWidth) ~= "function" then return 0, 0 end
    local okWidth, width = pcall(UIParent.GetWidth, UIParent)
    local okHeight, height = pcall(UIParent.GetHeight, UIParent)
    if not okWidth or not okHeight then return 0, 0 end
    return tonumber(width) or 0, tonumber(height) or 0
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

function Wizard:ApplyPlacement()
    if not frame then return end

    local uiWidth, uiHeight = screenSize()
    local width = frame:GetWidth() or WIDTH
    local height = frame:GetHeight() or 320
    local margin = 8

    local record = windowRecord()
    local place = record and record.wizard
    local x, y

    if type(place) == "table" and type(place.x) == "number" and type(place.y) == "number" then
        x = place.x * uiWidth
        y = place.y * uiHeight
    else
        x = (uiWidth - width) / 2
        y = (uiHeight - height) / 2
    end

    if uiWidth > 0 and uiHeight > 0 then
        if uiWidth > width then
            x = clamp(x, margin, uiWidth - width - margin)
        else
            x = (uiWidth - width) / 2
        end

        if uiHeight > height then
            y = clamp(y, margin, uiHeight - height - margin)
        else
            y = (uiHeight - height) / 2
        end
    end

    frame:ClearAllPoints()
    frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
end

function Wizard:SavePlacement()
    if not frame then return end

    local record = windowRecord()
    if not record then return end

    local uiWidth, uiHeight = screenSize()
    if uiWidth <= 0 or uiHeight <= 0 then return end

    local scale = frame:GetEffectiveScale() or 1
    local left = frame:GetLeft()
    local bottom = frame.GetBottom and frame:GetBottom() or nil
    local uiLeft = UIParent.GetLeft and UIParent:GetLeft() or nil
    local uiBottom = UIParent.GetBottom and UIParent:GetBottom() or nil

    if not left or not bottom or not uiLeft or not uiBottom then return end

    record.wizard = {
        x = ((left - uiLeft) / scale) / uiWidth,
        y = ((bottom - uiBottom) / scale) / uiHeight,
    }
end

------------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------------

local function describePlan(plan, index, willWrite)
    local slot = plan.slots[index]
    if not slot then return "Build " .. tostring(index) .. ": no plan" end

    if not willWrite then
        return "Build " .. tostring(index) .. ": hand-tuned — left alone"
    end

    local context = plan.context
    if index == 2 and plan.offContext then context = plan.offContext end

    return "Build " .. tostring(index) .. ": " .. tostring(slot.spec)
        .. " · " .. tostring(slot.role)
        .. " · " .. contextLabel(context)
end

-- The questionnaire reads one build at a time. Phase 1 is slot 1 and phase 2
-- is slot 2; the fields never mix, so changing a slot-1 answer cannot rewrite
-- the slot-2 answers that were just given.
local function phaseRole(draft, phase)
    if phase == 2 then return draft.offRole end
    return draft.role
end

local function phaseSpec(draft, phase)
    if phase == 2 then return draft.offSpec end
    return draft.spec
end

local function phaseContext(draft, phase)
    if phase == 2 then return draft.offContext or draft.context end
    return draft.context
end

local function phaseTemplate(draft, phase)
    if phase == 2 then return draft.offTemplate end
    return draft.template
end

------------------------------------------------------------------------------
-- First-run introduction
--
-- The first login shows what the toolkit does, not a build questionnaire:
-- there is no specialisation before level 10 and nothing to build yet. Three of
-- the pages are interactive - the switches, the levelling direction and the
-- ranks ask - and none of them writes anything until Finish. The join command
-- is printed into the chat box, never run for the player.
------------------------------------------------------------------------------

local function leaderboardChannel()
    local board = LT.Leaderboard
    if type(board) == "table" and type(board.ChannelName) == "function" then
        local ok, name = pcall(board.ChannelName, board)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return "LBTK"
end

-- The shipped defaults, so a switch can print what its default is even before
-- the character record has been written.
local function optionDefaults()
    local database = LT.Database
    if type(database) ~= "table" or type(database.defaultOptions) ~= "function" then
        return {}
    end

    local ok, defaults = pcall(database.defaultOptions, database)
    if ok and type(defaults) == "table" then return defaults end
    return {}
end

-- The character's own options table, or nil when the record is not loaded.
local function liveOptions()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return nil
    end

    local ok, options = pcall(database.GetOptions, database)
    if ok and type(options) == "table" then return options end
    return nil
end

-- Whether the leaderboard is sharing this character's progress. The module owns
-- the key; the tour reads it through the same accessor the Ranks page uses and
-- never writes it directly.
local function sharingNow()
    local board = LT.Leaderboard
    if type(board) == "table" and type(board.IsSharing) == "function" then
        local ok, value = pcall(board.IsSharing, board)
        if ok then return value == true end
    end
    return false
end

-- The switches the tour offers, each with the key it writes and one sentence on
-- what ticking it does. Every key is one Database.defaultOptions() already
-- ships and one of this addon's own modules already reads, so the tour explains
-- existing switches and invents none. `onlyClass` keeps a switch that belongs
-- to one class off every other class's page.
local INTRO_SWITCHES = {
    {
        key = "tooltipEnabled",
        label = "Item scores in tooltips",
        help = "Ticked, hovering an item adds the comparison line: upgrade, "
            .. "sidegrade or downgrade, and the reason.",
    },
    {
        key = "questRewardHighlight",
        label = "Highlight the best quest reward",
        help = "Ticked, the best of a quest's reward choices is outlined, so the "
            .. "pick has a reason instead of a guess.",
    },
    {
        key = "bagSpaceWarning",
        label = "Warn when the bags are nearly full",
        help = "Ticked, one line appears when two or fewer bag slots are free - "
            .. "before the bags are actually full.",
    },
    {
        key = "bagFrames",
        label = "Annotate the client's own bag frames",
        onValue = "client",         -- ticked: marks land on the client's own bags
        offValue = "replacement",   -- unticked: Bagnon / Baganator owns them
        help = "Ticked, the upgrade border and arrow are drawn on the client's own "
            .. "bag slots. Untick only when Bagnon or Baganator draws the bags: the "
            .. "toolkit then leaves their frames alone. Default: on ('client').",
    },
    {
        key = "junkSale",
        label = "Vendor auto-sell - the score-based junk sale",
        help = "Ticked, /lbv junk and the bag button may offer items the score calls "
            .. "worthless for this build, not only grey. The first press marks them "
            .. "and the second sells; nothing is destroyed. Off by default.",
    },
    {
        key = "toastUpgrades",
        label = "Toast when loot is an upgrade",
        help = "Ticked, loot that beats what you wear gets one line the moment "
            .. "you pick it up.",
    },
    {
        key = "debugChat",
        label = "Diagnostic lines in chat",
        help = "Ticked, chat fills with what the addon is reading and why. Noisy; "
            .. "it is for reporting a problem, not for playing.",
    },
    {
        key = "shamanImbueReminder",
        label = "Main-hand imbue reminder",
        onlyClass = "SHAMAN",
        help = "Ticked, one warning when the main-hand weapon carries no imbue or "
            .. "the imbue is about to expire.",
    },
}

-- One switch's value as the tour currently shows it: the draft if the player has
-- touched it, otherwise what the character record holds, otherwise the shipped
-- default. A row with onValue/offValue is a two-value setting shown as one tick
-- (ticked = the `onValue` word), so the draft stays boolean either way.
local function introSwitchValue(wizard, row)
    local key = row.key
    local draft = wizard.switchDraft
    if type(draft) == "table" and type(draft[key]) == "boolean" then
        return draft[key]
    end

    local options = liveOptions()
    if options then
        if type(row.onValue) == "string" then
            if type(options[key]) == "string" then
                return options[key] ~= row.offValue
            end
        elseif type(options[key]) == "boolean" then
            return options[key]
        end
    end

    local defaults = optionDefaults()
    if type(row.onValue) == "string" then
        return defaults[key] == row.onValue
    end
    return defaults[key] == true
end

local function introPages()
    return {
        {
            title = "Welcome to Lunchbox Toolkit",
            lines = {
                "Every item is scored against the build you are playing, so you can "
                    .. "tell an upgrade from a sidegrade before you equip it.",
                "Nothing is equipped, bought or sold for you. The addon reads your "
                    .. "character and explains; every decision stays yours.",
                "Use Next for a short tour, or close this window and open it again "
                    .. "any time with /lt setup.",
            },
        },
        {
            title = "Tooltips and scoring",
            lines = {
                "Hover an item: its tooltip gains a line comparing it with what you "
                    .. "wear and saying upgrade, sidegrade or downgrade — and why.",
                "/lt why explains the last item you hovered. /lt scan lists the "
                    .. "upgrades that are already in your bags.",
                "The weights come from your build — role, specialisation and context. "
                    .. "You set those on the Builds page.",
            },
        },
        {
            title = "Quest rewards",
            lines = {
                "When a quest offers a choice, the reward that upgrades you most is "
                    .. "marked, so you can pick with a reason instead of a guess.",
                "/lt quest reads the current reward list again. The ranking always "
                    .. "uses the active build.",
                "If nothing upgrades you, the reward with the best vendor value is "
                    .. "marked instead.",
            },
        },
        {
            title = "Bags",
            lines = {
                "/lt scan sorts the bags into what you can wear now and what waits "
                    .. "for a level. /lt drop lists what to destroy first when the "
                    .. "bags are full.",
                "A bag-space warning appears before the last slot is gone.",
                "Bag checks run out of combat only, so they never interrupt a fight.",
            },
        },
        {
            kind = "switches",
            title = "The switches you will actually use",
            lines = {
                "Each row is a real switch, set here where it is explained. Its "
                    .. "default is printed beside it: tick or untick anything and "
                    .. "press Finish to keep the answers.",
                "Nothing is written yet. Closing this window without Finish leaves "
                    .. "every switch exactly as it was, and they all live again under "
                    .. "/lt options.",
            },
        },
        {
            kind = "direction",
            title = "What are you doing first?",
            lines = {
                "Below level 10 there is no talent tree to answer for, so one "
                    .. "profile scores for you. Saying what you are doing first points "
                    .. "build slot 1 at that specialisation now, instead of leaving it "
                    .. "generic until the level-10 wizard asks.",
                "Your choice shows on the Builds page straight away and is offered "
                    .. "again, already filled in, when the build wizard opens at 10.",
            },
        },
        {
            kind = "ranks",
            title = "Ranks and the channel",
            lines = {
                "/lt ranks opens the leaderboard. Sharing is opt-in: nothing is sent "
                    .. "until you switch it on, and reports travel between toolkit "
                    .. "users as addon messages.",
                "At level 10 the build wizard opens once to choose your first "
                    .. "specialisation. Until then one default profile scores for you.",
                "That is the tour. Press Finish to open the main window.",
            },
        },
    }
end

-- The levelling direction this class pack ships, from the starters it already
-- carries: a "Levelling" starter wins, then its first PvE starter for a damage
-- role (ClassPacks:GetLevelling), then the class's default spec. Returns
-- { spec, role, name } or nil; name is the starter the recommendation came
-- from, so the page can say where the answer is written down.
function Wizard:RecommendedDirection()
    local options = self:ClassOptions()
    if #(options.specs or {}) == 0 then return nil end

    local packs = LT.ClassPacks
    local classToken = LT.player and LT.player.class
    local suggested

    if type(packs) == "table" and type(packs.GetLevelling) == "function"
        and type(classToken) == "string" and classToken ~= "" then
        local ok, entry = pcall(packs.GetLevelling, packs, classToken)
        if ok then suggested = entry end
    end

    if type(suggested) == "table" and type(suggested.spec) == "string"
        and has(options.specs, suggested.spec) then
        local role = suggested.role
        if not has(options.roles or {}, role) then
            role = roleForSpec(options, suggested.spec, options.defaultRole)
        end
        return { spec = suggested.spec, role = role, name = suggested.name }
    end

    return { spec = options.defaultSpec, role = options.defaultRole }
end

-- The values the tour opens with. The draft is a copy: nothing typed on the
-- pages reaches the character record until Finish.
function Wizard:ResetIntroDraft()
    local options = liveOptions()
    local defaults = optionDefaults()

    local draft = {}
    for _, row in ipairs(INTRO_SWITCHES) do
        local value = options and options[row.key]
        if type(row.onValue) == "string" then
            -- A two-value switch: the draft tick means "onValue", so an unread
            -- string falls back to the shipped word rather than to false.
            if type(value) == "string" then
                value = value ~= row.offValue
            else
                value = defaults[row.key] == row.onValue
            end
        elseif type(value) ~= "boolean" then
            value = defaults[row.key] == true
        end
        draft[row.key] = value
    end
    self.switchDraft = draft

    self.shareDraft = sharingNow()

    local direction = self:RecommendedDirection()
    self.directionSpec = direction and direction.spec or nil
    self.directionRole = direction and direction.role or nil
    self.directionRecommended = direction and direction.name or nil

    return draft
end

-- The switch rows: one checkbox row per switch, with the sentence that says
-- what ticking it does printed underneath. The toggle only edits the draft.
local function drawIntroSwitches(wizard, cursor)
    local defaults = optionDefaults()
    local classToken = LT.player and LT.player.class

    for _, row in ipairs(INTRO_SWITCHES) do
        if row.onlyClass == nil or row.onlyClass == classToken then
            local value = introSwitchValue(wizard, row)
            -- The shipped default printed beside the row, in the row's own words.
            local on = type(row.onValue) == "string" and row.onValue or true
            local word = defaults[row.key] == on and "on" or "off"

            cursor = addChoice(cursor, row.label .. " — default " .. word, value,
                function()
                    if type(wizard.switchDraft) ~= "table" then
                        wizard:ResetIntroDraft()
                    end
                    wizard.switchDraft[row.key] = not value
                    wizard:Render()
                end)
            cursor = addParagraph(cursor, row.help, "muted")
        end
    end

    return cursor
end

-- The direction rows: one per specialisation this class can play, with the
-- pack's own recommendation marked and already selected.
local function drawIntroDirection(wizard, cursor)
    local options = wizard:ClassOptions()
    local recommended = wizard:RecommendedDirection()

    if #(options.specs or {}) == 0 then
        return addLabel(cursor, "No specialisation data is available for this class yet.",
            "GameFontNormalSmall", "muted")
    end

    if type(wizard.directionRecommended) == "string" and wizard.directionRecommended ~= "" then
        cursor = addParagraph(cursor,
            "This class's levelling starter is " .. wizard.directionRecommended .. ".",
            "brand")
    end

    for _, spec in ipairs(options.specs) do
        local roles = options.specsByRole and options.specsByRole[spec] or {}
        local role = roles[1] or options.defaultRole
        local label = spec .. (role and (" — " .. tostring(role)) or "")
        if type(recommended) == "table" and recommended.spec == spec then
            label = label .. "  (recommended)"
        end

        cursor = addChoice(cursor, label, wizard.directionSpec == spec, function()
            wizard.directionSpec = spec
            wizard.directionRole = role
            wizard:Render()
        end)
    end

    return cursor + 4
end

-- The ranks ask: the sharing switch (off unless ticked) and the join command,
-- which is copied into the chat edit box and never run here.
local function drawIntroRanks(wizard, cursor)
    local channel = leaderboardChannel()
    local shared = wizard.shareDraft
    if type(shared) ~= "boolean" then shared = sharingNow() end

    cursor = addChoice(cursor, "Share my progress on the leaderboard — default off",
        shared, function()
            wizard.shareDraft = not shared
            wizard:Render()
        end)
    cursor = addParagraph(cursor, "Sharing stays opt-in: with this unticked nothing "
        .. "is sent and nothing is stored, and reports only travel between toolkit "
        .. "users as addon messages.", "muted")

    cursor = addParagraph(cursor, "The optional custom channel is called " .. channel
        .. ". To listen in, type  /join " .. channel .. "  in chat yourself — this "
        .. "addon will not join it for you.", "text")

    local copy = makeButton(contentFrame, "Copy  /join " .. channel, 200, 22,
        function()
            local command = "/join " .. leaderboardChannel()
            local opened = false
            if type(ChatFrame_OpenChat) == "function" then
                local ok = pcall(ChatFrame_OpenChat, command)
                opened = ok
            end
            if opened then
                LT:Print("The join command is in the chat box. Press Enter to join "
                    .. leaderboardChannel() .. " yourself.")
            else
                LT:Print("This client will not let the addon fill the chat box. "
                    .. "Type  " .. command .. "  yourself.")
            end
        end)
    if copy then copy:SetPoint("TOPLEFT", 0, -cursor) end

    return cursor + 28
end

function Wizard:Render()
    if not frame or not contentFrame then return end

    local intro = self.intro == true
    local introStep = tonumber(self.introStep) or 1
    local introList = intro and introPages() or nil

    if not intro and not self.draft then self:ResetDraft() end
    self.overrides = self.overrides or { [1] = false, [2] = false }

    local options = self:ClassOptions()
    local draft = self.draft
    local phase = self.phase or 1
    local step = self.step or 1
    local question = self.question
    local cursor = clearContent()

    if stepLabel then
        if intro then
            stepLabel:SetText("Getting started · Page " .. tostring(introStep)
                .. " of " .. tostring(#introList))
        elseif question == "second" then
            stepLabel:SetText("Build 1 saved · build 2 optional")
        elseif question == "same" then
            stepLabel:SetText("Two builds · one starter build")
        elseif step > 4 then
            stepLabel:SetText("")
        elseif phase == 2 then
            stepLabel:SetText("Build 2 · Step " .. tostring(step) .. " of 4 · "
                .. tostring(STEP_TITLES[step] or ""))
        else
            stepLabel:SetText("Step " .. tostring(step) .. " of 4 · "
                .. tostring(STEP_TITLES[step] or ""))
        end
    end

    if intro then
        local page = introList[introStep] or introList[1]
        cursor = addHeading(cursor, page.title)
        for _, line in ipairs(page.lines or {}) do
            cursor = addParagraph(cursor, line)
        end

        if page.kind == "switches" then
            cursor = drawIntroSwitches(self, cursor)
        elseif page.kind == "direction" then
            cursor = drawIntroDirection(self, cursor)
        elseif page.kind == "ranks" then
            cursor = drawIntroRanks(self, cursor)
        end

    elseif question == "second" then
        local plan = self:Plan()
        local wroteFirst = self.firstWritten == true

        cursor = addHeading(cursor, "Set up a second build?",
            "Second build", "Build 1 is saved. Yes asks the same four questions "
                .. "for build 2 and saves it when you press Save build 2. No "
                .. "thanks closes this window; build 2 is left as it is and the "
                .. "main window stays open.")

        cursor = addLabel(cursor, describePlan(plan, 1, wroteFirst),
            "GameFontNormalSmall", wroteFirst and "text" or "muted")
        cursor = cursor + 8

        local yes = makeButton(contentFrame, "Yes, set up build 2", 210, 22,
            function() Wizard:AcceptSecond() end)
        if yes then yes:SetPoint("TOPLEFT", 0, -cursor) end

        local no = makeButton(contentFrame, "No thanks, done for now", 210, 22,
            function() Wizard:DeclineSecond() end)
        if no then no:SetPoint("TOPLEFT", 220, -cursor) end

        cursor = cursor + 26

    elseif question == "same" then
        local plan = self:Plan()
        local wroteFirst = self.firstWritten == true
        local willWrite2 = plan.untouched[2] or self.overrides[2] == true

        cursor = addHeading(cursor,
            "Both builds will use the same starting weights — save anyway?",
            "Same starter", "Slot 1 and slot 2 resolve to the same class-pack "
                .. "starter, so the two builds begin from identical weights. Yes "
                .. "saves build 2 and closes. Choose another for build 2 goes back "
                .. "to the starter list for slot 2.")

        cursor = addLabel(cursor, describePlan(plan, 1, wroteFirst),
            "GameFontNormalSmall", wroteFirst and "text" or "muted")
        cursor = addLabel(cursor, describePlan(plan, 2, willWrite2),
            "GameFontNormalSmall", willWrite2 and "text" or "muted")
        cursor = cursor + 8

        local save = makeButton(contentFrame, "Yes, save build 2", 150, 22,
            function() Wizard:AcceptSame() end)
        if save then save:SetPoint("TOPLEFT", 0, -cursor) end

        local another = makeButton(contentFrame, "Choose another for build 2", 230, 22,
            function() Wizard:ChooseAnotherSecond() end)
        if another then another:SetPoint("TOPLEFT", 160, -cursor) end

        cursor = cursor + 26

    elseif step == 1 then
        local selected = phaseRole(draft, phase)
        local heading = phase == 2 and "Which role is build 2 for?"
            or "Which role is this build for?"

        cursor = addHeading(cursor, heading,
            "Role", "Only the roles this class can play are listed. They come from "
                .. "the class pack; a spec that cannot be played as the chosen role "
                .. "is not offered on the next step.")

        if #options.roles == 0 then
            cursor = addLabel(cursor, "No role data is available for this class yet.",
                "GameFontNormalSmall", "muted")
        else
            for _, role in ipairs(options.roles) do
                local field = phase == 2 and "offRole" or "role"
                cursor = addChoice(cursor, role, selected == role, function()
                    if self:SetChoice(field, role) then self:Render() end
                end)
            end
        end

    elseif step == 2 then
        local role = phaseRole(draft, phase)
        local selected = phaseSpec(draft, phase)
        local specs = specsForRole(options, role)
        local heading = phase == 2 and "Which specialisation for build 2?"
            or "Which specialisation?"

        cursor = addHeading(cursor, heading,
            "Spec", "Specs are filtered by the role chosen on the first step. "
                .. "A class pack may tie one spec to more than one role; the spec "
                .. "list always comes from this class only.")

        if #specs == 0 then
            cursor = addLabel(cursor, "No spec data is available for this role.",
                "GameFontNormalSmall", "muted")
        else
            for _, spec in ipairs(specs) do
                local field = phase == 2 and "offSpec" or "spec"
                cursor = addChoice(cursor, spec, selected == spec, function()
                    if self:SetChoice(field, spec) then self:Render() end
                end)
            end
        end

    elseif step == 3 then
        local selected = phaseContext(draft, phase)
        local role = phaseRole(draft, phase)
        local spec = phaseSpec(draft, phase)
        local contexts = self:ContextOptions(role, spec)
        local heading = phase == 2 and "Where will you play build 2?"
            or "Where will you play it?"

        cursor = addHeading(cursor, heading,
            "Context", "Only the contexts with a bundled profile for this class, "
                .. "role and specialty are listed, so every row leads to weights. "
                .. "Levelling is the same scoring context as PvE; it records that "
                .. "the build is for levelling. There is no level question: the "
                .. "level the score already uses decides the default.")

        if #contexts == 0 then
            cursor = addLabel(cursor,
                "No bundled weights exist for this role and specialty yet.",
                "GameFontNormalSmall", "muted")
        else
            -- A draft restored from an older answer may name a context this
            -- class no longer covers. Move it to a row that exists rather than
            -- drawing a question with nothing selected.
            if not hasContext(contexts, selected) then
                local field = phase == 2 and "offContext" or "context"
                selected = self:ContextFallback(role, spec)
                self:SetChoice(field, selected)
            end

            for _, entry in ipairs(contexts) do
                local field = phase == 2 and "offContext" or "context"
                cursor = addChoice(cursor, entry.label, selected == entry.key, function()
                    if self:SetChoice(field, entry.key) then self:Render() end
                end)
            end
        end

    elseif step == 4 then
        local list = templates()
        local slot = phase == 2 and 2 or 1
        local variants = self:TemplateChoices(slot)
        local selectedTemplate = phaseTemplate(draft, phase)
        local spec = phaseSpec(draft, phase)
        local heading = phase == 2 and "Which starter build for build 2?"
            or "Which starter build?"

        cursor = addHeading(cursor, heading,
            "Starter build", "Each row is one configuration this class pack ships "
                .. "for the role and context chosen on the earlier steps: its name, "
                .. "role, context and weapon setup, so 2H, DW and 1H+shield are told "
                .. "apart before anything is applied. A starter is a template, never "
                .. "a saved profile, so it cannot hand over someone else's weights.")

        cursor = addLabel(cursor,
            (phase == 2 and "Build 2 · " or "Build 1 · ") .. tostring(spec or "Any"),
            "GameFontNormal", "brand")

        if #list == 0 and phase == 2 then
            -- No templates at all: the class spec list is the only choice, and
            -- it includes the spec already used by build 1.
            for _, specChoice in ipairs(options.specs or {}) do
                cursor = addChoice(cursor, specChoice, draft.offSpec == specChoice, function()
                    if self:SetChoice("offSpec", specChoice) then self:Render() end
                end)
            end
        elseif #variants == 0 then
            cursor = addLabel(cursor,
                "No starter variant lists this spec. The role, spec and context "
                    .. "chosen on the earlier steps are used instead.",
                "GameFontNormalSmall", "muted")
        else
            for _, template in ipairs(variants) do
                local id = templateId(template)
                cursor = addChoice(cursor, variantLabel(template),
                    selectedTemplate == id, function()
                        if self:ChooseTemplate(slot, id) then self:Render() end
                    end)
            end
        end

        -- One line for the slot this step is about. No checkbox: a slot is
        -- filled only while it is untouched, and the save buttons write the
        -- slot the step asked about.
        local plan = self:Plan()
        local index = phase == 2 and 2 or 1
        local willWrite = plan.untouched[index] or self.overrides[index] == true
        cursor = cursor + 4
        cursor = addLabel(cursor, describePlan(plan, index, willWrite),
            "GameFontNormalSmall", willWrite and "text" or "muted")
    end

    -- The header is measured after both font strings exist, so a taller client
    -- font pushes the content down instead of overlapping the title.
    local titleHeight = measure(titleLabel, 18)
    local stepHeight = measure(stepLabel, LINE_FALLBACK)
    local headerHeight = PADDING + titleHeight + 6 + stepHeight + 10

    if stepLabel then
        stepLabel:ClearAllPoints()
        stepLabel:SetPoint("TOPLEFT", PADDING, -(PADDING + titleHeight + 6))
    end

    contentFrame:ClearAllPoints()
    contentFrame:SetPoint("TOPLEFT", PADDING, -headerHeight)
    contentFrame:SetWidth(CONTENT_WIDTH)
    contentFrame:SetHeight(math.max(cursor, 1))

    -- Header + measured content + footer (button row and margins).
    local height = headerHeight + cursor + 12 + 20 + PADDING + 12
    frame:SetHeight(math.max(height, 120))

    -- The question screens have their own two answers. Back is never offered
    -- there: build 1 is already written, and returning to its last step would
    -- offer a second save of the same slot. Back also stays hidden on the
    -- slot-2-only flow, which has no earlier step.
    local showBack = false
    if intro then
        showBack = introStep > 1
    elseif question then
        showBack = false
    elseif step > 1 then
        showBack = true
    elseif phase == 2 and step == 1 and self.target ~= 2 then
        showBack = true
    end

    if backButton then
        if showBack then backButton:Show() else backButton:Hide() end
    end

    if nextButton then
        if intro then
            nextButton:Show()
            pcall(nextButton.SetText, nextButton,
                introStep >= #introList and "Finish" or "Next")
        else
            local atEnd = (step or 1) >= 4
            local showNext = not question
                and (not atEnd or ((phase or 1) == 1 and self.target ~= 2))
            if showNext then nextButton:Show() else nextButton:Hide() end
            pcall(nextButton.SetText, nextButton, atEnd and "Save build 1" or "Next")
        end
    end

    if applyButton then
        if not intro and not question and step == 4 and (phase or 1) == 2 then
            applyButton:Show()
            pcall(applyButton.SetText, applyButton, "Save build 2")
        else
            applyButton:Hide()
        end
    end

    -- A longer step grows the window; clamp the new height immediately so a
    -- remembered place near the top of the UI cannot push it past the edge.
    if frame:IsShown() then self:ApplyPlacement() end
end

------------------------------------------------------------------------------
-- Steps and the window
------------------------------------------------------------------------------

-- Slot 2's questionnaire starts from the answers the draft already holds, but
-- a record written before the two-phase flow has no offRole/offContext. Only
-- missing fields are filled; a player's answer is never overwritten.
local function ensureSecondDraft(wizard)
    local options = wizard:ClassOptions()
    local draft = wizard.draft
    if not draft then return nil end

    if not has(options.specs or {}, draft.offSpec) then
        draft.offSpec = draft.spec or options.defaultSpec
    end
    if not has(options.roles or {}, draft.offRole) then
        draft.offRole = roleForSpec(options, draft.offSpec, draft.role)
            or draft.role or options.defaultRole
    end
    if not validContext(draft.offContext) then
        draft.offContext = draft.context
    end
    -- The second questionnaire may start after a role or spec change on the
    -- Builds page, so the shared context is only reused when the bundled
    -- profiles still cover it for slot 2's own role and spec.
    if not wizard:OffersContext(draft.offRole, draft.offSpec, draft.offContext) then
        draft.offContext = wizard:ContextFallback(draft.offRole, draft.offSpec)
    end
    draft.dualSpec = true
    return draft
end

-- One press, one save. `mode` names the only slot that may be written, so a
-- second press cannot reach the slot the first one saved.
local function applyOnce(wizard, mode)
    local ok, applied, plan = wizard:Apply(wizard.overrides, mode)
    if not ok then
        LT:Warn(applied or "The build wizard could not apply the answers.")
        return false
    end

    local list = applied or {}
    if #list == 0 then
        LT:Print("Build setup saved. No untouched slot needed filling, so nothing was overwritten.")
    else
        local names = {}
        for _, index in ipairs(list) do names[#names + 1] = "Build " .. tostring(index) end
        LT:Print("Build setup saved. Filled " .. table.concat(names, " and ") .. ".")
    end

    return true, list, plan
end

-- The second build opens at level 10, the first talent point. Below that the
-- character has one default profile and the wizard offers one slot.
function Wizard:CanSecondSlot()
    local level = playerLevel()
    if level then return level >= 10 end
    local builds = LT.Builds
    return type(builds) == "table" and tonumber(builds.SLOT_COUNT) == 2
end

-- Introduction navigation. These pages never write a build, and Back stops at
-- the first page so the first answer cannot be reached twice.
function Wizard:IntroNext()
    local pages = introPages()
    local step = tonumber(self.introStep) or 1
    if step < #pages then
        self.introStep = step + 1
        self:Render()
        return self.introStep
    end
    return self:FinishIntro()
end

function Wizard:IntroBack()
    local step = tonumber(self.introStep) or 1
    if step > 1 then
        self.introStep = step - 1
        self:Render()
    end
    return self.introStep
end

-- The three answers the tour can hold, written here and nowhere else. Closing
-- the window before Finish never reaches this function, so every switch, the
-- direction and the leaderboard ask stay exactly as they were.
function Wizard:ApplyIntroAnswers()
    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return false end

    -- 1. The switches, into the same option keys the Settings page writes, so a
    -- second place does not grow its own copy of the settings.
    local options = liveOptions()
    local drafted = self.switchDraft
    if options and type(drafted) == "table" then
        for _, row in ipairs(INTRO_SWITCHES) do
            local value = drafted[row.key]
            if type(value) == "boolean" then
                -- A two-value setting is stored as its word; every other row as
                -- the tick itself. A row left at its default is written too, so
                -- Finish always leaves a decided record.
                local settled = value
                if type(row.onValue) == "string" then
                    settled = value and row.onValue or row.offValue
                end

                if options[row.key] ~= settled then
                    options[row.key] = settled
                end
            end
        end
    end

    -- 2. The levelling direction. Slot 1 is pointed at the chosen spec now, so
    -- the score that matters before level 10 is right before level 10 rather
    -- than after it. The weapon setup, name and imbue are deliberately left
    -- alone: what the character actually holds is Builds' answer, and a slot
    -- the player has already tuned is never rewritten.
    local spec = self.directionSpec
    if type(spec) == "string" and spec ~= "" then
        local builds = LT.Builds
        if type(builds) == "table" and type(builds.Get) == "function"
            and self:IsSlotUntouched(1) then
            local okBuild, build = pcall(builds.Get, builds, 1)
            if okBuild and type(build) == "table" and build.spec ~= spec then
                writeField(1, "SetSpec", spec)
                if type(self.directionRole) == "string" then
                    writeField(1, "SetRole", self.directionRole)
                end
            end
        end

        -- Recorded on the character, not in character.setup: that table means
        -- "the build questions are answered" and would silence the level-10
        -- prompt. ResetDraft reads this back so the wizard opens on the same
        -- answer the player gave here.
        character.direction = {
            spec = spec,
            role = self.directionRole,
            context = "LEVELING",
            at = timeNow(),
        }
    end

    -- 3. The leaderboard ask, through the module's own switch. The channel
    -- itself is never joined: the command is printed for the player to send.
    if type(self.shareDraft) == "boolean" then
        local board = LT.Leaderboard
        if type(board) == "table" and type(board.SetSharing) == "function" then
            pcall(board.SetSharing, board, self.shareDraft)
        end
    end

    -- Spending the prompt is part of finishing: the tour is shown once and
    -- /lt setup is the way back to it.
    character.setupPrompted = true
    if type(database.Save) == "function" then
        pcall(database.Save, database, "wizard:intro")
    end

    return true
end

-- The end of the tour. The answers are written first, then the first-use prompt
-- is spent and the main window (its rail) opens.
function Wizard:FinishIntro()
    self:ApplyIntroAnswers()

    self.intro = nil
    self.introStep = nil
    self.switchDraft = nil
    self.shareDraft = nil
    self.directionSpec = nil
    self.directionRole = nil
    self.directionRecommended = nil
    self:Hide()

    local ui = LT.UI
    if type(ui) == "table" and type(ui.Show) == "function" then
        pcall(ui.Show, ui)
    end

    -- A character already past level 10 still owes one build answer. Ask now
    -- instead of waiting for a level-up that has already happened; below 10
    -- this is a no-op and the one default profile keeps scoring.
    self:BuildPromptIfNeeded()
    return true
end

-- Starts a flow: slot 1 walks build 1 and then asks about build 2; slot 2
-- opens directly on build 2's questionnaire and never writes slot 1.
function Wizard:BeginFlow(target)
    local slot = tonumber(target)
    if slot ~= 2 then slot = 1 end

    self.target = slot
    self.question = nil
    self.confirmedSameTemplate = nil
    self.firstWritten = nil
    self.overrides = { [1] = false, [2] = false }

    if slot == 2 then
        if not self.draft then self:ResetDraft() end
        ensureSecondDraft(self)
        self.phase = 2
    else
        self.phase = 1
        if self.draft then self.draft.dualSpec = false end
    end

    self.step = 1
end

function Wizard:GoNext()
    if self.intro then return self:IntroNext() end
    if self.question then return self.step end

    local phase = self.phase or 1
    local step = self.step or 1

    if step < 4 then
        self.step = step + 1
    elseif phase == 1 and self.target ~= 2 then
        -- Save build 1 once, then ask about build 2. The question has no Back
        -- and no Apply, so this slot is never written a second time.
        local ok, applied = applyOnce(self, "first")
        if not ok then return self.step end

        self.firstWritten = false
        for _, index in ipairs(applied or {}) do
            if index == 1 then self.firstWritten = true end
        end
        -- Below level 10 there is no second slot to offer: save build 1 and
        -- close, exactly as "No thanks" does after the question.
        if not self:CanSecondSlot() then
            self:Hide()
            return self.step
        end
        self.question = "second"
        self.step = 5
    elseif phase == 2 then
        -- The footer shows Save build 2 on this step; a keyboard/scripted Next
        -- takes the same path as the button.
        return self:Finish("second")
    end

    self:Render()
    return self.step
end

function Wizard:GoBack()
    if self.intro then return self:IntroBack() end
    local phase = self.phase or 1
    local step = self.step or 1

    if self.question == "same" then
        return self:ChooseAnotherSecond()
    end

    -- The second-build question is a point of no return: build 1 is already
    -- saved and its last step would offer a second write. Back is hidden
    -- there, and this makes a scripted call obey the same rule.
    if self.question == "second" then
        return self.step
    end

    if phase == 2 and step == 1 then
        -- From slot 2 back to the question that opened it. A slot-2-only flow
        -- has no earlier step, so Back stays hidden and does nothing.
        if self.target == 2 then return self.step end
        self.phase = 1
        self.question = "second"
        self.step = 5
        self:Render()
        return self.step
    end

    if step > 1 then
        self.step = step - 1
        self:Render()
    end
    return self.step
end

-- "Yes, set up build 2": close the question and walk slot 2's questionnaire.
-- Build 1 is already saved and is not written again.
function Wizard:AcceptSecond()
    if not self.draft then self:ResetDraft() end
    ensureSecondDraft(self)
    self.question = nil
    self.phase = 2
    self.step = 1
    self:Render()
    return true
end

-- "No thanks, done for now": build 1 was written when the question appeared.
-- This closes the wizard and writes nothing else.
function Wizard:DeclineSecond()
    self.question = nil
    self:Hide()
    return true
end

-- "Yes, save build 2" on the same-starter question. The flag makes Finish skip
-- the question it would otherwise ask again; only slot 2 is written.
function Wizard:AcceptSame()
    self.confirmedSameTemplate = true
    self.question = nil
    return self:Finish("second")
end

-- "Choose another for build 2": back to slot 2's starter list.
function Wizard:ChooseAnotherSecond()
    self.confirmedSameTemplate = nil
    self.question = nil
    self.phase = 2
    self.step = 4
    self:Render()
    return true
end

-- True when both slots resolve to the same class-pack starter. It compares the
-- template handles the plan actually used, so an explicit choice and a lookup
-- landing on the same starter count as the same answer to the player.
function Wizard:SameTemplateSelected()
    local plan = self:Plan()
    local first = plan.slots[1] and plan.slots[1].templateKey
    local second = plan.slots[2] and plan.slots[2].templateKey

    -- Identical starters begin from identical weights only while they are
    -- scored in the same context. Two builds of one starter split across PvE
    -- and PvP are different builds and are not asked about.
    return type(first) == "string" and first == second
        and sameSlotContext(plan.context, plan.offContext)
end

function Wizard:Finish(mode)
    if not self.draft then self:ResetDraft() end

    -- The phase decides the slot when no mode is given. The slot-2-only flow
    -- ("target" 2) has no phase 1, so it always saves build 2.
    if not mode then
        if (self.target or 1) == 2 or (self.phase or 1) == 2 then
            mode = "second"
        else
            mode = "first"
        end
    end

    -- Two builds from one starter begin from identical weights. Build 1 is
    -- already saved when this runs, so the question guards the one write still
    -- ahead: slot 2. A hand-tuned slot 2 cannot share weights and is not
    -- asked about. The asked flag and Choose another keep this to one ask per
    -- attempt.
    if mode == "second" and (self.target or 1) == 1
        and not self.confirmedSameTemplate then
        ensureSecondDraft(self)
        local plan = self:Plan()
        local willWrite2 = plan.untouched[2] or self.overrides[2] == true
        if willWrite2 and self:SameTemplateSelected() then
            self.question = "same"
            self.step = 5
            self:Render()
            return false, "same"
        end
    end

    local ok, applied, plan = applyOnce(self, mode)
    if not ok then return false end

    self:Hide()
    return true, applied, plan
end

-- `target` is 1 for the normal two-phase flow (the default, used by
-- /lt setup) and 2 for the Builds page's slot-2 button, which edits slot 2
-- alone. Either way this window is the only thing Show/Hide touches.
function Wizard:Show(target)
    self:RegisterSlash()

    -- The build wizard belongs to a character with a specialisation to build
    -- for. A sub-10 character keeps one default profile and sees the first-use
    -- introduction instead; /lt setup routes to it.
    local level = playerLevel()
    if level and level < 10 then
        return false, "The build wizard opens at level 10, the first talent point. "
            .. "Until then one default profile scores for you."
    end

    local slot = tonumber(target) or 1
    if slot == 2 and not self:CanSecondSlot() then
        return false, "The second build opens at level 10, the first talent point."
    end

    if combatLocked() then
        return false, "The build wizard does not open in combat. Try again after the fight."
    end

    local window = frame or build()
    if not window then return false, "The build wizard window could not be created." end

    self.intro = nil
    self.introStep = nil
    -- A spec-change prompt prefills the active specialisation; the draft is
    -- rebuilt so the suggestion is not overwritten by the last open's answers.
    if self.suggestedSpec then self.draft = nil end
    if not window:IsShown() or not self.draft then self:ResetDraft() end
    self.suggestedSpec = nil
    self:BeginFlow(target)
    self:Render()
    self:ApplyPlacement()
    if window.lunchboxDim then window.lunchboxDim:Show() end
    window:Show()
    if window.Raise then window:Raise() end

    return true
end

-- Opens the first-use tour in the same window. It is read-only and can be
-- dismissed at any page; closing it before Finish writes nothing.
function Wizard:ShowIntro()
    self:RegisterSlash()

    if combatLocked() then
        return false, "The introduction does not open in combat. Try again after the fight."
    end

    local window = frame or build()
    if not window then return false, "The wizard window could not be created." end

    self.draft = nil
    self.question = nil
    self.phase = nil
    self.target = nil
    self.intro = true
    self.introStep = 1
    self:ResetIntroDraft()

    self:Render()
    self:ApplyPlacement()
    if window.lunchboxDim then window.lunchboxDim:Show() end
    window:Show()
    if window.Raise then window:Raise() end

    return true
end

-- Hides this window and nothing else. UI.lua's window and its current page are
-- never touched from here; the player keeps the main window exactly as it was.
function Wizard:Hide()
    if frame then
        frame:Hide()
        if frame.lunchboxDim then frame.lunchboxDim:Hide() end
    end
    self.target = nil
    self.phase = nil
    self.question = nil
    self.confirmedSameTemplate = nil
    self.firstWritten = nil
    self.intro = nil
    self.introStep = nil
end

-- Closing before a save is the explicit "change nothing" exit. After build 1
-- is saved it only closes: nothing else is written.
function Wizard:Cancel()
    self:Hide()
    return false
end

function Wizard:IsShown()
    return frame ~= nil and frame:IsShown()
end

function Wizard:Toggle()
    if self:IsShown() then
        self:Hide()
        return false
    end
    return self:Show()
end

function Wizard:ShouldPrompt()
    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return false end
    if type(character.setup) == "table" then return false end
    -- Closing the prompt without Apply still counts as having been asked: the
    -- player can always reopen with /lt setup.
    if character.setupPrompted == true then return false end
    -- Player decision 2026-11-05: the tour is offered once per character, not
    -- only to characters that have never been played. A release-day player with
    -- three existing alts must see it on each of them once.

    local classToken = LT.player and LT.player.class
    return type(classToken) == "string" and classToken ~= "UNKNOWN"
end

-- Called after PLAYER_LOGIN has finished elsewhere, so the class is known. The
-- first login shows the introduction, not a build questionnaire: there is no
-- specialisation before level 10 and nothing to build yet. The prompt is
-- recorded only when the window was actually shown, so a refused combat open
-- does not use it up.
function Wizard:PromptIfNeeded()
    if not self:ShouldPrompt() then return false end
    if combatLocked() then return false end

    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return false end

    local shown = self:ShowIntro()
    if shown then
        character.setupPrompted = true
        if type(database.Save) == "function" then
            pcall(database.Save, database, "wizard:prompted")
        end
    end
    return shown
end

-- The build wizard waits for level 10 - a talent point is not required. It opens
-- once: closing it unanswered does not bring it back, and /lt setup is always
-- available. `levelOverride` lets the level-up listener pass the level the client
-- just reported, so a stale cached level cannot swallow the prompt.
function Wizard:ShouldBuildPrompt(levelOverride)
    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return false end
    if type(character.setup) == "table" then
        LT:Diag("build prompt: skipped, a build is already saved")
        return false
    end
    if character.buildPrompted == true then
        LT:Diag("build prompt: skipped, already asked once")
        return false
    end

    local level = tonumber(levelOverride) or playerLevel()
    if not level or level < 10 then
        LT:Diag("build prompt: skipped, level " .. tostring(level or "unknown"))
        return false
    end

    local classToken = LT.player and LT.player.class
    if type(classToken) ~= "string" or classToken == "UNKNOWN" then
        LT:Diag("build prompt: skipped, class not known yet")
        return false
    end
    return true
end

function Wizard:BuildPromptIfNeeded(levelOverride)
    if self:IsShown() then return false end
    if not self:ShouldBuildPrompt(levelOverride) then return false end
    if combatLocked() then
        LT:Diag("build prompt: deferred, in combat")
        return false
    end

    -- The first talent point already names a specialisation; preselect it so
    -- the player confirms an answer instead of picking from nothing.
    local active = activeSpecName()
    if active then self.suggestedSpec = active end

    local shown = self:Show()
    self.suggestedSpec = nil
    if not shown then return false end

    local database = LT.Database
    local character = database and database.character
    if type(character) == "table" then
        character.buildPrompted = true
        if type(database.Save) == "function" then
            pcall(database.Save, database, "wizard:build-prompted")
        end
    end
    return true
end

-- TALENTS_CHANGED / PLAYER_SPECIALIZATION_CHANGED: the active spec is the one
-- the character is actually playing. When it differs from the current build's
-- spec, ask once by opening the wizard with that spec preselected. A build
-- whose profile the player pinned is never prompted about, and nothing is ever
-- written here — the slot changes only if the player presses Save.
function Wizard:CheckSpecChange()
    if self:IsShown() then return false end

    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return false end

    local level = playerLevel()
    if not level or level < 10 then return false end

    local builds = LT.Builds
    if type(builds) ~= "table" or type(builds.GetActive) ~= "function" then
        return false
    end
    local ok, build = pcall(builds.GetActive, builds)
    if not ok or type(build) ~= "table" then return false end

    -- A named profile is the player's own choice; a locked or pinned build is
    -- never second-guessed, silently or otherwise.
    if build.profileKey ~= nil then return false end

    local active = activeSpecName()
    if not active then return false end
    if build.spec == active then return false end
    if character.specPrompted == active then return false end

    self.suggestedSpec = active
    local shown = self:Show()
    self.suggestedSpec = nil
    if not shown then return false end

    character.specPrompted = active
    if type(database.Save) == "function" then
        pcall(database.Save, database, "wizard:spec")
    end
    return true
end

------------------------------------------------------------------------------
-- Slash command
--
-- Slash.lua loads after this file, so the command is registered on
-- ADDON_LOADED (all files loaded by then) and again on the first open. The
-- registry refuses a second "setup", which is why RegisterSlash returns that
-- refusal instead of pretending the command is ours twice.
------------------------------------------------------------------------------

local HELP = "/lt setup — introduction below level 10; from 10, the build wizard: "
    .. "role, spec, context, starter build"

function Wizard:RegisterSlash()
    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then
        return false, "The slash command module is not loaded."
    end

    local ok, result = pcall(slash.RegisterCommand, slash, "setup",
        function()
            -- Below level 10 there is nothing to build yet: /lt setup repeats
            -- the introduction rather than opening a questionnaire with no
            -- specialisation to answer.
            local level = playerLevel()
            local shown, reason
            if level and level < 10 then
                shown, reason = Wizard:ShowIntro()
            else
                shown, reason = Wizard:Show()
            end
            if not shown and reason then LT:Warn(reason) end
        end, HELP)

    if ok and result == true then
        return true
    end

    return false, "The setup command is already registered."
end

------------------------------------------------------------------------------
-- Client events
--
-- One hidden listener, created at file load outside combat. It only registers
-- the command and asks the first-use question; the wizard frame itself is
-- still built on its first non-combat open.
------------------------------------------------------------------------------

do
    local ok, listener = pcall(CreateFrame, "Frame", nil, UIParent)

    if ok and listener then
        pcall(listener.RegisterEvent, listener, "ADDON_LOADED")
        pcall(listener.RegisterEvent, listener, "PLAYER_LOGIN")
        -- Not every client raises this; the registration is guarded and the
        -- TALENTS_CHANGED listener below covers the clients that do not.
        pcall(listener.RegisterEvent, listener, "PLAYER_SPECIALIZATION_CHANGED")
        -- A level-up that lands mid-fight defers the level-10 question instead
        -- of spending it: this is the event that says the fight is over.
        pcall(listener.RegisterEvent, listener, "PLAYER_REGEN_ENABLED")

        local function firstRun()
            -- The introduction comes first. Once it has been shown the level-10
            -- build prompt may still be due (an existing character above 10).
            if not Wizard:PromptIfNeeded() then
                Wizard:BuildPromptIfNeeded()
            end
        end

        listener:SetScript("OnEvent", function(_, event, arg1)
            if event == "ADDON_LOADED" then
                if arg1 == LT.name then Wizard:RegisterSlash() end
                return
            end

            if event == "PLAYER_SPECIALIZATION_CHANGED" then
                if Wizard:ShouldBuildPrompt() then
                    Wizard:BuildPromptIfNeeded()
                else
                    Wizard:CheckSpecChange()
                end
                return
            end

            if event == "PLAYER_REGEN_ENABLED" then
                -- Out of combat only, and only while the question is still
                -- owed: BuildPromptIfNeeded keeps its own guards, so a fight
                -- never shows the window and a shown window is never reopened.
                if Wizard:ShouldBuildPrompt() then
                    Wizard:BuildPromptIfNeeded()
                end
                return
            end

            if event == "PLAYER_LOGIN" then
                Wizard:RegisterSlash()

                -- One frame later: PLAYER_LOGIN also runs the core's module
                -- stage, and the wizard needs the class that stage detects.
                if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
                    pcall(C_Timer.After, 0, firstRun)
                else
                    firstRun()
                end
            end
        end)
    else
        LT:Error("The build wizard could not listen for login on this client.")
    end

    -- TALENTS_CHANGED is the core's own event (fired on PLAYER_TALENT_UPDATE
    -- and CHARACTER_POINTS_CHANGED), so it works on every client without an
    -- extra frame event. PLAYER_LEVEL_UP is forwarded by the core too.
    if type(LT.On) == "function" then
        LT:On("TALENTS_CHANGED", function()
            if Wizard:ShouldBuildPrompt() then
                Wizard:BuildPromptIfNeeded()
            else
                Wizard:CheckSpecChange()
            end
        end, "Wizard")

        LT:On("PLAYER_LEVEL_UP", function(payload)
            local level = type(payload) == "table" and tonumber(payload.level) or nil
            Wizard:BuildPromptIfNeeded(level)
            -- The core refreshes the player level immediately before firing this,
            -- so one frame later is a belt-and-braces retry for a client that
            -- reports the new level late. A shown window short-circuits it.
            if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
                pcall(C_Timer.After, 0, function()
                    Wizard:BuildPromptIfNeeded(level)
                end)
            end
        end, "Wizard")
    end
end
