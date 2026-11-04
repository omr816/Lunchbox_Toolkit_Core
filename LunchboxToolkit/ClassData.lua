--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — ClassData
    Bundled base profiles, class options, goal presets and racial notes.

    EVERY weight in this file is marked provisional. They are starting points
    inherited from the v0.5 addon plus reasonable extrapolations for roles it
    did not cover (Enhancement tanking). They are not validated against
    Forever's combat maths and must not be read as authoritative.

    The core does not own Shaman-specific rules: those belong in a plugin.
    What lives here is only the plain "what do the stats look like at the
    start" data every class needs.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local ClassData = {}
LT.ClassData = ClassData
LT.Modules.ClassData = ClassData

local PROVISIONAL = LT.SOURCE_BUNDLED

local function provisionalProfile(definition)
    definition.source = PROVISIONAL
    definition.provisional = true
    return definition
end

------------------------------------------------------------------------------
-- Goal presets (multipliers applied after the stored weights)
------------------------------------------------------------------------------

LT.GoalPresets = {
    Balanced    = { label = "Balanced",    primaryMultiplier = 1.00, secondaryMultiplier = 1.00, deprioritisedMultiplier = 1.00 },
    Power       = { label = "Power",       primaryMultiplier = 1.50, secondaryMultiplier = 1.15, deprioritisedMultiplier = 0.25 },
    Consistency = { label = "Consistency", primaryMultiplier = 1.15, secondaryMultiplier = 1.25, deprioritisedMultiplier = 0.75 },
    Survival    = { label = "Survival",    primaryMultiplier = 1.10, secondaryMultiplier = 1.00, deprioritisedMultiplier = 0.65 },
    Custom      = { label = "Custom",      primaryMultiplier = 1.00, secondaryMultiplier = 1.00, deprioritisedMultiplier = 1.00 },
}

local goalOrder = { "Balanced", "Power", "Consistency", "Survival", "Custom" }
LT.GoalOrder = goalOrder

------------------------------------------------------------------------------
-- Roles and weapon configurations
------------------------------------------------------------------------------

LT.Roles = { "Damage", "Tank", "Healer", "Hybrid" }

-- LEVELING is a real answer a class pack may name on a starter template and
-- the wizard may store. A build slot still understands only PVE and PVP:
-- Wizard.lua maps LEVELING onto the levelling (PvE) profile when it writes a
-- slot, so no profile lookup has to learn a third context.
LT.Contexts = {
    { key = "LEVELING", label = "Levelling" },
    { key = "PVE", label = "PvE" },
    { key = "PVP", label = "PvP" },
}

-- Weapon configuration drives what a candidate weapon can be compared against.
LT.WeaponSetups = {
    { key = "2H",         label = "Two-handed",        usesOffHand = false },
    { key = "1H_SHIELD",  label = "One-handed + shield", usesOffHand = true },
    { key = "DUAL_WIELD", label = "Dual wield",        usesOffHand = true },
    { key = "1H",         label = "One-handed only",   usesOffHand = false },
    { key = "RANGED",     label = "Ranged",            usesOffHand = true },
}

LT.WeaponSetupOrder = { "2H", "1H_SHIELD", "DUAL_WIELD", "1H", "RANGED" }

function LT:GetWeaponSetupDefinition(key)
    for _, setup in ipairs(LT.WeaponSetups) do
        if setup.key == key then return setup end
    end
    return nil
end

-- Inventory slot number for a weapon hand. Main hand 16 and off hand 17 are the
-- constants every client takes; the enum names are preferred only because they
-- document where the numbers come from. Unknown or missing input resolves to the
-- main hand, so a caller never passes nil to a client API.
function ClassData:WeaponSlot(which)
    local slots = type(Enum) == "table" and Enum.WeaponSlot
    if type(which) == "string" and which:upper() == "OFFHAND" then
        return (type(slots) == "table" and type(slots.OffHand) == "number"
            and slots.OffHand) or 17
    end
    return (type(slots) == "table" and type(slots.MainHand) == "number"
        and slots.MainHand) or 16
end

------------------------------------------------------------------------------
-- Classes
--
-- Each class carries two weight sets:
--   weights      one table per role; the role-level starting point, shipped as
--                a base profile with spec = "Any".
--   specWeights  [spec][role] weights, one entry per spec in `specs` and every
--                role that spec can perform. Each table is derived from the
--                class's role table above and adjusted for the spec, and every
--                number in it is provisional.
-- A stat key used in specWeights must already appear in this file's role
-- weights or hand-written profiles; the guard after the bundled profiles
-- refuses anything else, because the scorer would silently ignore it.
--
-- Stat RELEVANCE — which stats a build may weight at all — is enforced by
-- ClassData.weightRelevance, defined beside AuditClassData below. That audit
-- reports a base profile that weights a stat its build should ignore instead
-- of letting the number ship silently.
------------------------------------------------------------------------------

