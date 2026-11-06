--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — SelfTest
    In-game assertions for the things that are easy to get subtly wrong:
    scoring maths, profile isolation, cap single-application, plugin de-dupe,
    level scaling, weapon configuration rules, the v0.5 migration and the
    quest-reward ranking (purple / blue / gold).

    Most of this needs the client, so the in-game harness is /lt test. Nothing
    here touches the player's saved data — every test works on copies or on
    synthetic tables. The suites marked `pure` in SelfTest.suites take plain
    tables and call no client API, so an offline Lua harness can run those
    without the game.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local SelfTest = {}
LT.SelfTest = SelfTest
LT.Modules.SelfTest = SelfTest

local function newReport()
    return { passed = 0, failed = 0, lines = {}, failures = {} }
end

local function check(report, name, condition, detail)
    if condition then
        report.passed = report.passed + 1
        table.insert(report.lines, LT.Palette:Wrap("go", "PASS") .. " " .. name)
    else
        report.failed = report.failed + 1
        table.insert(report.lines, LT.Palette:Wrap("stop", "FAIL") .. " " .. name
            .. (detail and (" — " .. tostring(detail)) or ""))
        table.insert(report.failures, name)
    end
end

local function closeTo(a, b, tolerance)
    a, b = tonumber(a), tonumber(b)
    if not a or not b then return false end
    return math.abs(a - b) <= (tolerance or 0.0001)
end

local function withSyntheticCharacter(fn)
    -- Swap in a throwaway character record so tests never write into the
    -- player's real saved profile, then put the real one back.
    --
    -- A local addon may redirect custom profiles into its own saved variables.
    -- That has to be paused here as well, or these tests would write into the
    -- player's personal data instead of the throwaway record.
    local previousStore = LT.Profiles.GetCustomStore and LT.Profiles:GetCustomStore()
    if previousStore then LT.Profiles:SetCustomStore(nil) end

    local original = LT.Database.character

    local synthetic = LT.Database.defaultCharacter()
    synthetic.builds = {}
    synthetic.customProfiles = {}

    LT.Database.character = synthetic
    LT.Builds:EnsureForClass(LT.player.class)
    LT.Profiles:Invalidate()

    local ok, err = pcall(fn, synthetic)

    LT.Database.character = original
    if previousStore then LT.Profiles:SetCustomStore(previousStore) end
    LT.Profiles:Invalidate()

    if not ok then
        return false, err
    end

    return true
end

------------------------------------------------------------------------------
-- Tests
------------------------------------------------------------------------------

