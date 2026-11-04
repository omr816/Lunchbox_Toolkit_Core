--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Slash
    /lt command surface. Everything the UI can do has a command, which is also
    how this addon is tested in game while the UI is still growing.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Slash = {}
LT.Slash = Slash
LT.Modules.Slash = Slash

local helpLines = {
    "/lt — open or close the window",
    "/lt ui — open the window",
    "/lt test — run the self tests and print the result",
    "/lt level — how scoring levels are currently calculated",
    "/lt played — time played per level, AFK time and the last sessions",
    "/lt capture — measure the client's rating conversion at your level",
    "/lt divisor <stat> <rating per 1%> [level] — enter a conversion by hand",
    "/lt builds — show both build slots",
    "/lt use <1|2> — make a slot the active one",
    "/lt name <text> — rename the active slot",
    "/lt spec <text> | /lt role <role> | /lt context <PVE|PVP>",
    "/lt weapon <2H|1H_SHIELD|DUAL_WIELD|1H|RANGED>",
    "/lt save [1|2] — save the equipped items as that slot's equipment set",
    "/lt gear [1|2] — show a saved equipment set",
    "/lt scan — list the upgrades in the bags: wearable now, and what a level unlocks",
    "/lt profiles — list every profile",
    "/lt profile <key> — assign a profile to the active slot",
    "/lt profile create <name> [from key] — new custom profile",
    "/lt profile copy <source key> <new name>",
    "/lt export [key] — save the profile as an editable string, and print it",
    "/lt exports — list the stored export strings",
    "/lt import <n|last|text> [use] — import a profile as a new custom one",
    "/lt weight <stat> <value> — edit the active slot's custom profile",
    "/lt weights — list the stat keys a weight can be set for",
    "/lt caps — show cap status, including what is still needed",
    "/lt score [item link] — score an item against both slots",
    "/lt why — why the last tooltip showed no panel",
    "/lt unknown [clear] — stat keys the client reports but this build does not model",
    "/lt quest — what the quest reward highlight decided",
    "/lt questwalk — list every quest-log reward candidate and why it was refused",
    "/lt itemdump <item link> — every value the client returns for an item, by index",
    "/lt drop — what to destroy first when the bags are full",
    "/lt drop all | ignore [item] | forget <id> | list | print — bag triage",
    "Bags: the cheapest item is marked; /lt drop ignore keeps it off that list",
    "/lt sort bags|bank|all — sort the bags, the bank, or both (Settings switch first)",
    "/lt colours — what each colour means, and where it appears",
    "/lt imbunes — weapon imbue scoring and what each imbune assumes",
    "/lt imbunes <name> — set the active slot's weapon imbue",
    "/lt imbues | /lt imbue <name> — the old words still work",
    "/lt plugins — list registered plugins and any problems",
    "/lt auras — every helpful aura name this client returns (stance diagnosis)",
    "/lt trackers on|off|status|wf — combo points, or the Windfury top-5",
    "/lt wf — Windfury records popup (Shaman only)",
    "/lt wf reset — clear the Windfury records (testing)",
    "/lt probe — client APIs and current tracker values",
    "/lt probe log on|off — print the first 10 combat-log events, then stop",
    "/lt debug — toggle debug output",
    "/lt diag chat on|off — diagnostic lines in chat, for this character",
}

local extra = {}
local extraHelp = {}

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function splitCommand(input)
    local words = {}
    for word in tostring(input or ""):gmatch("%S+") do
        table.insert(words, word)
    end
    return words
end

local function describeStat(stat)
    return LT.StatLabels[stat] and stat or nil
end

------------------------------------------------------------------------------
-- Individual commands
------------------------------------------------------------------------------

local commands = {}

function commands.ui()
    if LT.UI then
        LT.UI:Show()
    else
        LT:Error("The UI module is not loaded.")
    end
end

function commands.help()
    local shown = {}
    for _, line in ipairs(helpLines) do
        shown[line] = true
        LT:Print(line)
    end
    for _, entry in ipairs(extraHelp) do
        -- A module may register a word whose line this list already carries;
        -- the same sentence is printed once.
        if not shown[entry.text] then
            LT:Print(entry.text)
        end
    end
end

function commands.test()
    if not LT.SelfTest then
        LT:Error("The self test module is not loaded.")
        return
    end

    LT.SelfTest:Run(true)
end

-- Bag triage: the one command that is not about scoring. The wording lives in
-- DropHint; this only checks that the module is there.
function commands.drop(words)
    if not LT.DropHint then
        LT:Error("The drop hint module is not loaded.")
        return
    end

    LT.DropHint:Command(words)
end

function commands.level()
    LT:Print(LT.Levels:DescribeScoringLevel())

    local profile = LT.Profiles:ResolveForBuild(LT.Builds:GetActiveIndex())
    if profile then
        LT:Print("Active slot profile: " .. tostring(profile.name)
            .. (profile.provisional and " (provisional)" or ""))
    end

    for _, row in ipairs(LT.Levels:GetReport()) do
        if row.value then
            LT:Print("  " .. row.label .. ": " .. LT:FormatNumber(row.value, 3)
                .. " rating per 1% at level " .. tostring(row.level)
                .. " (" .. tostring(row.source) .. ")")
        end
    end
end

function commands.capture()
    LT.Levels:CaptureAndReport()
end

-- Play-time ledger. All the formatting and the decisions live in Played; this
-- only checks that the module is loaded.
function commands.played()
    if not LT.Played then
        LT:Error("The play-time module is not loaded.")
        return
    end

    LT.Played:Report()
end

