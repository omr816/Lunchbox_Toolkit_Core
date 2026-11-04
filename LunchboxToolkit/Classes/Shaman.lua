--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Classes\Shaman
    The Shaman class pack. Data only; see ClassPacks.lua for the contract.

    specRoles is the only link ClassData cannot express on its own: the class
    lists Elemental / Enhancement / Restoration as specs and Damage / Tank /
    Healer as roles, but nothing ties the two together. Enhancement carries both
    Damage and Tank because the addon ships two Enhancement configurations
    (shaman_enhancement_tank_pve and shaman_enhancement_2h_pvp) — the tanking
    leg is the project's premise, not a claim that every Enhancement build is a
    tank.

    templates ships the eight starter configurations T-04 defines: Enhancement
    Tank PvE, Enhancement 2H PvE, Enhancement 2H PvP, Enhancement DW PvE,
    Enhancement DW PvP, Elemental PvE, Elemental PvP and Restoration PvE. The
    2H PvE row is the levelling build most Enhancement players use: two-handed
    with Windfury, role Damage, context PVE. Each names a role, spec, context,
    weapon setup and weapon imbue. None names a profile key: the wizard resolves
    the bundled base profile from the class, role and context that the template
    carries. The tank starts on Rockbiter (the threat imbue a Tank slot already
    starts on), every Enhancement damage configuration on Windfury (the
    project's Windfury premise), and the caster configurations on "none"
    because a caster's weapon is not scored through a melee swing.

    usable carries the weapon types the player's supplied tables of 2026-10-27
    mark as never usable — swords, polearms, wands, bows, crossbows, guns and
    thrown — and the armour facts stated then: mail at level 40, plate never.
    The Shaman's own gear is marked usable rather than left "unknown": the
    gear-check scan only scores a USABLE verdict, so an "unknown" shield or axe
    would never earn an upgrade arrow. Trainable weapons stay gated by the
    proficiency check (an untrained axe reads deferred, a trained one usable),
    so marking them usable does not claim the character has the skill.

    Still unclaimed, which reads "unknown": relics (totems), librams and "held
    in off-hand" frills — this client's armour subclasses for them are
    unconfirmed.

    buffs carries the main-hand imbue, moved here from ClassData with its id,
    option key and default unchanged (it is the one reminder that already
    defaulted on). An imbue is a weapon enchant, not an aura, so the entry lists
    spells rather than aura names and ClassData keeps its enchant reader; the
    four spell ids are the only ones this pack trusts.

    quirks names what the weights already carry and what they cannot: Windfury's
    extra swings ride the weapon channels through Imbues:AdjustStats when imbue
    scoring is on, shock damage rides the existing spellPower weight, and
    Rockbiter's threat is unvalued because no threat channel exists.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit
if not (LT and LT.ClassPacks) then return end

LT.ClassPacks:Register("SHAMAN", {
    apiVersion = 1,
    specRoles = {
        Elemental   = "Damage",
        Enhancement = { "Damage", "Tank" },
        Restoration = "Healer",
    },
    templates = {
        {
            name = "Enhancement Tank — PvE",
            spec = "Enhancement", role = "Tank", context = "PVE",
            weaponSetup = "1H_SHIELD", imbue = "rockbiter",
        },
        {
            name = "Enhancement Tank — PvP",
            spec = "Enhancement", role = "Tank", context = "PVP",
            weaponSetup = "1H_SHIELD", imbue = "rockbiter",
        },
        {
            name = "Enhancement 2H — PvE",
            spec = "Enhancement", role = "Damage", context = "PVE",
            weaponSetup = "2H", imbue = "windfury",
        },
        {
            name = "Enhancement 2H — PvP",
            spec = "Enhancement", role = "Damage", context = "PVP",
            weaponSetup = "2H", imbue = "windfury",
        },
        {
            name = "Enhancement DW — PvE",
            spec = "Enhancement", role = "Damage", context = "PVE",
            weaponSetup = "DUAL_WIELD", imbue = "windfury",
        },
        {
            name = "Enhancement DW — PvP",
            spec = "Enhancement", role = "Damage", context = "PVP",
            weaponSetup = "DUAL_WIELD", imbue = "windfury",
        },
        {
            name = "Elemental — PvE",
            spec = "Elemental", role = "Damage", context = "PVE",
            weaponSetup = "1H_SHIELD", imbue = "none",
        },
        {
            name = "Elemental — PvP",
            spec = "Elemental", role = "Damage", context = "PVP",
            weaponSetup = "1H_SHIELD", imbue = "none",
        },
        {
            name = "Restoration — PvE",
            spec = "Restoration", role = "Healer", context = "PVE",
            weaponSetup = "1H_SHIELD", imbue = "none",
        },
        {
            name = "Restoration — PvP",
            spec = "Restoration", role = "Healer", context = "PVP",
            weaponSetup = "1H_SHIELD", imbue = "none",
        },
    },
    usable = {
        armour = {
            Cloth   = true,
            Leather = true,
            Mail    = { fromLevel = 40 },
            Plate   = { never = true },
            Shield  = true,
        },
        weapons = {
            Axe1H    = true,
            Axe2H    = true,
            Mace1H   = true,
            Mace2H   = true,
            Staff    = true,
            Dagger   = true,
            Fist     = true,
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
            id = "shaman_mainhand_imbue",
            label = "Shaman main-hand weapon imbue",
            optionKey = "shamanImbueReminder",
            help = "Reads the main-hand weapon enchant, because an imbue is not an "
                .. "aura. Not applicable until the character has learned an imbue. "
                .. "The four ids below are the shipped ones and none is guessed.",
            auras = {},
            -- Rockbiter, Flametongue, Frostbrand, Windfury Weapon.
            spells = { 8017, 8024, 8033, 8232 },
            message = "No main-hand Shaman imbue detected. Apply the intended imbue.",
            expiringThreshold = 5 * 60 * 1000,
            -- The one reminder that already defaulted on before this data moved.
            default = true,
        },
    },
    quirks = {
        {
            id = "imbue_procs",
            label = "Windfury extra attacks",
            stat = "weaponDPS",
            note = "Imbues:AdjustStats raises the weapon channels when imbue "
                .. "scoring is on, and the extra swings are not added to any other "
                .. "weight. Off by default, so nothing changes until it is ticked.",
        },
        {
            id = "shock_spell_power",
            label = "Shock damage from spell power",
            stat = "spellPower",
            note = "Enhancement's 0.10 spellPower weight is the only place shock "
                .. "damage is valued; it is not re-added on top of the weapon channels.",
        },
        {
            id = "rockbiter_threat",
            label = "Rockbiter threat",
            unvalued = "threat generation has no stat channel and no weight in "
                .. "this addon, so a threat number could only be invented",
            note = "The Enhancement tank profile is a starting point, not a threat "
                .. "model.",
        },
    },
})