ClassData.classes = {
    WARRIOR = {
        name = "Warrior",
        roles = { "Damage", "Tank" },
        specs = { "Arms", "Fury", "Protection" },
        defaultRole = "Damage",
        -- A level-1 Warrior is handed a one-handed sword and a shield; a
        -- two-hander is a weapon-master purchase, not the starting kit. The
        -- slot starts on what the character can actually hold, and
        -- Builds:DeriveWeaponSetup still corrects it from the worn weapon at
        -- first login. The Arms/Fury starters keep their own 2H setup.
        defaultSetup = "1H_SHIELD",
        options = {
            { key = "stance", label = "Preferred stance", values = { "Battle", "Defensive", "Berserker" } },
            { key = "weaponStyle", label = "Weapon style", values = { "2H", "1H + shield", "Dual wield" } },
        },
        weights = {
            Damage = { strength = 1.00, agility = 0.35, stamina = 0.35, attackPower = 0.55, hit = 1.00, crit = 0.75, weaponDPS = 1.20 },
            Tank   = { strength = 0.75, agility = 0.25, stamina = 1.00, armor = 0.035, defense = 1.50, dodge = 1.15, parry = 1.15, block = 1.00, hit = 0.90, weaponDPS = 0.85 },
        },
        specWeights = {
            -- Two-handed swings: weapon damage and armour penetration carry Arms.
            Arms = {
                Damage = {
                    -- 2026-11-04: Two-Handed Weapon Specialization 1/2/3% -> 2/4/6%
                    -- and Flurry now 10/20/30% in three points; Slam's cooldown is
                    -- 15 s (was 18).
                    strength = 1.00, agility = 0.30, stamina = 0.35, attackPower = 0.55,
                    hit = 1.00, crit = 0.90, expertise = 0.55, armorPen = 0.45,
                    weaponDPS = 1.30, weaponAvgDamage = 0.80, weaponSpeed = 0.10,
                },
            },
            -- Dual wield: more swings, so hit and crit lead and average damage matters less.
            Fury = {
                Damage = {
                    strength = 1.00, agility = 0.35, stamina = 0.35, attackPower = 0.60,
                    hit = 1.05, crit = 0.90, expertise = 0.40, armorPen = 0.30,
                    weaponDPS = 1.15, weaponAvgDamage = 0.50,
                },
            },
            Protection = {
                Tank = {
                    strength = 0.75, agility = 0.25, stamina = 1.10, armor = 0.035,
                    defense = 1.60, dodge = 1.15, parry = 1.20, block = 1.10,
                    blockValue = 0.90, hit = 0.90, expertise = 0.50, weaponDPS = 0.85,
                },
            },
        },
    },

    PALADIN = {
        name = "Paladin",
        roles = { "Damage", "Tank", "Healer" },
        specs = { "Holy", "Protection", "Retribution" },
        defaultRole = "Damage",
        defaultSetup = "2H",
        options = {
            { key = "seal", label = "Preferred seal", values = { "Auto", "Command", "Righteousness", "Wisdom" } },
            { key = "weaponStyle", label = "Weapon style", values = { "2H", "1H + shield" } },
        },
        weights = {
            Damage = { strength = 1.00, stamina = 0.35, intellect = 0.15, attackPower = 0.50, hit = 1.00, crit = 0.70, weaponDPS = 1.15 },
            Tank   = { strength = 0.70, stamina = 1.00, armor = 0.04, defense = 1.60, dodge = 1.10, parry = 1.10, block = 1.00, blockValue = 0.85, hit = 0.85, weaponDPS = 0.80 },
            Healer = { intellect = 1.00, spirit = 0.75, stamina = 0.35, spellPower = 1.00, mp5 = 0.75, spellCrit = 0.45 },
        },
        specWeights = {
            -- Holy leans on spirit and sustained mana, and spell crit for Illumination-style returns.
            Holy = {
                Healer = {
                    intellect = 1.00, spirit = 0.90, stamina = 0.35, spellPower = 1.00,
                    mp5 = 0.90, spellCrit = 0.55,
                },
            },
            -- Shield tanking: block value matters, and spell power contributes to threat.
            Protection = {
                Tank = {
                    strength = 0.70, stamina = 1.10, armor = 0.04, defense = 1.70,
                    dodge = 1.10, parry = 1.20, block = 1.10, blockValue = 0.95,
                    hit = 0.85, expertise = 0.60, weaponDPS = 0.80, spellPower = 0.15,
                },
            },
            -- Two-handed seal damage: crit and weapon swings over sustained mana.
            Retribution = {
                Damage = {
                    strength = 1.00, stamina = 0.40, intellect = 0.10, attackPower = 0.55,
                    hit = 1.00, crit = 0.85, expertise = 0.50, weaponDPS = 1.20,
                    spellPower = 0.10,
                },
            },
        },
    },

    HUNTER = {
        name = "Hunter",
        roles = { "Damage" },
        specs = { "Beast Mastery", "Marksmanship", "Survival" },
        defaultRole = "Damage",
        defaultSetup = "RANGED",
        options = {
            { key = "ammo", label = "Ammo preference", values = { "Highest available", "Fast", "Slow" } },
            { key = "weaponStyle", label = "Weapon style", values = { "Bow", "Gun", "Crossbow" } },
        },
        weights = {
            -- 2026-11-04 launch notes: Aimed Shot +110%, Arcane Shot's AP coefficient
            -- 0.10 -> 0.15, Serpent Sting 3% -> 5% AP per tick, Aspect of the Hawk and
            -- Trueshot Aura restored to their posted ranged AP, Lightning Reflexes
            -- +15% Agility (was 10%). Agility, attack power and crit all rise; the
            -- 3 November hotfix is what puts Hawk and Trueshot back.
            Damage = { agility = 1.10, stamina = 0.30, attackPower = 0.80, hit = 1.00, crit = 0.85, weaponDPS = 1.10 },
        },
        specWeights = {
            -- The pet scales from attack power and stamina as much as from the hunter's own crit.
            ["Beast Mastery"] = {
                Damage = {
                    agility = 1.05, stamina = 0.35, attackPower = 0.85, hit = 1.00,
                    crit = 0.75, weaponDPS = 1.05,
                },
            },
            -- Aimed and Multi-Shot: weapon damage and armour penetration lead.
            Marksmanship = {
                Damage = {
                    agility = 1.10, stamina = 0.30, attackPower = 0.80, hit = 1.05,
                    crit = 0.90, armorPen = 0.40, weaponDPS = 1.20, weaponAvgDamage = 0.60,
                },
            },
            -- Survival trades some weapon emphasis for agility, stamina and crit.
            Survival = {
                Damage = {
                    agility = 1.20, stamina = 0.40, attackPower = 0.75, hit = 1.00,
                    crit = 0.85, armorPen = 0.25, weaponDPS = 1.05,
                },
            },
        },
    },

    ROGUE = {
        name = "Rogue",
        roles = { "Damage" },
        specs = { "Assassination", "Combat", "Subtlety" },
        defaultRole = "Damage",
        defaultSetup = "DUAL_WIELD",
        options = {
            { key = "mainHandPoison", label = "Main-hand poison", values = { "Instant", "Deadly", "Wound", "Crippling" } },
            { key = "offHandPoison", label = "Off-hand poison", values = { "Instant", "Deadly", "Wound", "Crippling", "Mind-numbing" } },
            { key = "weaponStyle", label = "Weapon style", values = { "Daggers", "Swords", "Fists", "Maces" } },
        },
        weights = {
            -- 2026-11-04 launch notes: Deadly Poison's AP coefficient 0.0045 -> 0.009 and
            -- Instant Poison's 0.005 -> 0.01 - poisons double their attack-power
            -- scaling, so AP rises for every rogue build. Shank (level 24) strikes
            -- with the off-hand, cannot miss, and the trees moved.
            Damage = { agility = 1.00, strength = 0.40, stamina = 0.25, attackPower = 0.80, hit = 1.00, crit = 0.80, weaponDPS = 1.10, weaponAvgDamage = 0.55 },
        },
        specWeights = {
            -- Daggers and poison: hit and crit first, weapon speed is the off-hand's business.
            Assassination = {
                Damage = {
                    agility = 1.05, strength = 0.40, stamina = 0.25, attackPower = 0.80,
                    hit = 1.00, crit = 0.85, expertise = 0.45, armorPen = 0.35,
                    weaponDPS = 1.10, weaponAvgDamage = 0.65,
                },
            },
            -- Swords or fists with Combat Potency: weapon DPS and expertise over crit.
            Combat = {
                Damage = {
                    agility = 1.00, strength = 0.40, stamina = 0.25, attackPower = 0.80,
                    hit = 1.00, crit = 0.75, expertise = 0.45, armorPen = 0.30,
                    weaponDPS = 1.25, weaponAvgDamage = 0.65,
                },
            },
            -- Burst from stealth: agility and crit, with less need for sustained hit.
            Subtlety = {
                Damage = {
                    agility = 1.10, strength = 0.40, stamina = 0.25, attackPower = 0.85,
                    hit = 0.95, crit = 0.85, expertise = 0.30, armorPen = 0.30,
                    weaponDPS = 1.05, weaponAvgDamage = 0.55,
                },
            },
        },
    },

    PRIEST = {
        name = "Priest",
        roles = { "Damage", "Healer" },
        specs = { "Discipline", "Holy", "Shadow" },
        defaultRole = "Healer",
        defaultSetup = "1H",
        options = {
            { key = "healingStyle", label = "Healing style", values = { "Mana", "Throughput", "Balanced" } },
        },
        weights = {
            Damage = { intellect = 0.90, spirit = 0.65, stamina = 0.30, spellPower = 1.00, spellCrit = 0.55, mp5 = 0.65 },
            Healer = { intellect = 1.00, spirit = 0.85, stamina = 0.30, spellPower = 1.00, spellCrit = 0.40, mp5 = 0.80 },
        },
        specWeights = {
            -- Discipline: mana return and spell crit before raw spirit.
            Discipline = {
                Healer = {
                    intellect = 1.00, spirit = 0.70, stamina = 0.30, spellPower = 1.00,
                    spellCrit = 0.55, mp5 = 0.95,
                },
            },
            -- Holy: the deepest spirit stack and the cheapest sustained healing.
            Holy = {
                Healer = {
                    intellect = 1.00, spirit = 0.95, stamina = 0.30, spellPower = 1.00,
                    spellCrit = 0.35, mp5 = 0.85,
                },
            },
            -- Shadow: spell hit is the damage stat, spirit is only mana.
            Shadow = {
                Damage = {
                    intellect = 0.90, spirit = 0.55, stamina = 0.30, spellPower = 1.05,
                    spellHit = 1.05, spellCrit = 0.60, mp5 = 0.45,
                },
            },
        },
    },

    SHAMAN = {
        name = "Shaman",
        roles = { "Damage", "Tank", "Healer" },
        specs = { "Elemental", "Enhancement", "Restoration" },
        defaultRole = "Damage",
        -- At level 1 a Shaman holds a one-handed weapon and no two-hander: the
        -- 2H axe is a weapon-master purchase and the quest rewards come at
        -- 10-20. The class is shield-capable from the start (the pack's usable
        -- table gates no shield by level), the Enhancement 2H starter is still
        -- one row away on the Builds page, and the language's levelling route
        -- (Enhancement) is what the introduction's direction page picks.
        defaultSetup = "1H_SHIELD",
        options = {
            { key = "weaponImbueMain", label = "Main-hand imbue", values = { "Windfury", "Flametongue", "Rockbiter", "Frostbrand", "None" } },
            { key = "weaponImbueOff", label = "Off-hand imbue", values = { "Windfury", "Flametongue", "Rockbiter", "Frostbrand", "None" } },
            { key = "shieldUse", label = "Shield use", values = { "Only for tanking", "Always when one-handed", "Never" } },
        },
        -- Enhancement tanking and two-handed Windfury PvP are this addon's
        -- first two shipped configurations, so they carry fuller notes.
        weights = {
            Damage = { strength = 0.90, agility = 0.35, stamina = 0.30, attackPower = 0.65, hit = 1.00, crit = 0.70, weaponDPS = 1.15, weaponAvgDamage = 0.70 },
            Healer = { intellect = 1.00, spirit = 0.70, stamina = 0.30, spellPower = 1.00, spellCrit = 0.45, mp5 = 0.75 },
        },
        -- The class has no role-level Tank table on purpose: only Enhancement
        -- tanking is a shipped configuration, and inventing a shaman_tank_*
        -- role profile would take the fallback away from the hand-written
        -- Enhancement Tank PvE profile below. The Tank weights live here.
        specWeights = {
            -- Elemental: a caster in the Damage role, so the melee Damage table
            -- above is not the base; the caster channels are.
            Elemental = {
                -- 2026-11-04 launch notes: Lightning Bolt's max rank base damage is up
                -- 80%, Lightning Overload is 10/20/30% (was 3/7/10%), Call of Thunder
                -- replaces Lava Burst with +5% crit for Lightning Bolt/Chain Lightning,
                -- and Chain Lightning costs ~225% of a Lightning Bolt's mana - so spell
                -- power, crit and mana per five all rise together.
                Damage = {
                    intellect = 0.85, stamina = 0.30, spirit = 0.25, spellPower = 1.10,
                    spellHit = 1.00, spellCrit = 0.85, mp5 = 0.50,
                },
            },
            -- Enhancement: melee swings plus shock damage, tanking on Rockbiter.
            Enhancement = {
                -- 2026-11-04 launch notes: Mental Dexterity now converts Intellect to
                -- Attack Power at 50/100/150% (was 33/67/100%), so Intellect stops
                -- being dead weight here. One Int is 1.5 AP at three points, minus
                -- the crit and mana it does not carry, which puts it above the
                -- attackPower weight and below strength.
                -- Stormstrike is 150% weapon damage on a 6 s cooldown (was 100%/8 s),
                -- Maelstrom Weapon's trigger chance doubled and Flurry is 6-30%:
                -- weaponDPS, crit and haste all rise.
                Damage = {
                    strength = 0.95, agility = 0.40, stamina = 0.35, intellect = 0.85,
                    attackPower = 0.75, hit = 1.00, crit = 0.85, haste = 0.40,
                    expertise = 0.40, armorPen = 0.25,
                    weaponDPS = 1.30, weaponAvgDamage = 0.80, spellPower = 0.10,
                },
                Tank = {
                    -- The same Int-to-AP conversion applies while tanking, but below
                    -- the attackPower weight: threat is not the tank's bottleneck.
                    stamina = 1.00, agility = 0.30, strength = 0.75, intellect = 0.30,
                    armor = 0.030, defense = 1.40, dodge = 1.10, parry = 1.00,
                    block = 1.00, blockValue = 0.80, hit = 0.90, expertise = 1.20,
                    crit = 0.45, attackPower = 0.50, weaponDPS = 0.85,
                    weaponAvgDamage = 0.40, spellPower = 0.10,
                },
            },
            Restoration = {
                Healer = {
                    intellect = 1.00, spirit = 0.85, stamina = 0.30, spellPower = 1.00,
                    spellCrit = 0.45, mp5 = 0.85,
                },
            },
        },
    },

    MAGE = {
        name = "Mage",
        roles = { "Damage" },
        specs = { "Arcane", "Fire", "Frost" },
        defaultRole = "Damage",
        -- A Mage starts with a staff, which the client reports as a two-handed
        -- weapon (INVTYPE_2HWEAPON); a slot on "1H" would score the off-hand it
        -- does not have and compare the staff against one-handers.
        -- Builds:DeriveWeaponSetup still replaces this with the worn weapon at
        -- first login, so a Mage who later wears one-hand and off-hand is
        -- corrected without touching this default.
        defaultSetup = "2H",
        options = {
            { key = "spellStyle", label = "Spell style", values = { "Frost", "Fire", "Arcane", "Balanced" } },
        },
        weights = {
            Damage = { intellect = 0.80, stamina = 0.25, spellPower = 1.00, spellHit = 1.00, spellCrit = 0.75, mp5 = 0.30 },
        },
        specWeights = {
            -- Arcane: hit first, then spell power; mana sustains the rotation.
            Arcane = {
                Damage = {
                    -- 2026-11-04: Arcane Focus (5 points of arcane hit) is gone, folded
                    -- into Precision (3 points, 2/4/6%); arcane mages need more hit
                    -- from gear, and Arcane Blast's per-stack spell damage is 12% of
                    -- Intellect (was 15%) on an 18 s timer.
                    intellect = 0.90, stamina = 0.25, spirit = 0.30, spellPower = 1.10,
                    spellHit = 1.10, spellCrit = 0.75, mp5 = 0.45,
                },
            },
            -- Fire: crit above spell hit, because the spec's damage is built on it.
            Fire = {
                Damage = {
                    intellect = 0.80, stamina = 0.25, spellPower = 1.05,
                    spellHit = 0.90, spellCrit = 0.95, mp5 = 0.25,
                },
            },
            -- Frost: the reverse — spell hit above crit, with more mana headroom.
            Frost = {
                Damage = {
                    intellect = 0.80, stamina = 0.25, spellPower = 1.00,
                    spellHit = 1.10, spellCrit = 0.75, mp5 = 0.35,
                },
            },
        },
    },

    WARLOCK = {
        name = "Warlock",
        roles = { "Damage" },
        specs = { "Affliction", "Demonology", "Destruction" },
        defaultRole = "Damage",
        defaultSetup = "1H",
        options = {
            { key = "petStyle", label = "Pet style", values = { "Demonology", "Damage", "Utility" } },
            { key = "spellStyle", label = "Spell style", values = { "Shadow", "Fire", "Balanced" } },
        },
        weights = {
            -- 2026-11-04 launch notes: Wrack's spell damage coefficient doubled (base at
            -- 60 is 36 -> 86 per second), Shadow and Flame 4/8/12/16/20%, and pets now
            -- gain 2 health per point of your Stamina instead of 7.5 - so spell power
            -- rises and the pet-related value of stamina falls.
            Damage = { intellect = 0.80, stamina = 0.35, spellPower = 1.05, spellHit = 1.00, spellCrit = 0.70, mp5 = 0.25 },
        },
        specWeights = {
            -- Affliction: spell hit and sustained damage over time. Note that
            -- shadow damage is not a channel the item scanner reports, so it
            -- cannot be weighted here; spell hit and spell power stand in.
            Affliction = {
                Damage = {
                    intellect = 0.80, stamina = 0.35, spirit = 0.35, spellPower = 1.05,
                    spellHit = 1.05, spellCrit = 0.55, mp5 = 0.45,
                },
            },
            -- Demonology: a sturdier warlock; stamina and spell power first.
            Demonology = {
                Damage = {
                    intellect = 0.85, stamina = 0.40, spellPower = 1.10,
                    spellHit = 0.95, spellCrit = 0.65, mp5 = 0.30,
                },
            },
            -- Destruction: crit above hit, on the back of shadow bolts and immolate.
            Destruction = {
                Damage = {
                    intellect = 0.80, stamina = 0.35, spellPower = 1.10,
                    spellHit = 0.95, spellCrit = 0.90, mp5 = 0.25,
                },
            },
        },
    },

    DRUID = {
        name = "Druid",
        roles = { "Damage", "Tank", "Healer" },
        specs = { "Balance", "Feral", "Restoration" },
        defaultRole = "Damage",
        defaultSetup = "2H",
        options = {
            { key = "form", label = "Preferred form", values = { "Cat", "Bear", "Caster", "Tree/Healer" } },
        },
        weights = {
            Damage = { agility = 1.00, strength = 0.35, stamina = 0.30, attackPower = 0.65, hit = 1.00, crit = 0.75, feralAttackPower = 0.75 },
            Tank   = { agility = 0.65, stamina = 1.00, armor = 0.045, defense = 0.80, dodge = 1.20, attackPower = 0.45, feralAttackPower = 0.45 },
            Healer = { intellect = 1.00, spirit = 0.85, stamina = 0.30, spellPower = 1.00, spellCrit = 0.40, mp5 = 0.80 },
        },
        specWeights = {
            -- Balance: a caster in the Damage role; spell hit and spell power lead.
            Balance = {
                Damage = {
                    intellect = 0.85, spirit = 0.30, stamina = 0.30, spellPower = 1.00,
                    spellHit = 1.00, spellCrit = 0.70, mp5 = 0.40,
                },
            },
            -- Feral is two shapes: the cat values agility, strength and crit, the
            -- bear stamina, armour and dodge. In both forms the weapon's damage
            -- becomes feral attack power, so these profiles weight
            -- feralAttackPower instead of weaponDPS/weaponAvgDamage.
            Feral = {
                Damage = {
                    -- 2026-11-04 launch notes: Shred 155% -> 200% weapon damage,
                    -- Claw 110% -> 140%, Ravage 350% -> 435%, and Rip/Rake/Ferocious
                    -- Bite/Pounce up ~25%; the weapon is converted to feral attack
                    -- power, so that channel and crit both rise.
                    agility = 1.00, strength = 0.50, stamina = 0.30, attackPower = 0.75,
                    hit = 1.00, crit = 0.90, feralAttackPower = 0.90,
                },
                Tank = {
                    agility = 0.70, stamina = 1.10, armor = 0.050, defense = 0.90,
                    dodge = 1.25, attackPower = 0.50, feralAttackPower = 0.55,
                    hit = 0.60, crit = 0.40,
                },
            },
            Restoration = {
                Healer = {
                    intellect = 1.00, spirit = 0.90, stamina = 0.30, spellPower = 1.00,
                    spellCrit = 0.40, mp5 = 0.85,
                },
            },
        },
    },
}