local function testScoringMaths(report)
    withSyntheticCharacter(function()
        local key = LT.Profiles:Create("SelfTest maths")
        local build = LT.Builds:Get(1)
        LT.Builds:SetProfile(1, key)
        LT.Profiles:SetWeight(key, "strength", 2)
        LT.Profiles:SetWeight(key, "hit", 3)

        LT.Profiles:Invalidate()
        local effective = LT.Profiles:GetEffective(1)
        local weights = effective.weights

        local stats = { strength = 10, hit = 4 }
        local expected = 10 * (weights.strength or 0) + 4 * (weights.hit or 0)

        local result = LT.Score:ScoreStats(stats, 1, { noCache = true })

        check(report, "weighted score equals sum of stat x weight",
            closeTo(result.score, expected, 0.0001),
            "expected " .. tostring(expected) .. " got " .. tostring(result.score))

        check(report, "breakdown accounts for every weighted stat",
            #result.breakdown == 2,
            "rows: " .. tostring(#result.breakdown))

        -- A stat with no weight must be reported, not silently dropped.
        local unknown = LT.Score:ScoreStats({ strength = 1, fireResist = 50 }, 1, { noCache = true })
        check(report, "unweighted stat is reported as not counted",
            #unknown.unsupported == 1 and unknown.unsupported[1].stat == "fireResist",
            "unsupported entries: " .. tostring(#unknown.unsupported))

        -- Scores from different profiles are separate scales.
        local otherKey = LT.Profiles:Create("SelfTest other scale")
        LT.Builds:SetProfile(2, otherKey)
        local a = LT.Score:ScoreStats({ strength = 1 }, 1, { noCache = true })
        local b = LT.Score:ScoreStats({ strength = 1 }, 2, { noCache = true })
        local comparable, _ = LT.Score:CompareScales(a, b)
        check(report, "scores from different profiles refuse to compare", comparable == false)
    end)
end

local function testCapSingleApplication(report)
    withSyntheticCharacter(function(character)
        -- The shipped defaults changed in 2026-11: an unmeasurable cap is no
        -- longer boosted, and levelling bands scale weights below 60. This test
        -- is about the cap multiplier, so pin both to the old behaviour here and
        -- assert the new default separately at the end.
        character.options.capBoostUnknown = true
        character.options.levellingBands = false

        -- The mode boost is 1.0 while PvE levelling by design, so "the boost
        -- happened" cannot be asserted against a real mode here. Pin the
        -- multiplier: this test is about applying the policy exactly once.
        local previousModeBoost = LT.Caps.GetModeBoost
        LT.Caps.GetModeBoost = function() return 2, "selftest" end

        local key = LT.Profiles:Create("SelfTest caps")
        LT.Builds:SetProfile(1, key)
        LT.Profiles:SetWeight(key, "hit", 4)
        LT.Profiles:SetWeight(key, "strength", 2)

        -- Disable every other cap so only hit is in play.
        for _, stat in ipairs(LT.Caps.order) do
            LT.Profiles:SetCap(key, stat, "enabled", stat == "hit")
        end
        LT.Profiles:SetCap(key, "hit", "target", 9)
        LT.Profiles:SetCap(key, "hit", "importance", 2)

        LT.Profiles:Invalidate()
        local first = LT.Profiles:GetEffective(1, { noCache = true }).weights.hit
        local second = LT.Profiles:GetEffective(1, { noCache = true }).weights.hit
        local third = LT.Profiles:GetEffective(1, { noCache = true }).weights.hit

        -- The cap policy boosts the capped stat above its stored weight; the
        -- exact multiplier is the mode-dependent boost (not the old flat
        -- importance), so assert the boost happened, not a hardcoded number.
        -- A nil boost is multiplied in as 1, so the status is printed: it says
        -- whether the cap was entered at all and what multiplier it carried.
        local capStatus = LT.Caps:GetStatus(LT.Profiles:Get(key), "hit", character.level)
        local capDetail = "boost=" .. tostring(capStatus and capStatus.boost)
            .. " enabled=" .. tostring(capStatus and capStatus.enabled)
            .. " relevant=" .. tostring(capStatus and capStatus.relevant)
            .. " known=" .. tostring(capStatus and capStatus.known)
            .. " mode=" .. tostring(capStatus and capStatus.mode)

        check(report, "cap policy is applied exactly once",
            type(first) == "number" and closeTo(first, 8, 0.0001),
            "expected hit 4 x 2 = 8, got " .. tostring(first) .. " (" .. capDetail .. ")")

        check(report, "repeat recalculation does not compound the cap bonus",
            closeTo(first, second, 0.0001) and closeTo(second, third, 0.0001),
            tostring(first) .. " / " .. tostring(second) .. " / " .. tostring(third))

        -- A stat with no cap must be untouched by the cap policy.
        check(report, "uncapped weights are left alone",
            closeTo(LT.Profiles:GetEffective(1, { noCache = true }).weights.strength, 2, 0.0001))

        -- The shipped default: no measured value means no boost.
        character.options.capBoostUnknown = false
        LT.Profiles:Invalidate()
        check(report, "an unmeasurable cap is not boosted by default",
            closeTo(LT.Profiles:GetEffective(1, { noCache = true }).weights.hit, 4, 0.0001),
            tostring(LT.Profiles:GetEffective(1, { noCache = true }).weights.hit))

        LT.Caps.GetModeBoost = previousModeBoost
    end)
end

local function testProfileIsolation(report)
    withSyntheticCharacter(function(character)
        -- Same pin as the cap test: isolate isolation from the new defaults.
        character.options.capBoostUnknown = true
        character.options.levellingBands = false

        -- Levelling mode boosts by 1.0 by design; pin a multiplier so "effective
        -- differs from stored" has something to measure.
        local previousModeBoost = LT.Caps.GetModeBoost
        LT.Caps.GetModeBoost = function() return 2, "selftest" end

        local base = LT.ClassData:GetBaseProfile("shaman_enhancement_tank_pve")
        local original = base.weights.stamina

        local copyKey = LT.Profiles:CopyProfile("shaman_enhancement_tank_pve", "SelfTest copy")
        LT.Profiles:SetWeight(copyKey, "stamina", 9.5)

        check(report, "editing a copy leaves the base profile untouched",
            closeTo(base.weights.stamina, original, 0.0001),
            "base stamina changed to " .. tostring(base.weights.stamina))

        local copy = LT.Profiles:Get(copyKey)
        check(report, "the copy took the new value",
            closeTo(copy.weights.stamina, 9.5, 0.0001))

        local okEdit, errEdit = LT.Profiles:SetWeight("shaman_enhancement_tank_pve", "stamina", 1)
        check(report, "base profiles refuse direct edits", okEdit == false, errEdit)

        -- Effective weights must never be written back into the stored weights.
        LT.Builds:SetProfile(1, copyKey)
        LT.Profiles:SetCap(copyKey, "hit", "enabled", true)
        LT.Profiles:SetCap(copyKey, "hit", "importance", 5)
        LT.Profiles:SetWeight(copyKey, "hit", 1)

        LT.Profiles:Invalidate()
        local effective = LT.Profiles:GetEffective(1, { noCache = true })
        check(report, "effective weights differ from stored weights when a cap applies",
            (effective.weights.hit or 0) > 1)
        check(report, "stored weights are unchanged by calculation",
            closeTo(LT.Profiles:Get(copyKey).weights.hit, 1, 0.0001),
            "stored hit is now " .. tostring(LT.Profiles:Get(copyKey).weights.hit))

        -- Turning the cap off must remove its effect entirely.
        LT.Profiles:SetCap(copyKey, "hit", "enabled", false)
        LT.Profiles:Invalidate()
        check(report, "disabling a cap removes its effect without damaging the profile",
            closeTo(LT.Profiles:GetEffective(1, { noCache = true }).weights.hit, 1, 0.0001))

        -- Independence of the two slots.
        local secondKey = LT.Profiles:Create("SelfTest slot2")
        LT.Builds:SetProfile(2, secondKey)
        LT.Profiles:SetWeight(secondKey, "stamina", 7)
        LT.Profiles:Invalidate()

        local one = LT.Profiles:GetEffective(1, { noCache = true }).weights
        local two = LT.Profiles:GetEffective(2, { noCache = true }).weights

        check(report, "the two slots hold independent weights",
            not closeTo(one.stamina, two.stamina, 0.0001),
            tostring(one.stamina) .. " vs " .. tostring(two.stamina))

        LT.Caps.GetModeBoost = previousModeBoost
    end)
end

local function testPluginInterface(report)
    -- The duplicate id and the too-new API below are refused on purpose, and
    -- every refusal appends a registration problem. Those problems are shown on
    -- the Plugins page, so they are removed again afterwards: the page must list
    -- real load-time problems only, and a second /lt test run has to start from
    -- the same list as the first. Recorded outside the pcall'd body so a failure
    -- half way through still cleans up.
    local api = LT.PluginAPI
    local problems = api and api.registrationProblems
    local problemsBefore = problems and #problems or 0

    withSyntheticCharacter(function()
        local key = LT.Profiles:Create("SelfTest plugins")
        LT.Builds:SetProfile(1, key)
        LT.Profiles:SetWeight(key, "weaponDPS", 1)
        LT.Profiles:Invalidate()

        local plugin = LT.PluginAPI:RegisterPlugin({
            id = "selftest.plugin",
            name = "Self test plugin",
            version = "1",
            apiVersion = 1,
        })

        check(report, "a plugin can register", plugin ~= nil)

        local duplicate, duplicateReason = LT.PluginAPI:RegisterPlugin({
            id = "selftest.plugin", name = "Duplicate", apiVersion = 1,
        })
        check(report, "a duplicate plugin id is refused",
            duplicate == nil and duplicateReason ~= nil, duplicateReason)

        local tooNew, tooNewReason = LT.PluginAPI:RegisterPlugin({
            id = "selftest.future", name = "Future", apiVersion = LT.PluginAPI.VERSION + 1,
        })
        check(report, "a plugin written for a newer API is refused",
            tooNew == nil and tooNewReason ~= nil, tooNewReason)

        -- Re-enabling a plugin must return to what the profile weighs on its own.
        -- That is not necessarily 1: a shaman base profile carries weaponDPS 1.08,
        -- and the old literal 1 made this check fail on every shaman.
        local baseWeaponDPS = LT.Profiles:GetEffective(1, { noCache = true }).weights.weaponDPS

        -- Two adjustments modelling the same benefit on the same stat.
        LT.PluginAPI:RegisterAdjustment("selftest.plugin", {
            id = "windfury-a",
            title = "Windfury (first)",
            benefit = "windfury_extra_attack",
            priority = 10,
            contribution = function() return { stats = { weaponDPS = 0.5 } } end,
        })

        LT.PluginAPI:RegisterAdjustment("selftest.plugin", {
            id = "windfury-b",
            title = "Windfury (second, same benefit)",
            benefit = "windfury_extra_attack",
            priority = 20,
            contribution = function() return { stats = { weaponDPS = 0.5 } } end,
        })

        local collected = LT.PluginAPI:CollectAdjustments({
            build = LT.Builds:Get(1),
            buildIndex = 1,
            profile = LT.Profiles:Get(key),
            level = 1,
            weights = { weaponDPS = 1 },
        })

        check(report, "only one of two adjustments modelling the same benefit applies",
            closeTo(collected.weights.weaponDPS, 1.5, 0.0001),
            "weaponDPS ended at " .. tostring(collected.weights.weaponDPS))

        check(report, "the skipped adjustment is reported",
            #collected.skipped >= 1 and #collected.limitations >= 1)

        -- A throwing adjustment must not break the core.
        LT.PluginAPI:RegisterAdjustment("selftest.plugin", {
            id = "broken",
            title = "Broken adjustment",
            benefit = "broken_thing",
            priority = 5,
            contribution = function() error("deliberate self test failure") end,
        })

        local survivors = LT.PluginAPI:CollectAdjustments({
            build = LT.Builds:Get(1),
            buildIndex = 1,
            profile = LT.Profiles:Get(key),
            level = 1,
            weights = { weaponDPS = 1 },
        })

        check(report, "a failing adjustment is skipped, not fatal",
            closeTo(survivors.weights.weaponDPS, 1.5, 0.0001))
        check(report, "the failure is recorded",
            LT.PluginAPI:HasErrors() == true)

        -- Disabling a plugin in the build removes its effect.
        LT.Builds:SetPluginEnabled(1, "selftest.plugin", false)
        LT.Profiles:Invalidate()
        local disabled = LT.Profiles:GetEffective(1, { noCache = true })
        check(report, "a disabled plugin contributes nothing",
            closeTo(disabled.weights.weaponDPS, baseWeaponDPS, 0.0001),
            "weaponDPS is " .. tostring(disabled.weights.weaponDPS)
                .. ", profile " .. tostring(baseWeaponDPS))

        LT.Builds:SetPluginEnabled(1, "selftest.plugin", true)
        LT.PluginAPI:UnregisterPlugin("selftest.plugin")
        check(report, "unregistering removes the plugin and its adjustments",
            LT.PluginAPI.plugins["selftest.plugin"] == nil
                and LT.PluginAPI.adjustments["selftest.plugin"] == nil)
    end)

    if problems then
        for index = #problems, problemsBefore + 1, -1 do
            problems[index] = nil
        end
    end
end

local function testLevelScaling(report)
    withSyntheticCharacter(function()
    local originalLevel = LT.player.level

    LT.player.level = 1
    check(report, "at level 1 the scoring level is 2",
        LT.Levels:GetScoringLevel() == 2, LT.Levels:GetScoringLevel())

    LT.player.level = 30
    check(report, "at level 30 the scoring level is 31",
        LT.Levels:GetScoringLevel() == 31, LT.Levels:GetScoringLevel())

    LT.player.level = 59
    check(report, "at level 59 the scoring level is 60",
        LT.Levels:GetScoringLevel() == 60, LT.Levels:GetScoringLevel())

    LT.player.level = 60
    check(report, "at level 60 the scoring level stays 60",
        LT.Levels:GetScoringLevel() == 60, LT.Levels:GetScoringLevel())

    LT.player.level = originalLevel

    -- Conversion handling: a measurement must beat a manual entry, and an
    -- unknown level must report a reason rather than a number.
    LT.Levels:SetConversion("crit", 20, 14, LT.SOURCE_MANUAL)
    LT.Levels:SetConversion("crit", 20, 12, LT.SOURCE_MEASURED)
    local value, meta = LT.Levels:GetConversion("crit", 20)

    check(report, "a measured conversion is kept over a manual one",
        closeTo(value, 12, 0.0001) and meta.source == LT.SOURCE_MEASURED,
        tostring(value) .. " / " .. tostring(meta.source))

    local stale = LT.Levels:SetConversion("crit", 20, 99, LT.SOURCE_MANUAL)
    check(report, "a weaker source cannot overwrite a stronger one", stale == false)

    local unknown, unknownMeta = LT.Levels:GetConversion("parry", 47)
    check(report, "an unmeasured conversion returns a reason, not a guess",
        unknown == nil and unknownMeta ~= nil and unknownMeta.reason ~= nil)

    check(report, "rating to percent maths uses the conversion",
        closeTo(LT.Levels:PercentForRating("crit", 24, 20), 2, 0.0001))
    end)
end

local function testWeaponConfigurationRules(report)
    local cases = {
        { setup = "2H",        equipLoc = "INVTYPE_2HWEAPON",      expectSlots = 1 },
        { setup = "2H",        equipLoc = "INVTYPE_WEAPONMAINHAND", expectSlots = 1 },
        { setup = "2H",        equipLoc = "INVTYPE_SHIELD",         expectSlots = 1 },
        { setup = "1H_SHIELD", equipLoc = "INVTYPE_2HWEAPON",      expectSlots = 1 },
        { setup = "1H_SHIELD", equipLoc = "INVTYPE_SHIELD",        expectSlots = 1 },
        { setup = "1H_SHIELD", equipLoc = "INVTYPE_WEAPON",        expectSlots = 1 },
        { setup = "DUAL_WIELD", equipLoc = "INVTYPE_WEAPON",       expectSlots = 2 },
        { setup = "DUAL_WIELD", equipLoc = "INVTYPE_2HWEAPON",     expectSlots = 1 },
        { setup = "RANGED",    equipLoc = "INVTYPE_RANGED",        expectSlots = 1 },
    }

    withSyntheticCharacter(function()
        LT.Builds:SetProfile(1, LT.Profiles:Create("SelfTest weapons"))

        for _, case in ipairs(cases) do
            LT.Builds:SetWeaponSetup(1, case.setup)

            local slots = LT.Compare:GetTargetSlots(1, { equipLoc = case.equipLoc })
            local label = case.setup .. " + " .. case.equipLoc

            check(report, "maps " .. label .. " against "
                .. tostring(case.expectSlots) .. " slot(s)",
                slots ~= nil and #slots == case.expectSlots,
                slots and ("got " .. tostring(#slots)) or "no slots")
        end
    end)
end

local function testMigration(report)
    local legacy = {
        schema = 5,
        activeProfile = "Default",
        profiles = {
            Default = {
                name = "Default",
                class = "SHAMAN",
                role = "DPS",
                context = "DUNGEON",
                contexts = {
                    DUNGEON = { baseWeights = { DPS = { strength = 1.5, hit = 2 } } },
                },
                goals = { primaryMultiplier = 1.2 },
                caps = { hit = { enabled = true, target = 9 } },
            },
        },
    }

    local migrated = LT.Database:Migrate(LT:Copy(legacy))

    check(report, "migration raises the schema version",
        migrated.schema == LT.Database.SCHEMA, tostring(migrated.schema))

    check(report, "migration keeps an untouched copy of the old data",
        migrated.legacyV5 ~= nil and migrated.legacyV5.Default ~= nil)

    local importedCount = 0
    local imported
    for key, profile in pairs(migrated.customProfiles or {}) do
        importedCount = importedCount + 1
        imported = profile
    end

    check(report, "migration imports old profiles as custom ones",
        importedCount == 1, tostring(importedCount))

    check(report, "migration carries the old weights across",
        imported ~= nil and closeTo(imported.weights.strength, 1.5, 0.0001)
            and closeTo(imported.weights.hit, 2, 0.0001),
        imported and tostring(imported.weights.strength))

    check(report, "an imported profile is marked provisional and explained",
        imported ~= nil and imported.provisional == true
            and type(imported.assumptions) == "string" and #imported.assumptions > 0)

    check(report, "migration assigns the active v0.5 profile to slot 1",
        migrated.builds[1] ~= nil and migrated.builds[1].profileKey ~= nil)

    local again = LT.Database:Migrate(LT:Copy(migrated))
    check(report, "migrating twice does not duplicate or reset",
        again.schema == LT.Database.SCHEMA)
end

local function testItemReading(report)
    -- Pure first, so these run on a character with nothing equipped: the mapping
    -- and the route report never touch the client.
    local merged, unmapped = {}, {}
    local mapped = LT.ItemStats.MergeRaw({
        ITEM_MOD_STAMINA = 5,
        ITEM_MOD_ARMOR_SHORT = 19,
        ITEM_MOD_NOT_IN_THE_ALIASES = 1,
    }, merged, unmapped)

    check(report, "raw client stat keys map to canonical channels", mapped == 2,
        tostring(mapped) .. " mapped")
    check(report, "a mapped stat keeps the number the client gave",
        merged.stamina == 5 and merged.armor == 19,
        "stamina " .. tostring(merged.stamina) .. ", armor " .. tostring(merged.armor))
    check(report, "a stat this build does not model is reported, never dropped",
        unmapped.ITEM_MOD_NOT_IN_THE_ALIASES == 1)

    local sources = LT.ItemStats:DescribeSources()
    check(report, "the client's stat routes can be named",
        type(sources) == "string" and sources ~= "", sources)

    -- The shape a client with no stat API leaves us, copied from the reward belt
    -- as the client drew it: the numbers are in the item's own tooltip text.
    local tooltipStats, tooltipUnmapped = {}, {}
    local tooltipRead = LT.ItemStats.ParseTooltipLines({
        { leftText = "Nomadic Belt" },
        { leftText = "Binds when picked up" },
        { leftText = "Waist" },
        { leftText = "Leather" },
        { leftText = "19 Armor" },
        { leftText = "+5 Stamina" },
        { leftText = "+1% Critical Strike" },
        { leftText = "12 - 19 Damage" },
        { leftText = "Durability 35 / 35" },
        { leftText = "Sell Price: 1 23" },
    }, tooltipStats, tooltipUnmapped)

    check(report, "tooltip text gives the stats the client will not hand over",
        tooltipRead == 2 and tooltipStats.armor == 19 and tooltipStats.stamina == 5,
        tostring(tooltipRead) .. " read, armor " .. tostring(tooltipStats.armor)
        .. ", stamina " .. tostring(tooltipStats.stamina))

    check(report, "a tooltip percentage is reported, never folded into a rating",
        tooltipUnmapped["tooltip: +1% Critical Strike"] == true)

    -- Damage, durability, the name, the type and the price all carry numbers or
    -- words; only the one unrecognised stat line may be reported, or every item
    -- in the game would carry a warning.
    local unknownCount = 0
    for _ in pairs(tooltipUnmapped) do unknownCount = unknownCount + 1 end
    check(report, "only the unrecognised stat line is reported",
        unknownCount == 1, tostring(unknownCount) .. " reported")

    -- The tooltip falls back to the button under the pointer when a pane fills a
    -- tooltip without handing it a link, so the shapes a reward button can have
    -- are checked here: a link it carries itself, an item ID only, and nothing.
    if LT.QuestRewards and type(LT.QuestRewards.LinkFromButton) == "function" then
        local carried = "|cff9d9d9d|Hitem:7109::::::::1:::::|h[Nomadic Belt]|h|r"

        check(report, "a reward button's own link is read back",
            LT.QuestRewards.LinkFromButton({ link = carried }) == carried)

        check(report, "a reward button with only an item ID still answers",
            LT.QuestRewards.LinkFromButton({ itemID = 7109 }) == "item:7109")

        check(report, "a button with nothing readable answers nothing",
            LT.QuestRewards.LinkFromButton({}) == nil)
    end

    local link = LT.GearSets:GetEquippedLink(16)
    local stats = nil

    if link then
        stats = LT.ItemStats:Get(link, { noCache = true })
    end

    if not link or not stats then
        table.insert(report.lines,
            LT.Palette:Wrap("caution", "SKIP") .. " item reading — nothing readable is equipped in the main hand")
        return
    end

    check(report, "an equipped weapon yields canonical stat channels",
        type(stats) == "table" and next(stats) ~= nil)

    local identity = LT.ItemStats:GetIdentity(link)
    check(report, "item identity includes an equip location",
        identity ~= nil and identity.equipLoc ~= nil, identity and tostring(identity.equipLoc))

    local score = LT.Score:ScoreItem(link, LT.Builds:GetActiveIndex(), { noCache = true })
    check(report, "an equipped item can be scored for the active build",
        score.ok == true or #(score.limitations or {}) > 0)
end

local function testImportExport(report)
    withSyntheticCharacter(function()
        local key = LT.Profiles:Create("SelfTest export", "shaman_enhancement_2h_pvp")
        LT.Profiles:SetWeight(key, "stamina", 1.5)
        LT.Profiles:SetCap(key, "hit", "enabled", true)
        LT.Profiles:SetCap(key, "hit", "target", 9)

        local text = LT.Profiles:Serialize(key)
        check(report, "a custom profile serialises to one line",
            type(text) == "string" and text:sub(1, 5) == "LBT1;",
            text and tostring(#text) .. " characters")

        check(report, "serialising is deterministic",
            LT.Profiles:Serialize(key) == text)

        local data, parseError = LT.Profiles:Parse(text)
        check(report, "an exported string parses back", data ~= nil, parseError)

        if data then
            check(report, "weights survive the round trip",
                closeTo(data.weights.stamina, 1.5, 0.0001),
                tostring(data.weights.stamina))

            check(report, "metadata survives the round trip",
                data.class == "SHAMAN" and data.context == "PVP"
                    and data.spec == "Enhancement",
                tostring(data.class) .. " / " .. tostring(data.spec)
                    .. " / " .. tostring(data.context))

            check(report, "caps survive the round trip",
                data.caps.hit ~= nil and data.caps.hit.enabled == true
                    and closeTo(data.caps.hit.target, 9, 0.0001),
                data.caps.hit and tostring(data.caps.hit.target))

            check(report, "the round trip reports no unknown stats",
                #data.unknownStats == 0, table.concat(data.unknownStats, ", "))
        end

        local importedKey = LT.Profiles:Import(text)
        check(report, "importing creates a custom profile", importedKey ~= nil)

        if importedKey then
            local imported = LT.Profiles:Get(importedKey)
            check(report, "the imported profile is editable and unlocked",
                imported ~= nil and imported.kind == "custom"
                    and imported.editable == true)

            check(report, "the imported profile does not replace the source",
                LT.Profiles:Get(key) ~= nil and importedKey ~= key)

            local secondKey = LT.Profiles:Import(text)
            check(report, "importing twice does not overwrite the first copy",
                secondKey ~= nil and secondKey ~= importedKey
                    and LT.Profiles:Get(importedKey) ~= nil)
        end

        local bad, badReason = LT.Profiles:Parse("SOMETHINGELSE;weights=hit:1")
        check(report, "a wrong format version is refused, not guessed at",
            bad == nil and type(badReason) == "string")

        local escaped = LT.Profiles:Parse("LBT1;name=Odd%3Bname;weights=hit:1")
        check(report, "escaped separators in a value are restored",
            escaped ~= nil and escaped.name == "Odd;name",
            escaped and tostring(escaped.name))
    end)
end

-- Runs `fn` with one slot's own scoring switch cleared, so the Settings option
-- decides for that slot, and puts the slot's recorded value back even if a
-- check inside `fn` fails or the body raises.
local function withInheritedScoreImbue(buildIndex, fn)
    local previous = LT.Builds:GetScoreImbue(buildIndex)
    LT.Builds:SetScoreImbue(buildIndex, nil)

    local ok, err = pcall(fn)
    LT.Builds:SetScoreImbue(buildIndex, previous)

    return ok, err
end

local function testImbues(report)
    withSyntheticCharacter(function()
        local key = LT.Profiles:Create("SelfTest imbue", "shaman_enhancement_2h_pvp")
        LT.Builds:SetProfile(1, key)
        LT.Builds:SetWeaponSetup(1, "2H")
        LT.Builds:SetImbue(1, "windfury")

        local options = LT.Database:GetOptions()
        local previousFlag = options.shamanImbueScoring
        local previousClass = LT.player.class

        local stats = { weaponDPS = 50, weaponAvgDamage = 100, weaponSpeed = 3.4, strength = 10 }

        -- A slot's own switch wins over the Settings option, so the option
        -- checks below run with the slot's switch cleared: they test the
        -- fallback path, and the slot's value is put back afterwards.
        local fallbackOk, fallbackErr = withInheritedScoreImbue(1, function()
            LT.player.class = "SHAMAN"
            options.shamanImbueScoring = false

            local untouched = LT.Imbues:AdjustStats(stats, 1)
            check(report, "with the option off the weapon stats are untouched",
                untouched.weaponDPS == 50 and untouched.weaponAvgDamage == 100)

            options.shamanImbueScoring = true

            local adjusted, notes = LT.Imbues:AdjustStats(stats, 1)
            check(report, "with the option on weapon DPS is valued through the imbue",
                adjusted.weaponDPS > 50 and adjusted.weaponAvgDamage > 100,
                tostring(adjusted.weaponDPS) .. " / " .. tostring(adjusted.weaponAvgDamage))

            check(report, "non-weapon stats are never changed by the imbue layer",
                adjusted.strength == 10)

            check(report, "the adjustment is explained, not silent",
                type(notes) == "table" and #notes > 0)

            check(report, "the stored item stats are not modified",
                stats.weaponDPS == 50 and stats.weaponAvgDamage == 100)

            -- A player who is not a Shaman must never get the layer.
            LT.player.class = "WARRIOR"
            local blocked = LT.Imbues:AdjustStats(stats, 1)
            check(report, "the imbue layer refuses a non-Shaman", blocked.weaponDPS == 50)

            LT.player.class = previousClass
            options.shamanImbueScoring = previousFlag

            -- Speed preference: Windfury should prefer the slow weapon, and the
            -- multiplier must stay inside its clamp.
            local windfury = LT.Imbues:GetDefinition("windfury")
            check(report, "windfury prefers a slower weapon",
                LT.Imbues:SpeedMultiplier(windfury, 3.5) > LT.Imbues:SpeedMultiplier(windfury, 1.8))

            local clamped = LT.Imbues:SpeedMultiplier(windfury, 99)
            check(report, "the speed rule is clamped rather than unbounded",
                clamped <= 1.5 and clamped >= 0.5, tostring(clamped))

            local flametongue = LT.Imbues:GetDefinition("flametongue")
            check(report, "flametongue prefers a faster weapon",
                LT.Imbues:SpeedMultiplier(flametongue, 1.5)
                    > LT.Imbues:SpeedMultiplier(flametongue, 3.0))

            -- "No imbue" must be a true no-op even with scoring switched on.
            LT.player.class = "SHAMAN"
            options.shamanImbueScoring = true
            LT.Builds:SetImbue(1, "none")

            local untouchedNone = LT.Imbues:AdjustStats(stats, 1)
            check(report, "no imbue means no adjustment at all",
                untouchedNone.weaponDPS == 50 and untouchedNone.weaponAvgDamage == 100,
                tostring(untouchedNone.weaponDPS) .. " / " .. tostring(untouchedNone.weaponAvgDamage))

            LT.Builds:SetImbue(1, "windfury")
            options.shamanImbueScoring = previousFlag
            LT.player.class = previousClass
        end)

        LT.player.class = previousClass
        options.shamanImbueScoring = previousFlag

        if not fallbackOk then
            error(fallbackErr, 0)
        end

        LT.player.class = "SHAMAN"

        -- A slot with no switch of its own follows the Settings option, both
        -- ways, and reports the option as the source of the decision.
        LT.Builds:SetScoreImbue(1, nil)
        options.shamanImbueScoring = false
        local offValue, offSource = LT.Imbues:ResolveScoring(1)
        options.shamanImbueScoring = true
        local onValue, onSource = LT.Imbues:ResolveScoring(1)

        check(report, "a slot with no switch follows the global option both ways",
            LT.Builds:GetScoreImbue(1) == nil
                and offValue == false and offSource == "global"
                and onValue == true and onSource == "global",
            tostring(offValue) .. "/" .. tostring(offSource) .. ", "
                .. tostring(onValue) .. "/" .. tostring(onSource))

        -- The switch is per slot: with the option off, slot 1 still scores and
        -- slot 2 still ignores. Slot 2's imbue is live, so the difference is
        -- the switch and not an empty imbue choice.
        -- Slot 2 only exists above the level that unlocks it; below that,
        -- SetImbue(2) writes nowhere and the test measured the level, not the
        -- switch. Pin the slot count and create the slot for the duration.
        local pinSlotCount = LT.Builds.SlotCountForLevel
        local pinBuilds = LT.Database:Get().builds
        local pinSlotTwo = pinBuilds[2]
        LT.Builds.SlotCountForLevel = function() return 2 end
        LT.Builds:EnsureForClass("SHAMAN")

        options.shamanImbueScoring = false
        LT.Builds:SetImbue(2, "windfury")
        LT.Builds:SetScoreImbue(1, true)
        LT.Builds:SetScoreImbue(2, true)

        local slotTwoControl = LT.Imbues:AdjustStats(stats, 2)
        LT.Builds:SetScoreImbue(2, false)

        local slotOneScoring, slotOneSource = LT.Imbues:ResolveScoring(1)
        local slotTwoScoring, slotTwoSource = LT.Imbues:ResolveScoring(2)
        local slotOne = LT.Imbues:AdjustStats(stats, 1)
        local slotTwo = LT.Imbues:AdjustStats(stats, 2)

        check(report, "a slot pinned on scores while a slot pinned off ignores, with the option off",
            slotTwoControl.weaponDPS > 50
                and slotOneScoring == true and slotOneSource == "slot"
                and slotTwoScoring == false and slotTwoSource == "slot"
                and slotOne.weaponDPS > 50 and slotTwo.weaponDPS == 50,
            "slot 1 " .. tostring(slotOne.weaponDPS)
                .. ", slot 2 " .. tostring(slotTwo.weaponDPS))

        pinBuilds[2] = pinSlotTwo
        LT.Builds.SlotCountForLevel = pinSlotCount

        LT.Builds:SetScoreImbue(1, nil)
        LT.Builds:SetScoreImbue(2, nil)

        -- A stored value that is not a boolean is not a switch: it inherits
        -- the Settings option instead of being read as truthy. Reading it
        -- normalises the field away, so it is put back for the second half.
        local buildOne = LT.Database:Get().builds[1]
        options.shamanImbueScoring = false
        buildOne.scoreImbue = "inherit"
        local unknownOff, unknownOffSource = LT.Imbues:ResolveScoring(1)
        local unknownRead = LT.Builds:GetScoreImbue(1)

        options.shamanImbueScoring = true
        buildOne.scoreImbue = "inherit"
        local unknownOn, unknownOnSource = LT.Imbues:ResolveScoring(1)

        check(report, "an unknown score switch value is read as inherit",
            unknownRead == nil
                and unknownOff == false and unknownOffSource == "global"
                and unknownOn == true and unknownOnSource == "global",
            tostring(unknownRead) .. ", " .. tostring(unknownOff)
                .. "/" .. tostring(unknownOffSource) .. ", "
                .. tostring(unknownOn) .. "/" .. tostring(unknownOnSource))

        LT.Builds:SetScoreImbue(1, nil)

        -- A blank slot takes its starting imbue from its role: Tank starts on
        -- Rockbiter, every other role still starts on "none". No shipped class
        -- defaults to Tank, so the class definition's role is borrowed for the
        -- duration and restored immediately.
        local classDefinition = LT.ClassData:GetClass("SHAMAN")
        local previousDefaultRole = classDefinition and classDefinition.defaultRole
        local builds = LT.Database:Get().builds
        local previousSlotTwo = builds[2]

        -- Slot 2 does not exist below the level that unlocks it, so asking for a
        -- blank slot 2 on a level-4 character created nothing and the check read
        -- nil. The question is what a blank slot starts on, not how many slots
        -- this character owns, so the slot count is pinned for the test.
        local previousSlotCount = LT.Builds.SlotCountForLevel
        LT.Builds.SlotCountForLevel = function() return 2 end

        local tankCreated = pcall(function()
            if classDefinition then classDefinition.defaultRole = "Tank" end
            builds[2] = nil
            LT.Builds:EnsureForClass("SHAMAN")
        end)

        if classDefinition then classDefinition.defaultRole = previousDefaultRole end

        local tankSlot = LT.Builds:Get(2)

        local otherCreated = pcall(function()
            if classDefinition then classDefinition.defaultRole = "Healer" end
            builds[2] = nil
            LT.Builds:EnsureForClass("SHAMAN")
        end)

        if classDefinition then classDefinition.defaultRole = previousDefaultRole end

        local otherSlot = LT.Builds:Get(2)
        builds[2] = previousSlotTwo
        LT.Builds.SlotCountForLevel = previousSlotCount

        check(report, "a blank Tank slot starts on rockbiter",
            tankCreated and tankSlot ~= nil and tankSlot.role == "Tank"
                and tankSlot.imbue == "rockbiter",
            "created=" .. tostring(tankCreated) .. " slot="
                .. (tankSlot and (tostring(tankSlot.role) .. " / " .. tostring(tankSlot.imbue)) or "nil"))

        check(report, "a blank slot for any other role still starts on none",
            otherCreated and otherSlot ~= nil and otherSlot.role == "Healer"
                and otherSlot.imbue == "none",
            "created=" .. tostring(otherCreated) .. " slot="
                .. (otherSlot and (tostring(otherSlot.role) .. " / " .. tostring(otherSlot.imbue)) or "nil"))

        options.shamanImbueScoring = previousFlag
        LT.player.class = previousClass
    end)
end

local function testQuestRewardRanking(report)
    local QuestRewards = LT.QuestRewards

    check(report, "the quest reward module is loaded", QuestRewards ~= nil)
    if not QuestRewards then return end

    -- The three toggles are separate switches; all of them are on by default so
    -- a character saved before they existed keeps the old behaviour.
    local defaults = LT.Database.defaultOptions()
    check(report, "quest highlight toggles default to on",
        defaults.questRewardHighlight == true
            and defaults.questRewardRanking == true
            and defaults.questVendorFallback == true)

    local function row(name, difference, price)
        return {
            name = name,
            link = "item:" .. name,
            status = difference and "upgrade" or "sidegrade",
            difference = difference,
            sellPrice = price,
        }
    end

    -- Two upgrades: the bigger difference is purple, the next one is blue. Money
    -- is decided by price alone, so the second upgrade takes the coin as well.
    local weak, middle, strongest = row("weak", 2, 100), row("mid", 7, 250), row("top", 11, 50)
    local split = QuestRewards:Classify({ weak, middle, strongest })

    check(report, "quest ranking puts the biggest upgrade first",
        split.best == strongest and split.second == middle,
        "best " .. tostring(split.best and split.best.name) .. ", second "
            .. tostring(split.second and split.second.name))

    check(report, "the coin goes to the priciest reward, upgrade or not",
        split.vendor == middle,
        tostring(split.vendor and split.vendor.name))

    -- Gold no longer waits for "nothing is an upgrade": the most profitable reward
    -- that earned no verdict border is marked even when something else is purple,
    -- because "wear this" and "take this to sell" are two different answers.
    local wearable, valuable = row("wearable", 8, 10), row("valuable", nil, 4000)
    local mixed = QuestRewards:Classify({ wearable, valuable })

    check(report, "gold is ranked alongside a purple upgrade",
        mixed.best == wearable and mixed.vendor == valuable,
        "vendor " .. tostring(mixed.vendor and mixed.vendor.name))

    -- ... and an upgrade with the highest price is the coin pick: the coin is a
    -- marker on top of its border, not a second colour competing with it.
    local richUpgrade, plain = row("rich-upgrade", 3, 90000), row("plain", nil, 100)
    local rich = QuestRewards:Classify({ richUpgrade, plain })

    check(report, "an upgrade can also be the most profitable reward",
        rich.best == richUpgrade and rich.vendor == richUpgrade,
        "vendor " .. tostring(rich.vendor and rich.vendor.name))

    -- One upgrade: purple with no second place. The 90g sidegrade beside it still
    -- takes the gold border, which is what deciding the two ranks independently buys.
    local onlyUpgrade = row("solo", 4, 10)
    local flat = row("flat", nil, 90000)
    local single = QuestRewards:Classify({ flat, onlyUpgrade })

    check(report, "a single upgrade is ranked with no second place",
        single.best == onlyUpgrade and single.second == nil,
        "second " .. tostring(single.second and single.second.name))

    check(report, "the profitable sidegrade is still marked gold",
        single.vendor == flat, tostring(single.vendor and single.vendor.name))

    -- No upgrade at all: the coin goes to the highest vendor value, and a reward
    -- with no known price is never mistaken for a cheap one.
    local cheap, pricey, unpriced = row("cheap", nil, 100), row("pricey", nil, 5000), row("unpriced", nil, nil)
    local vendor = QuestRewards:Classify({ cheap, unpriced, pricey })

    check(report, "with no upgrade the most profitable reward is gold",
        vendor.best == nil and vendor.vendor == pricey,
        "vendor " .. tostring(vendor.vendor and vendor.vendor.name))

    check(report, "an unpriced reward is never the vendor fallback",
        vendor.vendor ~= unpriced)

    -- Equal prices keep the first reward seen, so the coin cannot flicker between
    -- two equally rich rewards.
    local richA, richB = row("rich-a", nil, 900), row("rich-b", nil, 900)
    local moneyTie = QuestRewards:Classify({ richA, richB })

    check(report, "a vendor tie keeps one stable winner",
        moneyTie.vendor == richA,
        tostring(moneyTie.vendor and moneyTie.vendor.name))

    -- A reward that could not be evaluated must not out-rank a real upgrade,
    -- even when its number happens to be larger -- but it can still be the money
    -- pick, because its price does not depend on the build wanting it.
    local ineligible = {
        name = "ineligible",
        link = "item:ineligible",
        status = "ineligible",
        difference = 500,
        sellPrice = 500,
    }
    local guarded = QuestRewards:Classify({ ineligible, onlyUpgrade })

    check(report, "an unevaluable reward never out-ranks a real upgrade",
        guarded.best == onlyUpgrade)

    check(report, "an unevaluable reward can still be the money pick",
        guarded.vendor == ineligible,
        tostring(guarded.vendor and guarded.vendor.name))

    -- An empty list is a normal state (a quest that offers no items).
    local empty = QuestRewards:Classify({})
    check(report, "an empty reward list is handled",
        empty.best == nil and empty.second == nil and empty.vendor == nil)

    -- Ties keep a stable winner rather than producing two top borders.
    local tieA, tieB = row("tie-a", 5, 10), row("tie-b", 5, 20)
    local tied = QuestRewards:Classify({ tieA, tieB })
    check(report, "tied upgrades produce one purple and one blue",
        tied.best ~= nil and tied.second ~= nil and tied.best ~= tied.second)

    -- A reward the character cannot use yet is green, not second best: it is kept
    -- out of the purple/blue race, so the usable upgrade stays the purple one and
    -- the deferred upgrade gets a colour of its own (player's request, 2026-10-27).
    local usableUpgrade = row("usable", 6, 100)
    local laterUpgrade = row("later", 40, 100)
    laterUpgrade.deferred = true

    local deferredSplit = QuestRewards:Classify({ laterUpgrade, usableUpgrade })

    check(report, "a reward usable later is kept out of the purple/blue ranking",
        deferredSplit.best == usableUpgrade and deferredSplit.second == nil,
        "best " .. tostring(deferredSplit.best and deferredSplit.best.name))

    check(report, "a bigger upgrade usable later is listed as green",
        #deferredSplit.deferred == 1 and deferredSplit.deferred[1] == laterUpgrade,
        tostring(#deferredSplit.deferred) .. " green row(s)")

    -- Green is a verdict, not a rank, so the priciest reward can be green and still
    -- carry the coin: "not yet" and "worth the most to a vendor" on one icon.
    local richLater = row("rich-later", 9, 5000)
    richLater.deferred = true
    local coinOnGreen = QuestRewards:Classify({ richLater, usableUpgrade })

    check(report, "a green reward can still be the money pick",
        coinOnGreen.best == usableUpgrade and coinOnGreen.vendor == richLater,
        "vendor " .. tostring(coinOnGreen.vendor and coinOnGreen.vendor.name))

    -- Two deferred upgrades share one colour, so both are listed and neither takes
    -- a purple or blue border.
    local deferredA, deferredB = row("deferred-a", 3, 10), row("deferred-b", 30, 10)
    deferredA.deferred, deferredB.deferred = true, true
    local bothDeferred = QuestRewards:Classify({ deferredA, deferredB })

    check(report, "only deferred upgrades leave the ranking empty and list both",
        bothDeferred.best == nil and bothDeferred.second == nil
            and #bothDeferred.deferred == 2,
        tostring(#bothDeferred.deferred) .. " green row(s)")

    -- An empty list carries no green rows either, so Refresh draws nothing.
    check(report, "an empty reward list has no green rows", #empty.deferred == 0)
end

-- The colour is drawn around the item's icon, not the whole reward button. The
-- buttons are synthetic tables here -- the anchor question is pure enough to answer
-- without a frame -- so the check runs the same code the highlight runs.
local function testQuestRewardOutline(report)
    local QuestRewards = LT.QuestRewards

    check(report, "the quest reward module exposes its anchor rule",
        QuestRewards ~= nil and type(QuestRewards.OutlineAnchor) == "function")

    if not QuestRewards or type(QuestRewards.OutlineAnchor) ~= "function" then
        return end

    local function fakeRegion(width, height, anchored)
        return {
            GetPoint = function() return anchored and "TOPLEFT" or nil end,
            GetWidth = function() return width end,
            GetHeight = function() return height end,
            GetObjectType = function() return "Texture" end,
        }
    end

    local function fakeButton(width, height, fields)
        local button = {
            GetWidth = function() return width end,
            GetHeight = function() return height end,
            GetName = function() return nil end,
        }

        for key, value in pairs(fields or {}) do
            button[key] = value
        end

        return button
    end

    -- A named icon field wins: that is the region the border should hug.
    local icon = fakeRegion(36, 36, true)
    local named = fakeButton(244, 36, { Icon = icon })

    check(report, "the border anchors to a named icon field",
        QuestRewards.OutlineAnchor(named) == icon)

    -- A square texture the button owns is the next best answer, so a client that
    -- names its icon differently is still handled.
    local owned = fakeRegion(36, 36, true)
    local unnamed = fakeButton(244, 36, {
        GetRegions = function() return owned end,
    })

    check(report, "the border finds an unnamed square texture",
        QuestRewards.OutlineAnchor(unnamed) == owned)

    -- The button's own backdrop is not an icon: anchoring to it would draw the old
    -- wide border again, so a full-size texture is refused.
    local backdrop = fakeRegion(244, 36, true)
    local onlyBackdrop = fakeButton(244, 36, {
        GetRegions = function() return backdrop end,
    })

    check(report, "a full-size texture is not mistaken for an icon",
        QuestRewards.OutlineAnchor(onlyBackdrop) == onlyBackdrop)

    -- An unanchored texture has no rectangle to hug yet, so the button fallback is
    -- used and the next refresh re-asks once the client has laid it out.
    local unlaid = fakeRegion(36, 36, false)
    local pending = fakeButton(244, 36, { Icon = unlaid })

    check(report, "an unanchored icon falls back to the button",
        QuestRewards.OutlineAnchor(pending) == pending)

    -- A button with nothing recognisable keeps the old behaviour rather than
    -- losing its border.
    local bare = fakeButton(244, 36)
    check(report, "a button with no icon still anchors to itself",
        QuestRewards.OutlineAnchor(bare) == bare)

    -- A non-tabular button is answered with nil instead of an error.
    check(report, "a non-frame button is answered with nil",
        QuestRewards.OutlineAnchor(nil) == nil
            and QuestRewards.OutlineAnchor("not a button") == nil)

    -- The reward's position, as the client states it and as the button's name
    -- implies it. /lt quest prints this when a reward cannot be read, so a wrong
    -- answer here would send the player looking at the wrong reward.
    check(report, "the quest reward module exposes its position rule",
        type(QuestRewards.ItemPosition) == "function")

    if type(QuestRewards.ItemPosition) == "function" then
        local kind, index = QuestRewards.ItemPosition({ type = "choice", index = 4 })
        check(report, "an explicit type and index are used as given",
            kind == "choice" and index == 4)

        local _, namedIndex = QuestRewards.ItemPosition({
            GetName = function() return "QuestInfoRewardsFrameReward2" end,
        })
        check(report, "a button that only has a name still gives its position",
            namedIndex == 2)

        local _, idIndex = QuestRewards.ItemPosition({
            GetID = function() return 3 end,
        })
        check(report, "a button that only has an id still gives an index",
            idIndex == 3)

        local _, unknown = QuestRewards.ItemPosition({
            GetName = function() return "SomeFrame" end,
        })
        check(report, "a button with no position at all is answered with nil",
            unknown == nil)
    end

    -- /lt quest builds this line from the client's own answers, so it must say
    -- something for a button that answers nothing rather than throwing.
    if type(QuestRewards.ExplainButton) == "function" then
        local ok, text = pcall(QuestRewards.ExplainButton, QuestRewards, {
            GetName = function() return "QuestInfoRewardsFrameReward1" end,
        })
        check(report, "an unreadable button is explained in words",
            ok and type(text) == "string" and text ~= "")
    else
        check(report, "the quest reward module explains an unreadable button", false)
    end
end


-----------------------------------------------------------------------------
-- Runner
------------------------------------------------------------------------------

local function testPrivateProfiles(report)
    local PrivateProfiles = LT.PrivateProfiles

    check(report, "the private profile registry is loaded", PrivateProfiles ~= nil)
    if not PrivateProfiles then return end

    -- A token no real pack uses, so the assertions cannot be broken by a local
    -- addon that registers real profiles for a real class.
    local classToken = "SELFTEST"
    local key = "selftest.private.profile"
    local previous = PrivateProfiles:IsUnlocked()

    PrivateProfiles:SetUnlocked(false)

    local entry = PrivateProfiles:Register(classToken, {
        key = key,
        name = "Self test private profile",
        spec = "Any",
        role = "Damage",
        context = "PVE",
        weights = { strength = 1.00 },
    })

    check(report, "a private profile can be registered", entry ~= nil)
    check(report, "a private profile is not a bundled profile",
        LT.ClassData:GetBaseProfile(key) == nil)

    check(report, "a locked private profile is not offered",
        #PrivateProfiles:Get(classToken) == 0)
    check(report, "a locked private profile cannot be assigned",
        LT.Profiles:Assignable(key) == false)
    check(report, "a locked private profile still resolves for an existing slot",
        PrivateProfiles:Resolve(key) ~= nil and LT.Profiles:Get(key) ~= nil)

    PrivateProfiles:SetUnlocked(true)

    check(report, "an unlocked private profile is offered for its class",
        #PrivateProfiles:Get(classToken) == 1)

    local offeredElsewhere = false
    for _, row in ipairs(PrivateProfiles:Get("WARRIOR")) do
        if row.key == key then offeredElsewhere = true end
    end

    check(report, "an unlocked private profile is not offered for another class",
        offeredElsewhere == false)
    check(report, "an unlocked private profile can be assigned",
        LT.Profiles:Assignable(key) == true)

    -- A stat this build does not model would silently score nothing.
    PrivateProfiles:Resolve(key).weights.notAStat = 1
    local flagged = false
    for _, problem in ipairs(PrivateProfiles:Validate()) do
        if problem:find("notAStat", 1, true) then flagged = true end
    end

    check(report, "an unknown stat in a private profile is reported", flagged)

    check(report, "a private profile cannot shadow a bundled key",
        PrivateProfiles:Register(classToken, {
            key = (LT.ClassData:GetBaseProfiles()[1] or {}).key or "blank",
            name = "Shadow",
        }) == nil)

    PrivateProfiles:Forget(key)
    PrivateProfiles:SetUnlocked(previous)

    check(report, "forgetting a private profile removes it",
        PrivateProfiles:Resolve(key) == nil)
end

-- The shipped core must not carry a page for a local addon, and the reset hook
-- must exist. ResetCharacter is deliberately not executed here: it writes into
-- the real character store, and a self test must never edit saved data.
local function testDevPagePlumbing(report)
    local UI = LT.UI

    check(report, "the UI exposes a page list", type(UI.pages) == "table")

    -- The bundled pages in UI.lua's order. Best setup joined after this check was
    -- written, then Caps and Commands left the rail for popups and Actions took
    -- their place; a stale copy of this list is what makes the "extra page" check
    -- fail on an otherwise normal install.
    local expected = {
        "builds", "profiles", "gear", "setup", "plugins", "settings", "debug",
        "actions", "ranks",
    }

    -- A local addon may append pages through UI:AddPage (the dev install's
    -- Personal addon contributes "Dev"), so the bundled pages are checked as the
    -- leading entries rather than as the whole list.
    local pageCount = type(UI.pages) == "table" and #UI.pages or 0
    local orderMatches = pageCount >= #expected

    if orderMatches then
        for index, key in ipairs(expected) do
            local page = UI.pages[index]
            if not page or page.key ~= key or page.external then
                orderMatches = false
            end
        end
    end

    check(report, "the bundled pages lead the tab list, in order", orderMatches,
        tostring(pageCount) .. " page(s)")

    -- Anything past the bundled list must have come through UI:AddPage: it is the
    -- only appender, and it marks the entry external and requires a string key.
    -- Nothing here can prove *which* addon asked, so the check asserts the one
    -- contract the registry itself carries. An entry appended straight into
    -- UI.pages would put a tab in the window that nothing can draw.
    local stray = nil
    for index = #expected + 1, pageCount do
        local page = UI.pages[index]
        if not page or page.external ~= true or type(page.key) ~= "string" then
            stray = "entry " .. tostring(index)
                .. " (" .. tostring(page and page.key) .. ")"
            break
        end
    end

    check(report, "every extra page is external with a string key", stray == nil, stray)

    -- The probes below are refusals, so the list must come out unchanged however
    -- many contributed pages this install carries.
    local pagesBefore = pageCount

    check(report, "a bundled page key cannot be replaced",
        UI:AddPage("builds", "Shadow", function() end) == false)
    check(report, "a page without a draw function is refused",
        UI:AddPage("selftest_probe", "Probe") == false)
    check(report, "a page with a non-string key is refused",
        UI:AddPage(42, "Probe", function() end) == false)
    check(report, "a refused page leaves the page list unchanged", #UI.pages == pagesBefore,
        tostring(#UI.pages) .. " page(s)")

    check(report, "a contributed page has the widget helpers it needs",
        type(UI.AddPage) == "function" and type(UI.MakeButton) == "function"
        and type(UI.MakeLabel) == "function" and type(UI.IsShown) == "function")

    check(report, "the reset entry point exists",
        type(LT.Database.ResetCharacter) == "function")

    local fresh = LT.Database.defaultCharacter()
    check(report, "a fresh character record has no slots and no custom profiles",
        type(fresh) == "table" and next(fresh.builds or {}) == nil
        and next(fresh.customProfiles or {}) == nil)
    check(report, "a fresh character record carries the current schema",
        type(fresh) == "table" and fresh.schema == LT.Database.SCHEMA)
end

-- Class packs (Decision 7): the data every class file registers, checked
-- against ClassData and against the refusals Register is supposed to make.
local function testClassPacks(report)
    local packs = LT.ClassPacks

    check(report, "class pack registry is loaded",
        packs ~= nil and type(packs.Register) == "function")

    if not packs then return end

    -- Only real load-time refusals may be in this list. The probes below add
    -- their own entries on purpose and remove them again, so a second /lt test
    -- run sees the same clean list as the first.
    local problemsBefore = #packs:GetProblems()
    check(report, "no class pack was refused while loading",
        problemsBefore == 0, table.concat(packs:GetProblems(), "; "))

    -- Every role a pack maps a spec to must be a role that class really has.
    local strays = {}
    for _, classToken in ipairs(packs:GetOrder()) do
        local definition = LT.ClassData:GetClass(classToken) or {}
        local specRoles = packs:GetSpecRoles(classToken) or {}
        for spec, roles in pairs(specRoles) do
            for _, mapped in ipairs(roles) do
                local known = false
                for _, role in ipairs(definition.roles or {}) do
                    if role == mapped then known = true end
                end
                if not known then
                    table.insert(strays, classToken .. "/" .. tostring(spec) .. "->" .. tostring(mapped))
                end
            end
        end
    end
    check(report, "every mapped spec role is one the class has",
        #strays == 0, table.concat(strays, ", "))

    -- A spec with no role would sit in the wizard's spec step as a dead entry.
    local uncovered = {}
    local shaman = LT.ClassData:GetClass("SHAMAN") or {}
    for _, spec in ipairs(shaman.specs or {}) do
        if not packs:GetRolesForSpec("SHAMAN", spec) then
            table.insert(uncovered, spec)
        end
    end
    check(report, "the Shaman pack covers every Shaman spec",
        #uncovered == 0, table.concat(uncovered, ", "))

    local enhancement = packs:GetRolesForSpec("SHAMAN", "Enhancement")
    local hasDamage, hasTank = false, false
    for _, role in ipairs(enhancement or {}) do
        if role == "Damage" then hasDamage = true end
        if role == "Tank" then hasTank = true end
    end
    check(report, "the Shaman pack maps Enhancement to Damage and Tank",
        hasDamage and hasTank,
        enhancement and table.concat(enhancement, "/") or "no pack")

    -- Every class the addon ships should answer "can I use this?" from its own
    -- file instead of falling back to unknown.
    local missing = {}
    for _, classToken in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
        "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
        if not packs:Get(classToken) then
            table.insert(missing, classToken)
        end
    end
    check(report, "every class the addon ships has a pack",
        #missing == 0, table.concat(missing, ", "))

    -- Refusals. Validate runs exactly the checks Register runs without touching
    -- the registry, so a probe leaves nothing behind for the next run; the two
    -- Register probes below can only be refused before validation even starts.
    local countBefore = #packs:GetOrder()

    check(report, "a second pack for the same class is refused",
        packs:Register("SHAMAN", { specRoles = {} }) == false)
    check(report, "a pack for an unknown class is refused",
        packs:Register("NOT_A_CLASS", {}) == false)
    check(report, "a pack naming an unknown role is refused",
        packs:Validate("WARRIOR", { specRoles = { Arms = "Wizard" } }) == false)
    check(report, "a pack naming an unknown spec is refused",
        packs:Validate("WARRIOR", { specRoles = { Wizardry = "Damage" } }) == false)
    check(report, "a template may not name a profile key",
        packs:Validate("MAGE", { templates = { { name = "Probe", profileKey = "blank" } } }) == false)
    check(report, "a pack with an unknown armour type is refused",
        packs:Validate("DRUID", { usable = { armour = { Male = { never = true } } } }) == false)
    check(report, "a pack with a contradictory usable rule is refused",
        packs:Validate("DRUID", { usable = { armour = { Mail = { never = true, fromLevel = 40 } } } }) == false)
    check(report, "a refused pack leaves the registry unchanged",
        #packs:GetOrder() == countBefore,
        tostring(#packs:GetOrder()) .. " pack(s)")
    check(report, "validation records no problem of its own",
        #packs:GetProblems() == problemsBefore, table.concat(packs:GetProblems(), "; "))

    -- Buff registration and the class-data audit. The audit is read-only by
    -- contract: it reports what PLAYER_LOGIN registered and never registers
    -- anything itself, so it can run at any moment and still tell the truth.
    local classData = LT.ClassData
    if type(classData) == "table" and type(classData.IsLearnedBookType) == "function" then
        check(report, "a learned spellbook slot is accepted",
            classData:IsLearnedBookType("SPELL") == true)
        check(report, "a grey future spellbook slot is refused",
            classData:IsLearnedBookType("FUTURESPELL") == false)
        check(report, "the numeric future type is refused",
            classData:IsLearnedBookType(2) == false)
    end
    if type(classData) == "table" and type(classData.AuditClassData) == "function" then
        -- No shipped buff id may collide across classes. The registration key
        -- carries the class precisely so a collision is reported, not hidden.
        local duplicateLines = {}
        for _, finding in ipairs(classData:FindBuffIdDuplicates()) do
            table.insert(duplicateLines, tostring(finding.id) .. " ("
                .. tostring(finding.first) .. "/" .. tostring(finding.second) .. ")")
        end
        check(report, "no buff id is declared by two classes",
            #duplicateLines == 0, table.concat(duplicateLines, ", "))

        -- The detector must actually catch the case: one id under two class
        -- tokens is exactly the definition that used to be dropped.
        local probe = classData:FindBuffIdDuplicates({
            { classToken = "SHAMAN", entry = { id = "audit_probe_buff" } },
            { classToken = "MAGE",   entry = { id = "audit_probe_buff" } },
        })
        check(report, "a cross-class duplicate id is detected",
            #probe == 1 and probe[1].first == "SHAMAN" and probe[1].second == "MAGE",
            tostring(#probe) .. " finding(s)")

        local monitor = LT.BuffMonitor
        if type(monitor) == "table" and type(monitor.GetRegistry) == "function" then
            local calls = 0
            local stub = {
                GetRegistry = function() return {} end,
                Register = function() calls = calls + 1 ; return false end,
            }
            local keysBefore = {}
            local keyCountBefore = 0
            for key in pairs(classData.buffRegistration or {}) do
                keysBefore[key] = true
                keyCountBefore = keyCountBefore + 1
            end
            local ranBefore = classData.buffRegistrationRan

            LT.BuffMonitor = stub
            local ok, audit = pcall(classData.AuditClassData, classData)
            LT.BuffMonitor = monitor

            local sameKeys = true
            local keyCountAfter = 0
            for key in pairs(classData.buffRegistration or {}) do
                keyCountAfter = keyCountAfter + 1
                if not keysBefore[key] then sameKeys = false end
            end
            sameKeys = sameKeys and keyCountAfter == keyCountBefore

            local missing = 0
            for _, line in ipairs(type(audit) == "table" and audit or {}) do
                if tostring(line):find("registered 0 time", 1, true) then
                    missing = missing + 1
                end
            end

            check(report, "a fresh registry is reported as unregistered, not filled in",
                ok and missing > 0, tostring(missing) .. " buff(s) reported missing")
            check(report, "the audit registers nothing", calls == 0,
                tostring(calls) .. " Register call(s)")
            check(report, "the audit leaves the registration record untouched",
                sameKeys and classData.buffRegistrationRan == ranBefore)

            -- Keying: "CLASSTOKEN|id" for every entry, so a reuse of an id by
            -- another class no longer blocks this one. Only meaningful once the
            -- login pass has run; a run before that proves nothing.
            if ranBefore then
                local unkeyed = 0
                for key in pairs(classData.buffRegistration or {}) do
                    if not tostring(key):find("|", 1, true) then unkeyed = unkeyed + 1 end
                end
                check(report, "every registered buff is keyed by class and id",
                    unkeyed == 0, tostring(unkeyed) .. " key(s) without a class prefix")

                local function registrySize()
                    local total = 0
                    for _, definitions in pairs(monitor:GetRegistry()) do
                        total = total + #definitions
                    end
                    return total
                end

                local sizeBefore = registrySize()
                local again = classData:RegisterBuffDefs()
                check(report, "buff registration is idempotent",
                    again == 0 and registrySize() == sizeBefore,
                    tostring(again) .. " registered, "
                        .. tostring(registrySize()) .. " definition(s)")
            end
        end
    end
end

-- Item usability: the verdicts the tooltip acts on. Pure calls, no character and
-- no saved data involved, so nothing here can touch the player's records.
-- Bind state: whether a gear-check row may be equipped from our window. The bug
-- this guards (2026-11-05) read a bound item as unbound and refused to wear it.
-- Pure: the classifier takes a line reader, so no client item is needed.
local function testBindState(report)
    local popup = LT.GearPopup

    check(report, "the bind classifier is available",
        type(popup) == "table" and type(popup.BindFromLines) == "function")
    if type(popup) ~= "table" or type(popup.BindFromLines) ~= "function" then return end

    local function from(lines)
        return popup.BindFromLines(function(index) return lines[index] end)
    end

    check(report, "a worn item that says Soulbound reads as bound",
        from({ "Cracked Egg Shells", "Binds when equipped", "Soulbound" }) == true)

    check(report, "Binds when equipped alone reads as not bound",
        from({ "Worn Leather Belt", "Binds when equipped" }) == false)

    check(report, "Binds when picked up reads as not bound",
        from({ "Some Trinket", "Binds when picked up" }) == false)

    check(report, "a tooltip with no bind line answers nothing",
        from({ "Cracked Egg Shells", "5 Armor" }) == nil)

    check(report, "Soulbound outranks a Binds line in either order",
        from({ "Soulbound", "Binds when equipped" }) == true)
end

local function testItemUsability(report)
    local usability = LT.Usability

    check(report, "usability module is loaded",
        usability ~= nil and type(usability.Classify) == "function")

    if not usability then return end

    local PLATE, MAIL, LEATHER, SHIELD = 4, 3, 2, 6
    local SWORD1H, STAFF = 7, 10
    local MACE1H, DAGGER, WAND = 4, 15, 19
    local BOW, THROWN = 2, 16
    local ARMOUR, WEAPON = usability.ITEM_CLASS_ARMOUR, usability.ITEM_CLASS_WEAPON

    local function classify(classID, subClassID, level, requiredLevel)
        return usability:Classify({
            classID = classID,
            subClassID = subClassID,
            requiredLevel = requiredLevel,
        }, "SHAMAN", level)
    end

    local function verdictOf(classID, subClassID, level, requiredLevel)
        return classify(classID, subClassID, level, requiredLevel).verdict
    end

    local plateAt30 = verdictOf(ARMOUR, PLATE, 30)
    check(report, "a Shaman can never wear plate",
        plateAt30 == usability.NEVER, tostring(plateAt30))

    local swordAt60 = verdictOf(WEAPON, SWORD1H, 60)
    check(report, "a Shaman can never use a sword",
        swordAt60 == usability.NEVER, tostring(swordAt60))

    local mailAt30 = verdictOf(ARMOUR, MAIL, 30)
    check(report, "mail is deferred below level 40",
        mailAt30 == usability.DEFERRED, tostring(mailAt30))

    local mailAt40 = verdictOf(ARMOUR, MAIL, 40)
    check(report, "mail is usable once the level is reached",
        mailAt40 == usability.USABLE, tostring(mailAt40))

    -- The shaman pack lists staves, so the class can use one: the verdict follows
    -- the pack. Whether this character has trained it is a separate question the
    -- client answers, and a false answer narrows it to "not trained yet".
    local staffAt30 = verdictOf(WEAPON, STAFF, 30)
    check(report, "a learnable weapon is usable because the pack lists it",
        staffAt30 == usability.USABLE, tostring(staffAt30))

    -- Leather is listed for a shaman, so it is usable; the pack is the claim.
    local leatherAt30 = verdictOf(ARMOUR, LEATHER, 30)
    check(report, "a listed armour type is usable",
        leatherAt30 == usability.USABLE, tostring(leatherAt30))

    check(report, "a class with no pack stays unknown",
        usability:Classify({ classID = ARMOUR, subClassID = PLATE }, "NOT_A_CLASS", 60).verdict
            == usability.UNKNOWN)

    local mailTooHigh = verdictOf(ARMOUR, MAIL, 30, 45)
    check(report, "an item level requirement defers the item",
        mailTooHigh == usability.DEFERRED, tostring(mailTooHigh))

    local plateTooHigh = verdictOf(ARMOUR, PLATE, 30, 45)
    check(report, "never outranks an item level requirement",
        plateTooHigh == usability.NEVER, tostring(plateTooHigh))

    -- The data the player supplied for the other classes, spot-checked in both
    -- directions: a never-list entry must be refused and an omitted type must
    -- not be, or a learnable weapon would silently lose its score.
    local function verdictFor(classToken, classID, subClassID, level)
        return usability:Classify({
            classID = classID,
            subClassID = subClassID,
        }, classToken, level).verdict
    end

    local warriorPlate30 = verdictFor("WARRIOR", ARMOUR, PLATE, 30)
    check(report, "a Warrior is deferred out of plate before 40",
        warriorPlate30 == usability.DEFERRED, tostring(warriorPlate30))

    local warriorPlate40 = verdictFor("WARRIOR", ARMOUR, PLATE, 40)
    check(report, "a Warrior can wear plate from level 40",
        warriorPlate40 == usability.USABLE, tostring(warriorPlate40))

    local warriorStaff = verdictFor("WARRIOR", WEAPON, STAFF, 60)
    check(report, "a type the pack omits stays unknown",
        warriorStaff == usability.UNKNOWN, tostring(warriorStaff))

    -- The ranged and off-hand slot table the player supplied the same day, in
    -- both directions: a refusal where the table names other classes, and no
    -- refusal where the type is this class's own.
    local warriorWand = verdictFor("WARRIOR", WEAPON, WAND, 60)
    check(report, "a Warrior can never use a wand",
        warriorWand == usability.NEVER, tostring(warriorWand))

    local warriorBow = verdictFor("WARRIOR", WEAPON, BOW, 60)
    check(report, "a Warrior keeps his bow",
        warriorBow ~= usability.NEVER, tostring(warriorBow))

    local shamanWand = verdictFor("SHAMAN", WEAPON, WAND, 60)
    check(report, "a Shaman can never use a wand",
        shamanWand == usability.NEVER, tostring(shamanWand))

    local shamanShield = verdictFor("SHAMAN", ARMOUR, SHIELD, 60)
    check(report, "a Shaman keeps his shield",
        shamanShield ~= usability.NEVER, tostring(shamanShield))

    local rogueShield = verdictFor("ROGUE", ARMOUR, SHIELD, 60)
    check(report, "a Rogue can never use a shield",
        rogueShield == usability.NEVER, tostring(rogueShield))

    local hunterThrown = verdictFor("HUNTER", WEAPON, THROWN, 60)
    check(report, "a Hunter can never use a thrown weapon",
        hunterThrown == usability.NEVER, tostring(hunterThrown))

    -- Hunter mail was confirmed at 40 by the player on 2026-10-27 ("shaman and
    -- hunter is mail @ level 40"), so it carries the same gate as the Shaman's:
    -- scored below 40 and outlined orange, blue from 40.
    local hunterMail30 = verdictFor("HUNTER", ARMOUR, MAIL, 30)
    check(report, "a Hunter is deferred out of mail before 40",
        hunterMail30 == usability.DEFERRED, tostring(hunterMail30))

    local hunterMail40 = verdictFor("HUNTER", ARMOUR, MAIL, 40)
    check(report, "a Hunter can wear mail from 40",
        hunterMail40 == usability.USABLE, tostring(hunterMail40))

    local mageWand = verdictFor("MAGE", WEAPON, WAND, 60)
    check(report, "a Mage keeps his wand",
        mageWand ~= usability.NEVER, tostring(mageWand))

    local rogueMail = verdictFor("ROGUE", ARMOUR, MAIL, 60)
    check(report, "a Rogue can never wear mail",
        rogueMail == usability.NEVER, tostring(rogueMail))

    local priestSword = verdictFor("PRIEST", WEAPON, SWORD1H, 60)
    check(report, "a Priest can never use a sword",
        priestSword == usability.NEVER, tostring(priestSword))

    local hunterMace = verdictFor("HUNTER", WEAPON, MACE1H, 60)
    check(report, "a Hunter can never use a mace",
        hunterMace == usability.NEVER, tostring(hunterMace))

    local hunterStaff = verdictFor("HUNTER", WEAPON, STAFF, 30)
    check(report, "a Hunter's learnable staff is not refused",
        hunterStaff == usability.UNKNOWN, tostring(hunterStaff))

    local mageDagger = verdictFor("MAGE", WEAPON, DAGGER, 20)
    check(report, "a Mage's learnable dagger is not refused",
        mageDagger == usability.UNKNOWN, tostring(mageDagger))

    -- Weapon proficiency: the one verdict built from the character's own state
    -- rather than from the pack. A class that does not refuse the weapon is
    -- deferred while the skill is missing, and the tooltip names the city where
    -- the weapon master lives.
    local function proficiencyVerdict(classToken, subClassID, level, known)
        return usability:Classify({
            classID = WEAPON,
            subClassID = subClassID,
        }, classToken, level, {
            proficiency = { [usability.WEAPON_SUBCLASS[subClassID]] = known },
        })
    end

    local untrainedStaff = proficiencyVerdict("SHAMAN", STAFF, 60, false)
    check(report, "a weapon whose skill is missing is deferred",
        untrainedStaff.verdict == usability.DEFERRED, tostring(untrainedStaff.verdict))
    check(report, "the deferred weapon says which proficiency is missing",
        untrainedStaff.cause == "proficiency"
            and tostring(untrainedStaff.reason):find("Staves", 1, true) ~= nil,
        tostring(untrainedStaff.reason))

    check(report, "a learnable weapon is marked as trainable",
        untrainedStaff.trainable == true, tostring(untrainedStaff.trainable))

    local described = usability:DescribeTraining(untrainedStaff.trainable)
    check(report, "no weapon type still gives the plain weapon-master line",
        described == usability.TRAINER_HINT
            and tostring(described):find("weapon master", 1, true) ~= nil,
        tostring(described))

    local withCity = usability:DescribeTraining(true, "Axe2H")
    check(report, "a named weapon type names its training city",
        type(withCity) == "string"
            and withCity:find("Train ", 1, true) ~= nil
            and withCity:find("in ", 1, true) ~= nil,
        tostring(withCity))

    -- A wand is taught by the class trainer, not by a weapon master, so it keeps
    -- the reason line and gains no hint.
    local untrainedWand = proficiencyVerdict("MAGE", WAND, 60, false)
    check(report, "a skill with no weapon master keeps the reason only",
        untrainedWand.verdict == usability.DEFERRED
            and untrainedWand.trainable == false
            and usability:DescribeTraining(untrainedWand.trainable) == nil,
        tostring(untrainedWand.trainable))

    check(report, "no trainable flag means no hint line",
        usability:DescribeTraining(nil) == nil and usability:DescribeTraining(false) == nil)

    -- The skill check may only ever narrow a verdict, never widen one: a known
    -- skill or an unanswerable question leaves today's behaviour untouched, and a
    -- refused weapon stays refused.
    local knownStaff = proficiencyVerdict("SHAMAN", STAFF, 60, true)
    check(report, "a trained proficiency leaves the pack usable",
        knownStaff.verdict == usability.USABLE, tostring(knownStaff.verdict))

    local unaskedStaff = proficiencyVerdict("SHAMAN", STAFF, 60, nil)
    check(report, "an unanswerable proficiency leaves the pack usable",
        unaskedStaff.verdict == usability.USABLE, tostring(unaskedStaff.verdict))

    local refusedSword = proficiencyVerdict("SHAMAN", SWORD1H, 60, false)
    check(report, "never outranks a missing proficiency",
        refusedSword.verdict == usability.NEVER, tostring(refusedSword.verdict))

    -- The skill check may only ever narrow a verdict, never widen one: a known
    -- skill or an unanswerable question leaves today's behaviour untouched, and a
    -- refused weapon stays refused.
    local knownStaff = proficiencyVerdict("SHAMAN", STAFF, 60, true, "Horde")
    check(report, "a trained proficiency leaves the pack usable",
        knownStaff.verdict == usability.USABLE, tostring(knownStaff.verdict))

    local unaskedStaff = proficiencyVerdict("SHAMAN", STAFF, 60, nil, "Horde")
    check(report, "an unanswerable proficiency leaves the pack usable",
        unaskedStaff.verdict == usability.USABLE, tostring(unaskedStaff.verdict))

    local refusedSword = proficiencyVerdict("SHAMAN", SWORD1H, 60, false, "Horde")
    check(report, "never outranks a missing proficiency",
        refusedSword.verdict == usability.NEVER, tostring(refusedSword.verdict))

    -- Compare must not treat the client's "cannot use" as final for a "not yet"
    -- item: the score is what the orange note sits under. The verdicts are handed
    -- in so the answer does not depend on the character's real trained skills.
    check(report, "a deferred weapon keeps its score despite the client's refusal",
        LT.Compare:RefusalIsFinal(
            { classID = WEAPON, subClassID = STAFF, canUse = false },
            untrainedStaff) == false)

    check(report, "mail below 40 keeps its score as well",
        LT.Compare:RefusalIsFinal(
            { classID = ARMOUR, subClassID = MAIL, canUse = false },
            classify(ARMOUR, MAIL, 30)) == false)

    check(report, "a class that can never use the item still refuses it",
        LT.Compare:RefusalIsFinal(
            { classID = ARMOUR, subClassID = PLATE, canUse = false },
            classify(ARMOUR, PLATE, 30)) == true)

    check(report, "an item with nothing to ask about stays refused",
        LT.Compare:RefusalIsFinal(nil) == true)

    -- The tables themselves: a typo in a key would silently drop the hint, so
    -- every key must be one the verdict engine can produce.
    local badKey = nil
    for _, faction in ipairs({ "Horde", "Alliance" }) do
        for key, entries in pairs(usability.TRAINERS[faction]) do
            if not usability:IsKnownSubclass("weapons", key) then
                badKey = faction .. "." .. tostring(key)
            end
            for _, entry in ipairs(entries) do
                if type(entry.trainer) ~= "string" or type(entry.zone) ~= "string" then
                    badKey = faction .. "." .. tostring(key)
                end
            end
        end
    end

    check(report, "every trainer entry names a known weapon type and a location",
        badKey == nil, tostring(badKey))

    -- Professions: both factions need both lists, every entry needs a trainer and
    -- a zone, and each list starts with a junior trainer so a new character is
    -- never sent to a capital first.
    local badProfession = nil
    for _, faction in ipairs({ "Horde", "Alliance" }) do
        for _, profession in ipairs({ "Skinning", "Mining" }) do
            local entries = usability:GetProfessionTraining(profession, faction)
            if not entries then
                badProfession = faction .. ": " .. profession .. " missing"
            else
                if not (entries[1] and entries[1].junior == true) then
                    badProfession = faction .. ": " .. profession .. " does not start junior"
                end
                for _, entry in ipairs(entries) do
                    if type(entry.trainer) ~= "string" or entry.trainer == ""
                        or type(entry.zone) ~= "string" or entry.zone == "" then
                        badProfession = faction .. ": " .. profession .. " entry incomplete"
                    end
                end
            end
        end
    end
    check(report, "every profession entry names a trainer and a zone, starting zone first",
        badProfession == nil, tostring(badProfession))

    local badSpell = nil
    for key in pairs(usability.PROFICIENCY_SPELL) do
        if not usability:IsKnownSubclass("weapons", key) then
            badSpell = tostring(key)
        end
    end
    for key in pairs(usability.SKILL_LABEL) do
        if not usability:IsKnownSubclass("weapons", key) then
            badSpell = tostring(key)
        end
    end

    check(report, "every proficiency and label key is a weapon type",
        badSpell == nil, tostring(badSpell))

    check(report, "a consumable is neither armour nor a weapon",
        classify(0, 0, 60).verdict == usability.UNKNOWN)

    check(report, "a missing identity is unknown",
        usability:Classify(nil, "SHAMAN", 60).verdict == usability.UNKNOWN)

    -- The tooltip no longer prints this reason (a never-usable item just says
    -- "Unusable"), but /lt output and the logs do, so it must not be empty.
    local never = classify(ARMOUR, PLATE, 30)
    check(report, "a verdict carries a reason for the commands and logs",
        type(never.reason) == "string" and never.reason ~= "",
        tostring(never.reason))
end

-- The palette is the one place a colour lives, so this suite checks the promises
-- the rest of the add-on makes about it: that every colour drawn is explained,
-- that nothing unexplained is drawn, and that the modules hold the palette's own
-- tables rather than copies of its numbers (a copy drifts silently).
local function testPalette(report)
    local palette = LT.Palette

    check(report, "the palette module is registered",
        type(palette) == "table" and LT.Modules.Palette == palette)

    -- A legend row with no colour behind it would explain something the add-on
    -- never shows.
    local missing = {}
    for _, row in ipairs(palette.legend or {}) do
        if not palette:Colour(row.key) then table.insert(missing, tostring(row.key)) end
    end

    check(report, "every legend row names a real colour", #missing == 0,
        table.concat(missing, ", "))

    -- Then the hand-written list of the colours that must be explained, kept
    -- explicit so deleting a colour from the palette and its row together is
    -- still caught by the name it was known by.
    local explained = {}
    for _, row in ipairs(palette.legend or {}) do explained[row.key] = true end

    local unexplained = {}
    for _, key in ipairs({ "go", "good", "caution", "stop", "special", "unknown", "money" }) do
        if not explained[key] then table.insert(unexplained, key) end
    end

    check(report, "every verdict and reserved colour appears in the legend",
        #unexplained == 0, table.concat(unexplained, ", "))

    -- Any colour without a row would be a colour the player cannot look up, so
    -- walk the palette itself rather than a hand-written list.
    local unlisted = {}
    for _, group in ipairs({ palette.verdict, palette.reserved }) do
        for key in pairs(group) do
            if not explained[key] then table.insert(unlisted, key) end
        end
    end

    check(report, "no colour in the palette is missing from the legend", #unlisted == 0,
        table.concat(unlisted, ", "))

    -- Two rows with the same value would make one meaning indistinguishable from
    -- another, which is the exact confusion the palette exists to end. The alpha
    -- is part of the value: the chrome's black edge, its black inner line and
    -- its black card hairline are three different densities on screen and none
    -- of them is a meaning the legend has to tell apart.
    local seenHex, clash = {}, {}
    for key, hex in pairs(palette.hex) do
        local colour = palette:Colour(key)
        local value = hex
        if type(colour) == "table" then
            value = hex .. string.format("/%.2f", tonumber(colour[4]) or 1)
        end

        if seenHex[value] then
            table.insert(clash, tostring(seenHex[value]) .. "/" .. tostring(key))
        else
            seenHex[value] = key
        end
    end

    check(report, "no two colours share a value", #clash == 0,
        table.concat(clash, ", "))

    -- Identity, not equality: these modules must hold the palette's own tables.
    local tones = LT.TooltipPanel and LT.TooltipPanel.toneColours
    check(report, "the tooltip border uses the palette's verdict tables",
        tones and tones.normal == palette.verdict.go
            and tones.deferred == palette.verdict.caution
            and tones.never == palette.verdict.stop)

    local rewards = LT.QuestRewards and LT.QuestRewards.colours
    check(report, "the reward borders use the palette's verdict tables",
        rewards and rewards.upgradeBest == palette.verdict.go
            and rewards.upgradeSecond == palette.verdict.good
            and rewards.vendor == palette.verdict.money)

    -- "Even" is dimmed chrome; a failed comparison is a red verdict. They are
    -- different meanings and must not collapse into one colour.
    check(report, "a dimmed \"Even\" and a red no-answer stay different",
        LT.Compare:StatusColour("equal") ~= LT.Compare:StatusColour("incomparable"))

    check(report, "an upgrade score word is the palette's best colour",
        LT.Compare:StatusColour("upgrade") == palette.hex.go,
        tostring(LT.Compare:StatusColour("upgrade")))

    -- An item the character can never use is a verdict -- the "no" colour -- not a
    -- red "the add-on could not work this out".
    check(report, "an unusable item's score word is the palette's \"no\" colour",
        LT.Compare:StatusColour("ineligible") == palette.hex.stop,
        tostring(LT.Compare:StatusColour("ineligible")))

    check(report, "a downgrade is a verdict and an unscorable item is a no-answer",
        LT.Compare:StatusColour("downgrade") == palette.hex.stop
            and LT.Compare:StatusColour("unscorable") == palette.hex.unknown)

    -- The hex form has to be the eight-digit |cffRRGGBB the note stripper in
    -- Tooltip.lua matches, or raw codes leak onto the tooltip.
    local stripped = palette:Wrap("muted", "text")
        :gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    check(report, "wrapped text strips back to just the text", stripped == "text", stripped)

    local bad = {}
    for _, group in ipairs({ palette.verdict, palette.reserved, palette.chrome }) do
        for key, colour in pairs(group) do
            for channel = 1, 4 do
                local value = colour[channel]
                if type(value) ~= "number" or value < 0 or value > 1 then
                    table.insert(bad, key)
                    break
                end
            end
        end
    end

    check(report, "every colour is four channels between 0 and 1", #bad == 0,
        table.concat(bad, ", "))

    -- The chat list and the window read the same table, so the count is a cheap
    -- proof that /lt colours still prints every row it means to: one heading, two
    -- lines per row, and the two closing lines.
    local lines = palette:Describe()
    check(report, "the legend list matches the legend table",
        #lines == (#palette.legend * 2) + 3, tostring(#lines))

    check(report, "the legend window is available",
        type(LT.Legend) == "table"
            and type(LT.Legend.Show) == "function"
            and type(LT.Legend.Toggle) == "function")
end

-- The window chrome is geometry and palette lookups, so it can be checked
-- against a frame that records instead of drawing: no client, no texture file,
-- no screen. What matters is that every side is pinned by both ends (so a
-- resize cannot leave a gap), that a second call repaints rather than stacking,
-- and that every colour is the palette's.
local function testChrome(report)
    local chrome = LT.Chrome

    check(report, "the chrome module is registered",
        type(chrome) == "table" and LT.Modules.Chrome == chrome)

    if type(chrome) ~= "table" then return end

    for _, name in ipairs({ "Window", "Card", "Tint", "Remove" }) do
        check(report, "chrome exposes " .. name, type(chrome[name]) == "function")
    end

    local palette = LT.Palette
    local colours = (palette and palette.chrome) or {}
    local names = {}

    for _, key in ipairs({ "border", "borderDark", "cardEdge" }) do
        local colour = colours[key]
        local ok = type(colour) == "table" and #colour == 4
        if ok then
            for channel = 1, 4 do
                local value = colour[channel]
                if type(value) ~= "number" or value < 0 or value > 1 then ok = false end
            end
        end
        if not ok then table.insert(names, key) end
    end

    check(report, "the palette carries the three chrome edge colours",
        #names == 0, table.concat(names, ", "))

    -- A frame that records what was asked of it. Any size setter is a failure,
    -- which is how the "anchored to both ends, never sized" rule is proved.
    local function stubFrame()
        local frame = { textures = {} }

        function frame:CreateTexture(_, layer)
            local texture = { layer = layer, points = {}, shown = true }

            function texture:SetColorTexture(r, g, b, a)
                self.colour = { r, g, b, a }
            end
            function texture:SetPoint(point, _, relative, x, y)
                table.insert(self.points, { point, relative, x or 0, y or 0 })
            end
            function texture:ClearAllPoints() self.points = {} end
            function texture:SetAllPoints() self.allPoints = true end
            function texture:Show() self.shown = true end
            function texture:Hide() self.shown = false end
            function texture:SetWidth() self.sized = true end
            function texture:SetHeight() self.sized = true end
            function texture:SetSize() self.sized = true end

            table.insert(frame.textures, texture)
            return texture
        end

        return frame
    end

    local frame = stubFrame()
    local regions = chrome.Window(frame)

    check(report, "a window stores its regions on the frame",
        type(regions) == "table" and frame.ltChrome == regions)
    -- 4 edge + 4 inner + 4 bevel + 1 fill. The bevel was added after this check
    -- was written; the point of the check is that the count is exact and stable.
    check(report, "a window draws one fill, eight lines and a four-sided bevel",
        #frame.textures == 13, tostring(#frame.textures))

    local unpinned = 0
    for _, texture in ipairs(frame.textures) do
        if texture.layer == "BORDER" and (#texture.points ~= 2 or texture.sized) then
            unpinned = unpinned + 1
        end
    end

    check(report, "every line is pinned by both ends and never sized",
        unpinned == 0, tostring(unpinned))

    local edge = regions and regions.edges and regions.edges[1]
    local inner = regions and regions.inner and regions.inner[1]
    local fill = regions and regions.fill

    check(report, "the window edge is the palette's bronze",
        edge and edge.colour and colours.border
            and edge.colour[1] == colours.border[1]
            and edge.colour[4] == colours.border[4])

    check(report, "the inner line is the palette's near-black",
        inner and inner.colour and colours.borderDark
            and inner.colour[4] == colours.borderDark[4])

    check(report, "a window fills with the palette's window fill",
        fill and fill.colour and colours.fill and fill.colour[4] == colours.fill[4])

    chrome.Window(frame)
    check(report, "a second Window call repaints instead of stacking",
        #frame.textures == 13, tostring(#frame.textures))

    if palette and palette.verdict and palette.verdict.go then
        chrome.Tint(frame, palette.verdict.go)
        check(report, "Tint recolours the outer edge and leaves the inner line alone",
            edge ~= nil and inner ~= nil and edge.colour ~= nil and inner.colour ~= nil
                and colours.borderDark ~= nil
                and edge.colour[1] == palette.verdict.go[1]
                and inner.colour[4] == colours.borderDark[4])
    end

    local cardFrame = stubFrame()
    local card = chrome.Card(cardFrame)
    chrome.Card(cardFrame)

    -- 4 edge + 4 bevel: a card never has an inner line.
    check(report, "a card draws one edge and a bevel, no inner line",
        type(card) == "table" and #cardFrame.textures == 8,
        tostring(#cardFrame.textures))

    check(report, "a card's edge is the palette's card hairline",
        type(card) == "table" and colours.cardEdge
            and card.edges[1].colour ~= nil
            and card.edges[1].colour[4] == colours.cardEdge[4])

    chrome.Remove(frame)
    check(report, "Remove drops the record and hides every region",
        frame.ltChrome == nil and frame.textures[1].shown == false)

    check(report, "a missing frame is answered, not an error",
        chrome.Window(nil) == nil and chrome.Card(nil) == nil
            and chrome.Tint(nil) == false and chrome.Remove(nil) == false)

    check(report, "a frame with no CreateTexture gets nil, not an error",
        chrome.Window({}) == nil and chrome.Card({}) == nil)
end

-- The tooltip caption is sized to its rows, so a row is only ever shortened when
-- it has no space in it to wrap at. These checks are pure text: they need no
-- frame and no item.
local function testTooltipPanelText(report)
    local fit = LT.TooltipPanel and LT.TooltipPanel.fitRow

    check(report, "the tooltip panel exposes its row fitter", type(fit) == "function")
    if type(fit) ~= "function" then return end

    local short = "Not yet — Mail is training"
    check(report, "a row that fits the panel is left exactly as written",
        fit(short, 300, 150) == short)

    -- A long row with spaces in it is wrapped by the client. Shortening it here
    -- would cut a sentence the panel has room to show in full.
    local note = LT.Palette:Wrap("muted", "** The difference is a change in weighted "
        .. "item score, not a prediction of damage, healing or survivability.")
    check(report, "a long row with spaces is left for the client to wrap",
        fit(note, 388, 560) == note)

    -- One unbroken token cannot wrap, so it is the one row that gets cut: it must
    -- end in "...", keep the colour it started with and close that colour.
    local word = "VeryLongProfileNameWithoutAnySpaces"
    local token = LT.Palette:Wrap("muted", word)
    local fitted = fit(token, 200, 380)

    local plain = fitted:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local allowed = math.floor(#word * 200 / 380)

    check(report, "an unbreakable row is shortened and keeps its colour",
        fitted ~= token
            and fitted:find("^|c%x%x%x%x%x%x%x%x") ~= nil
            and fitted:find("|r%.%.%.$") ~= nil,
        fitted)

    check(report, "a shortened row fits the width it was given",
        #plain <= allowed, tostring(#plain) .. " > " .. tostring(allowed))

    check(report, "an empty row survives the fitter", fit("", 300, 0) == "")
end

-- Where the caption goes while the client is drawing its own comparison. Pure
-- geometry: the tooltip, the comparison and the screen are plain rectangles, so
-- the bag case that overlapped can be replayed without a bag or a tooltip.
local function testTooltipPanelPlacement(report)
    local pick = LT.TooltipPanel and LT.TooltipPanel.pickSide

    check(report, "the tooltip panel exposes its side rule", type(pick) == "function")
    if type(pick) ~= "function" then return end

    local screen = { 1024, 768 }
    local order = { "left", "right", "above", "below" }
    local tooltip = { left = 400, right = 600, bottom = 300, top = 500 }

    -- A tooltip in the middle with the client's comparison on the right: the
    -- caption keeps the side it has always used.
    local onRight = { left = 604, right = 804, bottom = 300, top = 500 }

    check(report, "a comparison on the right keeps the caption on the left",
        pick(tooltip, 330, 80, { tooltip, onRight }, screen, order) == "left")

    -- The bag case: the client had no room on the right, so it drew its own
    -- comparison on the left. Putting the caption there is what overlapped.
    local onLeft = { left = 60, right = 380, bottom = 300, top = 500 }

    check(report, "a comparison on the left pushes the caption to the right",
        pick(tooltip, 330, 80, { tooltip, onLeft }, screen, order) == "right")

    -- Both sides taken: the caption goes above the tooltip rather than on top of
    -- either box.
    check(report, "both sides taken moves the caption above the tooltip",
        pick(tooltip, 330, 80, { tooltip, onLeft, onRight }, screen, order) == "above")

    -- A comparison that only touches the caption's box is not an overlap: the one
    -- GAP is the whole separation the design asks for.
    local touching = { left = 0, right = 66, bottom = 300, top = 500 }

    check(report, "a comparison that only touches the caption leaves it there",
        pick(tooltip, 330, 80, { tooltip, touching }, screen, order) == "left")

    -- Nothing fits — a tooltip as big as the screen — so the caller keeps its own
    -- default instead of being handed an off-screen side.
    local whole = { left = 0, right = 1024, bottom = 0, top = 768 }

    check(report, "no free side answers nil rather than an off-screen place",
        pick(whole, 330, 80, { whole }, screen, order) == nil)
end

-- What the panel is allowed to draw at all. Pure: the wearable answer comes from
-- an identity table and combat from two arguments, so no character, item or fight
-- is needed to prove the rule.
local function testTooltipGates(report)
    local tooltip = LT.Tooltip
    local exposed = tooltip ~= nil
        and type(tooltip.IsWearable) == "function"
        and type(tooltip.MayShow) == "function"

    check(report, "the tooltip exposes its wearable gate", exposed)
    if not exposed then return end

    local usability = LT.Usability
    local ARMOUR = (usability and usability.ITEM_CLASS_ARMOUR) or 4
    local WEAPON = (usability and usability.ITEM_CLASS_WEAPON) or 2
    local QUEST, CONSUMABLE, TRADE_GOODS = 12, 0, 7

    local chest = { classID = ARMOUR, subClassID = 4, equipLoc = "INVTYPE_CHEST" }
    local axe = { classID = WEAPON, subClassID = 1, equipLoc = "INVTYPE_2HWEAPON" }

    check(report, "armour and a weapon are wearable",
        tooltip:IsWearable(chest) and tooltip:IsWearable(axe))

    -- These are the three shapes the screenshots showed with a panel on them.
    check(report, "a quest item, food and a reagent are not wearable",
        not tooltip:IsWearable({ classID = QUEST })
            and not tooltip:IsWearable({ classID = CONSUMABLE, subClassID = 0 })
            and not tooltip:IsWearable({ classID = TRADE_GOODS, subClassID = 12 }))

    -- A client that names the location but not the class still says the item is
    -- worn somewhere. Hiding every wearable on such a client would be a worse
    -- failure than the panel this replaces.
    check(report, "an equip location alone counts as wearable",
        tooltip:IsWearable({ equipLoc = "INVTYPE_FEET" }))

    check(report, "an unknown item says nothing at all",
        not tooltip:IsWearable(nil) and not tooltip:IsWearable({}))

    -- INVTYPE_NON_EQUIP starts with "INVTYPE_", which is how a grey, non-equippable
    -- item used to get a panel. The location must be one ItemStats can score.
    check(report, "a non-equip location is not wearable",
        not tooltip:IsWearable({ classID = 15, equipLoc = "INVTYPE_NON_EQUIP" })
            and not tooltip:IsWearable({ equipLoc = "INVTYPE_NON_EQUIP" }))

    -- The grey exception asks the real inventory whether the item would fill an
    -- empty slot, so on a character with a bare chest this check measured the
    -- character, not the rule. Pin the answer for the duration.
    local previousHasEmpty = LT.Compare and LT.Compare.HasEmptySlotFor
    if LT.Compare then
        LT.Compare.HasEmptySlotFor = function() return false end
    end
    check(report, "a grey item is refused before it is scored",
        tooltip:GateReason({ quality = 0, classID = ARMOUR, equipLoc = "INVTYPE_CHEST" },
            false, false, { tooltipCombatShiftOnly = true }) == "poor quality")
    if LT.Compare and previousHasEmpty then
        LT.Compare.HasEmptySlotFor = previousHasEmpty
    end

    local quiet = { tooltipCombatShiftOnly = true }
    local loud = { tooltipCombatShiftOnly = false }

    check(report, "out of combat the panel shows without a modifier",
        tooltip:MayShow(chest, false, false, quiet))

    check(report, "in combat the panel waits for the modifier",
        not tooltip:MayShow(chest, true, false, quiet)
            and tooltip:MayShow(chest, true, true, quiet))

    check(report, "with the switch off, combat behaves as it did before",
        tooltip:MayShow(chest, true, false, loud))

    check(report, "a non-wearable item is refused in every case",
        not tooltip:MayShow({ classID = QUEST }, false, true, loud)
            and not tooltip:MayShow({ classID = QUEST }, true, true, quiet))
end

-- The bag triage rule. Pure: the rows, their prices and the ignore set are plain
-- tables, so a full bag can be replayed without a bag.
local function testDropRanking(report)
    local drop = LT.DropHint
    local rank = drop and drop.Rank

    check(report, "the drop hint exposes its ranking rule", type(rank) == "function")
    if type(rank) ~= "function" then return end

    local function row(name, id, unit, count, extra)
        local result = { name = name, itemID = id, unitPrice = unit, count = count or 1,
            bag = 0, slot = id or 1 }
        for key, value in pairs(extra or {}) do result[key] = value end
        return result
    end

    -- A stack of five at 4c costs 20c to lose, which is still less than one
    -- sword at 25c: the stack total is the number that decides.
    local cloth = row("Linen Cloth", 2589, 4, 5)
    local sword = row("Rough Shortsword", 2494, 25, 1)
    local ranked = rank({ cloth, sword }, nil, 5)
    check(report, "a cheap stack sorts below a dearer single item", ranked.ranked[1] == cloth)
    check(report, "the whole stack is the cost compared", drop.StackCost(cloth) == 20)

    -- Quest items are never the answer, whatever they would fetch.
    local quest = row("A Quest Thing", 9999, 1, 1, { quest = true })
    ranked = rank({ quest, sword }, nil, 5)
    check(report, "a quest item is never the suggestion", ranked.cheapest == sword)
    check(report, "the skipped quest item is counted", ranked.questCount == 1)

    -- An ignored ID leaves the ranking and is counted; nothing else moves.
    ranked = rank({ cloth, sword }, { [2589] = true }, 5)
    check(report, "an ignored item leaves the ranking",
        #ranked.ranked == 1 and ranked.ranked[1] == sword)
    check(report, "the ignored item is counted", ranked.ignoredCount == 1)

    -- Gear the player could put on right now is held back even when cheapest.
    local wearable = row("Rough Cloth Belt", 1234, 3, 1, { wearNow = true })
    ranked = rank({ wearable, sword }, nil, 5)
    check(report, "wearable gear is not the first suggestion", ranked.cheapest == sword)
    check(report, "wearable gear is still reported", ranked.cheapestWearable == wearable)

    -- An uncached price is unknown, not zero: it must never rank as free.
    local unknown = row("Unknown Item", 4321, nil, 1)
    ranked = rank({ unknown }, nil, 5)
    check(report, "an unpriced item is not ranked as free",
        ranked.cheapest == nil and #ranked.unpriced == 1 and ranked.pricedCount == 0)

    -- An empty bag answers an empty ranking rather than an error.
    ranked = rank({}, nil, 5)
    check(report, "an empty bag answers no suggestion",
        ranked.cheapest == nil and #ranked.ranked == 0)
end

-- The played ledger's transition maths. Pure: the caller passes both clocks in,
-- so twenty minutes of play, an AFK stretch and a ding cost no time at all.
-- Nothing here reads the clock, the AFK flag or saved data.
local function testPlayedLedger(report)
    local played = LT.Played
    local pure = played and played.Pure

    check(report, "the played ledger exposes its pure transitions",
        type(pure) == "table" and type(pure.Begin) == "function")
    if type(pure) ~= "table" or type(pure.Begin) ~= "function" then return end

    -- Monotonic seconds from login, wall-clock epoch from the client, a level-10
    -- character dinging 11 at fifteen minutes and staying for five more.
    local record = {}
    pure.Begin(record, 10, 0, 1000, false)

    check(report, "a session opens on the bucket for its level",
        record.open and record.open.level == 10 and record.open.afk == false,
        record.open and ("level " .. tostring(record.open.level)) or "no open interval")

    -- Repeating the current AFK state is not a transition: no interval closes.
    check(report, "setting the same AFK state again is not a transition",
        pure.SetAfk(record, false, 1, 1001) == false and record.levels[10].active == 0)

    pure.SetAfk(record, true, 300, 1300)
    check(report, "five active minutes close into the level-10 active channel",
        record.levels[10].active == 300 and record.levels[10].afk == 0,
        "active " .. tostring(record.levels[10].active)
            .. ", afk " .. tostring(record.levels[10].afk))

    pure.SetAfk(record, false, 600, 1600)
    check(report, "the AFK stretch lands in the AFK channel, not active",
        record.levels[10].active == 300 and record.levels[10].afk == 300,
        "active " .. tostring(record.levels[10].active)
            .. ", afk " .. tostring(record.levels[10].afk))

    pure.Begin(record, 11, 900, 1900, false)
    check(report, "a ding closes the previous interval before opening level 11",
        record.levels[10].active == 600 and record.levels[11] ~= nil
            and record.open.level == 11,
        "level 10 active " .. tostring(record.levels[10].active))

    pure.End(record, 1200, 2200)
    check(report, "the final five minutes belong to level 11",
        record.levels[11].active == 300,
        "level 11 active " .. tostring(record.levels[11].active))

    check(report, "totals are the sum of the buckets",
        record.total.active == 900 and record.total.afk == 300,
        "active " .. tostring(record.total.active) .. ", afk " .. tostring(record.total.afk))

    -- Deaths are additive and only count on the way to 60: a death at the cap
    -- happened after the climb and must not grow the frozen total.
    check(report, "a death below 60 increments its level bucket and the total",
        pure.Death(record, 10) == true and record.levels[10].deaths == 1
            and record.total.deaths == 1,
        "level 10 " .. tostring(record.levels[10].deaths)
            .. ", total " .. tostring(record.total.deaths))

    pure.Death(record, 10)
    check(report, "a second death accumulates",
        record.levels[10].deaths == 2 and record.total.deaths == 2,
        "level 10 " .. tostring(record.levels[10].deaths))

    check(report, "a death at the cap is ignored",
        pure.Death(record, 60) == false and record.total.deaths == 2
            and record.levels[60] == nil,
        "total " .. tostring(record.total.deaths))
    check(report, "a death above the cap is ignored",
        pure.Death(record, 70) == false and record.total.deaths == 2)

    local deathsLedger = {}
    pure.Death(deathsLedger, 1)
    pure.Death(deathsLedger, 1)
    pure.Death(deathsLedger, 30)
    pure.Death(deathsLedger, 59)
    pure.Death(deathsLedger, 60)
    check(report, "deaths until 60 sum levels 1..59 and exclude the 60 bucket",
        pure.DeathsUntil60(deathsLedger) == 4 and deathsLedger.levels[60] == nil,
        tostring(pure.DeathsUntil60(deathsLedger)))
    check(report, "an empty ledger has zero deaths until 60",
        pure.DeathsUntil60({}) == 0)

    check(report, "one logout stores exactly one session and closes the bucket",
        record.total.sessions == 1 and #record.sessions == 1 and record.open == nil)

    check(report, "the stored session spans both levels",
        record.sessions[1].startLevel == 10 and record.sessions[1].endLevel == 11
            and record.sessions[1].active == 900 and record.sessions[1].afk == 300,
        tostring(record.sessions[1].active) .. " active, "
            .. tostring(record.sessions[1].afk) .. " afk")

    check(report, "a bucket keeps when the level was first and last played",
        record.levels[10].startedAt == 1000 and record.levels[10].endedAt == 1900
            and record.levels[11].startedAt == 1900 and record.levels[11].endedAt == 2200)

    -- The client's /played total can only explain a gap, never create active
    -- time: 5000 total against 1200 witnessed leaves 3800 untracked.
    local activeBefore = record.total.active
    pure.Reconcile(record, 5000, 5)
    check(report, "client play time beyond the ledger is untracked, never active",
        record.untracked == 3800 and record.total.active == activeBefore,
        "untracked " .. tostring(record.untracked))

    check(report, "the same client total is not recorded twice",
        pure.Reconcile(record, 5000, 5) == false and record.untracked == 3800)

    check(report, "a client total smaller than what was witnessed changes nothing",
        pure.Reconcile(record, 100, 5) == false and record.untracked == 3800)

    pure.Begin(record, 11, 0, 3000, false)
    pure.End(record, 60, 3060)
    check(report, "later witnessed time is added to active, not to untracked",
        record.total.active == 960 and record.untracked == 3800,
        "active " .. tostring(record.total.active) .. ", untracked " .. tostring(record.untracked))

    -- The level cap: 60 and everything above it share one bucket.
    local capped = {}
    pure.Begin(capped, 70, 0, 1000, false)
    pure.End(capped, 30, 1030)
    local levels = pure.LevelList(capped)
    check(report, "level 70 is recorded in the single level-60 bucket",
        capped.levels[60] ~= nil and capped.levels[60].active == 30
            and capped.levels[70] == nil and #levels == 1 and levels[1] == 60,
        table.concat(levels, ","))

    pure.Begin(capped, 60, 0, 2000, false)
    pure.End(capped, 10, 2010)
    check(report, "a level-60 session adds to the same bucket",
        capped.levels[60].active == 40 and #capped.sessions == 2,
        "active " .. tostring(capped.levels[60].active))

    -- Interval arithmetic boundaries.
    check(report, "an interval with no clock at all lasts zero",
        pure.Elapsed({ level = 1 }, 10, 20) == 0)
    check(report, "a backwards monotonic reading is clamped to zero",
        pure.Elapsed({ startedAt = 50 }, 10) == 0)
    check(report, "the wall clock answers when the monotonic one is missing",
        pure.Elapsed({ startedAtEpoch = 100 }, nil, 130) == 30)
    check(report, "the monotonic clock wins when both are present",
        pure.Elapsed({ startedAt = 5, startedAtEpoch = 100 }, 25, 900) == 20)

    -- Normalize must fill a schema-7 record without inventing play time.
    local normalized = pure.Normalize({ total = { active = -4, afk = "x" } })
    check(report, "normalize fills defaults without inventing time",
        normalized.total.active == 0 and normalized.total.afk == 0
            and normalized.total.sessions == 0 and normalized.untracked == 0
            and #normalized.levels == 0,
        "active " .. tostring(normalized.total.active))

    local normalizedDeaths = pure.Normalize({
        levels = { [10] = { deaths = "3" }, [11] = { deaths = -2 } },
        total = { deaths = "7" },
    })
    check(report, "normalize fills the additive deaths fields",
        normalizedDeaths.levels[10].deaths == 3
            and normalizedDeaths.levels[11].deaths == 0
            and normalizedDeaths.total.deaths == 7,
        "level 10 " .. tostring(normalizedDeaths.levels[10].deaths)
            .. ", total " .. tostring(normalizedDeaths.total.deaths))

    local many = { sessions = {} }
    for index = 1, 25 do many.sessions[index] = { start = index } end
    pure.Normalize(many)
    check(report, "the session list is capped at MAX_SESSIONS",
        #many.sessions == played.MAX_SESSIONS,
        tostring(#many.sessions) .. " kept")
end

-- The estimates pack format and the gate in front of it. Pure: records are
-- plain tables, the profile a pack is checked against is stubbed, and every
-- module field the test replaces is put back afterwards.
local function testEstimates(report)
    local estimates = LT.Estimates

    check(report, "the estimates module is loaded",
        type(estimates) == "table" and type(estimates.Parse) == "function")
    if type(estimates) ~= "table" or type(estimates.Parse) ~= "function" then return end

    local savedRecords, savedById = estimates.records, estimates.byId
    local savedPack, savedProvenance = estimates.pack, estimates.provenance
    local savedEnabled, savedExplicit = estimates.estimatesEnabled, estimates.enabledExplicit
    local savedProfiles, savedBuilds = LT.Profiles, LT.Builds

    local ok, err = pcall(function()
        estimates.records, estimates.byId = {}, {}
        estimates.pack, estimates.provenance = {}, nil
        estimates.estimatesEnabled, estimates.enabledExplicit = false, false

        local added = estimates:AddRecord({
            id = "selftest.tabbed",
            name = "Tab\tand\nnewline",
            kind = "estimate",
            class = "SHAMAN",
            spec = "Enhancement",
            text = "first line\nsecond\tcolumn",
            unknowns = { "spell;rank=2", "a=b" },
            weights = { strength = 1.25, hit = -2 },
        })
        check(report, "a record with tabs and newlines is accepted", added ~= nil)

        local text = estimates:Export()
        local lineCount = 0
        for _ in text:gmatch("[^\n]+") do lineCount = lineCount + 1 end
        check(report, "the export is a header plus one line per record",
            lineCount == 2, tostring(lineCount) .. " line(s)")
        check(report, "the export opens with the schema header",
            text:sub(1, #(estimates.HEADER .. "\t" .. tostring(estimates.SCHEMA)))
                == estimates.HEADER .. "\t" .. tostring(estimates.SCHEMA))

        local parsed, parseError = estimates:Parse(text)
        check(report, "an exported pack parses", parsed ~= nil, parseError)
        if parsed and parsed[1] then
            local back = parsed[1]
            check(report, "tabs and newlines survive the round trip",
                back.name == "Tab\tand\nnewline"
                    and back.text == "first line\nsecond\tcolumn",
                tostring(back.name) .. " / " .. tostring(back.text))
            check(report, "separators inside unknowns survive the round trip",
                back.unknowns[1] == "spell;rank=2" and back.unknowns[2] == "a=b")
            check(report, "weights survive the round trip exactly",
                back.weights.strength == 1.25 and back.weights.hit == -2)
            check(report, "identity fields survive the round trip",
                back.id == "selftest.tabbed" and back.kind == "estimate"
                    and back.class == "SHAMAN" and back.spec == "Enhancement")
        end

        local wrongSchema, schemaReason = estimates:Parse("LT-ESTIMATES\t2\n")
        check(report, "a pack declaring another schema is refused",
            wrongSchema == nil and type(schemaReason) == "string"
                and schemaReason:find("schema", 1, true) ~= nil,
            tostring(schemaReason))

        local notAPack, packReason = estimates:Parse("not a pack")
        check(report, "text without the header is refused",
            notAPack == nil and type(packReason) == "string",
            tostring(packReason))

        -- The registry bound. The temporary records are discarded below.
        estimates.records, estimates.byId = {}, {}
        for index = 1, estimates.MAX_RECORDS do
            estimates:AddRecord({ id = "selftest.bound." .. tostring(index) })
        end
        check(report, "the registry fills to its stated bound",
            estimates:Count() == estimates.MAX_RECORDS,
            tostring(estimates:Count()) .. " record(s)")

        local extra, fullReason = estimates:AddRecord({ id = "selftest.bound.extra" })
        check(report, "one record past the bound is refused",
            extra == nil and type(fullReason) == "string"
                and fullReason:find("full", 1, true) ~= nil,
            tostring(fullReason))

        local replaced = estimates:AddRecord({ id = "selftest.bound.1", name = "Replaced" })
        check(report, "re-adding an existing id replaces instead of growing",
            replaced ~= nil and replaced.name == "Replaced"
                and estimates:Count() == estimates.MAX_RECORDS)

        -- A pack may only speak about a stat the active profile already scores.
        LT.Profiles = {
            ResolveForBuild = function()
                return { weights = { strength = 1, hit = 0.5 } }
            end,
        }
        LT.Builds = nil

        local stored = estimates:ApplyPack({
            schema = 1,
            entries = {
                strength = { value = 12.5, reason = "stub", confidence = 0.25 },
                notAStat = { value = 1 },
                hit = { value = "not a number" },
            },
        })
        check(report, "a schema-1 pack with a scored stat is stored",
            stored.ok == true and stored.applied == 1 and stored.refused == 2,
            "applied " .. tostring(stored.applied) .. ", refused " .. tostring(stored.refused))

        local namedUnknown = false
        for _, refusal in ipairs(stored.refusals or {}) do
            if refusal.stat == "notAStat" then namedUnknown = true end
        end
        check(report, "an unknown stat key is refused and named",
            namedUnknown and estimates.pack.notAStat == nil and estimates.pack.hit == nil)

        check(report, "a refused pack leaves the stored values untouched",
            estimates.pack.strength ~= nil and estimates.pack.strength.value == 12.5)

        local stale = estimates:ApplyPack({ schema = 2, entries = {} })
        check(report, "a pack with the wrong schema is refused",
            stale.ok == false and tostring(stale.reason):find("schema", 1, true) ~= nil,
            tostring(stale.reason))

        estimates:SetEnabled(false)
        check(report, "with the gate off, Value answers nothing",
            estimates:Value("strength") == nil)

        estimates:SetEnabled(true)
        local value = estimates:Value("strength")
        check(report, "with the gate on, Value returns a marked copy",
            type(value) == "table" and value.value == 12.5
                and value.reason == "stub" and value.estimated == true,
            type(value) == "table" and tostring(value.value) or "nil")
        check(report, "Value does not invent an entry that was never stored",
            estimates:Value("notAStat") == nil and estimates:Value(nil) == nil)
    end)

    estimates.records, estimates.byId = savedRecords, savedById
    estimates.pack, estimates.provenance = savedPack, savedProvenance
    estimates.estimatesEnabled, estimates.enabledExplicit = savedEnabled, savedExplicit
    LT.Profiles, LT.Builds = savedProfiles, savedBuilds

    if not ok then
        check(report, "the estimates suite ran to completion", false, err)
    end
end

-- Which list a bag item belongs in. Pure: the verdict and the item's level
-- requirement are the whole input, so no character or bag is needed.
local function testGearCheckPlacement(report)
    local gearCheck = LT.GearCheck
    local usability = LT.Usability

    check(report, "gear check and usability are loaded",
        type(gearCheck) == "table" and type(gearCheck.Placement) == "function"
            and type(usability) == "table")
    if type(gearCheck) ~= "table" or type(gearCheck.Placement) ~= "function"
        or type(usability) ~= "table" then
        return
    end

    -- T-46: the 1H + shield package measured against a worn two-hander.
    if type(gearCheck.PackageDelta) == "function" then
        check(report, "a package that beats the two-hander has a positive delta",
            gearCheck.PackageDelta(100, 60, 50) == 10,
            tostring(gearCheck.PackageDelta(100, 60, 50)))

        check(report, "a package that loses has a negative delta",
            gearCheck.PackageDelta(100, 40, 30) == -30,
            tostring(gearCheck.PackageDelta(100, 40, 30)))

        check(report, "a missing score answers nothing",
            gearCheck.PackageDelta(100, nil, 30) == nil)
    else
        check(report, "the package comparator exists", false)
    end

    local function placement(verdict, required, current)
        return gearCheck:Placement({ verdict = verdict },
            required and { requiredLevel = required } or nil, current)
    end

    local list, required = placement(usability.USABLE, 5, 30)
    check(report, "usable gear goes in now with its requirement echoed",
        list == "now" and required == 5,
        tostring(list) .. " / " .. tostring(required))

    list, required = placement(usability.USABLE, nil, 30)
    check(report, "usable gear with no level gate still goes in now",
        list == "now" and required == nil)

    list, required = placement(usability.DEFERRED, 40, 30)
    check(report, "deferred gear with a higher requirement goes in soon",
        list == "soon" and required == 40,
        tostring(list) .. " / " .. tostring(required))

    list, required = placement(usability.DEFERRED, 31, 30)
    check(report, "one level short is still soon",
        list == "soon" and required == 31)

    list, required = placement(usability.DEFERRED, 30, 30)
    check(report, "a requirement already met is not soon",
        list == nil and required == nil)

    list, required = placement(usability.DEFERRED, 20, 30)
    check(report, "a requirement below the character's level is not soon",
        list == nil and required == nil)

    list, required = placement(usability.DEFERRED, nil, 30)
    check(report, "deferred without a number (training, proficiency) is neither list",
        list == nil and required == nil)

    list, required = placement(usability.NEVER, 20, 30)
    check(report, "never usable is in neither list",
        list == nil and required == nil)

    list, required = placement(usability.UNKNOWN, 20, 30)
    check(report, "an unknown verdict is in neither list",
        list == nil and required == nil)

    list, required = gearCheck:Placement(nil, { requiredLevel = 20 }, 30)
    check(report, "a missing verdict is in neither list",
        list == nil and required == nil)

    list, required = gearCheck:Placement({}, { requiredLevel = 20 }, 30)
    check(report, "a verdict with no stated value is in neither list",
        list == nil and required == nil)
end

-- The ranks packet format. Pure: one row in, one string out, the same string
-- parsed back — no group, no channel and no transport is touched.
local function testRanksPackets(report)
    local board = LT.Leaderboard
    local pure = board and board.Pure

    check(report, "the leaderboard exposes its pure packet logic",
        type(pure) == "table" and type(pure.Encode) == "function"
            and type(pure.Parse) == "function"
            and type(pure.Store) == "function" and type(pure.Merge) == "function")
    if type(pure) ~= "table" or type(pure.Encode) ~= "function"
        or type(pure.Parse) ~= "function" or type(pure.Store) ~= "function"
        or type(pure.Merge) ~= "function" then
        return
    end

    local row = {
        name = "Thrall", realm = "Area 52", class = "SHAMAN",
        race = "Orc", faction = "Horde",
        level = 60, lifetime = 12345, at60 = 9999, deaths = 7,
    }
    local packet = pure.Encode(row)
    check(report, "a well-formed row encodes", type(packet) == "string", tostring(packet))
    check(report,
        "the v4 field order is name|realm|class|race|faction|level|lifetime|at60|deaths",
        packet == "LBTK|4|P|Thrall|Area 52|SHAMAN|Orc|Horde|60|12345|9999|7",
        tostring(packet))

    local parsed, reason = pure.Parse(packet)
    check(report, "an encoded packet parses back", parsed ~= nil, reason)
    if parsed then
        check(report, "every packet field survives the round trip",
            parsed.name == row.name and parsed.realm == row.realm
                and parsed.class == row.class and parsed.level == row.level
                and parsed.race == row.race and parsed.faction == row.faction
                and parsed.lifetime == row.lifetime and parsed.at60 == row.at60
                and parsed.deaths == row.deaths,
            tostring(parsed.name) .. " " .. tostring(parsed.level)
                .. " deaths " .. tostring(parsed.deaths))

        check(report, "a parsed own packet keys to the same identity",
            pure.Key(parsed.name, parsed.realm) == pure.Key(row.name, row.realm))
    end

    -- Version 1 is still accepted: its two second counts are added into
    -- lifetime, and its time-to-60 is zero because that version had no field.
    local legacy = pure.Parse("LBTK|1|P|Old|SHAMAN|55|100|50|Area 52")
    check(report, "a v1 packet is accepted with at60 = 0",
        legacy ~= nil and legacy.name == "Old" and legacy.realm == "Area 52"
            and legacy.level == 55 and legacy.lifetime == 150 and legacy.at60 == 0
            and legacy.deaths == 0,
        legacy and (tostring(legacy.lifetime) .. "/" .. tostring(legacy.at60)))

    -- Version 3 has no deaths field. It is still accepted, with deaths = 0.
    local v3 = pure.Parse("LBTK|3|P|Old|Area 52|SHAMAN|Orc|Horde|60|12345|9999")
    check(report, "a v3 packet is accepted with deaths = 0",
        v3 ~= nil and v3.level == 60 and v3.lifetime == 12345
            and v3.at60 == 9999 and v3.deaths == 0,
        v3 and tostring(v3.deaths))

    check(report, "identity keys ignore case in name and realm",
        pure.Key("Thrall", "Area 52") == pure.Key("THRALL", "area 52"))

    check(report, "text that is not a packet is refused", pure.Parse(nil) == nil)

    local broken, fieldReason = pure.Parse("LBTK|2|P|Thrall|Area 52|SHAMAN|60|1")
    check(report, "a packet with the wrong field count is refused",
        broken == nil and fieldReason == "field count", tostring(fieldReason))

    local wrongPrefix, prefixReason = pure.Parse("XXXX|2|P|Thrall|Area 52|SHAMAN|60|1|2")
    check(report, "a packet from another prefix is refused",
        wrongPrefix == nil and prefixReason == "prefix", tostring(prefixReason))

    local wrongVersion, versionReason = pure.Parse("LBTK|5|P|Thrall|Area 52|SHAMAN|Orc|Horde|60|1|2|3")
    check(report, "a packet of an unknown version is refused",
        wrongVersion == nil and versionReason == "version", tostring(versionReason))

    local wrongClass, classReason = pure.Parse("LBTK|2|P|Thrall|Area 52|BARD|60|1|2")
    check(report, "a packet naming an unknown class is refused",
        wrongClass == nil and classReason == "class", tostring(classReason))

    local wrongLevel, levelReason = pure.Parse("LBTK|2|P|Thrall|Area 52|SHAMAN|61|1|2")
    check(report, "a packet above the level cap is refused",
        wrongLevel == nil and levelReason == "level range", tostring(levelReason))

    local zeroLevel, zeroReason = pure.Parse("LBTK|2|P|Thrall|Area 52|SHAMAN|0|1|2")
    check(report, "a packet below level 1 is refused",
        zeroLevel == nil and zeroReason == "level range")

    local clamped = pure.Parse("LBTK|2|P|Thrall|Area 52|SHAMAN|60|99999999|-3")
    check(report, "lifetime and at60 are clamped to the format's range",
        clamped ~= nil and clamped.lifetime == board.MAX_SECONDS and clamped.at60 == 0,
        clamped and (tostring(clamped.lifetime) .. "/" .. tostring(clamped.at60)) or "nil")

    local lowParsed = pure.Parse("LBTK|2|P|Thrall|Area 52|SHAMAN|55|100|300")
    check(report, "a row below the cap cannot claim a time-to-60",
        lowParsed ~= nil and lowParsed.at60 == 0)

    -- Deaths: a v4 field, whole-number, clamped, and never a reason to drop a
    -- packet for a value that can be normalised instead.
    local badDeaths, deathsReason = pure.Parse(
        "LBTK|4|P|Thrall|Area 52|SHAMAN|Orc|Horde|60|100|0|many")
    check(report, "a v4 packet with a non-numeric deaths field is refused",
        badDeaths == nil and deathsReason == "deaths", tostring(deathsReason))

    local clampedDeaths = pure.Parse(
        "LBTK|4|P|Thrall|Area 52|SHAMAN|Orc|Horde|60|100|0|999999")
    check(report, "deaths are clamped to the format's range",
        clampedDeaths ~= nil and clampedDeaths.deaths == board.MAX_DEATHS,
        clampedDeaths and tostring(clampedDeaths.deaths) or "nil")

    local negativeDeaths = pure.Parse(
        "LBTK|4|P|Thrall|Area 52|SHAMAN|Orc|Horde|60|100|0|-5")
    check(report, "a negative deaths field is clamped to zero",
        negativeDeaths ~= nil and negativeDeaths.deaths == 0,
        negativeDeaths and tostring(negativeDeaths.deaths) or "nil")

    local belowCapDeaths = pure.Parse(
        "LBTK|4|P|Thrall|Area 52|SHAMAN|Orc|Horde|55|100|0|42")
    check(report, "a level below the cap keeps its live death count",
        belowCapDeaths ~= nil and belowCapDeaths.deaths == 42
            and belowCapDeaths.at60 == 0,
        belowCapDeaths and tostring(belowCapDeaths.deaths) or "nil")

    local encodedDeaths = pure.Encode({
        name = "Deaths", realm = "Area 52", class = "MAGE",
        level = 55, lifetime = 100, deaths = 1234,
    })
    local deathsRoundTrip = encodedDeaths and pure.Parse(encodedDeaths)
    check(report, "deaths survive a v4 encode and parse",
        deathsRoundTrip ~= nil and deathsRoundTrip.deaths == 1234,
        tostring(encodedDeaths))

    local ownRow = { name = "Own", realm = "Area 52", class = "MAGE",
        level = 30, lifetime = 100, at60 = 0, deaths = 12 }
    local withOwn = pure.WithOwn({}, ownRow)
    check(report, "the own row carries a numeric deaths field",
        #withOwn == 1 and withOwn[1].deaths == 12,
        #withOwn == 1 and tostring(withOwn[1].deaths) or "missing")

    local demoRow = pure.DemoRow(1, 60)
    check(report, "a demo row carries a numeric death count",
        type(demoRow) == "table" and type(demoRow.deaths) == "number"
            and demoRow.deaths >= 0,
        type(demoRow) == "table" and tostring(demoRow.deaths) or "missing")
    check(report, "demo death counts vary between rows",
        pure.DemoRow(1, 60).deaths ~= pure.DemoRow(2, 60).deaths)

    check(report, "a row with a pipe in its name cannot be encoded",
        pure.Encode({ name = "Thr|all", realm = "Area 52", class = "SHAMAN",
            level = 60, lifetime = 0, at60 = 0 }) == nil)
    check(report, "a row naming an unknown class cannot be encoded",
        pure.Encode({ name = "Thrall", realm = "Area 52", class = "BARD",
            level = 60, lifetime = 0, at60 = 0 }) == nil)
    check(report, "a row without a lifetime cannot be encoded",
        pure.Encode({ name = "Thrall", realm = "Area 52", class = "SHAMAN",
            level = 60 }) == nil)

    -- "Further along" is the only reason a report may overwrite a stored row:
    -- a higher level, then a recorded time-to-60, then the shorter lifetime.
    local existing = { level = 40, lifetime = 100 }
    check(report, "a higher level is further along",
        pure.FurtherAlong({ level = 41, lifetime = 99999 }, existing) == true)
    check(report, "a lower level is not further along, whatever its time",
        pure.FurtherAlong({ level = 39, lifetime = 0 }, existing) == false)
    check(report, "the same level with a shorter lifetime is further along",
        pure.FurtherAlong({ level = 40, lifetime = 99 }, existing) == true)
    check(report, "the same level with a longer lifetime is not",
        pure.FurtherAlong({ level = 40, lifetime = 101 }, existing) == false)
    check(report, "an identical report is not further along",
        pure.FurtherAlong({ level = 40, lifetime = 100 }, existing) == false)
    check(report, "a missing candidate is not further along",
        pure.FurtherAlong(nil, existing) == false)

    check(report, "a recorded time-to-60 beats no record at the same level",
        pure.FurtherAlong({ level = 60, lifetime = 900, at60 = 500 },
            { level = 60, lifetime = 900, at60 = 0 }) == true)
    check(report, "a faster recorded time-to-60 wins at the same level",
        pure.FurtherAlong({ level = 60, lifetime = 900, at60 = 400 },
            { level = 60, lifetime = 900, at60 = 500 }) == true)
    check(report, "deaths do not make a report further along",
        pure.FurtherAlong({ level = 40, lifetime = 100, deaths = 999 },
            { level = 40, lifetime = 100, deaths = 0 }) == false)

    -- Rows live on two boards, and the board plus the arrival channel travel
    -- with the row so the UI can tell a guild report from a server report.
    local roster = { server = { rows = {}, count = 0 }, guild = { rows = {}, count = 0 } }
    local storedStatus, stored = pure.Store(roster, parsed, "server",
        board.ROSTER_CAP, 7, "PARTY")
    check(report, "a report is stored on the named board with its channel",
        storedStatus == "added" and stored ~= nil and stored.board == "server"
            and stored.channel == "PARTY" and stored.lifetime == row.lifetime
            and stored.deaths == row.deaths,
        tostring(storedStatus))
    check(report, "the other board stays empty",
        roster.guild.rows[pure.Key(row.name, row.realm)] == nil
            and roster.server.rows[pure.Key(row.name, row.realm)] ~= nil)

    local guildStatus = pure.Store(roster, legacy, "guild", board.ROSTER_CAP, 8, "GUILD")
    check(report, "a version-1 report lands on the guild board with at60 = 0",
        guildStatus == "added"
            and roster.guild.rows[pure.Key(legacy.name, legacy.realm)].at60 == 0
            and roster.guild.rows[pure.Key(legacy.name, legacy.realm)].channel == "GUILD")

    check(report, "the merged read is one row per character across both boards",
        #pure.Merge(roster) == 2, tostring(#pure.Merge(roster)))
end

-- What the build wizard would write. Pure: the class data, the class pack and
-- the build slots are stubbed tables, and every replaced field is restored.
-- The test proves the default fill and both explicit exits without opening a
-- window or saving the player's answers.
local function testWizardPlan(report)
    local wizard = LT.Wizard

    check(report, "the wizard exposes Review and Apply planning",
        type(wizard) == "table" and type(wizard.Plan) == "function"
            and type(wizard.IsSlotUntouched) == "function"
            and type(wizard.Apply) == "function")
    if type(wizard) ~= "table" or type(wizard.Plan) ~= "function"
        or type(wizard.IsSlotUntouched) ~= "function"
        or type(wizard.Apply) ~= "function" then
        return
    end

    local savedPlayer, savedClassData, savedClassPacks = LT.player, LT.ClassData, LT.ClassPacks
    local savedBuilds, savedDatabase, savedDraft = LT.Builds, LT.Database, wizard.draft
    local savedHide = wizard.Hide

    local writes = {}
    local build = {}

    local function resetBuilds()
        writes = {}
        build[1] = { name = "Build 1", spec = "Any", role = "Damage", context = "PVE",
            weaponSetup = "2H", imbue = "none", pluginOptions = {} }
        build[2] = { name = "Build 2", spec = "Any", role = "Damage", context = "PVE",
            weaponSetup = "2H", imbue = "none", pluginOptions = {} }
    end

    local function record(method, index, value)
        writes[#writes + 1] = { method = method, index = index, value = value }
        if method == "SetName" then build[index].name = value end
        if method == "SetSpec" then build[index].spec = value end
        if method == "SetRole" then build[index].role = value end
        if method == "SetContext" then build[index].context = value end
        if method == "SetWeaponSetup" then build[index].weaponSetup = value end
        if method == "SetImbue" then build[index].imbue = value end
    end

    local function wrote(index, method, value)
        for _, write in ipairs(writes) do
            if write.index == index and write.method == method and write.value == value then
                return true
            end
        end
        return false
    end

    local function wroteSlot(index)
        for _, write in ipairs(writes) do
            if write.index == index then return true end
        end
        return false
    end

    local ok, err = pcall(function()
        resetBuilds()

        -- Cancel closes the window; the assertion is about the write, not the
        -- UI, so the real frame is left alone for the length of the check.
        wizard.Hide = function() end

        LT.player = { class = "STUB", level = 60 }
        LT.ClassData = {
            GetClass = function(_, token)
                if token ~= "STUB" then return nil end
                return {
                    name = "Stub",
                    roles = { "Damage", "Tank" },
                    specs = { "StubSpec", "OtherSpec" },
                    defaultRole = "Damage",
                    defaultSetup = "2H",
                    options = {},
                }
            end,
        }
        LT.ClassPacks = {
            Get = function(_, token)
                if token ~= "STUB" then return nil end
                return { specRoles = { StubSpec = { "Tank" }, OtherSpec = { "Damage" } } }
            end,
            GetTemplates = function(_, token)
                if token ~= "STUB" then return {} end
                return { {
                    name = "Stub Tank", spec = "StubSpec", role = "Tank",
                    context = "PVE", weaponSetup = "1H_SHIELD", imbue = "rockbiter",
                } }
            end,
        }
        LT.Builds = {
            Get = function(_, index) return build[index] end,
            EnsureForClass = function() end,
            SetProfile = function(_, index, value) record("SetProfile", index, value) end,
            SetSpec = function(_, index, value) record("SetSpec", index, value) end,
            SetRole = function(_, index, value) record("SetRole", index, value) end,
            SetContext = function(_, index, value) record("SetContext", index, value) end,
            SetWeaponSetup = function(_, index, value) record("SetWeaponSetup", index, value) end,
            SetName = function(_, index, value) record("SetName", index, value) end,
            SetImbue = function(_, index, value) record("SetImbue", index, value) end,
        }
        LT.Database = { character = {}, Save = function() end }
        wizard.draft = { role = "Tank", spec = "StubSpec", context = "PVE",
            dualSpec = false, offSpec = nil }

        local plan = wizard:Plan()
        check(report, "Plan writes nothing", #writes == 0,
            tostring(#writes) .. " write(s)")
        check(report, "both fresh slots are untouched",
            plan.untouched[1] == true and plan.untouched[2] == true)
        check(report, "the main slot takes the pack template",
            plan.slots[1].name == "Stub Tank" and plan.slots[1].spec == "StubSpec"
                and plan.slots[1].role == "Tank"
                and plan.slots[1].weaponSetup == "1H_SHIELD"
                and plan.slots[1].imbue == "rockbiter",
            tostring(plan.slots[1].name))
        check(report, "a slot with no template falls back to the class default",
            plan.slots[2].name == "Build 2" and plan.slots[2].spec == "Any"
                and plan.slots[2].role == "Damage")

        local appliedOk, applied = wizard:Apply()
        check(report, "Apply fills untouched slots and nothing else",
            appliedOk == true and #applied == 2 and applied[1] == 1 and applied[2] == 2,
            type(applied) == "table" and tostring(#applied) or "no list")
        check(report, "Apply writes the chosen template",
            wrote(1, "SetName", "Stub Tank") and wrote(1, "SetRole", "Tank")
                and wrote(1, "SetWeaponSetup", "1H_SHIELD"))
        check(report, "Apply clears the profile a replaced slot pointed at",
            wrote(1, "SetProfile", nil))

        -- A hand-tuned slot is left alone unless the player ticks replace.
        resetBuilds()
        build[1].name = "My Tank"
        check(report, "a renamed slot is not untouched",
            wizard:IsSlotUntouched(1) == false and wizard:IsSlotUntouched(2) == true)

        local keptOk, kept = wizard:Apply()
        check(report, "Apply leaves the hand-tuned slot alone",
            keptOk == true and #kept == 1 and kept[1] == 2)
        check(report, "no write reached the hand-tuned slot", wroteSlot(1) == false)

        resetBuilds()
        build[2].profileKey = "borrowed"
        check(report, "a slot holding a profile key is not untouched",
            wizard:IsSlotUntouched(2) == false)
        local profileOk, profileApplied = wizard:Apply()
        check(report, "a hand-tuned second slot is skipped too",
            profileOk == true and #profileApplied == 1 and profileApplied[1] == 1)
        check(report, "no write reached the profile-holding slot", wroteSlot(2) == false)

        resetBuilds()
        build[1].name = "My Tank"
        local replaceOk, replaced = wizard:Apply({ replace1 = true })
        check(report, "an explicit replace overwrites the hand-tuned slot",
            replaceOk == true and #replaced == 2 and wrote(1, "SetName", "Stub Tank"),
            type(replaced) == "table" and tostring(#replaced) or "no list")

        -- Closing before Apply is the change-nothing exit.
        resetBuilds()
        local setupBefore = LT.Database.character.setup
        local cancelResult = wizard:Cancel()
        check(report, "Cancel refuses and writes no slot",
            cancelResult == false and #writes == 0
                and LT.Database.character.setup == setupBefore,
            tostring(#writes) .. " write(s)")

        local _ = wizard:Plan()
        check(report, "planning after Cancel still writes nothing", #writes == 0)
    end)

    LT.player, LT.ClassData, LT.ClassPacks = savedPlayer, savedClassData, savedClassPacks
    LT.Builds, LT.Database, wizard.draft = savedBuilds, savedDatabase, savedDraft
    wizard.Hide = savedHide

    if not ok then
        check(report, "the wizard suite ran to completion", false, err)
    end
end

-- Every template the shipped class packs register: it must pass the same
-- validation Register used, and the role it names must be one the pack offers
-- for that spec. Data-only, so it costs nothing and cannot touch saved data.
local function testClassTemplates(report)
    local packs = LT.ClassPacks
    local classData = LT.ClassData

    check(report, "the class pack registry is loaded",
        type(packs) == "table" and type(packs.Validate) == "function"
            and type(classData) == "table")
    if type(packs) ~= "table" or type(packs.Validate) ~= "function"
        or type(classData) ~= "table" then
        return
    end

    local invalid = {}
    local unrouted = {}
    local templateCount = 0

    for _, classToken in ipairs(packs:GetOrder()) do
        local pack = packs:Get(classToken) or {}
        local definition = classData:GetClass(classToken) or { roles = {}, specs = {} }

        -- Re-validate the whole registered pack, not a probe: a template that
        -- only validates in isolation would still be a broken wizard step.
        local valid, message, problems = packs:Validate(classToken, {
            apiVersion = pack.apiVersion or 1,
            specRoles  = pack.specRoles,
            templates  = pack.templates,
            usable     = pack.usable,
        })
        if not valid then
            invalid[#invalid + 1] = classToken .. ": "
                .. tostring(message or (problems and problems[1]) or "refused")
        end

        for index, template in ipairs(pack.templates or {}) do
            templateCount = templateCount + 1

            if type(template) ~= "table" then
                unrouted[#unrouted + 1] = classToken .. " template "
                    .. tostring(index) .. " is not a table"
            elseif template.role ~= nil then
                local spec = template.spec or "Any"
                local roles
                if spec == "Any" then
                    roles = definition.roles
                else
                    roles = packs:GetRolesForSpec(classToken, spec)
                end

                local offered = false
                for _, role in ipairs(roles or {}) do
                    if role == template.role then offered = true end
                end

                if not offered then
                    unrouted[#unrouted + 1] = classToken .. "/" .. tostring(spec)
                        .. " -> " .. tostring(template.role)
                end
            end
        end
    end

    check(report, "the shipped packs carry at least one template",
        templateCount > 0, tostring(templateCount) .. " template(s)")
    check(report, "every registered pack re-validates as a whole",
        #invalid == 0, table.concat(invalid, "; "))
    check(report, "every template role is offered for its spec",
        #unrouted == 0, table.concat(unrouted, "; "))

    -- A role that exists for some class but not this one must be refused, not
    -- crash the registry. Before this check existed, the probe raised inside
    -- Validate and no pack was either refused or reported.
    local probeOk, probeValid, probeMessage, probeProblems = pcall(packs.Validate, packs, "MAGE", {
        apiVersion = 1,
        templates = {
            { name = "Probe", spec = "Frost", role = "Healer", context = "PVE", weaponSetup = "1H" },
        },
    })
    local refused = probeOk and probeValid == false
        and ((type(probeProblems) == "table" and #probeProblems > 0)
            or type(probeMessage) == "string")
    check(report, "a template role the class does not have is refused", refused,
        probeOk and tostring(probeMessage or (probeProblems and probeProblems[1])) or tostring(probeValid))

    if type(classData.AuditClassData) == "function"
        and type(LT.Database) == "table"
        and type(LT.Database.defaultOptions) == "function" then
        local audit = classData:AuditClassData()
        check(report, "class data audit is clean",
            type(audit) == "table" and #audit == 0,
            type(audit) == "table" and table.concat(audit, "; ") or tostring(audit))
    end
end

SelfTest.testNames = {
    "scoring maths",
    "cap single application",
    "profile isolation",
    "plugin interface",
    "level scaling",
    "weapon configuration rules",
    "v0.5 migration",
    "item reading",
    "import/export",
    "weapon imbues",
    "quest reward ranking",
    "quest reward outline",
    "private profiles",
    "dev page plumbing",
    "class packs",
    "item usability",
    "palette",
    "window chrome",
    "tooltip panel text",
    "tooltip panel placement",
    "tooltip gates",
    "drop ranking",
    "played ledger",
    "estimates pack",
    "gear check placement",
    "best setup chooser",
    "ranks packets",
    "wizard plan",
    "class templates",
}

-- One ordered list, used by Run and exposed so an offline harness can execute
-- the pure suites without the client. `pure` marks a suite that takes plain
-- tables and calls no client API; a pure suite must also appear in testNames.
local function testBestSetup(report)
    local best = LT.BestSetup
    check(report, "best setup is loaded",
        type(best) == "table" and type(best.Choose) == "function")
    if type(best) ~= "table" or type(best.Choose) ~= "function" then return end

    local function item(link, score, loc)
        return { link = link, name = link, score = score, equipLoc = loc }
    end

    local pool = {
        item("item:1", 100, "INVTYPE_2HWEAPON"),
        item("item:2", 150, "INVTYPE_WEAPONMAINHAND"),
        item("item:3", 90, "INVTYPE_WEAPON"),
        item("item:4", 40, "INVTYPE_SHIELD"),
        item("item:5", 60, "INVTYPE_HOLDABLE"),
        item("item:6", 30, "INVTYPE_RANGED"),
    }

    local two = best:Choose(pool, "2H")
    check(report, "two-handed takes the two-hander, not the higher one-hander",
        two.available == true and two.main.link == "item:1" and two.total == 100)
    check(report, "two-handed carries no off hand", two.off == nil)

    local dw = best:Choose(pool, "DUAL_WIELD")
    check(report, "dual wield takes the best main hand",
        dw.available == true and dw.main.link == "item:2")
    check(report, "dual wield takes a different off-hand item",
        dw.off ~= nil and dw.off.link ~= dw.main.link)
    check(report, "dual wield total is both hands",
        dw.total == dw.main.score + dw.off.score)

    local single = best:Choose({ item("item:7", 120, "INVTYPE_WEAPON") }, "DUAL_WIELD")
    check(report, "one weapon cannot fill both hands",
        single.available == false and type(single.reason) == "string")

    local noDual = best:Choose(pool, "DUAL_WIELD", { canDualWield = false })
    check(report, "a character who cannot dual wield gets no dual-wield card",
        noDual.available == false)

    local shield = best:Choose(pool, "1H_SHIELD")
    check(report, "the shield card pairs a one-hander with a shield",
        shield.available == true and shield.main.link == "item:2" and shield.off.link == "item:4")

    local bare = best:Choose({ item("item:8", 100, "INVTYPE_WEAPON") }, "1H_SHIELD")
    check(report, "no shield means no shield card",
        bare.available == false and type(bare.reason) == "string")

    local held = best:Choose(pool, "1H")
    check(report, "the caster card takes a held item",
        held.available == true and held.off ~= nil and held.off.link == "item:5")

    local ranged = best:Choose(pool, "RANGED")
    check(report, "the ranged card takes the ranged weapon",
        ranged.available == true and ranged.main.link == "item:6")

    local empty = best:Choose({}, "2H")
    check(report, "an empty pool is unavailable, never a zero-score card",
        empty.available == false)

    local style, hand = best:StyleFor("INVTYPE_SHIELD")
    check(report, "a shield belongs to the shield card, off hand",
        style == "1H_SHIELD" and hand == "off")
    local armourStyle, armourHand = best:StyleFor("INVTYPE_CHEST")
    check(report, "armour belongs to no weapon card",
        armourStyle == nil and armourHand == nil)

    local tie = best:Choose({
        item("item:b", 50, "INVTYPE_2HWEAPON"),
        item("item:a", 50, "INVTYPE_2HWEAPON"),
    }, "2H")
    check(report, "equal scores are decided by link, so the page cannot flicker",
        tie.main ~= nil and tie.main.link == "item:a")

    local missing = best:Choose(pool, "1H")
    check(report, "the chosen items carry the score the page prints",
        missing.main.score == 150 and type(missing.total) == "number")

    -- Which cards a class sees. The rule is pack data, so these two are the
    -- player's own examples: a Shaman has no bare one-hander and no ranged card,
    -- a Rogue has dual wield and nothing else.
    local function has(list, key)
        for _, value in ipairs(list or {}) do if value == key then return true end end
        return false
    end

    local shaman = best:RelevantStyles("SHAMAN")
    check(report, "a shaman sees two-handed, dual wield and shield",
        has(shaman, "2H") and has(shaman, "DUAL_WIELD") and has(shaman, "1H_SHIELD"))
    check(report, "a shaman sees no bare one-hander and no ranged card",
        not has(shaman, "1H") and not has(shaman, "RANGED"))

    local rogue = best:RelevantStyles("ROGUE")
    check(report, "a rogue sees dual wield only",
        #rogue == 1 and rogue[1] == "DUAL_WIELD")

    local hunter = best:RelevantStyles("HUNTER")
    check(report, "a hunter sees a ranged card", has(hunter, "RANGED"))
end

local suites = {
    { name = "scoring maths", fn = testScoringMaths },
    { name = "cap single application", fn = testCapSingleApplication },
    { name = "profile isolation", fn = testProfileIsolation },
    { name = "plugin interface", fn = testPluginInterface },
    { name = "level scaling", fn = testLevelScaling },
    { name = "weapon configuration rules", fn = testWeaponConfigurationRules },
    { name = "v0.5 migration", fn = testMigration },
    { name = "item reading", fn = testItemReading },
    { name = "import/export", fn = testImportExport },
    { name = "weapon imbues", fn = testImbues },
    { name = "quest reward ranking", fn = testQuestRewardRanking },
    { name = "quest reward outline", fn = testQuestRewardOutline },
    { name = "private profiles", fn = testPrivateProfiles },
    { name = "dev page plumbing", fn = testDevPagePlumbing },
    { name = "class packs", fn = testClassPacks },
    { name = "item usability", fn = testItemUsability },
    { name = "bind state", fn = testBindState, pure = true },
    { name = "palette", fn = testPalette },
    { name = "window chrome", fn = testChrome },
    { name = "tooltip panel text", fn = testTooltipPanelText },
    { name = "tooltip panel placement", fn = testTooltipPanelPlacement },
    { name = "tooltip gates", fn = testTooltipGates },
    { name = "drop ranking", fn = testDropRanking },
    { name = "played ledger", fn = testPlayedLedger, pure = true },
    { name = "estimates pack", fn = testEstimates, pure = true },
    { name = "gear check placement", fn = testGearCheckPlacement, pure = true },
    { name = "best setup chooser", fn = testBestSetup, pure = true },
    { name = "ranks packets", fn = testRanksPackets, pure = true },
    { name = "wizard plan", fn = testWizardPlan, pure = true },
    { name = "class templates", fn = testClassTemplates, pure = true },
}

SelfTest.suites = suites

function SelfTest:Run(verbose)
    local report = newReport()

    for _, suite in ipairs(suites) do
        local ok, err = pcall(suite.fn, report)
        if not ok then
            report.failed = report.failed + 1
            table.insert(report.lines, LT.Palette:Wrap("stop", "FAIL") .. " " .. suite.name
                .. " suite crashed — " .. tostring(err))
            table.insert(report.failures, suite.name .. " (crash)")
        end
    end

    report.summary = tostring(report.passed) .. " passed, " .. tostring(report.failed) .. " failed"

    if verbose then
        LT:Print("Self test — " .. report.summary)

        for _, line in ipairs(report.lines) do
            print("  " .. line)
        end

        if report.failed == 0 then
            LT:Print("All checks passed.")
        else
            LT:Error("Failing checks: " .. table.concat(report.failures, "; "))
        end
    end

    return report
end