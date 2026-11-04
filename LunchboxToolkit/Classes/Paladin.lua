--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Classes\Paladin
    The Paladin class pack. Data only; see ClassPacks.lua for the contract.

    usable comes from the armour and weapon tables the player supplied on
    2026-10-27 (WoW Classic rules, NOT yet verified on Forever):

      * plate is trained at level 40 — usable later, scored, orange outline;
      * bows, crossbows, guns, thrown, staves, daggers and fist weapons are
        never usable: no score, one grey "Unusable" line, grey outline.

    The ranged and off-hand slot table supplied the same day settles wands: they
    belong to Mage, Priest and Warlock, so a Paladin never uses one. A shield is a
    Paladin's own, so it needs no rule and stays usable.

    Relics (librams) and "held in off-hand" frills carry no claim yet: the slot
    table covers them, but this client's armour subclasses for them are
    unconfirmed, so both stay unknown.

    specRoles and templates: Holy is Healer, Protection is Tank and Retribution
    is Damage — the three roles the class declares, one per spec. templates
    ships the three levelling PvE starter configurations first: Holy and
    Protection on "1H_SHIELD" (the shield is a Paladin's own, and a Prot tank
    holds one), and Retribution on "2H", the class default. The PvP starter for
    each spec follows with the same role and setup, because the class has a
    bundled profile for that exact spec, role and context. None names a profile
    key and none carries an imbue: a seal is a ClassData option, not a weapon
    imbue.

    buffs carries the seal reminder, moved here from ClassData with its id and
    option key unchanged. `auras = { "Seal of" }` is the shipped prefix rule kept
    as data: an aura entry is a Lua pattern, so a seal added later still matches
    without a second matcher. Off by default.

    quirks keeps the two halves of seal damage apart: the spell-power half is
    already in the Retribution and Protection weights, while the proc half needs
    a proc rate and a damage unit the scan does not report, so it is recorded as
    unvalued rather than guessed.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit
if not (LT and LT.ClassPacks) then return end

LT.ClassPacks:Register("PALADIN", {
    apiVersion = 1,
    specRoles = {
        Holy        = "Healer",
        Protection  = "Tank",
        Retribution = "Damage",
    },
    templates = {
        {
            name = "Holy — Levelling PvE",
            spec = "Holy", role = "Healer", context = "PVE",
            weaponSetup = "1H_SHIELD",
        },
        {
            name = "Protection — Levelling PvE",
            spec = "Protection", role = "Tank", context = "PVE",
            weaponSetup = "1H_SHIELD",
        },
        {
            name = "Retribution — Levelling PvE",
            spec = "Retribution", role = "Damage", context = "PVE",
            weaponSetup = "2H",
        },
        {
            key = "paladin_holy_healer_pvp",
            name = "Holy — PvP",
            spec = "Holy", role = "Healer", context = "PVP",
            weaponSetup = "1H_SHIELD",
        },
        {
            key = "paladin_protection_tank_pvp",
            name = "Protection — PvP",
            spec = "Protection", role = "Tank", context = "PVP",
            weaponSetup = "1H_SHIELD",
        },
        {
            key = "paladin_retribution_damage_pvp",
            name = "Retribution — PvP",
            spec = "Retribution", role = "Damage", context = "PVP",
            weaponSetup = "2H",
        },
    },
    usable = {
        armour = {
            Plate = { fromLevel = 40 },
        },
        weapons = {
            Bow       = { never = true },
            Crossbow  = { never = true },
            Gun       = { never = true },
            Thrown    = { never = true },
            Staff     = { never = true },
            Dagger    = { never = true },
            Fist      = { never = true },
            Wand      = { never = true },
        },
    },
    buffs = {
        {
            id = "paladin_seal",
            label = "Paladin seal",
            optionKey = "paladinSealReminder",
            help = "Warns when no seal buff is on the player. The aura entry is a "
                .. "pattern, so a seal added later still matches; confirm the name "
                .. "in game before relying on it. It never casts a seal.",
            auras = { "Seal of" },
            spells = {},
            message = "No Paladin seal is active.",
            expiringThreshold = 2 * 60 * 1000,
            default = false,
        },
    },
    quirks = {
        {
            id = "seal_spell_power",
            label = "Seal damage from spell power",
            stat = "spellPower",
            note = "The caster half of seal damage already rides the existing "
                .. "spellPower weight (0.10 Retribution, 0.15 Protection); nothing "
                .. "is added on top of it.",
        },
        {
            id = "seal_procs",
            label = "Seal procs (Command, Righteousness)",
            unvalued = "a proc needs a proc rate and a damage unit per swing; the "
                .. "item scan reports neither, so no weight or conversion can hold it",
            note = "The spell-power half is valued above; the proc half is recorded "
                .. "and never guessed at.",
        },
    },
})