function commands.divisor(words)
    local stat = words[2]
    local value = tonumber(words[3])
    local level = tonumber(words[4])

    if not stat or not value then
        LT:Print("Usage: /lt divisor <stat> <rating per 1%> [level]")
        LT:Print("Example: /lt divisor hit 10.5")
        return
    end

    if not LT.StatLabels[stat] then
        LT:Error("Unknown stat \"" .. tostring(stat) .. "\".")
        return
    end

    if LT.Levels:SetConversion(stat, level or LT.Levels:GetCurrentLevel(), value, LT.SOURCE_MANUAL) then
        LT:Print("Recorded " .. LT:Label(stat) .. ": " .. LT:FormatNumber(value, 3)
            .. " rating per 1% at level " .. tostring(level or LT.Levels:GetCurrentLevel()) .. ".")
    else
        LT:Warn("A better source is already recorded for that stat and level.")
    end
end

function commands.builds()
    for index = 1, LT.Builds.SLOT_COUNT do
        local build = LT.Builds:Get(index)
        local marker = (index == LT.Builds:GetActiveIndex()) and "> " or "  "
        LT:Print(marker .. LT.Builds:Describe(index))

        if build then
            LT:Print("    profile: " .. tostring(build.profileKey or "not set"))
            LT:Print("    equipment set: " .. LT.GearSets:Describe(index))
        end
    end
end

function commands.use(words)
    local index = tonumber(words[2])
    if not index then
        LT:Print("Usage: /lt use <1|2>")
        return
    end

    if LT.Builds:SetActive(index) then
        LT:Print("Active slot: " .. LT.Builds:Describe(index))
    else
        LT:Error("There is no slot " .. tostring(index) .. ".")
    end
end

function commands.name(words)
    local text = trim(tostring(words[2] or ""))
    if text == "" then
        LT:Print("Usage: /lt name <text>")
        return
    end

    local index = LT.Builds:GetActiveIndex()
    if LT.Builds:SetName(index, text) then
        LT:Print("Slot " .. tostring(index) .. " renamed to \"" .. text .. "\".")
    end
end

function commands.spec(words)
    local index = LT.Builds:GetActiveIndex()
    LT.Builds:SetSpec(index, trim(words[2] or "") ~= "" and trim(words[2]) or "Any")
    LT:Print("Slot " .. tostring(index) .. " specialisation: " .. tostring(LT.Builds:Get(index).spec))
end

function commands.role(words)
    local index = LT.Builds:GetActiveIndex()
    LT.Builds:SetRole(index, words[2] or "Damage")
    LT:Print("Slot " .. tostring(index) .. " role: " .. tostring(LT.Builds:Get(index).role))
end

function commands.context(words)
    local index = LT.Builds:GetActiveIndex()
    LT.Builds:SetContext(index, words[2] or "PVE")
    LT:Print("Slot " .. tostring(index) .. " context: " .. tostring(LT.Builds:Get(index).context))
end

function commands.weapon(words)
    local index = LT.Builds:GetActiveIndex()
    local setup = words[2]

    if not setup then
        LT:Print("Weapon configurations: " .. table.concat(LT.WeaponSetupOrder, ", "))
        return
    end

    if LT.Builds:SetWeaponSetup(index, setup) then
        LT:Print("Slot " .. tostring(index) .. " weapon configuration: " .. setup)
        LT:Warn("Changing the weapon configuration changes which comparisons are valid. "
            .. "Re-save the equipment set when the gear matches it.")
    else
        LT:Error("Unknown weapon configuration \"" .. tostring(setup) .. "\".")
    end
end

