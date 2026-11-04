--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Classes\Druid
    The Druid class pack. Data only; see ClassPacks.lua for the contract.

    usable comes from the armour and weapon tables the player supplied on
    2026-10-27 (WoW Classic rules, NOT yet verified on Forever):

      * mail and plate are never usable: no score, grey "Unusable" line;
      * axes, swords, polearms, bows, crossbows, guns and thrown are never
        usable. Maces, staves, daggers and fist weapons are: they need no rule.

    The ranged and off-hand slot table supplied the same day adds two refusals: a
    wand belongs to Mage, Priest and Warlock only, and a shield to Warrior,
    Paladin and Shaman only. An idol is a Druid's own relic, but relics carry no
    claim yet (see below).

    Deliberately absent: cloth and leather need no rule; relics (librams, totems,
    idols) and "held in off-hand" frills stay unknown because this client's armour
    subclasses for them are unconfirmed.

    specRoles ties the flat spec list to the class's roles. Feral carries both
    Damage and Tank, the same shape Shaman uses for Enhancement: a cat build is
    damage and a bear build is a tank, so the pack offers one template per form
    rather than picking a side. Balance is Damage and Restoration is Healer.

    templates ships the four levelling PvE starter configurations first:
    Balance (caster), Feral cat, Feral bear and Restoration. The PvP starter for
    each of those rows follows in the same order, because a bundled profile
    exists for that exact spec, role and context. Each names a spec, role,
    context and weapon setup. Every one uses "2H", the setup ClassData gives
    DRUID as its default and the registry accepts; no template claims a Druid
    fights with a one-hander. None names a profile key — the wizard resolves the
    bundled base profile from class, spec, role and context — and none carries an
    imbue, because no Druid weapon-imbue option exists.

    buffs carries the two form reminders separately: Cat Form is the feral damage
    shape and Bear/Dire Bear the tank shape. A Balance or Restoration Druid casts
    in caster form, so one combined "any form" entry would warn them wrongly;
    each entry has its own key and both start off.

    quirks: feral attack power now has its own feralAttackPower weight in the
    feral profiles (the weapon's damage converts to it in cat and bear form) and
    weaponDPS/weaponAvgDamage are no longer weighted there; the bear armour
    multiplier rides the existing armour weight; weapon damage inside a form is
    recorded as unvalued rather than re-weighted raw.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit
if not (LT and LT.ClassPacks) then return end

LT.ClassPacks:Register("DRUID", {
    apiVersion = 1,
    specRoles = {
        Balance     = "Damage",
        Feral       = { "Damage", "Tank" },
        Restoration = "Healer",
    },
    templates = {
        {
            name = "Balance — Levelling PvE",
            spec = "Balance", role = "Damage", context = "PVE",
            weaponSetup = "2H",
        },
        {
            name = "Feral Cat — Levelling PvE",
            spec = "Feral", role = "Damage", context = "PVE",
            weaponSetup = "2H",
        },
        {
            name = "Feral Bear — Levelling PvE",
            spec = "Feral", role = "Tank", context = "PVE",
            weaponSetup = "2H",
        },
        {
            name = "Restoration — Levelling PvE",
            spec = "Restoration", role = "Healer", context = "PVE",
            weaponSetup = "2H",
        },
        {
            key = "druid_balance_damage_pvp",
            name = "Balance — PvP",
            spec = "Balance", role = "Damage", context = "PVP",
            weaponSetup = "2H",
        },
        {
            key = "druid_feral_damage_pvp",
            name = "Feral Cat — PvP",
            spec = "Feral", role = "Damage", context = "PVP",
            weaponSetup = "2H",
        },
        {
            key = "druid_feral_tank_pvp",
            name = "Feral Bear — PvP",
            spec = "Feral", role = "Tank", context = "PVP",
            weaponSetup = "2H",
        },
        {
            key = "druid_restoration_healer_pvp",
            name = "Restoration — PvP",
            spec = "Restoration", role = "Healer", context = "PVP",
            weaponSetup = "2H",
        },
    },
    usable = {
        armour = {
            Mail   = { never = true },
            Plate  = { never = true },
            Shield = { never = true },
        },
        weapons = {
            Axe1H    = { never = true },
            Axe2H    = { never = true },
            Sword1H  = { never = true },
            Sword2H  = { never = true },
            Polearm  = { never = true },
            Bow      = { never = true },
            Crossbow = { never = true },
            Gun      = { never = true },
            Thrown   = { never = true },
            Wand     = { never = true },
        },
    },
    buffs = {
        {
            id = "druid_cat_form",
            label = "Cat Form",
            optionKey = "druidCatFormReminder",
            help = "Feral cat only. Warns when Cat Form is not active. A Balance or "
                .. "Restoration Druid casts in caster form, so this stays off for "
                .. "them unless they tick it.",
            auras = { "Cat Form" },
            spells = {},
            message = "Cat Form is not active.",
            expiringThreshold = 5 * 60 * 1000,
            default = false,
        },
        {
            id = "druid_bear_form",
            label = "Bear form",
            optionKey = "druidBearFormReminder",
            help = "Feral bear only. Warns when neither Bear Form nor Dire Bear "
                .. "Form is active. Off by default, so a cat build never sees it.",
            auras = { "Bear Form", "Dire Bear Form" },
            spells = {},
            message = "No bear form is active (Bear or Dire Bear Form).",
            expiringThreshold = 5 * 60 * 1000,
            default = false,
        },
    },
    quirks = {
        {
            id = "feral_attack_power",
            label = "Feral attack power",
            stat = "feralAttackPower",
            note = "In cat and bear form the weapon's damage becomes feral attack "
                .. "power, so the feral profiles (role Damage/Tank and the Feral "
                .. "cat/bear spec weights) weight feralAttackPower instead of "
                .. "weaponDPS/weaponAvgDamage. The regular attackPower weight "
                .. "still covers strength and agility attack power.",
        },
        {
            id = "form_weapon_damage",
            label = "Weapon damage inside a form",
            unvalued = "a form converts the weapon's raw DPS into feral attack "
                .. "power, so weaponDPS/weaponAvgDamage have no direct weight; the "
                .. "conversion is carried by the feralAttackPower weight instead",
            note = "Recorded so the feralAttackPower weight is not mistaken for a "
                .. "raw weapon stat.",
        },
        {
            id = "bear_armor_multiplier",
            label = "Bear form armour multiplier",
            stat = "armor",
            note = "The form multiplies armour, and the existing armour weight "
                .. "(0.045 role tank, 0.050 Feral tank) is where it is valued; the "
                .. "multiplier is not applied a second time.",
        },
    },
})
