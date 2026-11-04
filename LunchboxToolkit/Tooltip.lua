--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Tooltip

    Nothing is written into the game's tooltip. Every score is drawn in its own
    small frame (TooltipPanel.lua) anchored above the tooltip it describes, so:

      * the base display is three short lines and never pushes the item text
        around;
      * pressing Shift still gives the client's own item comparison; the panel
        belongs to the frame, not to the item text, so nothing is written into
        either tooltip. The comparison and shopping frames get no panel of their
        own: the item under the pointer already states what it is compared with,
        and a second panel beside it landed in the same band, on top of the first.

    Base display:
      Lunchbox Toolkit
      Score: 42.5 vs Equipped: 38.0 - Upgrade: +4.5
      (one more line per additional enabled build slot)

    While Shift (or Control, or Alt) is held the same panel also lists the stats
    that changed, the profile and level the number was made from, the per-stat
    breakdown and the limitations the number carries. A comparison against a
    saved set put together at another level adds one caution line saying so.

    A deferred item — usable later, mail before 40, or a weapon whose proficiency
    is not trained yet — keeps its score and gains one green line under the
    heading saying why. A weapon the character could learn instead gains a second
    green line, "See a weapon master". No trainer name and no city is printed:
    the seeded table for those is provisional, and a wrong city is worse than none.
    When that deferred item also wins its comparison, one more green line says
    "Keep: best in slot at 40" — the level it is gated at, or "once trained" when
    no level is stated. Only the winning item gets it; the runner-up never does.

    Every look that draws nothing records why, and `/lt why` prints that record:
    the item, the rule that refused, and the one thing that would change it.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Tooltip = {}
LT.Tooltip = Tooltip
LT.Modules.Tooltip = Tooltip

-- The "LT:" tag in front of every tooltip line. It is chrome, never a verdict,
-- so it takes the brand tint rather than anything from the verdict scale.
local LINE_PREFIX = LT.Palette:Code("brand") .. "LT:|r "

local HEADING = "Lunchbox Toolkit"

-- What a "never usable" item says: one word, grey, and no number anywhere. The
-- class restriction is absolute, so there is nothing to qualify and nothing the
-- player can act on — a reason line here would be noise on every plate drop.
-- Grey is the palette's "no" and the same colour TooltipPanel paints on the
-- outline for this verdict; red is kept for "no answer" (see ToneFor below).
local UNUSABLE_LINE = LT.Palette:Wrap("stop", "Unusable")

