--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Classes\Warrior
    The Warrior class pack. Data only; see ClassPacks.lua for the contract.

    usable comes from the armour and weapon tables the player supplied on
    2026-10-27 (WoW Classic rules, NOT yet verified on Forever):

      * plate is trained at level 40, so a Warrior below 40 sees plate as
        "usable later" — scored, orange outline, not refused. Cloth, leather and
        mail need no rule: they are scorable from level 1.
      * no weapon type is listed as never. The supplied table says "None", so
        nothing is refused here.

    The ranged and off-hand slot table supplied the same day adds the one weapon
    claim this class needs: wands belong to Mage, Priest and Warlock, so a Warrior
    never uses one. Shields and thrown weapons are a Warrior's own, so they need
    no rule and stay scored as today.

    Deliberately absent, which reads as "unknown" and keeps today's behaviour:
    relics (librams, totems, idols) and "held in off-hand" frills. The slot table
    covers both, but this client's armour subclasses for them have not been
    confirmed with a /dump, so no claim is made yet.

    specRoles links the three specs ClassData lists to the two roles the class
    has: Arms and Fury are damage, Protection is the tank. templates ships one
    levelling PvE starter per spec first, then the PvP starter for the same
    spec, role and setup; each of those rows has a bundled base profile in both
    contexts. No template names a profile key, an imbue or a level band: a
    Warrior has no weapon imbue, and the bundled base profile is resolved from
    class, spec, role and context.

    buffs carries the two maintenance reminders: the shout (moved here from
    ClassData with its id and option key unchanged) and the stance, which is a
    new entry with its own key because a shout and a stance are separate
    choices. Both start off.

    quirks records what the score cannot see. A shout's attack power and a
    stance's percentage are character state, not item channels, so neither is
    folded into a weight: both say why and stay unvalued.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit
if not (LT and LT.ClassPacks) then return end

LT.ClassPacks:Register("WARRIOR", {
    apiVersion = 1,
    specRoles = {
        Arms       = "Damage",
        Fury       = "Damage",
        Protection = "Tank",
    },
    templates = {
        {
            name = "Arms — Levelling PvE",
            spec = "Arms", role = "Damage", context = "PVE",
            weaponSetup = "2H",
        },
        {
            name = "Fury — Levelling PvE",
            spec = "Fury", role = "Damage", context = "PVE",
            weaponSetup = "DUAL_WIELD",
        },
        {
            name = "Protection — Levelling PvE",
            spec = "Protection", role = "Tank", context = "PVE",
            weaponSetup = "1H_SHIELD",
        },
        {
            key = "warrior_arms_damage_pvp",
            name = "Arms — PvP",
            spec = "Arms", role = "Damage", context = "PVP",
            weaponSetup = "2H",
        },
        {
            key = "warrior_fury_damage_pvp",
            name = "Fury — PvP",
            spec = "Fury", role = "Damage", context = "PVP",
            weaponSetup = "DUAL_WIELD",
        },
        {
            key = "warrior_protection_tank_pvp",
            name = "Protection — PvP",
            spec = "Protection", role = "Tank", context = "PVP",
            weaponSetup = "1H_SHIELD",
        },
    },
    usable = {
        armour = {
            Plate = { fromLevel = 40 },
        },
        weapons = {
            Wand = { never = true },
        },
    },
    buffs = {
        {
            id = "warrior_shout",
            label = "Battle or Commanding Shout",
            optionKey = "warriorShoutReminder",
            help = "Warns when neither Battle Shout nor Commanding Shout is on the "
                .. "player. Optional levelling reminder; it never casts either shout.",
            -- Plain names, so a rank suffix cannot hide a shout.
            auras = { "Battle Shout", "Commanding Shout" },
            spells = {},
            message = "No Battle/Commanding Shout active.",
            expiringThreshold = 2 * 60 * 1000,
            default = false,
        },
        {
            id = "warrior_stance",
            label = "Warrior stance",
            optionKey = "warriorStanceReminder",
            help = "Warns when no stance is active. Which stance is right depends "
                .. "on the role, so this only says that none is on; it never picks.",
            auras = { "Battle Stance", "Defensive Stance", "Berserker Stance" },
            spells = {},
            message = "No Warrior stance is active.",
            expiringThreshold = 2 * 60 * 1000,
            default = false,
        },
    },
    quirks = {
        {
            id = "shout_attack_power",
            label = "Battle Shout / Commanding Shout",
            unvalued = "a shout is character state, not an item channel; folding "
                .. "its attack power into the attackPower weight would add it to "
                .. "every item scored",
            note = "The buff reminder watches the shout. The score reads only what "
                .. "the item itself carries.",
        },
        {
            id = "stance_multipliers",
            label = "Stance damage multipliers",
            unvalued = "a stance multiplies damage dealt and taken; the scanner "
                .. "reports no percentage channel and a multiplier has no "
                .. "per-item unit",
            note = "Nothing is estimated here, and no weight is invented to stand in.",
        },
    },
})
