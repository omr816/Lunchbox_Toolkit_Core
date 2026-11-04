--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Database
    Saved variables, schema versioning and migrations.

    The v0.5 saved shape (one character record with a "profiles" table driven
    by a single DUNGEON/RAID/PVP context) is migrated forward, not discarded:
    the old default profile becomes custom profile "Imported (v0.5)" and is
    assigned to build slot 1. The untouched v0.5 table is kept under
    character.legacyV5 so nothing that was saved before is unrecoverable.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Database = {}
LT.Database = Database
LT.Modules.Database = Database

-- v7 added the locked flag to profiles and needed no conversion. v8 adds
-- character.played for the play-time ledger (Played.lua); it is additive, so an
-- older record only gains an empty table.
Database.SCHEMA = 8

local function defaultOptions()
    return {
        tooltipEnabled      = true,
        tooltipBuildOne     = true,
        tooltipBuildTwo     = true,
        tooltipExpanded     = false,   -- hold the modifier key for detail
        tooltipShowLimits   = true,
        tooltipCombatShiftOnly = true, -- during a fight, only while a modifier is held
        tooltipCompareEquipped = true, -- compare with worn gear; false = saved equipment set
        questRewardHighlight = true,   -- outline quest rewards for the active slot
        questRewardRanking   = true,   -- purple = biggest upgrade, blue = second biggest
        questVendorFallback  = true,   -- gold = highest vendor value when nothing upgrades
        capsEndgame          = false,  -- "aim for MH hit cap": force boss hit/expertise/spell targets at every level
        capsUncrittable      = false,  -- "aim for uncrittable (defence)": engage the tank defence cap at every level
        capGetCloseEnough    = false,  -- "get close enough": aim ~80% of the cap, then drop the stat to near-zero
        loginMessage         = true,   -- one line at login: "/lt for options"
        minimapButton        = false,  -- small dot on the minimap ring; the addon-compartment entry is the normal launcher
        gearCheckOnLevel     = true,   -- scan the bags after a level-up, once out of combat
        gearCheckBankPrompt  = true,   -- offer a bank scan when the bank is opened
        toastUpgrades        = true,   -- one line when a looted item beats the worn item (T-32)
        bagSortEnabled       = false,  -- allow /lt sort to rearrange the bags or the bank
        sortMode             = "client", -- "client" = the client's own sort, "order" = BankStack-style
        sortReverse          = false,  -- order mode: highest first becomes lowest first
        -- Which frames the bag marks belong on: 'client' = annotate the client's
        -- own bags, 'replacement' = hand the job to the replacement addon
        -- (Bagnon, Baganator) and draw nothing there (T-137).
        bagFrames           = "client",
        bagSpaceWarning     = true,   -- one line at two or fewer free bag slots
        -- L-15 (T-134): three lines at a campfire - the fire/XP-food line, the
        -- buff's time left, and a warning before it expires. Off by default:
        -- the buff names it matches come from the guide, not from this client.
        campfireToasts      = false,
        showProvisionalNote = true,
        -- BuffMonitor option keys (Decision 1; the buffs themselves are declared
        -- in Classes\<Class>.lua under Decision 9). The pack's `default` must
        -- agree with the value here — ClassPacks refuses a pack that disagrees,
        -- and ClassData:AuditClassData() reports it. Additive only: the Migrate
        -- loop below fills a missing key on every load, so no schema bump.
        shamanImbueReminder = true,    -- warn when main-hand imbue is missing or expiring
        shamanImbueGlow     = true,    -- glow the imbue action buttons when the imbue is missing
        shamanTotemBar      = true,    -- the Shaman totem bar (Earth/Fire/Water/Air) on screen
        shamanCastClock     = false,   -- mana cast clock: the 5 s rule drawn on the Shaman HUD (T-127)
        shamanTotemAlert    = false,   -- totem expiry warning and Totemic Recall cue (T-128)
        -- Shaman weapon-imbue scoring (off until ticked; Shaman only)
        shamanImbueScoring  = false,   -- score weaponDPS / weapon damage through the imbue
        shamanDefaultImbue  = "windfury", -- default for a slot that has not chosen one
        paladinSealReminder = false,   -- warn when no seal is active (confirm spell names first)
        hunterAspectReminder= false,   -- warn when no aspect is active (confirm spell names first)
        warriorShoutReminder= false,   -- warn when no Battle/Commanding Shout is active (optional)
        warriorStanceReminder = false, -- warn when no Battle/Defensive/Berserker Stance is active
        roguePoisonHint     = false,   -- Rogue poison hint; this client cannot read poison charges
        priestInnerFireReminder = false, -- warn when Inner Fire is inactive
        mageArmorReminder   = false,   -- warn when no Frost/Ice/Mage Armor is active
        warlockDemonArmorReminder = false, -- warn when no Demon Skin/Demon Armor is active
        -- Hunter and Warlock maintenance checks (2026-10-29 suggestions,
        -- sections 6 and 7). All five start off: every reader behind them is
        -- pcall'd but unproven on this client, and a wrong warning is worse than
        -- no warning. Additive keys only; the Migrate loop fills them on load.
        hunterAmmoLow      = false,   -- warn under 200 rounds in the ammo slot
        hunterAmmoType     = false,   -- warn when the ammo does not match the ranged weapon
        warlockPet         = false,   -- warn when no demon is out or it is dead; Demonic
                                      -- Sacrifice suppresses for 120 s at most
        warlockShards      = false,   -- warn at 0 or 1 soul shards (item 6265)
        druidCatFormReminder = false,  -- Feral cat only: warn when Cat Form is inactive
        druidBearFormReminder = false, -- Feral bear only: warn when no Bear/Dire Bear Form is active
        -- Trackers.lua. Both are additive and off by default; the Migrate loop
        -- fills them in on an existing record without a schema bump.
        comboTracker        = false,   -- small movable frame: Rogue / Cat Form combo points
        combatLogProbe      = false,   -- diagnostic: print the first 10 combat-log events, then stop
        -- Bag, vendor, cap and levelling switches (2026-11 wave). Additive only:
        -- the Migrate loop below fills a missing key on every load.
        gearCheckOnBagOpen  = false,   -- scan the bags when they open (opt-in)
        questTurnInScan     = false,   -- bag scan on quest turn-in (opt-in)
        durabilityWarn      = true,    -- one line at a merchant when an equipped item is worn out
        autoRepair          = false,   -- repair all at a merchant, player money only
        junkSale            = false,   -- allow the score-based junk sale (see Vendor)
        debugChat           = false,   -- diagnostic lines in chat (dev)
        capBoostUnknown     = false,   -- true = keep boosting caps whose current value is unknown
        levellingBands      = true,    -- level-band weight multipliers while below 60
        showPaceLine        = true,    -- levelling pace line on the Ranks page
        trainerHint         = true,    -- remind to visit the class trainer on a level-up
        goldGoal            = 0,       -- 0 = off; a target in copper
    }