-- The roster as the client states it on 2026-10-29: the eight classic races plus
-- Skyborne in its two versions. Keys are the tokens UnitRace reports, matched
-- exactly; the dev notes name SkyborneAlliance and SkyborneHorde, and one
-- /dump UnitRace("player") on each version is still owed before those two keys
-- can be called confirmed.
--
-- Racial names follow the same notes. Three weapon specialisations were
-- replaced: Human Sword Specialization -> Ruthless, Dwarf Mace Specialization ->
-- Earth Fury, Orc Axe Specialization -> Savage. Only names are recorded here;
-- this table carries no numbers and no weight, so nothing here scores a racial.
-- Tauren Endurance is left as a name only: the notes describe it as 2% increased
-- critical damage and healing while an older premise said +5% maximum health,
-- and only an in-game tooltip settles which is current, so no effect is
-- restated and no adjustment is recorded anywhere in this file.
-- Wind Blessed's haste bonus cannot be expressed at all until haste has a
-- weight (see ClassData.unscoredStats below).
--
-- DRAENEI is retired, not shipped as a roster row: Draenei is not playable in
-- this game. The key stays so an older saved race token still resolves to a
-- name instead of reading "Unknown", and `retired` keeps it out of the roster.
ClassData.races = {
    HUMAN    = { name = "Human",    racials = { "Perception", "Ruthless", "Mace Specialization", "Diplomacy" } },
    DWARF    = { name = "Dwarf",    racials = { "Stoneform", "Earth Fury", "Gun Specialization", "Frost Resistance" } },
    NIGHTELF = { name = "Night Elf", racials = { "Shadowmeld", "Nature Resistance" } },
    GNOME    = { name = "Gnome",    racials = { "Escape Artist", "Arcane Resistance", "Engineering Specialization" } },
    ORC      = { name = "Orc",      racials = { "Blood Fury", "Savage", "Hardiness" } },
    UNDEAD   = { name = "Undead",   racials = { "Will of the Forsaken", "Cannibalize", "Shadow Resistance" } },
    TAUREN   = { name = "Tauren",   racials = { "War Stomp", "Endurance", "Nature Resistance" } },
    TROLL    = { name = "Troll",    racials = { "Berserking", "Regeneration", "Bow Specialization", "Throwing Specialization" } },
    SkyborneAlliance = {
        name = "High Order Skyborne",
        faction = "Alliance",
        classes = { "WARRIOR", "HUNTER", "ROGUE", "DRUID", "MAGE" },
        racials = { "Wind Blessed", "Read Ley Line", "Walk on Air", "Elemental Insight" },
    },
    SkyborneHorde = {
        name = "Windshaper Skyborne",
        faction = "Horde",
        classes = { "WARRIOR", "HUNTER", "ROGUE", "DRUID", "SHAMAN" },
        racials = { "Wind Blessed", "Skysight", "Walk on Air", "Elemental Insight" },
    },
    DRAENEI  = {
        name = "Draenei",
        retired = true,   -- not playable here; kept for saved race tokens only
        racials = { "Gift of the Naaru", "Heroic Presence", "Gemcutting" },
    },
}

-- The playable roster, in display order. `ClassData.races` keeps every key a
-- saved record might carry; this list is what a surface should offer.
ClassData.raceRoster = {
    "HUMAN", "DWARF", "NIGHTELF", "GNOME",
    "ORC", "UNDEAD", "TAUREN", "TROLL",
    "SkyborneAlliance", "SkyborneHorde",
}

------------------------------------------------------------------------------
-- Stats the client exposes but no weight prices yet
--
-- The player's decision (2026-10-29) is that haste keeps a zero weight until a
-- value is chosen per class and role. This table is the readable half of that:
-- a label and one help line, so a surface can say "not scored yet" instead of
-- silently showing zero. It is data only — no class table gains a weight key,
-- and nothing here may be multiplied into a score.
------------------------------------------------------------------------------

ClassData.unscoredStats = {
    haste = {
        label = "Haste Rating",
        note = "Read from items and converted per level, but no class table gives it "
            .. "a weight yet, so it scores zero. Not scored yet; the value is the "
            .. "player's decision.",
    },
    spellHaste = {
        label = "Spell Haste Rating",
        note = "Read from items and converted per level like Haste Rating, and worth "
            .. "zero for the same reason. Not scored yet; no weight is assumed.",
    },
}

-- nil for a stat that is scored, so a caller can test the answer directly.
function ClassData:GetUnscoredStat(statKey)
    return self.unscoredStats[statKey]
end

-- The playable roster as { token, name, faction, racials } records. Retired
-- keys are left out by construction: the list names what may be shown.
function ClassData:GetRaceRoster()
    local list = {}
    for _, token in ipairs(self.raceRoster) do
        local definition = self.races[token]
        if definition then
            table.insert(list, {
                token   = token,
                name    = definition.name,
                faction = definition.faction,
                racials = LT:Copy(definition.racials),
            })
        end
    end
    return list
end

function ClassData:GetClass(classToken)
    return self.classes[classToken or (LT.player and LT.player.class) or ""]
end

function ClassData:GetClassName(classToken)
    local definition = self:GetClass(classToken)
    return definition and definition.name or tostring(classToken or "Unknown")
end

function ClassData:GetRace(raceToken)
    local token = raceToken or (LT.player and LT.player.race) or ""
    if token == "" then return nil end

    local direct = self.races[token]
    if direct then return direct end

    -- Case-insensitive fallback: UnitRace reports mixed case ("Tauren") while
    -- the table keys mix styles ("TAUREN", "SkyborneAlliance"), so a direct
    -- lookup misses the uppercase ones. Match on lowercase instead.
    local lower = token:lower()
    for key, entry in pairs(self.races) do
        if key:lower() == lower then return entry end
    end

    return nil
end

------------------------------------------------------------------------------
-- Bundled base profiles
--
-- One entry per class / role / context combination. A base profile is read
-- only: editing a copy is the only way to change it, which is what keeps an
-- experimental tweak from rewriting the shipped starting point.
------------------------------------------------------------------------------

local baseProfiles = {}
local baseProfileKeys = {}

local function addBase(definition)
    if baseProfileKeys[definition.key] then
        LT:Warn("ClassData: duplicate base profile key \"" .. tostring(definition.key)
            .. "\"; the later entry was dropped.")
        return false
    end
    baseProfileKeys[definition.key] = true
    provisionalProfile(definition)
    table.insert(baseProfiles, definition)
    return true
end

-- Generic class starting points, derived from the class weight table above.
for classToken, definition in pairs(ClassData.classes) do
    for role, weights in pairs(definition.weights or {}) do
        for _, context in ipairs({ "PVE", "PVP" }) do
            addBase({
                key = string.lower(classToken) .. "_" .. string.lower(role) .. "_" .. string.lower(context),
                name = definition.name .. " — " .. role .. " (" .. context .. ")",
                class = classToken,
                spec = "Any",
                role = role,
                context = context,
                weights = LT:Copy(weights),
                assumptions = "Generic starting weights carried over from the addon's "
                    .. "class table. Not validated against Forever's combat maths, and "
                    .. "not adjusted for any specific specialisation.",
            })
        end
    end
end

------------------------------------------------------------------------------
-- BuffMonitor definitions (Decision 1; the data moved into the class packs)
--
-- Every reminder is declared once, in Classes\<Class>.lua, and
-- ClassData:RegisterBuffDefs() builds the BuffMonitor definition from it. This
-- file keeps the two things a pack cannot express: the aura scan the generic
-- check uses, and the one reader that is not an aura at all (the Shaman
-- main-hand imbue is a weapon enchant).
------------------------------------------------------------------------------

