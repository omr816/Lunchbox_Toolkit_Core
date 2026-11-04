--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Classes\Priest
    The Priest class pack. Data only; see ClassPacks.lua for the contract.

    usable comes from the armour and weapon tables the player supplied on
    2026-10-27 (WoW Classic rules, NOT yet verified on Forever):

      * leather, mail and plate are never usable: no score, grey "Unusable" line;
      * axes, swords, polearms, fist weapons, bows, crossbows, guns and thrown
        are never usable. Maces, staves, daggers and wands are: no rule needed.

    The off-hand slot table supplied the same day adds one refusal: a shield
    belongs to Warrior, Paladin and Shaman only. Wands are a Priest's own, so they
    need no rule.

    Cloth needs no rule. Relics (librams) and "held in off-hand" frills carry no
    claim yet: the slot table covers them, but this client's armour subclasses for
    them are unconfirmed, so both stay unknown.

    specRoles and templates: Discipline and Holy are Healer, Shadow is Damage —
    the two roles the class declares. templates ships the three levelling PvE
    starter configurations first, one per spec, on the "1H" setup ClassData gives
    PRIEST as its default; the PvP starter for each spec follows on the same
    setup, because a bundled profile exists for that exact spec, role and
    context. None names a profile key and none carries an imbue: Priest has no
    weapon-imbue option.

    buffs carries one reminder: Inner Fire, with its own option key, off by
    default. It reads the aura name only and never casts the spell.

    quirks keeps the spirit half and the Inner Fire half apart. Spirit is already
    a weight in every Priest table, so its out-of-combat regeneration is valued
    there and not added again; Inner Fire's own numbers apply to the character
    rather than to the item, and neither armour nor attack power is a Priest
    weight, so that quirk is recorded as unvalued.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit
if not (LT and LT.ClassPacks) then return end

LT.ClassPacks:Register("PRIEST", {
    apiVersion = 1,
    specRoles = {
        Discipline = "Healer",
        Holy       = "Healer",
        Shadow     = "Damage",
    },
    templates = {
        {
            name = "Discipline — Levelling PvE",
            spec = "Discipline", role = "Healer", context = "PVE",
            weaponSetup = "1H",
        },
        {
            name = "Holy — Levelling PvE",
            spec = "Holy", role = "Healer", context = "PVE",
            weaponSetup = "1H",
        },
        {
            name = "Shadow — Levelling PvE",
            spec = "Shadow", role = "Damage", context = "PVE",
            weaponSetup = "1H",
        },
        {
            key = "priest_discipline_healer_pvp",
            name = "Discipline — PvP",
            spec = "Discipline", role = "Healer", context = "PVP",
            weaponSetup = "1H",
        },
        {
            key = "priest_holy_healer_pvp",
            name = "Holy — PvP",
            spec = "Holy", role = "Healer", context = "PVP",
            weaponSetup = "1H",
        },
        {
            key = "priest_shadow_damage_pvp",
            name = "Shadow — PvP",
            spec = "Shadow", role = "Damage", context = "PVP",
            weaponSetup = "1H",
        },
    },
    usable = {
        armour = {
            Leather = { never = true },
            Mail    = { never = true },
            Plate   = { never = true },
            Shield  = { never = true },
        },
        weapons = {
            Axe1H    = { never = true },
            Axe2H    = { never = true },
            Sword1H  = { never = true },
            Sword2H  = { never = true },
            Polearm  = { never = true },
            Fist     = { never = true },
            Bow      = { never = true },
            Crossbow = { never = true },
            Gun      = { never = true },
            Thrown   = { never = true },
        },
    },
    buffs = {
        {
            id = "priest_inner_fire",
            label = "Inner Fire",
            optionKey = "priestInnerFireReminder",
            help = "Warns when Inner Fire is not on the player. Reads the aura "
                .. "name only; it never casts the spell and never picks a rank.",
            auras = { "Inner Fire" },
            spells = {},
            message = "Inner Fire is not active.",
            expiringThreshold = 5 * 60 * 1000,
            default = false,
        },
    },
    quirks = {
        {
            id = "spirit_regeneration",
            label = "Spirit-based mana regeneration",
            stat = "spirit",
            note = "Spirit returns mana outside the five-second rule, and every "
                .. "Priest table already weights it; the regeneration is not "
                .. "counted a second time anywhere else.",
        },
        {
            id = "inner_fire",
            label = "Inner Fire",
            unvalued = "the buff's numbers apply to the character, not to the "
                .. "item, and neither armour nor attack power is a weight in any "
                .. "Priest table",
            note = "The reminder above watches that the buff is on; the score "
                .. "reads only the item's own channels.",
        },
    },
})