end

local function defaultCharacter()
    return {
        schema      = Database.SCHEMA,
        activeBuild = 1,
        builds      = {},          -- slot index -> build table (see Builds.lua)
        -- Where the main window was left and which page it was showing. The
        -- place is a fraction of the UI area, so it survives a resolution
        -- change; it is filled in after the first drag.
        window      = { page = "builds" },
        customProfiles = {},       -- profile key -> custom profile
        conversions = {},          -- level -> stat -> { value, source, at }
        options     = defaultOptions(),
        exports     = {},          -- profile strings written by /lt export
        -- Play-time ledger (Played.lua): per-level buckets, the running total
        -- and up to 20 sessions. Filled on the first transition after login.
        played      = {},
        -- Build wizard answers (Wizard.lua). Additive and optional: nil means
        -- the wizard has never been completed, which is distinct from answers
        -- that happen to equal the defaults. No schema bump; Wizard.lua owns
        -- the field shape.
        setup       = nil,
        -- True once the login prompt has actually been shown. Closing it
        -- unanswered therefore stops it returning every login; /lt setup is
        -- still always available.
        setupPrompted = false,
        legacyV5    = nil,
        createdWith = LT.version,
    }
end

Database.defaultOptions = defaultOptions
Database.defaultCharacter = defaultCharacter

------------------------------------------------------------------------------
-- Access
------------------------------------------------------------------------------