-- A name resolved by GetSpellInfo only proves the client has spell data for it,
-- never that the character learned it; a level-12 Warrior can resolve Battle
-- Shout that way. So the display name is cached for messages only, and the
-- learned state comes from IsPlayerSpell alone.
local spellNameCache = {}

local function spellDisplayName(name)
    if type(name) ~= "string" then return nil end
    local cached = spellNameCache[name]
    if cached ~= nil then return cached end

    local getInfo = (type(C_Spell) == "table" and C_Spell.GetSpellInfo) or GetSpellInfo
    if type(getInfo) == "function" then
        local ok, info = pcall(getInfo, name)
        local resolved
        if ok then
            if type(info) == "table" then resolved = info.name
            elseif type(info) == "string" then resolved = info end
        end
        if type(resolved) == "string" and resolved ~= "" then
            spellNameCache[name] = resolved
            return resolved
        end
    end
    return nil
end

-- True when IsPlayerSpell confirms one of the ids, false when the ids were
-- checked and none is known, nil when the answer cannot be verified. An
-- unverifiable gate must not suppress a reminder, so a missing IsPlayerSpell
-- answers nil rather than guessing from names.
local function knowsAnySpell(names, ids)
    for _, name in ipairs(names or {}) do spellDisplayName(name) end

    if type(IsPlayerSpell) ~= "function" then return nil end

    local canTell = false
    for _, id in ipairs(ids or {}) do
        if type(id) == "number" then
            canTell = true
            local ok, known = pcall(IsPlayerSpell, id)
            if ok and known == true then return true end
        end
    end
    if not canTell then return nil end
    return false
end

-- Scans the player's helpful auras for a name the matcher accepts.
-- Prefers C_UnitAuras (modern clients), falls back to UnitBuff.
-- UnitBuff returns: name, icon, count, debuffType, duration, expirationTime, source, ...
-- Returns nil when no usable aura API exists, so BuffMonitor treats the state as
-- "unknown" instead of raising a false "missing" warning.
-- The player spellbook, name -> true. A reminder for an ability the character
-- has not learned must not fire: a level-12 Warrior without Battle Shout is the
-- clearest case. MoP also lists unlearned abilities as grey FUTURESPELL slots,
-- so only SPELL slots count as learned. An empty or unreadable spellbook returns
-- count=0, which the caller treats as "unknown", never as "knows nothing".
local spellbookCache, spellbookAt

local function learnedBookType(kind)
    if type(kind) == "string" then return kind:upper() == "SPELL" end
    if type(kind) == "number" then
        local spellType = type(Enum) == "table" and type(Enum.SpellBookItemType) == "table"
            and Enum.SpellBookItemType.Spell
        return kind == (spellType or 1)
    end
    return false
end

local function knownById(id)
    if type(id) ~= "number" then return nil end
    if type(IsPlayerSpell) == "function" then
        local ok, known = pcall(IsPlayerSpell, id)
        if ok and type(known) == "boolean" then return known end
    end
    if type(C_SpellBook) == "table" and type(C_SpellBook.IsSpellKnown) == "function" then
        local ok, known = pcall(C_SpellBook.IsSpellKnown, id)
        if ok and type(known) == "boolean" then return known end
    end
    if type(IsSpellKnown) == "function" then
        local ok, known = pcall(IsSpellKnown, id)
        if ok and type(known) == "boolean" then return known end
    end
    return nil
end

local function spellbookSnapshot()
    if spellbookCache and type(GetTime) == "function" then
        local now = GetTime()
        if now - (spellbookAt or 0) < 5 then return spellbookCache end
    elseif spellbookCache then
        return spellbookCache
    end

    local names, count = {}, 0
    local function add(name)
        if type(name) == "string" and name ~= "" and not names[name] then
            names[name] = true
            count = count + 1
        end
    end

    local usedInfo = false
    if type(C_SpellBook) == "table" and type(C_SpellBook.GetSpellBookItemInfo) == "function" then
        local bank = (type(Enum) == "table" and type(Enum.SpellBookSpellBank) == "table"
            and Enum.SpellBookSpellBank.Player) or 0
        for i = 1, 300 do
            local ok, info = pcall(C_SpellBook.GetSpellBookItemInfo, i, bank)
            if not ok or type(info) ~= "table" then break end
            usedInfo = true
            local known = knownById(info.spellID or info.actionID)
            if learnedBookType(info.itemType) and known ~= false then
                local name = info.name
                if type(name) ~= "string" and type(C_SpellBook.GetSpellBookItemName) == "function" then
                    local okName, bookName = pcall(C_SpellBook.GetSpellBookItemName, i, bank)
                    if okName then name = bookName end
                end
                add(name)
            end
        end
    end

    if not usedInfo and type(GetSpellBookItemInfo) == "function"
        and type(GetSpellBookItemName) == "function"
        and type(GetNumSpellTabs) == "function" and type(GetSpellTabInfo) == "function" then
        local okTabs, tabs = pcall(GetNumSpellTabs)
        if okTabs and type(tabs) == "number" then
            for tab = 1, tabs do
                local okTab, _, _, offset, numSpells = pcall(GetSpellTabInfo, tab)
                if okTab and type(offset) == "number" and type(numSpells) == "number" then
                    for i = offset + 1, offset + numSpells do
                        local okInfo, spellType, spellId = pcall(GetSpellBookItemInfo, i, BOOKTYPE_SPELL or "spell")
                        if okInfo and learnedBookType(spellType) and knownById(spellId) ~= false then
                            local okName, name = pcall(GetSpellBookItemName, i, BOOKTYPE_SPELL or "spell")
                            if okName then add(name) end
                        end
                    end
                end
            end
        end
    end

    spellbookCache = { names = names, count = count }
    if type(GetTime) == "function" then spellbookAt = GetTime() end
    return spellbookCache
end

function ClassData:IsLearnedBookType(kind)
    return learnedBookType(kind)
end

function ClassData:KnowsSpellName(pattern)
    local snapshot = spellbookSnapshot()
    if not snapshot or snapshot.count == 0 then return nil end
    for name in pairs(snapshot.names) do
        if name:find(pattern, 1, true) then return true end
    end
    return false
end

local function scanPlayerBuffs(matcher)
    local function found(expiry)
        local timeLeft
        local expires = LT:Number(expiry)
        local now
        if type(GetTime) == "function" then
            local okNow, value = pcall(GetTime)
            now = okNow and LT:Number(value) or nil
        end
        -- Subtract only from two real numbers: a secret or unreadable timestamp
        -- leaves timeLeft unknown instead of producing a bogus value.
        if expires and now and expires > 0 then
            timeLeft = math.max(0, math.floor((expires - now) * 1000))
        end
        return { active = true, timeLeft = timeLeft, precise = true }
    end

    if type(C_UnitAuras) == "table" and type(C_UnitAuras.GetAuraDataByIndex) == "function" then
        local usable = false
        for i = 1, 40 do
            local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
            if not ok then break end
            usable = true
            if type(aura) ~= "table" then break end
            local name = aura.name
            if type(name) == "string" and not LT:IsSecret(name) and matcher(name) then
                return found(aura.expirationTime)
            end
        end
        if usable then return { active = false } end
    end

    if type(UnitBuff) == "function" then
        local usable = false
        for i = 1, 40 do
            local ok, name, _, _, _, _, expiry = pcall(UnitBuff, "player", i)
            if not ok then break end
            usable = true
            if not name then break end
            if type(name) == "string" and not LT:IsSecret(name) and matcher(name) then
                return found(expiry)
            end
        end
        if usable then return { active = false } end
    end

    return nil
end

-- The Shaman main-hand imbue is a weapon enchant, not an aura, so it keeps its
-- own reader. The pack owns the entry's label, key, message and default; the
-- names below are what the client is asked about, never a copy of that data.
ClassData.ImbueSpellNames = {
    "Rockbiter Weapon", "Flametongue Weapon", "Frostbrand Weapon", "Windfury Weapon",
}

function ClassData.MainHandImbueCheck()
    if type(C_Item) == "table" and type(C_Item.GetWeaponEnchantInfo) == "function" then
        local slot = (type(Enum) == "table" and type(Enum.WeaponSlot) == "table"
            and Enum.WeaponSlot.MainHand) or 0
        local ok, result = pcall(C_Item.GetWeaponEnchantInfo, slot)
        if ok and type(result) == "table" then
            local records = (result.hasEnchant ~= nil or result.enchantType ~= nil)
                and { result } or result
            local imbueType = (type(Enum) == "table" and type(Enum.ItemEnchantType) == "table"
                and Enum.ItemEnchantType.Imbue) or 3
            for _, e in pairs(records) do
                if type(e) == "table" and e.hasEnchant and e.enchantType == imbueType then
                    return { active = true, timeLeft = tonumber(e.timeLeft), precise = true }
                end
            end
            return { active = false }
        end
    end
    if type(GetWeaponEnchantInfo) == "function" then
        local ok2, hasMain = pcall(GetWeaponEnchantInfo)
        if ok2 and hasMain then
            -- Legacy expiry is unreliable (seconds-vs-milliseconds, and a wrong
            -- value was turning a fresh imbue into an "expiring" warning), so
            -- report presence only. The modern C_Item path above carries the
            -- real timeLeft when this client exposes it.
            return { active = true, timeLeft = nil, precise = false }
        end
    end
    return { active = false }
end

------------------------------------------------------------------------------
-- Hunter and Warlock readers (2026-10-29 suggestions, sections 6 and 7)
--
-- Every one of these is a read of client state plus a decision. The decision is
-- kept in ClassData.buffRules as a plain function of the values that were read,
-- so it can be exercised offline; the reader is only the pcall'd boundary. A
-- reader returns nil when the client cannot answer, which BuffMonitor reports
-- as "unknown" and never as a warning. A check that does not apply to the
-- character returns { active = true }.
--
-- None of these touches an item: nothing is equipped, moved, bought or sold.
------------------------------------------------------------------------------

-- Slot numbers this client uses: 0 is the ammo slot, 18 the ranged weapon.
local AMMO_SLOT   = 0
local RANGED_SLOT = 18
local AMMO_LOW_THRESHOLD = 200
local SOUL_SHARD_ITEM_ID = 6265

-- Demonic Sacrifice: the aura name is the one the notes do not give. "Demonic
-- Sacrifice" is the talent's name and the best guess this file can make; one
-- in-game aura read settles it, and the reminder ships off by default so a
-- wrong guess is silent until the player turns it on.
local SACRIFICE_AURA_NAME = "Demonic Sacrifice"
local SACRIFICE_SUPPRESS_MS = 120 * 1000

-- A number from the client that is fit to compare: not nil, not a string and not
-- a secret value, because arithmetic on one of those is either wrong or an error
-- on a client that hides it.
local function safeNumber(value)
    if type(value) ~= "number" then return nil end
    if LT:IsSecret(value) then return nil end
    return value
end

local function playerItemLink(slot)
    if type(GetInventoryItemLink) ~= "function" then return nil end
    local ok, link = pcall(GetInventoryItemLink, "player", slot)
    if not ok or type(link) ~= "string" or link == "" then return nil end
    if LT:IsSecret(link) then return nil end
    return link
end

local function itemIDFromLink(link)
    if type(link) ~= "string" or LT:IsSecret(link) then return nil end
    return tonumber(string.match(link, "item:(%d+)"))
end