function commands.save(words)
    local index = tonumber(words[2]) or LT.Builds:GetActiveIndex()
    local snapshot, err = LT.GearSets:Save(index, { reason = "slash command" })

    if not snapshot then
        LT:Error(err or "The equipment set could not be saved.")
        return
    end

    LT:Print("Saved equipment set for \"" .. tostring(snapshot.buildName) .. "\": "
        .. tostring(#snapshot.rows) .. " slots, total score "
        .. LT:FormatNumber(snapshot.totalScore, 1) .. ".")

    if #snapshot.emptySlots > 0 then
        LT:Warn("Nothing equipped in: " .. table.concat(snapshot.emptySlots, ", ")
            .. ". Comparisons for those slots will report as incomplete.")
    end
end

function commands.gear(words)
    local index = tonumber(words[2]) or LT.Builds:GetActiveIndex()
    local status = LT.GearSets:GetStatus(index)

    LT:Print("Equipment set for slot " .. tostring(index) .. ": " .. LT.GearSets:Describe(index))

    for _, limitation in ipairs(status.limitations) do
        LT:Warn(limitation)
    end

    for _, row in ipairs(LT.GearSets:GetRows(index)) do
        if row.link then
            LT:Print("  " .. row.label .. ": " .. tostring(row.itemName or row.link)
                .. " — score " .. (row.score and LT:FormatNumber(row.score, 1) or "n/a"))
        elseif not row.expectedEmpty and not row.cosmetic then
            LT:Print("  " .. row.label .. ": " .. LT.Palette:Wrap("unknown", "empty"))
        end
    end
end

function commands.scan()
    local popup = LT.GearPopup
    if type(popup) ~= "table" or type(popup.PrintList) ~= "function" then
        LT:Error("The gear check module is not loaded.")
        return
    end

    popup:PrintList({ includeBank = false })
end

function commands.profiles()
    for _, profile in ipairs(LT.Profiles:GetAll()) do
        LT:Print("  [" .. tostring(profile.kind) .. "] " .. tostring(profile.name)
            .. "  key=" .. tostring(profile.key)
            .. (profile.provisional and ("  " .. LT.Palette:Wrap("caution", "provisional")) or ""))
    end
end

function commands.profile(words)
    local action = words[2]
    local active = LT.Builds:GetActiveIndex()

    if not action then
        commands.profiles()
        return
    end

    if action == "create" then
        local name = trim(words[3] or "")
        local fromKey = words[4]
        local key, err = LT.Profiles:Create(name, fromKey)

        if not key then
            LT:Error(err)
            return
        end

        LT:Print("Created custom profile \"" .. name .. "\" (key " .. key .. ").")
        return
    end

    if action == "copy" then
        local fromKey = words[3]
        local newName = trim(words[4] or "")
        local key, err = LT.Profiles:CopyProfile(fromKey, newName)

        if not key then
            LT:Error(err)
            return
        end

        LT:Print("Copied to \"" .. newName .. "\" (key " .. key .. ").")
        return
    end

    local key = action
    if not LT.Profiles:Assignable(key) then
        LT:Error("There is no profile with key \"" .. tostring(key) .. "\" that can be assigned.")
        return
    end

    if LT.Builds:SetProfile(active, key) then
        local profile = LT.Profiles:Get(key)
        LT:Print("Slot " .. tostring(active) .. " now uses \""
            .. tostring(profile and profile.name or key) .. "\".")
    else
        LT:Error("That profile could not be assigned.")
    end
end

function commands.weight(words)
    local stat = words[2]
    local value = tonumber(words[3])
    local build = LT.Builds:GetActive()

    if not stat or not value then
        LT:Print("Usage: /lt weight <stat> <value>")
        return
    end

    if not LT.StatLabels[stat] then
        LT:Error("Unknown stat \"" .. tostring(stat) .. "\". Try /lt weights to list them.")
        return
    end

    if not build or not build.profileKey then
        LT:Error("The active slot has no profile yet.")
        return
    end

    local ok, err = LT.Profiles:SetWeight(build.profileKey, stat, value)
    if ok then
        LT:Print("Set " .. LT:Label(stat) .. " to " .. LT:FormatNumber(value, 3)
            .. " in \"" .. tostring(LT.Profiles:Get(build.profileKey).name) .. "\".")
    else
        LT:Error(err)
    end
end

function commands.caps()
    local build = LT.Builds:GetActive()
    local profile = LT.Profiles:ResolveForBuild(LT.Builds:GetActiveIndex())

    if not profile then
        LT:Error("No profile for the active slot.")
        return
    end

    LT:Print("Caps for \"" .. tostring(profile.name) .. "\" — "
        .. LT.Levels:DescribeScoringLevel())

    -- Decision 5: name every registered cap adjustment with its source and
    -- reason, so a Tauren's hit or a weapon-skill racial/talent is visible.
    local adjustments = (type(LT.Caps) == "table" and type(LT.Caps.adjustments) == "table")
        and LT.Caps.adjustments or {}
    if #adjustments > 0 then
        LT:Print("  registered cap adjustments (" .. tostring(#adjustments) .. "):")
        for _, adj in ipairs(adjustments) do
            if type(adj) == "table" then
                LT:Print("    " .. tostring(adj.source) .. " — " .. tostring(adj.reason)
                    .. " (" .. LT:FormatNumber(adj.delta, 2) .. " " .. LT:Label(adj.stat) .. ")")
            end
        end
    else
        LT:Print("  registered cap adjustments: none.")
    end

    for _, status in ipairs(LT.Caps:GetAllStatus(profile, LT.Levels:GetScoringLevel())) do
        if status.enabled and status.relevant then
            if status.measured == false then
                LT:Print("  " .. status.label .. ": "
                    .. LT.Palette:Wrap("unknown", status.measuredLabel or "not measured yet"))
                for _, limitation in ipairs(status.limitations or {}) do
                    LT:Print("      " .. limitation)
                end
            else
            local text = "  " .. status.label .. ": target "
                .. LT:FormatNumber(status.target, 2)

            if status.kind == "percent" then text = text .. "%" end

            if status.targetRating then
                text = text .. " = " .. LT:FormatNumber(status.targetRating, 1)
                    .. " rating at level " .. tostring(status.level)
            elseif status.ratingUnavailable then
                text = text .. " " .. LT.Palette:Wrap("unknown", "(rating equivalent unavailable)")
            end

            if status.known then
                text = text .. " — " .. (status.capped and LT.Palette:Wrap("go", "met")
                    or LT.Palette:Wrap("caution", "short by " .. LT:FormatNumber(
                        status.remainingRating or status.remainingPercent or 0, 2)
                        .. (status.remainingRating and " rating" or "%")))
            else
                text = text .. " — " .. LT.Palette:Wrap("unknown", "state unknown")
            end

            LT:Print(text)

            for _, limitation in ipairs(status.limitations or {}) do
                LT:Print("      " .. limitation)
            end
            end
        end
    end

    LT:Warn("Every cap default is provisional, and a score difference is not a "
        .. "prediction of damage or survival.")
end

function commands.score(words)
    local link = words[2]

    if not link then
        if LT.UI and LT.UI.GetHoveredItemLink then
            link = LT.UI:GetHoveredItemLink()
        end

        if not link then
            LT:Print("Usage: /lt score <item link>  (shift-click an item into the chat box)")
            return
        end
    end

    local identity = LT.ItemStats:GetIdentity(link)
    if not identity then
        LT:Error("That item link could not be read.")
        return
    end

    LT:Print("Scores for " .. tostring(identity.name or link) .. " — "
        .. LT.Levels:DescribeScoringLevel())

    for index = 1, LT.Builds.SLOT_COUNT do
        local comparison = LT.Compare:ForBuild(link, index)
        local colour = LT.Compare:StatusColour(comparison.status)

        LT:Print("  " .. tostring(comparison.buildName) .. ": |cff" .. colour
            .. tostring(comparison.status) .. "|r — " .. LT.Compare:Describe(comparison))

        for _, limitation in ipairs(comparison.limitations or {}) do
            LT:Print("      " .. limitation)
        end

        for _, note in ipairs((comparison.candidate and comparison.candidate.imbueNotes) or {}) do
            LT:Print(note)
        end

        for _, row in ipairs(LT.Score:FormatBreakdown(comparison.candidate or {}, 8)) do
            LT:Print(row)
        end
    end
end

-- /lt why: what the last look at an item tooltip decided, in the player's
-- words. Chat only — the record lives in Tooltip, and nothing here draws.
function commands.why()
    local tooltip = LT.Tooltip
    local decision = tooltip and type(tooltip.LastDecision) == "function"
        and tooltip:LastDecision() or nil

    if not decision then
        LT:Print("No tooltip refusal recorded. The last item hover drew a panel, "
            .. "or nothing has been hovered since the addon loaded.")
        return
    end

    LT:Print("Last tooltip decision: "
        .. (decision.itemName and tostring(decision.itemName)
            or "an item the client did not name"))

    if decision.link then
        LT:Print("  item: " .. tostring(decision.link))
    end

    -- A known rule prints as a sentence, with its rule name in parentheses for
    -- diagnosis. A rule this build does not know — a plugin's own refusal — keeps
    -- the old fragment form, so the record is never hidden.
    local sentence = type(tooltip.RefusalSentence) == "function"
        and tooltip:RefusalSentence(decision.rule) or nil

    if sentence then
        LT:Print("  " .. sentence)
    else
        LT:Print("  refused because: " .. tostring(decision.rule))
    end

    LT:Print("  would change with: " .. tostring(decision.change))
end

-- The example is shown by the name inside its link when the client gave one;
-- a link with no name is printed as-is rather than guessed at.
local function exampleName(link)
    if type(link) ~= "string" then return tostring(link) end
    if LT:IsSecret(link) then return "an item the client did not name" end

    local name = link:match("%[(.-)%]")
    if name and name ~= "" then return name end

    return link
end

-- /lt unknown: the client stat keys the alias table could not map, most
-- reported first. Counts are item links, so this says which key is worth an
-- alias entry. Nothing here changes a score.
function commands.unknown(words)
    local itemStats = LT.ItemStats
    if type(itemStats) ~= "table"
        or type(itemStats.KnownUnknowns) ~= "function"
        or type(itemStats.ClearKnownUnknowns) ~= "function" then
        LT:Error("The item stats module is not loaded.")
        return
    end

    local action = words[2] and string.lower(tostring(words[2])) or nil

    if action == "clear" then
        itemStats:ClearKnownUnknowns()
        LT:Print("Cleared the unmodelled stat key store.")
        return
    end

    if action and action ~= "" then
        LT:Print("Usage: /lt unknown [clear]")
        return
    end

    local known = itemStats:KnownUnknowns()
    local rows = {}
    for key, entry in pairs(known) do
        table.insert(rows, { key = key, entry = entry })
    end

    if #rows == 0 then
        LT:Print("No unmodelled stat keys recorded yet. Hover an item, or run "
            .. "/lt score on it, and the keys this build cannot map will appear here.")
        return
    end

    table.sort(rows, function(left, right)
        local leftCount = left.entry.count or 0
        local rightCount = right.entry.count or 0
        if leftCount ~= rightCount then return leftCount > rightCount end
        return left.key < right.key
    end)

    local shown = math.min(#rows, 20)
    LT:Print("Unmodelled stat keys: " .. tostring(#rows) .. " distinct, showing "
        .. tostring(shown) .. " by item count. /lt unknown clear resets the store.")

    for index = 1, shown do
        local row = rows[index]
        LT:Print("  " .. row.key .. " — " .. tostring(row.entry.count or 0)
            .. " item(s) — e.g. " .. exampleName(row.entry.link))
    end
end

function commands.plugins()
    local count = 0

    for pluginId, plugin in pairs(LT.PluginAPI.plugins) do
        count = count + 1
        LT:Print("  " .. tostring(plugin.name) .. " v" .. tostring(plugin.version)
            .. " (api " .. tostring(plugin.apiVersion) .. ", id " .. tostring(pluginId) .. ")")

        local list = LT.PluginAPI.adjustments[pluginId] or {}
        LT:Print("      " .. tostring(#list) .. " adjustment(s) registered")

        for _, problem in ipairs(LT.PluginAPI.errors[pluginId] or {}) do
            LT:Print("      " .. LT.Palette:Wrap("stop", problem))
        end
    end

    if count == 0 then
        LT:Print("No plugins are loaded. The core works on its own — plugins only "
            .. "add class and talent knowledge.")
    end

    for _, problem in ipairs(LT.PluginAPI.registrationProblems or {}) do
        LT:Warn(problem)
    end
end

function commands.questwalk()
    local rewards = LT.QuestRewards
    if not rewards or type(rewards.WalkReport) ~= "function" then
        LT:Error("Quest reward diagnostics are not loaded.")
        return
    end
    local lines, visited = rewards:WalkReport(120)
    LT:Print("Quest-log walk: " .. tostring(visited) .. " frame(s) visited.")
    for _, line in ipairs(lines) do LT:Print("  " .. line) end
end

function commands.auras()
    local names, order, source = {}, {}, nil

    local function add(name, from)
        if type(name) == "string" and name ~= "" and not names[name]
            and not LT:IsSecret(name) then
            names[name] = from
            order[#order + 1] = name
        end
    end

    if type(C_UnitAuras) == "table" and type(C_UnitAuras.GetAuraDataByIndex) == "function" then
        source = "C_UnitAuras"
        for i = 1, 40 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
            if not ok or type(aura) ~= "table" then break end
            add(aura.name, source)
        end
    elseif type(UnitBuff) == "function" then
        source = "UnitBuff"
        for i = 1, 40 do
            local ok, name = pcall(UnitBuff, "player", i)
            if not ok or not name then break end
            add(name, source)
        end
    end

    if not source then
        LT:Error("This client exposes neither C_UnitAuras nor UnitBuff.")
        return
    end

    LT:Print(tostring(#order) .. " helpful aura(s) via " .. source .. ":")
    for _, name in ipairs(order) do LT:Print("  " .. name) end
end

function commands.imbunes(words)
    if words and words[2] then return commands.imbue(words) end
    return commands.imbues()
end

function commands.imbues()
    local enabled = LT.Imbues:IsEnabled()
    local active = LT.Builds:GetActiveIndex()

    LT:Print("Weapon imbue scoring: " .. (enabled and LT.Palette:Wrap("go", "on")
        or LT.Palette:Wrap("muted", "off"))
        .. " (Shaman only; tick it on the Builds or Settings page).")

    for index = 1, LT.Builds.SLOT_COUNT do
        local definition = LT.Imbues:ForKey(index)
        LT:Print("  Slot " .. tostring(index) .. ": " .. tostring(definition.label)
            .. (index == active and "  <- active" or ""))
    end

    if type(GetWeaponEnchantInfo) == "function" then
        local rawOk, hasMain, mainExp, mainCharges, fourth, fifth, sixth = pcall(GetWeaponEnchantInfo)
        local hasOff, offExp
        if type(fourth) == "boolean" then
            hasOff, offExp = fourth, fifth
        else
            hasOff, offExp = fifth, sixth
        end
        LT:Print("  Legacy raw: ok=" .. tostring(rawOk)
            .. " main=" .. tostring(hasMain) .. "/" .. tostring(mainExp)
            .. " charges=" .. tostring(mainCharges)
            .. " off=" .. tostring(hasOff) .. "/" .. tostring(offExp))
    else
        LT:Print("  Legacy raw: GetWeaponEnchantInfo is absent")
    end

    if type(GetInventoryItemLink) == "function" then
        local okMain, mainLink = pcall(GetInventoryItemLink, "player", 16)
        local okOff, offLink = pcall(GetInventoryItemLink, "player", 17)
        LT:Print("  Items: 16=" .. tostring(okMain and mainLink or "unreadable")
            .. " 17=" .. tostring(okOff and offLink or "unreadable"))
    end

    if LT.WeaponBuffs and type(LT.WeaponBuffs.HandState) == "function" then
        local hands = LT.WeaponBuffs:HandState()
        local function describe(state)
            if type(state) ~= "table" then return "unreadable" end
            local count = type(state.records) == "table" and #state.records or 0
            return tostring(count) .. " record(s), precise=" .. tostring(state.precise == true)
        end
        LT:Print("  Hand check: main slot " .. tostring(hands.mainSlot)
            .. " -> " .. describe(hands.main)
            .. "; off slot " .. tostring(hands.offSlot)
            .. " -> " .. describe(hands.off))
    end

    LT:Print("Imbues and what each one assumes:")
    for _, key in ipairs(LT.Imbues.order) do
        local definition = LT.Imbues:GetDefinition(key)
        if definition then
            local weapon = definition.weapon or {}
            LT:Print("  " .. tostring(definition.label)
                .. " — DPS x" .. LT:FormatNumber(weapon.dps or 1, 2)
                .. ", damage x" .. LT:FormatNumber(weapon.avgDamage or 1, 2)
                .. (definition.provisional and ("  " .. LT.Palette:Wrap("caution", "provisional")) or ""))
            if definition.assumptions and definition.assumptions ~= "" then
                LT:Print("      " .. definition.assumptions)
            end
        end
    end

    LT:Print("Usage: /lt imbunes <windfury / flametongue / frostbrand / rockbiter / none> "
        .. "sets the active slot's imbue (/lt imbue works too).")
end

function commands.imbue(words)
    local key = words[2]

    if not key then
        commands.imbues()
        return
    end

    local index = LT.Builds:GetActiveIndex()

    if not LT.Builds:SetImbue(index, key) then
        LT:Error("Unknown imbue \"" .. tostring(key) .. "\". Options: "
            .. table.concat(LT.Imbues.order, ", "))
        return
    end

    LT:Print("Slot " .. tostring(index) .. " imbue: "
        .. LT.Imbues:Describe(LT.Builds:GetImbue(index)))

    if not LT.Imbues:IsEnabled() then
        LT:Warn("Imbue scoring is off, so the choice is saved but not used yet. "
            .. "Tick \"Score weapons using the chosen imbue\" on the Builds page.")
    end
end

function commands.quest()
    if not LT.QuestRewards then
        LT:Error("The quest reward module is not loaded.")
        return
    end

    for _, line in ipairs(LT.QuestRewards:Describe()) do
        LT:Print(line)
    end
end

-- /lt itemdump: the raw reply behind a price. Every return the client gives is
-- printed by index, type and value, so a layout this build refuses can be
-- reported exactly instead of guessed at. Read-only: no score, no saved data.
function commands.itemdump(words)
    if not LT.QuestRewards or type(LT.QuestRewards.ItemDump) ~= "function" then
        LT:Error("The quest reward module is not loaded.")
        return
    end

    -- An item link can contain spaces inside its [name], so the whole remaining
    -- line is the link rather than just the second word.
    local link = table.concat(words, " ", 2)

    for _, line in ipairs(LT.QuestRewards:ItemDump(link)) do
        LT:Print(line)
    end
end

-- /lt colours: the second way into the legend window (the first is the Colours
-- button on the Settings page). If the window cannot be created on this client,
-- the same words are printed instead, so the meanings are never unreachable.
function commands.colours()
    if LT.Legend and LT.Legend:Show() then
        LT:Print("Colours window opened — what each colour means, and where it appears.")
        return
    end

    if not LT.Palette then
        LT:Error("The palette module is not loaded.")
        return
    end

    for _, line in ipairs(LT.Palette:Describe()) do
        LT:Print(line)
    end
end

-- Dev-only consolidated client probe. Not in /lt help: it exists to capture the
-- APIs we must confirm on Forever, and prints one block the player pastes back.
local function clientKind(name)
    local value = _G[name]
    if type(value) == "function" then return "function" end
    if type(value) == "table" then return "table" end
    return "absent"
end

local function nestedKind(tableName, methodName)
    local t = _G[tableName]
    if type(t) ~= "table" then return "absent (" .. tableName .. " absent)" end
    local v = t[methodName]
    if type(v) == "function" then return "function" end
    if type(v) == "table" then return "table" end
    return "absent"
end

function commands.clientinfo(words)
    local function say(text) LT:Print(text) end
    say("Lunchbox Toolkit client info — paste this into chat or capture")

    say("identity -------------------------------------------------")
    local function probe(name, ...)
        local api = _G[name]
        if type(api) ~= "function" then
            say("  " .. name .. ": absent")
            return
        end
        local ok, a, b = pcall(api, ...)
        say("  " .. name .. ": " .. (ok and (tostring(a) .. (b and (" | " .. tostring(b)) or "")) or ("error " .. tostring(a))))
    end
    probe("UnitName", "player")
    probe("UnitFullName", "player")
    probe("UnitRace", "player")
    probe("UnitClass", "player")
    probe("UnitLevel", "player")
    probe("UnitFactionGroup", "player")
    probe("GetRealmName")
    probe("GetCurrentRegion")
    say("  C_PlayerInfo.GetSurname: " .. nestedKind("C_PlayerInfo", "GetSurname"))
    say("  C_PlayerInfo.ShouldDisplaySurname: " .. nestedKind("C_PlayerInfo", "ShouldDisplaySurname"))

    say("spellbook / talents --------------------------------------")
    say("  IsPlayerSpell: " .. clientKind("IsPlayerSpell"))
    say("  IsSpellKnown: " .. clientKind("IsSpellKnown"))
    say("  C_SpellBook: " .. clientKind("C_SpellBook"))
    say("  C_SpellBook.IsSpellKnown: " .. nestedKind("C_SpellBook", "IsSpellKnown"))
    say("  C_ClassTalents: " .. clientKind("C_ClassTalents"))
    say("  C_ClassTalents.GetActiveConfigID: " .. nestedKind("C_ClassTalents", "GetActiveConfigID"))
    say("  C_Traits: " .. clientKind("C_Traits"))
    say("  C_Traits.GetTreeInfo: " .. nestedKind("C_Traits", "GetTreeInfo"))

    say("map / quest location -------------------------------------")
    say("  C_Map: " .. clientKind("C_Map"))
    say("  C_Map.GetBestMapForUnit: " .. nestedKind("C_Map", "GetBestMapForUnit"))
    say("  C_QuestLog: " .. clientKind("C_QuestLog"))
    say("  C_QuestLog.GetNextWaypoint: " .. nestedKind("C_QuestLog", "GetNextWaypoint"))
    say("  QuestPOIGetIconInfo: " .. clientKind("QuestPOIGetIconInfo"))

    say("channels / leaderboard -----------------------------------")
    say("  C_ChatInfo: " .. clientKind("C_ChatInfo"))
    say("  C_ChatInfo.RegisterAddonMessagePrefix: " .. nestedKind("C_ChatInfo", "RegisterAddonMessagePrefix"))
    say("  C_ChatInfo.SendAddonMessage: " .. nestedKind("C_ChatInfo", "SendAddonMessage"))
end

function commands.debug()
    LT.DEBUG = not LT.DEBUG
    LT:Print("Debug output " .. (LT.DEBUG and "on" or "off") .. ".")
end

-- /lt diag chat on|off: the per-character chat switch for LT:Diag. It is stored
-- in the character's options, so it survives a reload and does not follow the
-- player to an alt. Nothing here prints unless the option was written or read.
function commands.diag(words)
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        LT:Error("Saved variables are not available yet. Try again after the character loads.")
        return
    end

    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then
        LT:Error("The saved options could not be read.")
        return
    end

    local scope = string.lower(words[2] or "")
    local state = string.lower(words[3] or "")
    if scope ~= "chat" then
        LT:Print("Usage: /lt diag chat on|off")
        return
    end

    if state == "on" or state == "off" then
        options.debugChat = (state == "on")
        if type(database.Save) == "function" then
            pcall(database.Save, database, "diag:chat")
        end
    elseif state ~= "" then
        LT:Print("Usage: /lt diag chat on|off")
        return
    end

    LT:Print("Diagnostic chat lines " .. (options.debugChat == true and "on" or "off")
        .. " for this character.")
end

-- The combo-point tracker and its diagnostics. Everything the command prints
-- and every guard on the client APIs live in Trackers; this only routes words.
function commands.trackers(words)
    if not LT.Trackers then
        LT:Error("The tracker module is not loaded.")
        return
    end

    LT.Trackers:Command(words)
end

-- Windfury records popup. The window lives in the Weapon Buffs plugin (the
-- imbue surface); /lt trackers wf prints the same list in chat.
function commands.wf(words)
    local mode = words and words[2]
    local plugin = LT.WeaponBuffs
    local function refreshPopup()
        if type(plugin) == "table" and type(plugin.ShowRecords) == "function" then
            plugin:ShowRecords()
        end
    end
    if mode == "debug" then
        local on = words and words[3]
        if LT.Trackers then
            if on == "on" then
                LT.Trackers.wfProbe = true
                LT:Print("Windfury debug on: swings, casts and combat events will print.")
            elseif on == "off" then
                LT.Trackers.wfProbe = false
                LT:Print("Windfury debug off.")
            else
                LT:Print("Usage: /lt wf debug on|off")
            end
        end
        return
    end
    if mode == "move" then
        if LT.Trackers and type(LT.Trackers.FlashWindfury) == "function" then
            LT.Trackers:FlashWindfury("Windfury! (drag me)", 60, true)
            LT:Print("Drag the alert where you want it; the spot is saved.")
        end
        return
    end
    if mode == "reset" then
        if LT.Trackers and type(LT.Trackers.ResetWindfuryRecords) == "function" then
            LT.Trackers:ResetWindfuryRecords()
            LT:Print("Windfury records cleared.")
        end
        refreshPopup()
        return
    end
    -- The chat list reads the live store, so it is never stale; the popup
    -- reads the same store and is refreshed here every time.
    if LT.Trackers and type(LT.Trackers.PrintWindfuryRecords) == "function" then
        LT.Trackers:PrintWindfuryRecords()
    end
    refreshPopup()
end

function commands.probe(words)
    if not LT.Trackers then
        LT:Error("The tracker module is not loaded.")
        return
    end

    LT.Trackers:CommandProbe(words)
end

function commands.weights()
    local groups = LT.ItemStats.statGroups

    for _, group in ipairs(groups) do
        local names = {}
        for _, stat in ipairs(group.stats) do
            table.insert(names, stat .. " (" .. LT:Label(stat) .. ")")
        end
        LT:Print(group.label .. ": " .. table.concat(names, ", "))
    end
end

-----------------------------------------------------------------------------
-- Profile export / import
--
-- An addon cannot write a text file, so an export is two things at once:
--   * a numbered copy kept in saved variables, which the client writes to
--     WTF/Account/<account>/SavedVariables/LunchboxToolkitDB.lua on
--     logout or /reload — that is the file the player can edit;
--   * the same string printed to chat, so it can also be copied straight out.
-- /lt import reads either: a numbered entry from that file, or pasted text.
-----------------------------------------------------------------------------

local EXPORT_CHUNK = 220

-- Long strings wrap badly and can be cut short, so they are printed in
-- numbered pieces the player can read in order.
local function printChunks(text)
    local length = #text
    local index = 1
    local piece = 1

    while index <= length do
        LT:Print("[" .. tostring(piece) .. "] " .. text:sub(index, index + EXPORT_CHUNK - 1))
        index = index + EXPORT_CHUNK
        piece = piece + 1
    end
end

function commands.export(words)
    local key = words[2]
    local activeKey = LT.Builds:GetActiveIndex()

    if not key then
        local profile = LT.Profiles:ResolveForBuild(activeKey)
        key = profile and profile.key
    end

    if not key then
        LT:Error("The active slot has no profile to export.")
        return
    end

    local text, err = LT.Profiles:Serialize(key)
    if not text then
        LT:Error(err)
        return
    end

    local profile = LT.Profiles:Get(key)
    local index = LT.Profiles:StoreExport(text, profile and profile.name or key)

    LT:Print("Exported \"" .. tostring(profile and profile.name or key) .. "\" as entry "
        .. tostring(index) .. " (" .. tostring(#text) .. " characters).")
    printChunks(text)

    LT:Print("To edit it in a file: open WTF\\Account\\<account>\\SavedVariables\\"
        .. "LunchboxToolkitDB.lua, find characters[\"...\"].exports[" .. tostring(index)
        .. "].text, change the string, save, then /reload and /lt import " .. tostring(index) .. ".")
    LT:Print("To import a hand-edited string instead: /lt import <paste the whole line>")
end

function commands.exports()
    local rows = LT.Profiles:DescribeExports()

    if #rows == 0 then
        LT:Print("No exports have been written yet. /lt export copies the active slot's "
            .. "profile into saved variables, where it can be edited in a text file.")
        return
    end

    LT:Print("Stored export entries — characters[\"...\"].exports[n].text:")
    for _, row in ipairs(rows) do
        LT:Print("  " .. row)
    end

    LT:Print("/lt import <n> loads one back as a new custom profile. "
        .. "/lt import last loads the newest.")
end

function commands.import(words)
    local argument = words[2]

    if not argument then
        LT:Print("Usage:")
        LT:Print("  /lt import <n>        import stored export entry n")
        LT:Print("  /lt import last       import the newest stored export")
        LT:Print("  /lt import <text>     import a pasted LBT1 string")
        LT:Print("Add \"use\" at the end to assign the result to the active slot.")
        return
    end

    local text
    local assign = false
    local lastWord = words[#words]

    if lastWord == "use" or lastWord == "assign" then
        assign = true
        table.remove(words, #words)
        argument = words[2]
    end

    if argument == "last" or argument == "file" then
        local wanted = (argument == "last") and #LT.Profiles:GetExports()
            or tonumber(words[3])

        local entry = wanted and LT.Profiles:GetExport(wanted)
        if not entry then
            LT:Error("There is no stored export at that position. /lt exports lists them.")
            return
        end

        text = entry.text
    elseif tonumber(argument) then
        local entry = LT.Profiles:GetExport(tonumber(argument))
        if not entry then
            LT:Error("There is no stored export at position " .. tostring(argument) .. ".")
            return
        end

        text = entry.text
    else
        text = table.concat(words, " ", 2)
    end

    local key, data = LT.Profiles:Import(text)
    if not key then
        LT:Error(data or "The profile could not be imported.")
        return
    end

    local profile = LT.Profiles:Get(key)
    LT:Print("Imported \"" .. tostring(profile and profile.name or key) .. "\" (key "
        .. tostring(key) .. ") as a new custom profile. Nothing existing was changed.")

    if data then
        if #data.unknownStats > 0 then
            LT:Warn("This string mentions stats this build does not model: "
                .. table.concat(data.unknownStats, ", ")
                .. ". They were kept, but they contribute nothing to a score.")
        end

        for _, warning in ipairs(data.warnings or {}) do
            LT:Warn(warning)
        end
    end

    if assign then
        if LT.Builds:SetProfile(LT.Builds:GetActiveIndex(), key) then
            LT:Print("Slot " .. tostring(LT.Builds:GetActiveIndex()) .. " now uses it.")
        else
            LT:Warn("The profile was imported but could not be assigned to the active slot.")
        end
    else
        LT:Print("Assign it with /lt use <1|2> then /lt profile " .. tostring(key) .. ".")
    end
end

------------------------------------------------------------------------------
-- Dispatch
------------------------------------------------------------------------------

local dispatch = {
    ["help"] = commands.help, ["?"] = commands.help,
    ["ui"] = commands.ui, ["open"] = commands.ui,
    ["test"] = commands.test,
    ["level"] = commands.level,
    ["played"] = commands.played,
    ["capture"] = commands.capture,
    ["divisor"] = commands.divisor,
    ["builds"] = commands.builds,
    ["use"] = commands.use,
    ["name"] = commands.name,
    ["spec"] = commands.spec,
    ["role"] = commands.role,
    ["context"] = commands.context,
    ["weapon"] = commands.weapon,
    ["save"] = commands.save,
    ["gear"] = commands.gear,
    ["scan"] = commands.scan,
    ["profiles"] = commands.profiles,
    ["profile"] = commands.profile,
    ["export"] = commands.export,
    ["exports"] = commands.exports,
    ["import"] = commands.import,
    ["weight"] = commands.weight,
    ["weights"] = commands.weights,
    ["caps"] = commands.caps,
    ["score"] = commands.score,
    ["why"] = commands.why,
    ["unknown"] = commands.unknown,
    ["quest"] = commands.quest,
    ["itemdump"] = commands.itemdump,
    ["drop"] = commands.drop,
    ["trash"] = commands.drop,
    ["colours"] = commands.colours,
    ["colors"] = commands.colours,
    ["imbune"] = commands.imbue,
    ["imbues"] = commands.imbues,
    ["imbunes"] = commands.imbunes,
    ["auras"] = commands.auras,
    ["trackers"] = commands.trackers,
    ["wf"] = commands.wf,
    ["probe"] = commands.probe,
    ["questwalk"] = commands.questwalk,
    ["imbue"] = commands.imbue,
    ["plugins"] = commands.plugins,
    ["debug"] = commands.debug,
    ["diag"] = commands.diag,
    ["clientinfo"] = commands.clientinfo,
    ["client"] = commands.clientinfo,
}

-- Commands registered by a module or plugin after load, so a new surface does
-- not have to edit this table. Word is the first token; an existing word can
-- never be replaced, so a plugin cannot hijack /lt test.
function Slash:RegisterCommand(word, handler, help)
    if type(word) ~= "string" or word == "" then return false end
    if type(handler) ~= "function" then return false end

    local key = string.lower(word)
    if dispatch[key] or extra[key] then return false end

    extra[key] = handler
    if type(help) == "string" and help ~= "" then
        extraHelp[#extraHelp + 1] = { text = help }
    end
    return true
end

function Slash:RegisteredCommands()
    local list = {}
    for key in pairs(dispatch) do list[#list + 1] = key end
    for key in pairs(extra) do list[#list + 1] = key end
    table.sort(list)
    return list
end

-- Register slash aliases at file load time. WoW's slash-command system reads
-- SLASH_<NAME><INDEX> globals during addon loading; defining them only at
-- PLAYER_LOGIN can be too late on some clients.
_G.SLASH_LUNCHBOXTOOLKIT1 = "/lt"
_G.SLASH_LUNCHBOXTOOLKIT2 = "/lunchbox"

local function SlashCommandHandler(input)
    Slash:Handle(input)
end

-- The standard WoW API is direct assignment into SlashCmdList. Do not rely on
-- RegisterSlashCmd, which is not part of the normal WoW slash-command API.
if type(SlashCmdList) == "table" then
    SlashCmdList["LUNCHBOXTOOLKIT"] = SlashCommandHandler
end

function Slash:OnPlayerLogin()
    -- Reassert the registration defensively in case a client initializes
    -- slash-command globals unusually late.
    _G.SLASH_LUNCHBOXTOOLKIT1 = "/lt"
    _G.SLASH_LUNCHBOXTOOLKIT2 = "/lunchbox"

    if type(SlashCmdList) == "table" then
        SlashCmdList["LUNCHBOXTOOLKIT"] = SlashCommandHandler
    else
        LT:Error("Slash command system is unavailable; use /reload after checking the addon files.")
    end
end

function Slash:Handle(input)
    local words = splitCommand(input)
    local command = words[1]

    if not command or command == "" then
        if LT.UI then LT.UI:Toggle() end
        return
    end

    local key = string.lower(command)
    local handler = dispatch[key] or extra[key]
    if handler then
        local ok, err = pcall(handler, words)
        if not ok then
            LT:Error("Command failed: " .. tostring(err))
        end
        return
    end

    LT:Print("Unknown command \"" .. tostring(command) .. "\". /lt help lists them.")
end