function Database:Initialize()
    -- Called on ADDON_LOADED and again through the module stage at login; the
    -- second call must not rebuild the character record.
    if self.character then
        return self.character
    end

    LunchboxToolkitDB = LunchboxToolkitDB or {}
    local store = LunchboxToolkitDB

    store.schema = store.schema or 0
    store.characters = store.characters or {}

    -- Account-wide, not per character: the items a player never wants suggested
    -- for destroying are the same items on every alt. Kept at the store root so
    -- it survives ResetCharacter. Read and written through GetDropIgnore.
    store.dropIgnore = store.dropIgnore or {}

    local key = LT:GetPlayerKey()
    local character = store.characters[key]

    if character then
        self:Migrate(character)
    else
        character = defaultCharacter()
    end

    self.character = character
    store.characters[key] = character

    -- The store root version follows the record that was just migrated: once
    -- this character is at the current schema, so is the store that holds it.
    -- ResetCharacter rebuilds a record but never touches this number, so a reset
    -- cannot make the store look older than it is.
    store.schema = self.SCHEMA

    -- The active build must always exist before any other module reads it,
    -- but at ADDON_LOADED the class is still UNKNOWN: creating slots then would
    -- build a generic "Build 1 / Build 2" that a class-aware pass can no longer
    -- correct, because existing slots are never rewritten. So the slots are
    -- only created once the class is known (PLAYER_LOGIN), and the table is
    -- simply made safe in the meantime.
    local classToken = LT.player and LT.player.class
    if classToken == "UNKNOWN" or not classToken then
        self.character.builds = self.character.builds or {}
    elseif LT.Builds then
        LT.Builds:EnsureForClass(classToken)
    end

    -- Slots are created above once the class is known. Nothing else is filled in
    -- here, so an existing character record is never rewritten at load.

    self:ReportMigration()
    return character
end

function Database:Get()
    return self.character
end

-- The account-wide "never suggest this" list, created on first use so an
-- existing saved-variables file needs no migration. Returns the live table.
function Database:GetDropIgnore()
    LunchboxToolkitDB = LunchboxToolkitDB or {}
    LunchboxToolkitDB.dropIgnore = LunchboxToolkitDB.dropIgnore or {}
    return LunchboxToolkitDB.dropIgnore
end

-- Rebuilds this character's record from scratch, which is what makes a "new
-- install" reproducible without deleting saved variables by hand.
--
--   scope "builds"     keeps the saved custom profiles and the recorded play
--                      time; slots, options, level conversions and exports go
--                      back to their defaults.
--   scope "everything" clears the custom profiles and the play time as well.
--
-- Install-wide tables belonging to other addons are never touched, and neither
-- is any other character's record, so this cannot reach data this addon does
-- not own.
function Database:ResetCharacter(scope)
    local keepProfiles = scope ~= "everything"

    LunchboxToolkitDB = LunchboxToolkitDB or {}
    local store = LunchboxToolkitDB
    store.characters = store.characters or {}

    local previous = self.character
    local fresh = defaultCharacter()

    if keepProfiles and type(previous) == "table" then
        if type(previous.customProfiles) == "table" then
            fresh.customProfiles = LT:Copy(previous.customProfiles)
        end

        -- Play time is history, not configuration: rebuilding the builds and
        -- options does not change how long the character has been played. An
        -- "everything" reset clears it along with the profiles.
        if type(previous.played) == "table" then
            fresh.played = LT:Copy(previous.played)
        end
    end

    self.character = fresh
    store.characters[LT:GetPlayerKey()] = fresh

    -- Slots are rebuilt from the class defaults, exactly as on a first login.
    if LT.Builds then
        LT.Builds:Initialize()
    end

    self:Save("reset:" .. tostring(scope or "builds"))
    LT:Fire(LT.EVENT_BUILDS, { reason = "reset" })

    return fresh
end

-- Saving is implicit (saved variables are written on logout); this exists so
-- callers have one place to flag "the character's data changed".
function Database:Save(reason)
    if LT.Profiles then
        LT.Profiles:Invalidate()
    end
    LT:Fire(LT.EVENT_PROFILE, { reason = reason or "save" })
end

function Database:GetOptions()
    local character = self.character
    if not character then return defaultOptions() end

    character.options = character.options or defaultOptions()
    for key, value in pairs(defaultOptions()) do
        if character.options[key] == nil then
            character.options[key] = value
        end
    end

    return character.options
end

------------------------------------------------------------------------------
-- Migration
------------------------------------------------------------------------------

