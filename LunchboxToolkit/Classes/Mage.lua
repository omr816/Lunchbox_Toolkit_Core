--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Classes\Mage
    The Mage class pack. Data only; see ClassPacks.lua for the contract.

    usable comes from the armour and weapon tables the player supplied on
    2026-10-27 (WoW Classic rules, NOT yet verified on Forever):

      * leather, mail and plate are never usable: no score, grey "Unusable" line;
      * axes, maces, polearms, fist weapons, bows, crossbows, guns and thrown are
        never usable. Swords, staves, daggers and wands are: no rule needed.

    The off-hand slot table supplied the same day adds one refusal: a shield
    belongs to Warrior, Paladin and Shaman only. Wands are a Mage's own, so they
    need no rule.

    Cloth needs no rule. Relics and "held in off-hand" frills carry no claim yet:
    the slot table covers them, but this client's armour subclasses for them are
    unconfirmed, so both stay unknown.

    specRoles and templates: all three specs are Damage, the only role the class
    declares. templates ships the three levelling PvE starter configurations
    first, one per spec, on the "1H" setup ClassData gives MAGE as its default;
    the PvP starter for each spec follows on the same setup, because a bundled
    profile exists for that exact spec, role and context. None names a profile
    key and none carries an imbue: Mage has no weapon-imbue option.

    buffs carries one reminder for the armour buff — Frost, Ice or Mage Armor,
    whichever the player maintains. Off by default.

    quirks: mana per five seconds is already a Mage weight, so sustain is valued
    there; the armour those spells grant applies to the character, and armour is
    not a Mage weight, so that half is recorded as unvalued.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit
if not (LT and LT.ClassPacks) then return end

LT.ClassPacks:Register("MAGE", {
    apiVersion = 1,
    specRoles = {
        Arcane = "Damage",
        Fire   = "Damage",
        Frost  = "Damage",
    },
    templates = {
        {
            name = "Arcane — Levelling PvE",
            spec = "Arcane", role = "Damage", context = "PVE",
            weaponSetup = "1H",
        },
        {
            name = "Fire — Levelling PvE",
            spec = "Fire", role = "Damage", context = "PVE",
            weaponSetup = "1H",
        },
        {
            name = "Frost — Levelling PvE",
            spec = "Frost", role = "Damage", context = "PVE",
            weaponSetup = "1H",
        },
        {
            key = "mage_arcane_damage_pvp",
            name = "Arcane — PvP",
            spec = "Arcane", role = "Damage", context = "PVP",
            weaponSetup = "1H",
        },
        {
            key = "mage_fire_damage_pvp",
            name = "Fire — PvP",
            spec = "Fire", role = "Damage", context = "PVP",
            weaponSetup = "1H",
        },
        {
            key = "mage_frost_damage_pvp",
            name = "Frost — PvP",
            spec = "Frost", role = "Damage", context = "PVP",
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
            Mace1H   = { never = true },
            Mace2H   = { never = true },
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
            id = "mage_armor",
            label = "Mage armour",
            optionKey = "mageArmorReminder",
            help = "Warns when none of Frost Armor, Ice Armor or Mage Armor is on "
                .. "the player. It does not choose between them and never casts one.",
            auras = { "Frost Armor", "Ice Armor", "Mage Armor" },
            spells = {},
            message = "No Mage armour is active (Frost, Ice or Mage Armor).",
            expiringThreshold = 5 * 60 * 1000,
            default = false,
        },
    },
    quirks = {
        {
            id = "mana_sustain",
            label = "Mana sustain",
            stat = "mp5",
            note = "Mana per five seconds is the sustain channel the Mage tables "
                .. "weight; Arcane's own spirit weight is separate and is not "
                .. "added to it.",
        },
        {
            id = "armor_buff",
            label = "Frost / Ice / Mage Armor",
            unvalued = "the armour these spells grant applies to the character, "
                .. "and armour is not a weight in any Mage table",
            note = "The reminder watches that one of them is on; the score still "
                .. "reads only the item's own channels.",
        },
    },
})