-- The item's subclass string ("Bows", "Guns", "Arrow", ...), lower-cased.
-- GetItemInfo can return nil until the client has cached the item, so nil here
-- means "not known yet", never "not that kind".
local function itemSubclass(link)
    if type(link) ~= "string" then return nil end
    local getInfo
    if type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function" then
        getInfo = C_Item.GetItemInfo
    elseif type(GetItemInfo) == "function" then
        getInfo = GetItemInfo
    end
    if not getInfo then return nil end

    local ok, name, _, _, _, _, _, subclass = pcall(getInfo, link)
    if not ok or type(subclass) ~= "string" or subclass == "" then return nil end
    if LT:IsSecret(subclass) then return nil end
    return string.lower(subclass)
end

-- The kind of ammo a ranged weapon needs: "arrow", "bullet", "thrown" (its own
-- stack, so no ammo slot exists) or nil when the subclass is not recognised.
-- Lower-cased substring tests, because the exact strings on this client are
-- unmeasured and case is not worth trusting.
local function rangedAmmoKind(subclass)
    if type(subclass) ~= "string" then return nil end
    if string.find(subclass, "thrown", 1, true) then return "thrown" end
    if string.find(subclass, "crossbow", 1, true) then return "arrow" end
    if string.find(subclass, "bow", 1, true) then return "arrow" end
    if string.find(subclass, "gun", 1, true) then return "bullet" end
    return nil
end

local function projectileKind(subclass)
    if type(subclass) ~= "string" then return nil end
    if string.find(subclass, "arrow", 1, true) then return "arrow" end
    if string.find(subclass, "bullet", 1, true) then return "bullet" end
    return nil
end

local function itemCountByID(itemID)
    itemID = safeNumber(itemID)
    if not itemID then return nil end

    if type(C_Item) == "table" and type(C_Item.GetItemCount) == "function" then
        local ok, count = pcall(C_Item.GetItemCount, itemID)
        count = ok and safeNumber(count) or nil
        if count then return count end
    end
    if type(GetItemCount) == "function" then
        local ok, count = pcall(GetItemCount, itemID)
        count = ok and safeNumber(count) or nil
        if count then return count end
    end
    return nil
end

-- Ammo in the ammo slot. GetInventoryItemCount is the direct read; the item
-- count of the slotted ammo is the fallback for a client without it. Both are
-- pcall'd, and neither has been proven on this client.
local function ammoSlotCount()
    -- An empty or removed ammo slot is zero ammo. GetInventoryItemCount has
    -- answered 1 (and other nonsense) for slot 0 on 5.5, so the link decides.
    local link = playerItemLink(AMMO_SLOT)
    if link == nil then return 0 end

    if type(GetInventoryItemCount) == "function" then
        local ok, count = pcall(GetInventoryItemCount, "player", AMMO_SLOT)
        count = ok and safeNumber(count) or nil
        if count then return count end
    end
    return itemCountByID(itemIDFromLink(playerItemLink(AMMO_SLOT)))
end

local function ammoSlotPresent()
    if type(GetInventorySlotInfo) ~= "function" then return nil end
    local ok, slot = pcall(GetInventorySlotInfo, "AmmoSlot")
    if not ok then return nil end
    return type(slot) == "number"
end

function ClassData:HasAmmoSlot()
    return ammoSlotPresent()
end

local function unitExists(unit)
    if type(UnitExists) ~= "function" then return nil end
    local ok, exists = pcall(UnitExists, unit)
    if not ok then return nil end
    if exists == true then return true end
    if exists == false then return false end
    return nil
end

local function unitIsDeadOrGhost(unit)
    if type(UnitIsDeadOrGhost) ~= "function" then return nil end
    local ok, dead = pcall(UnitIsDeadOrGhost, unit)
    if not ok then return nil end
    if dead == true then return true end
    if dead == false then return false end
    return nil
end

local function currentTime()
    if type(GetTime) ~= "function" then return nil end
    local ok, now = pcall(GetTime)
    return ok and safeNumber(now) or nil
end

local function playerInCombat()
    if type(UnitAffectingCombat) ~= "function" then return nil end
    local ok, inCombat = pcall(UnitAffectingCombat, "player")
    if not ok then return nil end
    if inCombat == true then return true end
    if inCombat == false then return false end
    return nil
end

-- First moment this session at which Demonic Sacrifice was seen, and whether
-- that sighting's window is spent. Module state on purpose: it is not saved, and
-- a reload simply starts a new window.
local sacrificeStartedAt
local sacrificeClosed = false

-- Best-effort suppression window. While the aura is seen, the window starts at
-- the first sighting and lasts at most SACRIFICE_SUPPRESS_MS; leaving combat
-- closes it at once, because that is when the demon is worth re-summoning. The
-- window is spent, not refreshed, while the aura stays on: a sacrifice 20
-- minutes old must not silence the reminder again the moment combat starts.
-- Returns 0 when nothing suppresses, and 0 when the aura scan is unavailable:
-- an unverifiable gate must not silence a real warning.
local function sacrificeSuppressionRemaining()
    local scan = scanPlayerBuffs(function(name)
        return string.find(name, SACRIFICE_AURA_NAME, 1, true) ~= nil
    end)
    if type(scan) ~= "table" then return 0 end

    local now = currentTime()
    if not now then return 0 end

    if not scan.active then
        sacrificeStartedAt, sacrificeClosed = nil, false
        return 0
    end
    if playerInCombat() == false then
        sacrificeStartedAt, sacrificeClosed = nil, true
        return 0
    end
    if sacrificeClosed then return 0 end

    -- GetTime counts seconds; the window is kept in milliseconds so it compares
    -- with BuffMonitor's own thresholds.
    local nowMs = now * 1000
    if not sacrificeStartedAt then sacrificeStartedAt = nowMs end

    local remaining = ClassData.buffRules.sacrificeRemaining(sacrificeStartedAt, nowMs, true)
    if remaining <= 0 then
        sacrificeStartedAt, sacrificeClosed = nil, true
        return 0
    end
    return remaining
end

local function hunterAmmoLowCheck()
    local weaponKind = rangedAmmoKind(itemSubclass(playerItemLink(RANGED_SLOT)))
    if weaponKind == nil then return nil end   -- no ranged weapon, or unreadable
    if weaponKind == "thrown" then return { active = true } end
    return ClassData.buffRules.ammoLow(ammoSlotCount())
end

local function hunterAmmoTypeCheck()
    local weaponKind = rangedAmmoKind(itemSubclass(playerItemLink(RANGED_SLOT)))
    if weaponKind == nil then return nil end
    if weaponKind == "thrown" then return { active = true } end

    local ammoKind = projectileKind(itemSubclass(playerItemLink(AMMO_SLOT)))
    if ammoKind == nil then return nil end   -- empty or unreadable ammo slot
    return ClassData.buffRules.ammoType(weaponKind, ammoKind)
end

local function warlockPetCheck()
    local exists = unitExists("pet")
    if exists == nil then return nil end

    local dead = unitIsDeadOrGhost("pet")
    if exists == true and dead ~= true then
        -- A demon is out, so any sacrifice window is over: a later death must
        -- warn, not inherit a window opened before the re-summon.
        sacrificeStartedAt, sacrificeClosed = nil, false
        return { active = true }
    end
    return ClassData.buffRules.warlockPet(exists, dead, sacrificeSuppressionRemaining())
end

local function warlockShardsCheck()
    return ClassData.buffRules.soulShards(itemCountByID(SOUL_SHARD_ITEM_ID))
end

------------------------------------------------------------------------------
-- Pure decisions for the checks above
--
-- Each takes the values a reader got and returns { active = true } when there
-- is nothing to report, { active = false, message = ... } when the reminder
-- should speak, or nil when the answer is not known. No client API is touched
-- here, so each one can be exercised outside the game. BuffMonitor currently
-- shows the pack's fixed message; the richer message here is returned as data
-- for a surface that can print the number.
------------------------------------------------------------------------------

ClassData.buffRules = {
    ammoLowThreshold = AMMO_LOW_THRESHOLD,
    soulShardItemID  = SOUL_SHARD_ITEM_ID,
    sacrificeSuppressMs = SACRIFICE_SUPPRESS_MS,
}

function ClassData.buffRules.ammoLow(count)
    if type(count) ~= "number" then return nil end
    if count >= AMMO_LOW_THRESHOLD then return { active = true } end
    if count <= 0 then
        return { active = false, message = "You have no ammo left." }
    end

    local number = math.floor(count)
    if number <= 20 then
        return { active = false, message = "You have " .. tostring(number)
            .. " rounds of ammo left — critically low." }
    end
    if number <= 100 then
        return { active = false, message = "You have " .. tostring(number)
            .. " rounds of ammo left — low." }
    end

    return { active = false, message = "You have " .. tostring(number)
        .. " rounds of ammo left (under " .. tostring(AMMO_LOW_THRESHOLD) .. ")." }
end

function ClassData.buffRules.ammoType(weaponKind, ammoKind)
    if weaponKind == "thrown" then return { active = true } end
    if weaponKind ~= "arrow" and weaponKind ~= "bullet" then return nil end
    if ammoKind ~= "arrow" and ammoKind ~= "bullet" then return nil end
    if weaponKind == ammoKind then return { active = true } end

    local needed = weaponKind == "arrow" and "arrows" or "bullets"
    local held   = ammoKind == "arrow" and "arrows" or "bullets"
    return { active = false,
        message = "Your ranged weapon needs " .. needed
            .. "; the ammo slot holds " .. held .. "." }
end

function ClassData.buffRules.warlockPet(exists, dead, suppressRemainingMs)
    if exists == nil then return nil end
    if exists == true and dead ~= true then return { active = true } end
    if type(suppressRemainingMs) == "number" and suppressRemainingMs > 0 then
        return { active = true }
    end
    if exists == true then
        return { active = false, message = "Your demon is dead." }
    end
    return { active = false, message = "No demon is summoned." }
end

function ClassData.buffRules.soulShards(count)
    if type(count) ~= "number" then return nil end
    if count >= 2 then return { active = true } end
    if count <= 0 then
        return { active = false, message = "You have no soul shards." }
    end
    return { active = false, message = "You have 1 soul shard." }
end

-- Milliseconds left in the window opened by a Demonic Sacrifice seen at
-- `startedAt`. An explicit false for inCombat ends it at once; an unknown
-- in-combat answer does not shorten it. At exactly two minutes it is zero, so
-- the warning returns then.
function ClassData.buffRules.sacrificeRemaining(startedAt, now, inCombat)
    if type(startedAt) ~= "number" or type(now) ~= "number" then return 0 end
    if inCombat == false then return 0 end
    local elapsed = now - startedAt
    if elapsed ~= elapsed or elapsed < 0 then return SACRIFICE_SUPPRESS_MS end
    return math.max(0, SACRIFICE_SUPPRESS_MS - elapsed)
end

-- Readers that cannot be expressed as an aura name, keyed by buff id. Everything
-- else is the generic check below, so there is one matcher and one registration
-- path.
-- Warrior stances are a shapeshift form on some clients, not a helpful aura;
-- the 5.5 retest said "no stance" while Battle Stance was up. Read both.
-- An aura entry is a Lua pattern, so "Seal of" keeps the shipped prefix rule and
-- a plain buff name such as "Inner Fire" is a substring match. One matcher, not
-- a second copy of the old per-class lambdas. Defined before warriorStanceCheck,
-- which calls it.
local function auraMatcher(patterns)
    local list = patterns or {}
    return function(name)
        for _, pattern in ipairs(list) do
            local ok, found = pcall(string.find, name, pattern)
            if ok and found then return true end
        end
        return false
    end