-- Frames the client uses for its own comparison and shopping tooltips. They get
-- no panel at all. The item under the pointer already states what it is compared
-- with ("Equipped: 0.1" is on the item's own panel), and the second panel was
-- drawn in the same band above the two tooltips, on top of the first one — which
-- is what made the shift view unreadable. Matched by name so a frame created
-- after load is still recognised.
local NO_PANEL = {
    ["GameTooltip2"] = true,
    ["ShoppingTooltip1"] = true,
    ["ShoppingTooltip2"] = true,
    ["ShoppingTooltip3"] = true,
    ["ItemRefShoppingTooltip1"] = true,
    ["ItemRefShoppingTooltip2"] = true,
}

local function isComparisonFrame(tooltip)
    if type(tooltip.GetName) ~= "function" then return false end
    local ok, name = pcall(tooltip.GetName, tooltip)
    return ok and name and NO_PANEL[name] == true or false
end

-- The two build names are labels, not verdicts, so they take the two chrome
-- tints rather than anything from the verdict scale: a name must never look like
-- a judgement on the item.
local function buildColour(index)
    if index == 1 then return LT.Palette.hex.buildOne end
    return LT.Palette.hex.buildTwo
end

-------------------------------------------------------------------------------
-- What may be drawn, and when
--
-- These rules decide whether a panel appears at all, and all are asked before a
-- single row is built, so every route into the panel — the item hook, the
-- client's comparison frame, the poller, the quest log's own pane — gets the
-- same answer.
-------------------------------------------------------------------------------

-- Combat is read through one guarded call. A client without the API is "not in
-- combat", which leaves the panel behaving exactly as it did before this rule.
local function inCombatNow()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, inCombat = pcall(InCombatLockdown)
    return ok and inCombat == true
end

-- Only an item that can be worn has a score worth reading. Food, reagents, quest
-- items and vendor trash have no slot, so every line the panel could print about
-- them is a refusal to a question nobody asked — "incomparable — Forever did not
-- report where this item is worn" over a stack of Leg Meat.
--
-- The equip location is the client's own answer, but it is not enough to say
-- "starts with INVTYPE_": INVTYPE_NON_EQUIP does exactly that and is the answer
-- for a grey, non-equippable item — the panel that appeared on one in game. The
-- location is therefore checked against the same map ItemStats scores from, and
-- anything outside it is not wearable. A client that reports a class but no
-- location still gets the class answer (weapon or armour).
function Tooltip:IsWearable(identity)
    if type(identity) ~= "table" then return false end

    local equipLoc = identity.equipLoc
    if type(equipLoc) == "string" and equipLoc ~= "" then
        local itemStats = LT.ItemStats
        local slots = itemStats and itemStats.equipSlots
        if type(slots) == "table" then
            return slots[equipLoc] ~= nil
        end
        return equipLoc:sub(1, 8) == "INVTYPE_"
            and equipLoc ~= "INVTYPE_NON_EQUIP"
    end

    local usability = LT.Usability
    local weapon = (usability and usability.ITEM_CLASS_WEAPON) or 2
    local armour = (usability and usability.ITEM_CLASS_ARMOUR) or 4

    return identity.classID == weapon or identity.classID == armour
end

-- A grey item is normally vendor trash and is never scored. The one exception
-- the player asked for: below level 10 an empty slot is worse than any grey
-- armour or weapon, so a grey item that would fill an empty slot is scored
-- against nothing. A grey item whose slots are all filled changes no answer, and
-- one with no slot at all is refused by IsWearable before this is asked.
--
-- The level is read from LT.player with no client call; an unreadable level is
-- not "below 10" and keeps the refusal. The slot read is guarded inside Compare.
local GREY_LEVEL_LIMIT = 10
Tooltip.GREY_LEVEL_LIMIT = GREY_LEVEL_LIMIT

function Tooltip:GreyBeatsEmpty(identity)
    if type(identity) ~= "table" then return false end
    if tonumber(identity.quality) ~= 0 then return false end

    local level = LT.player and tonumber(LT.player.level)
    if not level or level >= GREY_LEVEL_LIMIT then return false end

    local compare = LT.Compare
    if type(compare) ~= "table" or type(compare.HasEmptySlotFor) ~= "function" then
        return false
    end

    local ok, empty = pcall(compare.HasEmptySlotFor, compare, identity)
    return ok and empty == true
end

-- The whole gate in one place: the item must be wearable, a grey item must be
-- the low-level empty-slot exception, and during a fight the panel only appears
-- while a modifier key is held — so it is there when it is asked for and never
-- lying over the fight. `inCombat` and `modifierHeld` are arguments rather than
-- looks at the game, which is what lets the self test prove the combat rule
-- without a character or a fight; the grey exception is the one rule that needs
-- the player's level and worn links, both guarded (LT.player and Compare).
--
-- The answer is the refusing rule's name, so MayShow below can be the yes/no and
-- the record `/lt why` prints can never disagree about why a panel stayed hidden.
function Tooltip:GateReason(identity, inCombat, modifierHeld, options)
    if not self:IsWearable(identity) then return "not wearable" end

    -- A grey item is vendor trash and is never scored, with one exception: below
    -- level 10 it is considered when it would fill an empty slot, because empty
    -- is worse than grey. A filled slot keeps the refusal.
    if tonumber(identity and identity.quality) == 0
        and not self:GreyBeatsEmpty(identity) then
        return "poor quality"
    end

    -- Absent or true means the rule is on: a profile saved before this option
    -- existed gets the quieter combat behaviour rather than the old one.
    if (options == nil or options.tooltipCombatShiftOnly ~= false)
        and inCombat and not modifierHeld then
        return "in combat without Shift"
    end

    return nil
end

function Tooltip:MayShow(identity, inCombat, modifierHeld, options)
    return self:GateReason(identity, inCombat, modifierHeld, options) == nil
end

-------------------------------------------------------------------------------
-- Why the last look was refused
--
-- Every route that ends without a panel records one line here: which rule
-- refused, and the single thing that would have changed the answer. `/lt why`
-- prints it. This is a record of the last look, not a log: a panel that was
-- drawn clears it, because a refusal that no longer applies is worse than no
-- answer.
-------------------------------------------------------------------------------

-- The one thing that would change each answer. "no build" is left out because
-- its two call sites disagree about what the player would turn on.
local WHY_CHANGE = {
    ["link unreadable"] = "a tooltip whose item the client can describe with a link",
    ["comparison frame"] = "hovering the item itself rather than the client's comparison frame",
    ["no stats"] = "an item whose stats the client reports",
    ["not wearable"] = "a wearable item — armour or a weapon",
    ["poor quality"] = "an item of common quality or better, or a grey item below "
        .. "level 10 that would fill an empty slot",
    ["in combat without Shift"] = "holding Shift (or Control, or Alt) during the fight",
}

-- What `/lt why` says when a look was refused, in a sentence rather than in the
-- rule's name. The rule is kept in parentheses at the end because that is the
-- token a report of a wrong refusal needs to quote; everything in front of it is
-- what the player reads.
local WHY_SENTENCE = {
    ["link unreadable"] =
        "No panel: the client did not describe the hovered item with a link. (link unreadable)",
    ["comparison frame"] =
        "No panel: the client's own comparison tooltip never gets a caption, so hover the item itself. (comparison frame)",
    ["no stats"] =
        "No panel: the client reports no stats for this item, so there is nothing to score. (no stats)",
    ["poor quality"] =
        "No panel: grey items are scored only below level 10, and only when the "
        .. "slot they would fill is empty. (poor quality)",
    ["not wearable"] =
        "No panel: food, reagents and quest items are not scored. (not wearable)",
    ["in combat without Shift"] =
        "No panel: a fight is running, so the panel waits for Shift, Control or Alt. (in combat without Shift)",
    ["no build"] =
        "No panel: no build line is switched on for the tooltip. (no build)",
}

-- The sentence for a rule, or nil for a rule this table does not know — a
-- plugin's own refusal, say, which then keeps its rule name. Pure: no game state
-- is read, so the wording can be checked offline.
function Tooltip:RefusalSentence(rule)
    if type(rule) ~= "string" then return nil end
    return WHY_SENTENCE[rule]
end

local lastDecision = nil

-- The record is copied out again by LastDecision, so nothing outside this file
-- can change what the last look decided.
function Tooltip:RecordDecision(rule, link, identity, change)
    lastDecision = {
        rule = rule,
        link = link,
        itemName = (type(identity) == "table" and identity.name) or nil,
        change = change or WHY_CHANGE[rule] or "—",
    }

    return lastDecision
end

function Tooltip:LastDecision()
    if not lastDecision then return nil end

    return {
        rule = lastDecision.rule,
        link = lastDecision.link,
        itemName = lastDecision.itemName,
        change = lastDecision.change,
    }
end

-- A drawn panel is not a refusal: the next `/lt why` must not describe an item
-- that is no longer under the pointer.
local function clearDecision()
    lastDecision = nil
end

------------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------------

-- One line per enabled build.
--   Score: 42.5 vs Equipped: 38.0 - Upgrade: +4.5
function Tooltip:BuildLine(comparison, index, showName)
    local status = comparison.status
    local colour = LT.Compare:StatusColour(status)
    local prefix = ""

    if showName then
        prefix = "|cff" .. buildColour(index)
            .. tostring(comparison.buildName or ("Build " .. tostring(index))) .. "|r  "
    end

    if status == "upgrade" or status == "downgrade" or status == "equal" then
        local versus = (comparison.vs == "equipped") and "Equipped" or "Saved"
        local verdict = (status == "upgrade" and "Upgrade")
            or (status == "downgrade" and "Downgrade")
            or "Even"

        -- The two numbers are plain text, not verdicts: the verdict word at the
        -- end of the line carries the colour.
        local plain = LT.Palette:Code("text")

        return prefix
            .. "Score: " .. plain .. LT:FormatNumber(comparison.candidateScore, 1) .. "|r"
            .. " vs " .. versus .. ": " .. plain
            .. LT:FormatNumber(comparison.referenceScore, 1) .. "|r"
            .. " - |cff" .. colour .. verdict .. ": "
            .. LT:FormatSigned(comparison.difference, 1) .. "|r"
    end

    return prefix .. "|cff" .. colour .. tostring(status) .. "|r  "
        .. LT.Palette:Wrap("muted", comparison.reason or "not comparable")
end

-- How far a weapon, shield or held item is from the best this character owns for
-- that hand (BestSetup.lua). One extra line; the score line above it, and the
-- reference it uses, are untouched.
function Tooltip:BestLine(itemLink)
    local best = LT.BestSetup
    if type(best) ~= "table" or type(best.ForItem) ~= "function" then return nil end

    local ok, answer = pcall(best.ForItem, best, itemLink)
    if not ok or type(answer) ~= "table" or answer.bestScore == nil then return nil end

    local plain = LT.Palette:Code("text")
    local label = "Best " .. tostring(answer.label or "setup") .. ": "
        .. plain .. LT:FormatNumber(answer.bestScore, 1) .. "|r"

    if answer.sameItem then
        return label .. LT.Palette:Wrap("muted", " — this item is part of the best setup")
    end

    local status = (answer.delta or 0) >= 0 and "upgrade" or "downgrade"
    local colour = LT.Compare and type(LT.Compare.StatusColour) == "function"
        and LT.Compare:StatusColour(status) or nil
    if not colour then return label end

    return label .. " — this item |cff" .. colour
        .. LT:FormatSigned(answer.delta or 0, 1) .. "|r"
end

-- "Reason: +2 Stamina, -1 Intellect" — the stat-level difference the score is
-- made of, biggest mover first. Only shown while a modifier key is held.
function Tooltip:BuildReason(itemLink, index, versus)
    if not LT.Compare or not LT.Compare.StatDeltas then return nil end

    -- StatDeltas is measured against what is worn right now, which is only the
    -- same reference the score line used when the build compares with equipped.
    -- Against a saved set the stat comparison would describe a different swap
    -- than the score, so nothing is claimed.
    if versus ~= "equipped" then return nil end

    local deltas = LT.Compare:StatDeltas(itemLink, index)
    if not deltas or #deltas == 0 then return nil end

    local parts = {}
    for position, row in ipairs(deltas) do
        if position > 4 then
            table.insert(parts, LT.Palette:Wrap("muted", "+" .. tostring(#deltas - 4) .. " more"))
            break
        end

        -- A stat that went up is "go", one that went down is "stop": the same two
        -- verdict colours a whole-item upgrade uses, at stat scale.
        local colour = row.amount > 0 and LT.Palette.hex.go or LT.Palette.hex.stop
        table.insert(parts, "|cff" .. colour .. LT:FormatSigned(row.amount, 0) .. "|r "
            .. tostring(row.label))
    end

    return table.concat(parts, " " .. LT.Palette:Wrap("muted", "/") .. " ")
end

-- A number this addon may read, or nil when it is missing or the client marks
-- it secret. Nothing is ever computed from a secret value.
local function plainNumber(value)
    if value == nil or LT:IsSecret(value) then return nil end
    return tonumber(value)
end

-- The expanded panel's receipt: which profile produced the number, at which
-- level, and whether either carries a qualification. `effective` is exactly what
-- Profiles:GetEffective returned for the build the detail belongs to. When it
-- cannot name a profile or a level there is no receipt at all, rather than a
-- guess at what was used.
function Tooltip.ReceiptLine(effective)
    if type(effective) ~= "table" or not effective.profile then return nil end

    local name = effective.scaleName
    if type(name) ~= "string" or name == "" then return nil end

    local level = plainNumber(effective.level)
    if not level then return nil end

    local text = "profile " .. name .. " · level " .. tostring(level)

    if effective.provisional == true then
        text = text .. " · provisional"
    end

    -- pluginsApplied holds one entry per applied adjustment; the suffix counts
    -- the plugins that made them, because that is what the word says. Two
    -- adjustments from one plugin are one plugin.
    local applied = effective.pluginsApplied
    local plugins, seen = 0, {}

    if type(applied) == "table" then
        for _, entry in ipairs(applied) do
            local pluginId = type(entry) == "table" and entry.pluginId or nil
            if pluginId and not seen[pluginId] then
                seen[pluginId] = true
                plugins = plugins + 1
            end
        end
    end

    if plugins > 0 then
        text = text .. " · plugins: " .. tostring(plugins)
    end

    return LT.Palette:Wrap("muted", text)
end

-- One caution when the comparison was against a saved set that was put together
-- at a different character level. Both levels must be known and must differ; an
-- unknown level says nothing, because a guessed level is worse than no line.
function Tooltip.SavedSetCaution(comparison, savedLevel, currentLevel)
    if type(comparison) ~= "table" or comparison.vs ~= "saved" then return nil end

    savedLevel = plainNumber(savedLevel)
    currentLevel = plainNumber(currentLevel)

    if not savedLevel or not currentLevel or savedLevel == currentLevel then return nil end

    return LT.Palette:Wrap("caution", "saved set is from level " .. tostring(savedLevel))
end

-- The level the saved set was put together at, and the level now. Both are read
-- from the modules that own them; a missing answer stays nil.
local function savedSetLevel(buildIndex)
    local sets = LT.GearSets
    if not sets or type(sets.Get) ~= "function" then return nil end

    local snapshot = sets:Get(buildIndex)
    return type(snapshot) == "table" and snapshot.characterLevel or nil
end

local function currentLevel()
    local levels = LT.Levels
    if not levels or type(levels.GetCurrentLevel) ~= "function" then return nil end

    local ok, level = pcall(levels.GetCurrentLevel, levels)
    return ok and level or nil
end

-- The "Keep" note for a deferred item: it would win its slot once it can be
-- worn, so the player should hold on to it. One line, and only on the winner —
-- a deferred item the comparison calls a downgrade or an even swap (the
-- runner-up) gets nothing. A wearable item never gets it either: the note says
-- what to keep for later, not what to wear now.
--
-- The level comes from GearCheck:Placement, which is the one place that turns a
-- deferred verdict into the level that gates the item (its own requirement, or
-- the class's armour/weapon unlock). That keeps "at 40" and the bag scan's
-- "soon" rows from ever disagreeing. When no level is stated — a weapon master
-- proficiency the pack does not put at a level — the note says "once trained"
-- rather than inventing a number.
function Tooltip:KeepLine(verdict, comparisons, identity)
    if type(verdict) ~= "table" or not LT.Usability then return nil end
    if verdict.verdict ~= LT.Usability.DEFERRED then return nil end

    local won = false
    if type(comparisons) == "table" then
        for _, comparison in pairs(comparisons) do
            if type(comparison) == "table" and comparison.status == "upgrade"
                and (tonumber(comparison.difference) or 0) > 0 then
                won = true
                break
            end
        end
    end

    if not won then return nil end

    local gate = nil
    local gearCheck = LT.GearCheck
    if type(gearCheck) == "table" and type(gearCheck.Placement) == "function" then
        local ok, placement, level = pcall(gearCheck.Placement, gearCheck, verdict,
            identity, currentLevel())

        if ok and placement == "soon" then gate = tonumber(level) end
    end

    if gate then
        return LT.Palette:Wrap("caution", "Keep: best in slot at " .. tostring(gate))
    end

    if verdict.cause == "proficiency" then
        return LT.Palette:Wrap("caution", "Keep: best in slot once trained")
    end

    return nil
end

-- Which outline the panel wears. Pure: the Usability answer and the comparison
-- statuses are arguments, so the precedence can be proved without a character,
-- an item or a frame.
--
-- Usability's own answer comes first, always. "Not yet" *is* an answer, so a
-- deferred item stays green even when a build could not compare it (ineligible,
-- incomparable, unscorable); a never item stays grey for the same reason. Red
-- would say "the add-on cannot answer" about an item it has just answered, which
-- is exactly the contradiction the mail-at-6 report described.
--
-- With no such verdict — none at all, or "unknown" — the comparisons decide,
-- with one exception: an unknown verdict with nothing scored is red even when a
-- build calls the item ineligible. Usability made no "no" of its own there, and
-- grey would assert one it never gave. An unknown verdict that still produced a
-- number is not red: the add-on did answer the item, so it keeps the ordinary
-- outline rather than denying the score it just printed.
--   incomparable/incomplete/
--   unscorable                 red   ("no answer": a gap in the data)
--   ineligible                 grey  ("no", the class cannot use it)
--   a plain score              purple (the ordinary answer)
function Tooltip:ToneFor(verdict, statuses)
    local usability = LT.Usability or {}
    local value = (type(verdict) == "table" and verdict.verdict) or verdict

    if value == usability.NEVER then return "never" end
    if value == usability.DEFERRED then return "deferred" end

    local scored, noAnswer, ineligible = false, false, false

    for _, status in ipairs(statuses or {}) do
        if status == "ineligible" then
            ineligible = true
        elseif status == "incomparable" or status == "incomplete"
            or status == "unscorable" then
            noAnswer = true
        elseif status == "upgrade" or status == "downgrade" or status == "equal" then
            scored = true
        end
    end

    if value == usability.UNKNOWN and not scored then return "unknown" end

    -- A build that produced a number is the ordinary answer, even when another
    -- build refuses the item on weapon configuration: the shield that is a tank
    -- upgrade but not a 2H-build item still wears purple, not grey.
    if scored then return "normal" end

    if noAnswer then return "unknown" end
    if ineligible then return "never" end

    return "normal"
end

-- One build's status mapped to the outline tone it wears on its half of the
-- border. A scored build is purple, an ineligible one grey, and an unanswered
-- one red — the same meanings ToneFor uses, judged per build instead of across
-- the whole panel.
local function perBuildTone(status)
    if status == "upgrade" or status == "downgrade" or status == "equal" then
        return "normal"
    end
    if status == "ineligible" then
        return "never"
    end
    return "unknown"
end

-- Builds the panel contents for one item. `expanded` adds the detail lines.
-- Returns a list of strings, the first of which is the heading, and the outline
-- tone for TooltipPanel:Show.
function Tooltip:CollectRows(itemLink, expanded, identity)
    local options = LT.Database:GetOptions()
    if not options.tooltipEnabled then
        Tooltip:RecordDecision("no build", itemLink, identity,
            "turning the tooltip panel on in Settings")
        return {}
    end

    local enabledBuilds = {}
    for index = 1, LT.Builds.SLOT_COUNT do
        local enabled = (index == 1 and options.tooltipBuildOne)
            or (index == 2 and options.tooltipBuildTwo)

        if enabled then
            table.insert(enabledBuilds, index)
        end
    end

    if #enabledBuilds == 0 then
        Tooltip:RecordDecision("no build", itemLink, identity,
            "turning on a build line for the tooltip")
        return {}
    end

    -- Usability decides whether a number is the right answer at all:
    --   never     this class can never use the item — no score, one grey
    --             "Unusable" line, grey outline;
    --   deferred  usable later — keep the score, green outline, say why;
    --   unknown   no claim either way, so the comparisons decide the outline.
    -- The call is guarded because it reads the character's trained skills.
    local verdict = nil

    if LT.Usability and type(LT.Usability.GetVerdict) == "function" then
        local ok, answer = pcall(LT.Usability.GetVerdict, LT.Usability,
            itemLink, { identity = identity })

        if ok and type(answer) == "table" then verdict = answer end
    end

    if verdict and verdict.verdict == LT.Usability.NEVER then
        return LT.TooltipPanel:BuildRows(HEADING, { UNUSABLE_LINE }), "never"
    end

    local showNames = #enabledBuilds > 1
    local comparisons = {}
    local statuses = {}
    local lines = {}

    for _, index in ipairs(enabledBuilds) do
        local comparison = LT.Compare:ForBuild(itemLink, index)
        comparisons[index] = comparison

        if type(comparison) == "table" then
            statuses[#statuses + 1] = comparison.status
        end

        table.insert(lines, Tooltip:BuildLine(comparison, index, showNames))
    end

    -- The outline follows ToneFor's precedence, so a deferred item stays green
    -- even when a build could not compare it, and only a real "no answer" is red.
    local tone = self:ToneFor(verdict, statuses)

    -- Two enabled builds with different answers split the border: build 1 owns
    -- the top and left edges, build 2 the bottom and right. A deferred (or
    -- never) item keeps its single colour — the player asked for that.
    local tone2 = nil
    if #enabledBuilds == 2
        and not (verdict and verdict.verdict == LT.Usability.DEFERRED) then
        local first = comparisons[enabledBuilds[1]]
        local second = comparisons[enabledBuilds[2]]
        local t1 = perBuildTone(first and first.status)
        local t2 = perBuildTone(second and second.status)
        if t1 ~= t2 then
            tone = t1
            tone2 = t2
        end
    end

    -- "Would this be worth the trip?" is now a flat rule: a weapon whose
    -- proficiency is missing says "See a weapon master" on every such item, not
    -- only on upgrades. The number is green because of the missing proficiency,
    -- so the hint belongs beside it whether the weapon is better or worse than
    -- what is worn, and Compare no longer blanks the score for this case.
    local rows = LT.TooltipPanel:BuildRows(HEADING, lines)

    -- The only grey items that reach a panel are the low-level empty-slot
    -- exception; one muted line under the heading says why a grey item is being
    -- scored at all.
    if tonumber(identity and identity.quality) == 0 and self:GreyBeatsEmpty(identity) then
        table.insert(rows, 2, LT.Palette:Wrap("muted", "grey — better than empty"))
    end

    -- Placed directly under the heading so the "not yet" reason is read before
    -- the number it applies to, with the weapon-master line under it. Both are
    -- green: a condition on an answer, not a refusal, and the outline agrees.
    if verdict and verdict.verdict == LT.Usability.DEFERRED then
        table.insert(rows, 2, LT.Palette:Wrap("caution", "Not yet — " .. tostring(verdict.reason)))

        local training = LT.Usability and LT.Usability.DescribeTraining
            and LT.Usability:DescribeTraining(verdict.trainable, verdict.key) or nil

        if training then
            table.insert(rows, 3, LT.Palette:Wrap("caution", training))
        end

        -- Under the reason it is not worn yet: this is the item worth keeping,
        -- and only when the comparison already calls it a win for the slot.
        local keep = Tooltip:KeepLine(verdict, comparisons, identity)
        if keep then table.insert(rows, training and 4 or 3, keep) end
    end

    if not expanded then
        return rows, tone, tone2
    end

    local primaryIndex = enabledBuilds[1]
    local primary = comparisons[primaryIndex]
    if not primary then return rows, tone, tone2 end

    -- Compact detail: one stat-delta line, and at most one "**" note. The
    -- profile name, per-stat breakdown, per-slot rows and the full limitation
    -- list are deliberately not printed here; /lt score <item> shows them.
    if LT.ItemStats and type(LT.ItemStats.Get) == "function" then
        local stats = LT.ItemStats:Get(itemLink)
        if type(stats) == "table" and tonumber(stats.haste) and tonumber(stats.haste) > 0 then
            table.insert(rows, LT.Palette:Wrap("muted",
                "Haste is read but not scored yet (no weight in this build)."))
        end
    end

    -- Shift view only: where this item stands against the best the character owns
    -- for its own hand, and whether it is part of that best set. The plain hover
    -- keeps its single worn comparison.
    local bestLine = Tooltip:BestLine(itemLink)
    if bestLine then table.insert(rows, bestLine) end

    local reason = Tooltip:BuildReason(itemLink, primaryIndex, primary.vs)
    if reason then
        table.insert(rows, reason)
    elseif primary.vs == "saved" then
        -- Shift must visibly answer every time, or the key looks broken. The two
        -- reasons the detail can be empty are said out loud instead of leaving
        -- the panel looking identical to the plain hover.
        table.insert(rows, LT.Palette:Wrap("muted",
            "Stat detail compares with worn gear only; this build compares with a saved set."))
    else
        table.insert(rows, LT.Palette:Wrap("muted",
            "No stat difference to list: no stat was read for this item."))
    end

    -- The most specific note wins: an imbue note explains the number better
    -- than a general limitation does.
    local note = (primary.candidate and primary.candidate.imbueNotes
        and primary.candidate.imbueNotes[1])
        or (primary.limitations and primary.limitations[1])

    if note and tostring(note) ~= "" then
        local text = tostring(note):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        text = text:gsub("^%s+", "")
        table.insert(rows, LT.Palette:Wrap("muted", "** " .. text))
    end

    -- The receipt goes last because it describes the whole panel: which profile
    -- produced the numbers, at which level, and whether either carries a
    -- qualification. Same GetEffective call the score made, so the cache hands
    -- back the answer that was actually used rather than computing a second one.
    local profiles = LT.Profiles
    if profiles and type(profiles.GetEffective) == "function" then
        local receipt = Tooltip.ReceiptLine(profiles:GetEffective(primaryIndex))
        if receipt then table.insert(rows, receipt) end
    end

    -- A saved set put together at another level is still re-scored at today's
    -- level, so the comparison is valid; the line only says the gear is old.
    local caution = Tooltip.SavedSetCaution(primary,
        savedSetLevel(primaryIndex), currentLevel())
    if caution then table.insert(rows, caution) end

    -- The tone is returned on this path too: losing it here is what let an
    -- expanded deferred item fall back to the purple "normal" outline.
    return rows, tone, tone2
end

-- Draws (or clears) the panel that belongs to this tooltip frame. Nothing is
-- ever appended to the tooltip itself: the panel is a separate frame anchored
-- above it, which is what lets the client's own Shift comparison keep the
-- tooltip to itself.
function Tooltip:AddLines(tooltip, itemLink, identity)
    if not tooltip or not itemLink then return false end
    if not LT.TooltipPanel then return false end

    local options = LT.Database:GetOptions()
    local wanted = (options and options.tooltipExpanded == true)
        or LT.TooltipPanel:IsExpandedByKey()

    -- The comparison and shopping frames never reach this function — decorate
    -- stops before it — so the modifier alone decides the detail here.
    local expanded = wanted == true

    local rows, tone, tone2 = self:CollectRows(itemLink, expanded, identity)
    if #rows == 0 then
        LT.TooltipPanel:Clear(tooltip)
        return false
    end

    LT.TooltipPanel:Show(tooltip, rows, tone, tone2)

    -- A panel was drawn, so there is no refusal left to explain.
    clearDecision()

    -- Remembered so the panel can be redrawn when the modifier key changes
    -- while the tooltip is still open.
    tooltip.__ltLink = itemLink
    tooltip.__ltExpanded = expanded

    return true
end

------------------------------------------------------------------------------
-- Hooking
------------------------------------------------------------------------------

local function currentTooltipLink(tooltip)
    -- The client can describe a tooltip that neither GetItem nor the tooltip data
    -- table can: the quest log sets its reward tooltip without a link of its own,
    -- and TooltipUtil answers what is actually displayed. Asked first because it
    -- is the most specific answer, and guarded because older builds lack it.
    if type(TooltipUtil) == "table" and type(TooltipUtil.GetDisplayedItem) == "function" then
        local ok, _, link = pcall(TooltipUtil.GetDisplayedItem, tooltip)
        if ok and type(link) == "string" and link ~= "" and not LT:IsSecret(link) then
            return link
        end
    end

    if type(tooltip.GetItem) == "function" then
        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if ok and link and not LT:IsSecret(link) then return link end
    end

    -- Quest reward and some other item tooltips do not answer GetItem(); the
    -- structured tooltip data still carries the hyperlink.
    if tooltip.GetPrimaryTooltipData then
        local okData, data = pcall(tooltip.GetPrimaryTooltipData, tooltip)
        local hyperlink = okData and type(data) == "table" and data.hyperlink or nil
        if hyperlink and not LT:IsSecret(hyperlink) then return hyperlink end
    end

    -- A pane that fills a tooltip without handing it a link still leaves the
    -- button the pointer is on, and the quest log's reward pane is one. The reward
    -- module already knows every way to ask such a button for its item, so it is
    -- asked last, and its answer is resolved the same way the reward overlay
    -- resolves it -- a bare item ID is not something the tooltip API accepts.
    if type(tooltip.GetOwner) == "function"
        and LT.QuestRewards
        and type(LT.QuestRewards.LinkFromButton) == "function" then
        local okOwner, owner = pcall(tooltip.GetOwner, tooltip)

        if okOwner and type(owner) == "table" then
            local okLink, link = pcall(LT.QuestRewards.LinkFromButton, owner)

            if okLink and type(link) == "string"
                and type(LT.QuestRewards.ResolveLink) == "function" then
                local okResolve, resolved = pcall(LT.QuestRewards.ResolveLink, link)
                if okResolve then link = resolved end
            end

            if okLink and type(link) == "string" and link ~= "" and not LT:IsSecret(link) then
                return link
            end
        end
    end

    return nil
end

local function decorate(tooltip)
    if not tooltip then return end

    local link = currentTooltipLink(tooltip)
    if not link then
        Tooltip:RecordDecision("link unreadable", nil, nil)
        LT.TooltipPanel:Clear(tooltip)
        tooltip.__ltLink = nil
        return
    end

    -- Nothing at all is drawn for the client's own comparison and shopping
    -- tooltips: the panel of the item under the pointer is the caption the player
    -- reads, and it already says what that item is compared with.
    if isComparisonFrame(tooltip) then
        Tooltip:RecordDecision("comparison frame", link, nil)
        LT.TooltipPanel:Clear(tooltip)
        tooltip.__ltLink = link
        return
    end

    local identity = LT.ItemStats:GetIdentity(link)
    if not identity then
        Tooltip:RecordDecision("no stats", link, nil)
        LT.TooltipPanel:Clear(tooltip)
        tooltip.__ltLink = nil
        return
    end

    -- Nothing is built for an item that cannot be worn, and during a fight
    -- nothing stays on screen unless a modifier is held. The link is remembered
    -- anyway, so the poller does not re-ask ten times a second and the panel can
    -- come back on its own once the fight is over.
    local refusal = Tooltip:GateReason(identity, inCombatNow(),
        LT.TooltipPanel:IsExpandedByKey(), LT.Database:GetOptions())

    if refusal then
        Tooltip:RecordDecision(refusal, link, identity)
        LT.TooltipPanel:Clear(tooltip)
        tooltip.__ltLink = link
        return
    end

    local ok, err = pcall(Tooltip.AddLines, Tooltip, tooltip, link, identity)
    if not ok then
        LT:Debug("tooltip panel failed: " .. tostring(err))
    end
end

-- Installs the fallback item hook on one tooltip frame. Only used when the
-- client's TooltipDataProcessor cannot be registered: the legacy
-- OnTooltipSetItem hook is what taints the bag buttons on Forever, so it is
-- never installed beside a working processor. Missing frames are skipped, so a
-- client that names them differently still works.
local function hookTooltip(frame)
    if type(frame) ~= "table" or frame.__ltHooked then return false end

    local ok = pcall(frame.HookScript, frame, "OnTooltipSetItem", function(self)
        decorate(self)
    end)

    if not ok then return false end

    frame.__ltHooked = true

    -- The panel is anchored to the tooltip, so it must never outlive it.
    pcall(frame.HookScript, frame, "OnHide", function(self)
        LT.TooltipPanel:Clear(self)
    end)

    -- A tooltip is shown before its item is set, so at that moment any panel
    -- still around belongs to the previous item: clearing is correct, and the
    -- fresh panel is drawn by the OnTooltipSetItem hook that follows.
    pcall(frame.HookScript, frame, "OnShow", function(self)
        LT.TooltipPanel:Clear(self)
        self.__ltLink = nil
        self.__ltTried = nil
    end)

    return true
end

-- Every frame the client can hand an item to. Named once because two things need
-- the list: the panels built ahead of the first hover, and the combat redraw
-- that has to reach a panel already on screen when a fight starts or ends.
-- GameTooltip2, ShoppingTooltip3 and FloatingTooltip are deliberately absent:
-- no shipped Forever addon mentions them, so hooking or polling them only
-- guesses at frames this client may not have.
local HOOK_NAMES = {
    "GameTooltip",
    "ItemRefTooltip",
    "ItemRefShoppingTooltip1",
    "ItemRefShoppingTooltip2",
    "ShoppingTooltip1",
    "ShoppingTooltip2",
}

-- Draws (or clears) the panel of every tooltip that is on screen right now. Only
-- the frames above can own a panel, so this reaches all of them, and the gate in
-- decorate decides what comes back.
local function redrawShown()
    for _, name in ipairs(HOOK_NAMES) do
        local frame = _G[name]

        if type(frame) == "table" and type(frame.IsShown) == "function" then
            local ok, shown = pcall(frame.IsShown, frame)
            if ok and shown then decorate(frame) end
        end
    end
end

local function hookAllTooltips()
    local hooked = 0

    for _, name in ipairs(HOOK_NAMES) do
        if hookTooltip(_G[name]) then hooked = hooked + 1 end
    end

    return hooked
end

function Tooltip:Initialize()
    -- Build the panel of every frame that can own one before any hook exists.
    -- Creating a frame from inside a tooltip hook is what taints the client's bag
    -- buttons on Forever, and a tainted bag button can no longer right-click
    -- sell. Show reuses these panels for the rest of the session.
    if LT.TooltipPanel and type(LT.TooltipPanel.Prepare) == "function" then
        for _, name in ipairs(HOOK_NAMES) do
            local frame = _G[name]

            if type(frame) == "table" and not NO_PANEL[name] then
                pcall(LT.TooltipPanel.Prepare, LT.TooltipPanel, frame)
            end
        end
    end

    -- Modern hook first: it covers every tooltip frame the client creates, so a
    -- comparison tooltip is handled without knowing its name. The named-frame
    -- hooks are the fallback for a client where this registration fails; they
    -- are not installed beside a working processor, because the legacy
    -- OnTooltipSetItem hook is the one that taints bag buttons.
    local modern = false

    if type(TooltipDataProcessor) == "table" and TooltipDataProcessor.AddTooltipPostCall
        and type(Enum) == "table" and Enum.TooltipDataType then
        modern = pcall(TooltipDataProcessor.AddTooltipPostCall,
            Enum.TooltipDataType.Item,
            function(tooltip)
                decorate(tooltip)
            end)
    end

    local hooked = 0

    if not modern then
        hooked = hookAllTooltips()
    end

    if modern then
        LT:Debug("tooltip panels installed (data processor)")
    elseif hooked > 0 then
        LT:Debug("tooltip panels installed (named frames: " .. tostring(hooked) .. ")")
    else
        LT:Warn("tooltips could not be hooked on this client build; "
            .. "use /lt score <item link> instead.")
    end

    -- Combat is the one change the hover hooks never see: no tooltip is re-set
    -- when a fight starts, so a panel would sit there for the whole fight. One
    -- small frame listens for the two transitions and redraws whatever is on
    -- screen; the gate in decorate decides whether anything comes back. All this
    -- ever does in combat is hide our own textures, which is why it is safe
    -- inside the lockdown.
    local combatWatch = CreateFrame("Frame")
    combatWatch:RegisterEvent("PLAYER_REGEN_DISABLED")
    combatWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- The client fetches item data lazily. If the first hover saw "no stats",
    -- the same tooltip must be redrawn when the reply arrives; otherwise a
    -- green +Attack Power drop reads as statless until it is hovered again.
    pcall(combatWatch.RegisterEvent, combatWatch, "GET_ITEM_INFO_RECEIVED")
    pcall(combatWatch.RegisterEvent, combatWatch, "ITEM_DATA_LOAD_RESULT")
    combatWatch:SetScript("OnEvent", function()
        redrawShown()
    end)

    -- Two things change while a tooltip is open: the modifier, which decides
    -- which detail belongs on the panel, and the item under the pointer, which a
    -- pane can replace without going through the script hooks above -- the quest
    -- log's reward pane fills the tooltip itself. Both are checked a few times a
    -- second rather than every frame, and nothing is rebuilt unless one of them
    -- actually changed, so this costs nothing while nothing is hovered.
    local polled = {}

    for _, name in ipairs({ "GameTooltip", "ItemRefTooltip",
        "ShoppingTooltip1", "ShoppingTooltip2" }) do
        local frame = _G[name]
        if type(frame) == "table" and type(frame.IsShown) == "function" then
            table.insert(polled, frame)
        end
    end

    local ticker = CreateFrame("Frame")
    local elapsed = 0

    ticker:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + (delta or 0)
        if elapsed < 0.10 then return end
        elapsed = 0

        -- Nothing hovered means nothing to do: no tooltip, no work.
        local any = false

        for _, tooltip in ipairs(polled) do
            local okShown, shown = pcall(tooltip.IsShown, tooltip)

            if okShown and shown then
                any = true

                -- A link that changed under an open tooltip is a different item,
                -- so the panel belongs to the old one and is redrawn here. The
                -- link already tried is remembered too: a tooltip carrying no
                -- item at all must not be re-read ten times a second.
                local link = currentTooltipLink(tooltip)
                local current = tooltip.__ltLink or tooltip.__ltTried

                if link ~= current then
                    decorate(tooltip)
                    tooltip.__ltTried = link
                end
            end
        end

        if not any then return end

        local expanded = LT.TooltipPanel:IsExpandedByKey()
        if LT.TooltipPanel.lastExpanded == expanded then return end

        LT.TooltipPanel.lastExpanded = expanded

        -- Every tooltip on screen is redrawn, not only the ones whose panel is
        -- visible: the combat rule clears a panel while its item is still hovered,
        -- so pressing the modifier has to be able to bring it back without the
        -- pointer leaving the item.
        redrawShown()
    end)
end

Tooltip.decorate = decorate
Tooltip.LINE_PREFIX = LINE_PREFIX