-- Fills in anything a stored character record is missing and upgrades old
-- schemas. Safe to call on every login.
function Database:Migrate(character)
    if type(character) ~= "table" then return character end

    character.schema = tonumber(character.schema) or 5
    character.builds = character.builds or {}
    character.customProfiles = character.customProfiles or {}
    character.conversions = character.conversions or {}
    character.options = character.options or defaultOptions()
    character.exports = character.exports or {}   -- /lt export storage
    -- Added after schema 7 with no data to convert: an older record simply has
    -- no remembered window place yet, so the window opens centred.
    if type(character.window) ~= "table" then
        character.window = { page = "builds" }
    end
    -- v8: the play-time ledger. Additive only: an older record gains an empty
    -- table and nothing else on the record is read or rewritten. Played.lua
    -- normalizes the table on its first transition.
    if type(character.played) ~= "table" then
        character.played = {}
    end
    -- Wizard answers (Wizard.lua) stay nil until the wizard is completed, so
    -- "never answered" remains distinguishable from "answered with defaults".
    -- A value that is not a table is discarded rather than trusted; there is
    -- nothing to convert and no schema bump.
    if character.setup ~= nil and type(character.setup) ~= "table" then
        character.setup = nil
    end
    -- The wizard's "already asked" flag, additive: an older record gains false
    -- and is asked once more. Only `true` counts, so a damaged value is treated
    -- as not asked rather than trusted.
    character.setupPrompted = character.setupPrompted == true

    for key, value in pairs(defaultOptions()) do
        if character.options[key] == nil then
            character.options[key] = value
        end
    end

    -- The v0.5 import only applies to a record that predates v6. Running it for
    -- later schemas would rewrite character.migration on every version bump
    -- (and could re-import the old profiles table), which an additive migration
    -- must not do.
    if character.schema < 6 then
        self:MigrateV5(character)
    end
    -- v6 -> v7 (the optional locked flag) and v7 -> v8 (played) add fields
    -- above and convert nothing, so neither needs a step of its own.
    -- defaultOptions() already adds new option keys on every load (loop above).

    character.schema = self.SCHEMA
    return character
end

-- v0.5 -> v6.
-- v0.5 stored: activeProfile = "Default", profiles = { [name] = profile }
-- where profile.contexts held DUNGEON / RAID / PVP weight sets and
-- profile.goals held the primary/secondary multipliers.
function Database:MigrateV5(character)
    local profiles = character.profiles
    if type(profiles) ~= "table" then
        character.migration = { from = 5, profilesImported = 0 }
        return
    end

    -- Keep an untouched copy first. This is the recoverable path if the
    -- imported result is not what the player expected.
    character.legacyV5 = character.legacyV5 or LT:Copy(profiles)

    local imported = 0

    for name, old in pairs(profiles) do
        if type(old) == "table" then
            local key = "imported_" .. tostring(name)
            local context = old.context or "DUNGEON"
            local ctx = old.contexts and old.contexts[context]
            local role = old.role or "DPS"

            local weights = {}
            if ctx then
                weights = (ctx.baseWeights and ctx.baseWeights[role])
                    or ctx.weights
                    or {}
            end

            character.customProfiles[key] = {
                name = tostring(name) .. " (v0.5)",
                origin = "migrated from v0.5",
                class = old.class,
                race = old.race,
                role = role,
                context = context,
                source = LT.SOURCE_MANUAL,
                provisional = true,
                assumptions = "Imported from the Lunchbox Toolkit v0.5 saved profile. "
                    .. "The weights were carried across unchanged and have not been "
                    .. "re-validated.",
                weights = LT:Copy(weights),
                goals = LT:Copy(old.goals or {}),
                caps = LT:Copy(old.caps or {}),
                classOptions = LT:Copy(old.classOptions or {}),
                createdAt = time and time() or 0,
            }

            -- Slot 1 takes the profile that was active in v0.5, others fill as
            -- free slots for the player to configure.
            if old == profiles[character.activeProfile] and not character.builds[1] then
                character.builds[1] = character.builds[1] or {}
                character.builds[1].profileKey = key
                character.builds[1].name = tostring(name) .. " (imported)"
            end

            imported = imported + 1
        end
    end

    character.migration = { from = 5, profilesImported = imported }
end

function Database:ReportMigration()
    local migration = self.character and self.character.migration
    if not migration or migration.reported then return end

    migration.reported = true

    if (migration.profilesImported or 0) > 0 then
        LT:Print("Imported " .. tostring(migration.profilesImported)
            .. " profile(s) from your previously saved data. They are available as"
            .. " custom profiles and the originals are kept untouched.")
    end
end