end

local function warriorStanceCheck()
    local state = scanPlayerBuffs(auraMatcher({
        "Battle Stance", "Defensive Stance", "Berserker Stance",
    }))
    if state and state.active then return state end

    -- On 5.5 the form-info return order differs and the name can be a boolean;
    -- the form index is the reliable answer. A Warrior in any form is in a
    -- stance: Battle (1), Defensive (2), Berserker (3); 0 is no stance.
    if type(GetShapeshiftForm) == "function" then
        local ok, form = pcall(GetShapeshiftForm)
        if ok and type(form) == "number" then
            if form > 0 then return { active = true, precise = true } end
            return { active = false }
        end
    end

    return state
end

local specialBuffs = {
    warrior_stance = {
        check = warriorStanceCheck,
        isAvailable = function()
            local unknown = false
            for _, name in ipairs({ "Battle Stance", "Defensive Stance", "Berserker Stance" }) do
                local known = ClassData:KnowsSpellName(name)
                if known == true then return true end
                if known == nil then unknown = true end
            end
            if unknown then return nil end
            return false
        end,
    },
    shaman_mainhand_imbue = {
        check = ClassData.MainHandImbueCheck,
        -- Not applicable until the character has learned at least one weapon
        -- imbue. The ids are the pack's, so a corrected id is one edit.
        isAvailable = function(entry)
            return knowsAnySpell(ClassData.ImbueSpellNames, entry.spells)
        end,
    },
    -- Hunter (2026-10-29 suggestions, section 6). No isAvailable gate: whether a
    -- check applies is part of the answer, because a thrown weapon makes the ammo
    -- checks inapplicable rather than satisfied, and the reader is the only thing
    -- that can tell.
    hunter_ammo_low = {
        check = hunterAmmoLowCheck,
        -- MoP and later removed the ammo slot; the check is not applicable.
        isAvailable = function() return ammoSlotPresent() end,
    },
    hunter_ammo_type = {
        check = hunterAmmoTypeCheck,
        isAvailable = function() return ammoSlotPresent() end,
    },
    -- Warlock (section 7). The pet check carries the best-effort Demonic
    -- Sacrifice suppression; the shard check is one bag count.
    warlock_pet = { check = warlockPetCheck },
    warlock_soul_shards = { check = warlockShardsCheck },
}

local function packBuffEntries()
    local entries = {}
    if not (LT.ClassPacks and type(LT.ClassPacks.GetOrder) == "function") then
        return entries
    end
    for _, classToken in ipairs(LT.ClassPacks:GetOrder()) do
        for _, entry in ipairs(LT.ClassPacks:GetBuffs(classToken)) do
            table.insert(entries, { classToken = classToken, entry = entry })
        end
    end
    return entries
end

-- One definition per pack entry. `message` is the "missing" line; the
-- "expiring" line is built from the label, because a pack carries one message.
local function buildBuffDefinition(entry, special)
    local check = special and special.check

    if not check then
        local auras = entry.auras or {}
        if #auras == 0 then
            -- Nothing this entry could look for: report "unknown" rather than a
            -- state it cannot support, so it can never warn from a guess.
            check = function() return nil end
        else
            local matcher = auraMatcher(auras)
            check = function() return scanPlayerBuffs(matcher) end
        end
    end

    local definition = {
        id                = entry.id,
        label             = entry.label,
        optionKey         = entry.optionKey,
        messages          = {
            missing  = entry.message,
            expiring = entry.label .. " is expiring in about {minutes} minute(s).",
        },
        expiringThreshold = entry.expiringThreshold,
        checkFn           = check,
        -- Documentation for the Debug page; BuffMonitor reads neither.
        help              = entry.help,
        default           = entry.default,
    }

    if special and special.isAvailable then
        definition.isAvailable = function() return special.isAvailable(entry) end
    elseif not special and type(entry.auras) == "table" and #entry.auras > 0 then
        -- A reminder for an ability the character has not learned must not
        -- fire. Match every aura name against the spellbook; one known name is
        -- enough, all positively unknown is unavailable, and an unreadable
        -- spellbook stays nil so the reminder is not silently disabled.
        definition.isAvailable = function()
            local unknown = false
            for _, auraName in ipairs(entry.auras) do
                local known = ClassData:KnowsSpellName(auraName)
                if known == true then return true end
                if known == nil then unknown = true end
            end
            if unknown then return nil end
            return false
        end
    end

    return definition
end

-- Registration key: "CLASSTOKEN|buffId". Keying by the buff id alone meant a
-- second class that reused an id was silently unregistrable; the class half
-- keeps every pack's own definition, and a second call is a no-op that returns
-- 0 and warns about nothing, so a repeated hook cannot produce noise.
local function registrationKey(classToken, id)
    return tostring(classToken) .. "|" .. tostring(id)
end

-- "CLASSTOKEN|buffId" -> class token for everything registered this session.
ClassData.buffRegistration = {}
-- buff id -> { ["FIRST|SECOND"] = true } for ids two classes both declare.
-- Recorded so each collision is warned once, however often registration runs.
ClassData.buffDuplicates = {}
-- True once the registration pass has actually run (Core calls it at
-- PLAYER_LOGIN). AuditClassData reports against this instead of registering.
ClassData.buffRegistrationRan = false

-- Cross-class collisions in a list of pack entries ({ classToken, entry }),
-- as { id, first, second } in pack order. One implementation decides what a
-- collision is: registration warns from it and the self test reads it, so the
-- two can never disagree about the same data.
function ClassData:FindBuffIdDuplicates(entries)
    if type(entries) ~= "table" then entries = packBuffEntries() end

    local findings, first = {}, {}
    for _, item in ipairs(entries) do
        local id = item.entry.id
        if first[id] == nil then
            first[id] = item.classToken
        elseif first[id] ~= item.classToken then
            table.insert(findings, { id = id, first = first[id], second = item.classToken })
        end
    end
    return findings
end

-- Reads the class packs and registers every declared buff. Returns the number
-- registered by this call. A missing BuffMonitor registers nothing and prints
-- nothing: the reminders are an optional surface.
--
-- A buff id two classes both declare is warned about by name and registered for
-- both: the collision is a data bug to fix, never a reason to drop a class's
-- definition on the floor.
function ClassData:RegisterBuffDefs()
    if type(LT.BuffMonitor) ~= "table" or type(LT.BuffMonitor.Register) ~= "function" then
        return 0
    end

    self.buffRegistration = self.buffRegistration or {}
    self.buffDuplicates = self.buffDuplicates or {}
    self.buffRegistrationRan = true

    for _, finding in ipairs(self:FindBuffIdDuplicates()) do
        local seen = self.buffDuplicates[finding.id]
        if not seen then
            seen = {}
            self.buffDuplicates[finding.id] = seen
        end

        local pair = finding.first .. "|" .. finding.second
        if not seen[pair] then
            seen[pair] = true
            LT:Warn("ClassData: buff id \"" .. tostring(finding.id) .. "\" is declared by "
                .. tostring(finding.first) .. " and " .. tostring(finding.second)
                .. "; both are registered, but the id should be unique")
        end
    end

    local registered = 0

    for _, item in ipairs(packBuffEntries()) do
        local entry = item.entry
        local key = registrationKey(item.classToken, entry.id)
        if not self.buffRegistration[key] then
            local definition = buildBuffDefinition(entry, specialBuffs[entry.id])
            if LT.BuffMonitor:Register(item.classToken, definition) then
                self.buffRegistration[key] = item.classToken
                registered = registered + 1
            end
        end
    end

    return registered
end

------------------------------------------------------------------------------
-- Class quirks (Decision 9)
--
-- A quirk explains a scoring distortion. One that an existing weight can carry
-- names that weight; one that would need a channel or a conversion this addon
-- does not have says so and is never scored. No quirk adds a weight key.
------------------------------------------------------------------------------

local function packQuirks(classToken)
    if not (LT.ClassPacks and type(LT.ClassPacks.GetQuirks) == "function") then
        return {}
    end
    return LT.ClassPacks:GetQuirks(classToken)
end

-- One readable line per quirk, for the Debug page. An empty list means the class
-- has no quirks (or no pack), never an error.
function ClassData:DescribeQuirks(classToken)
    local lines = {}

    for _, quirk in ipairs(packQuirks(classToken)) do
        local scope = quirk.spec and (" (" .. quirk.spec .. ")") or ""
        local verdict
        if quirk.stat then
            verdict = "valued through the existing " .. quirk.stat .. " weight"
        else
            verdict = "cannot be valued yet — " .. tostring(quirk.unvalued)
        end
        table.insert(lines, quirk.label .. scope .. ": " .. verdict .. ". " .. quirk.note)
    end

    return lines
end

-- Option keys that already defaulted on before the packs owned this data. Every
-- other buff must start off; anything else is a finding, not a preference.
local PRE_EXISTING_BUFF_ON = {
    shamanImbueReminder = true,
}

------------------------------------------------------------------------------
-- Weight relevance rules
--
-- The single place that decides whether a stat may appear in a base profile's
-- weights at all. A weight the scorer prices but the build should ignore is a
-- data bug, so AuditClassData walks every bundled profile against these rules
-- and reports the profile + stat rather than letting the number ship silently.
--
-- These are the WEIGHTS side only. The CAP side (which caps a build even
-- follows) is Caps:IsRelevant; rule 2 reuses Caps:ResolveChannels for the
-- caster/physical/tank split instead of re-deriving it. Read Caps.lua before
-- touching either side: the two gates must stay one each.
--
-- Each rule owns a set of stats and an `allowed(profile, stat, value)`
-- predicate. `profile` is a base profile ({ class, spec, role, context,
-- weights }). A falsy answer means the stat must not be weighted there.
------------------------------------------------------------------------------

-- Classes that can hold a shield; only their Tank builds keep block/blockValue.
local SHIELD_CLASSES = { WARRIOR = true, PALADIN = true, SHAMAN = true }

-- Hybrid specs that keep a SMALL spellPower for a seal (Paladin) or shock
-- (Shaman) while staying physical.
local HYBRID_SEAL_SPECS = {
    PALADIN = { Retribution = true, Protection = true },
    SHAMAN  = { Enhancement = true },
}
local HYBRID_SEAL_SPELLPOWER_MAX = 0.20

-- Hybrid specs that also keep a SMALL spellCrit. L-8 (T-129): an Enhancement
-- Shaman's shocks crit with spells, and the player's own profile ranks spell
-- crit high enough that the stat has to be storable. Capped like the seal
-- spellPower, so a physical profile cannot drift into being a caster one.
local HYBRID_SPELLCRIT_SPECS = {
    SHAMAN = { Enhancement = true },
}
local HYBRID_SPELLCRIT_MAX = 0.40

-- Caster/physical/tank resolution, reused from Caps so the weight gate and the
-- cap gate can never disagree. Returns nil when Caps is not loaded (an offline
-- caller); the predicates then answer "no opinion" and flag nothing.
local function weightChannels(profile)
    if type(LT.Caps) ~= "table" or type(LT.Caps.ResolveChannels) ~= "function" then
        return nil
    end
    local ok, channels = pcall(LT.Caps.ResolveChannels, LT.Caps, profile)
    if not ok or type(channels) ~= "table" then return nil end
    return channels
end

ClassData.weightRelevance = {
    {
        id = "block_requires_shield",
        label = "Block and block value need a shield",
        stats = { block = true, blockValue = true },
        reason = "it is not a shield tank (a 2H, dual-wield or druid-form tank has no shield to block with)",
        allowed = function(profile, stat, value)
            return profile.role == "Tank" and SHIELD_CLASSES[profile.class] == true
        end,
    },
    {
        id = "spell_caster_or_hybrid_seal",
        label = "Spell power and spell crit are caster stats",
        stats = { spellPower = true, spellCrit = true },
        reason = "it is not a caster build (Warrior and Rogue never weight them, and a hybrid keeps only a small seal/shock spellPower)",
        allowed = function(profile, stat, value)
            local channels = weightChannels(profile)
            if channels == nil or channels.isCaster then return true end
            if stat == "spellCrit" then
                local critSpecs = HYBRID_SPELLCRIT_SPECS[profile.class]
                return critSpecs ~= nil and critSpecs[profile.spec] == true
                    and type(value) == "number" and value <= HYBRID_SPELLCRIT_MAX
            end
            local specs = HYBRID_SEAL_SPECS[profile.class]
            return specs ~= nil and specs[profile.spec] == true
                and type(value) == "number" and value <= HYBRID_SEAL_SPELLPOWER_MAX
        end,
    },
    {
        id = "druid_feral_weapon",
        label = "Druid feral uses feral attack power, not the weapon",
        stats = { weaponDPS = true, weaponAvgDamage = true },
        reason = "in bear or cat form the weapon's damage becomes feral attack power, so feral profiles weight feralAttackPower instead",
        allowed = function(profile, stat, value)
            if profile.class ~= "DRUID" then return true end
            local channels = weightChannels(profile)
            if channels == nil then return true end
            -- Balance and Restoration (and the Healer role) are casters; only
            -- the feral shapes are weapon-free.
            return channels.isCaster
        end,
    },
}

-- Pure: the day-one answer every class gets before level 10. Below 10 a
-- character has one slot, and its role and weapon setup come from the class
-- table rather than from a build questionnaire, so those two fields plus the
-- weight table they resolve are the whole pre-10 experience. This checks them
-- through the same lookup ResolveForBuild uses (Profiles.FindBaseProfile), so a
-- class that has no PvE weights, an empty weight table, or a weapon
-- configuration the client does not know is reported here instead of showing up
-- as a silent zero in a level-1 score. Returns an array of strings; an empty
-- array means every class resolves.
function ClassData:AuditStarterDefaults()
    local problems = {}
    local function add(message)
        table.insert(problems, tostring(message))
    end

    local classTokens = {}
    for classToken in pairs(self.classes) do
        table.insert(classTokens, classToken)
    end
    table.sort(classTokens)

    local profiles = LT.Profiles
    local findProfile = type(profiles) == "table" and profiles.FindBaseProfile or nil

    for _, classToken in ipairs(classTokens) do
        local definition = self.classes[classToken]
        local role = definition.defaultRole

        local roleIsListed = false
        for _, listed in ipairs(definition.roles or {}) do
            if listed == role then roleIsListed = true end
        end
        if not roleIsListed then
            add(classToken .. " defaultRole \"" .. tostring(role)
                .. "\" is not one of its roles")
        end

        -- The client must know the setup: a typo here makes every weapon
        -- comparison for the class read "unknown" until the player changes it.
        if type(LT.GetWeaponSetupDefinition) ~= "function" then
            add("LT.GetWeaponSetupDefinition is not available, so no defaultSetup can be checked")
        elseif LT:GetWeaponSetupDefinition(definition.defaultSetup) == nil then
            add(classToken .. " defaultSetup \"" .. tostring(definition.defaultSetup)
                .. "\" is not a known weapon configuration")
        end

        if type(findProfile) ~= "function" then
            add("Profiles.FindBaseProfile is not available, so no day-one weight table can be checked")
        else
            local ok, profile = pcall(findProfile, classToken, "Any", role, "PVE")
            if not ok then
                add(classToken .. " day-one profile lookup failed: " .. tostring(profile))
            elseif type(profile) ~= "table" then
                add(classToken .. " has no PvE profile for role \"" .. tostring(role)
                    .. "\", so a level 1-9 slot resolves no weights")
            elseif type(profile.weights) ~= "table" or next(profile.weights) == nil then
                add(classToken .. " day-one profile \"" .. tostring(profile.key)
                    .. "\" has an empty weight table")
            end
        end
    end

    return problems
end

-- The self-test hook: an empty list means the packs, the option keys and the
-- quirks agree. Read-only by contract: it reports what the packs declare and,
-- when BuffMonitor is loaded, what is actually registered. It never registers —
-- that belongs to PLAYER_LOGIN (Core) — so an audit run at any moment describes
-- the truth instead of repairing it. A registry that is still empty because the
-- login pass has not run is reported as such, once, and the per-buff counts
-- then read zero rather than being filled in by the audit.
function ClassData:AuditClassData()
    local problems = {}
    local function add(message)
        table.insert(problems, tostring(message))
    end

    if not (LT.ClassPacks and type(LT.ClassPacks.GetOrder) == "function") then
        add("ClassPacks is not loaded")
        return problems
    end

    local defaults
    if type(LT.Database) == "table" and type(LT.Database.defaultOptions) == "function" then
        defaults = LT.Database.defaultOptions()
    end
    if not defaults then add("Database.defaultOptions is not available") end

    local registry
    if type(LT.BuffMonitor) == "table" and type(LT.BuffMonitor.GetRegistry) == "function" then
        local ok, value = pcall(LT.BuffMonitor.GetRegistry, LT.BuffMonitor)
        if ok and type(value) == "table" then registry = value end
    end
    if registry and not self.buffRegistrationRan then
        add("buff registration has not run yet (PLAYER_LOGIN runs it); every declared buff reads as unregistered")
    end

    local buffIds, optionKeys = {}, {}
    local classTokens = {}
    for classToken in pairs(self.classes) do
        table.insert(classTokens, classToken)
    end
    table.sort(classTokens)

    for _, classToken in ipairs(classTokens) do
        local pack = LT.ClassPacks:Get(classToken)

        if not pack then
            add(classToken .. " has no class pack")
        else
            for _, buff in ipairs(pack.buffs or {}) do
                if buffIds[buff.id] then
                    add("buff id \"" .. tostring(buff.id) .. "\" is declared by "
                        .. tostring(buffIds[buff.id]) .. " and " .. classToken)
                else
                    buffIds[buff.id] = classToken
                end

                if optionKeys[buff.optionKey] then
                    add("option key \"" .. tostring(buff.optionKey) .. "\" is declared by "
                        .. tostring(optionKeys[buff.optionKey]) .. " and " .. classToken)
                else
                    optionKeys[buff.optionKey] = classToken
                end

                if defaults then
                    if defaults[buff.optionKey] == nil then
                        add("option key \"" .. tostring(buff.optionKey)
                            .. "\" is missing from Database.defaultOptions()")
                    elseif defaults[buff.optionKey] ~= buff.default then
                        add("option key \"" .. tostring(buff.optionKey) .. "\" defaults to "
                            .. tostring(defaults[buff.optionKey]) .. " in the database and "
                            .. tostring(buff.default) .. " in the pack")
                    elseif buff.default == true and not PRE_EXISTING_BUFF_ON[buff.optionKey] then
                        add("option key \"" .. tostring(buff.optionKey)
                            .. "\" defaults on; only a pre-existing key may")
                    end
                end

                if registry then
                    local found = 0
                    for _, definition in ipairs(registry[classToken] or {}) do
                        if definition.id == buff.id then
                            found = found + 1
                        end
                    end
                    if found ~= 1 then
                        add("buff \"" .. tostring(buff.id) .. "\" is registered "
                            .. tostring(found) .. " time(s) for " .. classToken)
                    end
                end
            end

            local quirkIds = {}
            for _, quirk in ipairs(pack.quirks or {}) do
                local hasStat = quirk.stat ~= nil
                local hasUnvalued = quirk.unvalued ~= nil

                if quirkIds[quirk.id] then
                    add("quirk id \"" .. tostring(quirk.id) .. "\" is declared twice for " .. classToken)
                else
                    quirkIds[quirk.id] = true
                end

                if hasStat == hasUnvalued then
                    add(classToken .. " quirk \"" .. tostring(quirk.id)
                        .. "\" must be keyed to a stat or marked unvalued, not both")
                elseif hasStat and not LT.ClassPacks:StatIsWeighted(classToken, quirk.stat) then
                    add(classToken .. " quirk \"" .. tostring(quirk.id) .. "\" names \""
                        .. tostring(quirk.stat) .. "\", which the class does not weight")
                elseif hasStat and LT.StatLabels ~= nil and LT.StatLabels[quirk.stat] == nil then
                    add(classToken .. " quirk \"" .. tostring(quirk.id) .. "\" names \""
                        .. tostring(quirk.stat) .. "\", which is not a known stat channel")
                end
            end
        end
    end

    -- Weight-relevance rules: a bundled profile that weights a stat its build
    -- should ignore is reported with the profile key and the stat, never left
    -- to ship silently. See ClassData.weightRelevance above.
    for _, profile in ipairs(self.baseProfiles or {}) do
        local weights = profile.weights
        if type(weights) == "table" then
            for stat, value in pairs(weights) do
                if type(value) == "number" and value ~= 0 then
                    for _, rule in ipairs(ClassData.weightRelevance or {}) do
                        if rule.stats and rule.stats[stat]
                            and type(rule.allowed) == "function"
                            and not rule.allowed(profile, stat, value) then
                            add(profile.key .. " (\"" .. tostring(profile.name) .. "\") weights \""
                                .. tostring(stat) .. "\" but " .. tostring(rule.reason))
                        end
                    end
                end
            end
        end
    end

    -- The day-one defaults: every class must resolve a weapon configuration and
    -- a non-empty weight table before the level-10 questionnaire exists.
    for _, message in ipairs(self:AuditStarterDefaults()) do
        add(message)
    end

    return problems
end

------------------------------------------------------------------------------

-- The two configurations this project is actually focused on.
addBase({
    key = "shaman_enhancement_tank_pve",
    name = "Enhancement Tank — PvE",
    class = "SHAMAN",
    spec = "Enhancement",
    role = "Tank",
    context = "PVE",
    weights = {
        stamina = 1.00, agility = 0.30, strength = 0.75,
        armor = 0.030, defense = 1.40, dodge = 1.10, parry = 1.00, block = 1.00, blockValue = 0.80,
        hit = 0.90, expertise = 1.20, crit = 0.45,
        attackPower = 0.50, weaponDPS = 0.85, weaponAvgDamage = 0.40,
        spellPower = 0.10,
    },
    assumptions = "Starting point for Enhancement tanking, which no bundled profile "
        .. "covered before. Built by combining this addon's tanking weights with the "
        .. "stats an Enhancement Shaman actually gets on gear. Threat generation, "
        .. "block and defense requirements have NOT been verified against Forever, so "
        .. "treat every number here as a placeholder to be corrected in play.",
})

addBase({
    key = "shaman_enhancement_2h_pvp",
    name = "Enhancement — 2H Windfury PvP",
    class = "SHAMAN",
    spec = "Enhancement",
    role = "Damage",
    context = "PVP",
    weights = {
        strength = 0.90, agility = 0.45, stamina = 0.60,
        attackPower = 0.65, hit = 1.00, crit = 0.80, expertise = 0.60, armorPen = 0.30,
        weaponDPS = 1.25, weaponAvgDamage = 0.90, weaponSpeed = 0.10,
    },
    assumptions = "Two-handed Windfury PvP starting point. Weapon damage and DPS are "
        .. "weighted high because Windfury scales from the swing, and stamina is raised "
        .. "above the PvE profile for survivability. The Windfury proc itself is not "
        .. "modelled — see the plugin interface for where that belongs.",
})

addBase({
    key = "blank",
    name = "Blank (all zero)",
    class = "ANY",
    spec = "Any",
    role = "Hybrid",
    context = "PVE",
    weights = {},
    assumptions = "An empty profile. Every weight starts at zero so you can build a "
        .. "profile up from nothing without inheriting anyone else's assumptions.",
})

------------------------------------------------------------------------------
-- Spec-level starting points
--
-- One base profile per class / spec / role / context, keyed
-- class_spec_role_context and named "Class — Spec Role (PVE|PVP)". The
-- role-level profiles above stay as the fallback for a slot that names no
-- specialisation.
--
-- The two hand-written Shaman premises above already cover their combination,
-- so they are not generated a second time: two base profiles claiming one
-- class/spec/role/context would leave resolution dependent on name order.
------------------------------------------------------------------------------

-- Spec weights are authored against the same stat channels as the role tables
-- and the hand-written profiles in this file. LT.StatLabels (the canonical
-- channel list) is built by ItemStats.lua, which loads after this file, so the
-- authority used here is "a key that already ships and scores"; the self test
-- cross-checks every resulting key against LT.StatLabels at runtime. A key the
-- scorer would ignore is dropped rather than left to score nothing.
local knownSpecWeightKeys = {}

local function learnWeightKeys(weights)
    for stat in pairs(weights or {}) do
        knownSpecWeightKeys[stat] = true
    end
end

for _, definition in pairs(ClassData.classes) do
    for _, weights in pairs(definition.weights or {}) do
        learnWeightKeys(weights)
    end
end

for _, profile in ipairs(baseProfiles) do
    learnWeightKeys(profile.weights)
end

-- A key is acceptable when it already ships in this file, or when the canonical
-- channel list is available and names it. At load only the first test can
-- answer; after ItemStats.lua has run, LT.StatLabels is the final authority.
local function isKnownSpecWeightStat(stat)
    if knownSpecWeightKeys[stat] then return true end
    return LT.StatLabels ~= nil and LT.StatLabels[stat] ~= nil
end

ClassData.specWeightProblems = {}

-- Drops every spec weight the scorer could not score and records it. Idempotent
-- and public, so the self test can prove the guard on a deliberately bad entry.
-- Runs once at load, before the spec base profiles are copied.
function ClassData:ValidateSpecWeights()
    self.specWeightProblems = self.specWeightProblems or {}

    for classToken, definition in pairs(self.classes) do
        for spec, roles in pairs(definition.specWeights or {}) do
            if type(roles) == "table" then
                for role, weights in pairs(roles) do
                    if type(weights) == "table" then
                        for stat, value in pairs(weights) do
                            if not isKnownSpecWeightStat(stat) or type(value) ~= "number" then
                                weights[stat] = nil
                                table.insert(self.specWeightProblems,
                                    classToken .. "/" .. tostring(spec) .. "/" .. tostring(role)
                                        .. " refused stat \"" .. tostring(stat) .. "\"")
                            end
                        end
                    end
                end
            end
        end
    end

    return self.specWeightProblems
end

ClassData:ValidateSpecWeights()

local function slug(text)
    return (tostring(text):lower():gsub("%s+", "_"):gsub("[^%w_]", ""))
end

local function exactBaseExists(classToken, spec, role, context)
    for _, profile in ipairs(baseProfiles) do
        if profile.class == classToken
            and profile.spec == spec
            and profile.role == role
            and profile.context == context then
            return true
        end
    end
    return false
end

for classToken, definition in pairs(ClassData.classes) do
    for spec, roles in pairs(definition.specWeights or {}) do
        if type(roles) == "table" then
            for role, weights in pairs(roles) do
                if type(weights) == "table" and next(weights) then
                    for _, context in ipairs({ "PVE", "PVP" }) do
                        if not exactBaseExists(classToken, spec, role, context) then
                            addBase({
                                key = slug(classToken) .. "_" .. slug(spec) .. "_"
                                    .. slug(role) .. "_" .. slug(context),
                                name = definition.name .. " — " .. spec .. " " .. role
                                    .. " (" .. context .. ")",
                                class = classToken,
                                spec = spec,
                                role = role,
                                context = context,
                                weights = LT:Copy(weights),
                                assumptions = "Provisional " .. spec .. " " .. role
                                    .. " starting point, derived from the "
                                    .. definition.name .. " role weights and adjusted for "
                                    .. "the specialisation. Every number is a starting "
                                    .. "point, not validated against Forever's combat maths, "
                                    .. "and the PvE and PvP entries share these numbers. "
                                    .. "The " .. definition.name .. " " .. role
                                    .. " role profile (spec Any) remains the fallback when "
                                    .. "a slot names no specialisation.",
                            })
                        end
                    end
                end
            end
        end
    end
end

-- Deterministic order for the UI.
table.sort(baseProfiles, function(a, b) return a.name < b.name end)

ClassData.baseProfiles = baseProfiles

function ClassData:GetBaseProfiles()
    return self.baseProfiles
end

function ClassData:GetBaseProfile(key)
    for _, profile in ipairs(self.baseProfiles) do
        if profile.key == key then return profile end
    end
    return nil
end

------------------------------------------------------------------------------
-- Spec coverage audit
--
-- One question, one answer, for the self test and /lt debug: does every
-- class / spec / role this file claims to support have a bundled starting
-- point, and does every role a slot can choose have a fallback the resolver
-- will find? Returns an array of { class, spec, role, context, reason }; an
-- empty array means complete.
------------------------------------------------------------------------------

local function roleIsListed(definition, role)
    for _, known in ipairs(definition.roles or {}) do
        if known == role then return true end
    end
    return false
end

local function specIsListed(definition, spec)
    for _, known in ipairs(definition.specs or {}) do
        if known == spec then return true end
    end
    return false
end

function ClassData:AuditSpecCoverage()
    local problems = {}

    local function add(classToken, spec, role, context, reason)
        table.insert(problems, {
            class = classToken,
            spec = spec,
            role = role,
            context = context,
            reason = reason,
        })
    end

    local function exactCount(classToken, spec, role, context)
        local count = 0
        for _, profile in ipairs(self.baseProfiles) do
            if profile.class == classToken
                and profile.spec == spec
                and profile.role == role
                and profile.context == context then
                count = count + 1
            end
        end
        return count
    end

    local function roleFallbackExists(classToken, role, context)
        for _, profile in ipairs(self.baseProfiles) do
            if profile.class == classToken
                and profile.role == role
                and profile.context == context then
                return true
            end
        end
        return false
    end

    local classTokens = {}
    for classToken in pairs(self.classes or {}) do
        table.insert(classTokens, classToken)
    end
    table.sort(classTokens)

    for _, classToken in ipairs(classTokens) do
        local definition = self.classes[classToken]
        local bySpec = definition.specWeights or {}

        for _, spec in ipairs(definition.specs or {}) do
            local roles = bySpec[spec]
            if type(roles) ~= "table" or not next(roles) then
                add(classToken, spec, nil, nil, "no specWeights entry for this spec")
            end
        end

        local specNames = {}
        for spec in pairs(bySpec) do
            table.insert(specNames, spec)
        end
        table.sort(specNames)

        for _, spec in ipairs(specNames) do
            if not specIsListed(definition, spec) then
                add(classToken, spec, nil, nil,
                    "specWeights names a spec this class does not list")
            end

            local roles = bySpec[spec]
            if type(roles) ~= "table" then
                add(classToken, spec, nil, nil, "specWeights entry is not a role table")
            else
                local roleNames = {}
                for role in pairs(roles) do
                    table.insert(roleNames, role)
                end
                table.sort(roleNames)

                for _, role in ipairs(roleNames) do
                    if not roleIsListed(definition, role) then
                        add(classToken, spec, role, nil,
                            "specWeights names a role this class does not list")
                    end

                    for _, context in ipairs({ "PVE", "PVP" }) do
                        local count = exactCount(classToken, spec, role, context)
                        if count == 0 then
                            add(classToken, spec, role, context,
                                "no base profile for this spec, role and context")
                        elseif count > 1 then
                            add(classToken, spec, role, context,
                                tostring(count) .. " base profiles claim this spec, role and context")
                        end
                    end
                end
            end
        end

        for _, role in ipairs(definition.roles or {}) do
            for _, context in ipairs({ "PVE", "PVP" }) do
                if not roleFallbackExists(classToken, role, context) then
                    add(classToken, "Any", role, context,
                        "no fallback profile for this role and context")
                end
            end
        end
    end

    table.sort(problems, function(a, b)
        local left = table.concat({ a.class or "", a.spec or "", a.role or "", a.context or "", a.reason or "" }, "|")
        local right = table.concat({ b.class or "", b.spec or "", b.role or "", b.context or "", b.reason or "" }, "|")
        return left < right
    end)

    return problems
end

-- Class options are stored per profile so two builds of the same class can
-- hold different imbue / stance choices.
function ClassData:GetDefaultClassOptions(classToken)
    local definition = self:GetClass(classToken)
    local options = {}

    for _, option in ipairs(definition and definition.options or {}) do
        options[option.key] = option.values[1]
    end

    return options
end

------------------------------------------------------------------------------
-- L-8 (T-129): the two Enhancement weight keys the base profiles had no row for
--
-- The shipped Enhancement ordering, in words: Strength > Intellect > AP/SP >
-- Agility > Spirit. Throughput first: SHAMAN-ENHANCE-STAT-THEORYCRAFT.md puts
-- Strength ahead on damage per second, while the guide ranks Intellect first
-- for experience per hour because it removes the downtime. Both are answers to
-- different questions, so the order above is the levelling profile's and the
-- numbers under it are unchanged here - including the attackPower 0.75 beside
-- agility 0.40, which is the open M-2 measurement and must not be adjusted
-- from this block.
--
-- spellCrit and mp5 are added by patching the generated profiles here, after
-- generation, rather than in the Enhancement specWeights tables: the shipped
-- Enhancement Tank PvE profile is hand-written (it predates that loop) and
-- would never be reached, and without a key a custom profile cannot store the
-- player's own preference at all - the weights editor draws a row for every
-- stat, but a weight with no key behind it has nothing to write into.
-- Existing keys are left alone; these values are PROVISIONAL starting points.
local ENHANCEMENT_EXTRA_WEIGHTS = {
    spellCrit = 0.35, -- PROVISIONAL: shocks crit; the player's own preference
    mp5 = 0.10,       -- PROVISIONAL: mana per five, downtime insurance
}

for _, profile in ipairs(ClassData.baseProfiles or {}) do
    if profile.class == "SHAMAN"
        and profile.spec == "Enhancement"
        and (profile.role == "Damage" or profile.role == "Tank")
        and type(profile.weights) == "table" then
        for stat, value in pairs(ENHANCEMENT_EXTRA_WEIGHTS) do
            if profile.weights[stat] == nil then
                profile.weights[stat] = value
            end
        end
    end
end
