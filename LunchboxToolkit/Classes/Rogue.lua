--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Classes\Rogue
    The Rogue class pack. Data only; see ClassPacks.lua for the contract.

    usable comes from the armour and weapon tables the player supplied on
    2026-10-27 (WoW Classic rules, NOT yet verified on Forever):

      * mail and plate are never usable: no score, grey "Unusable" line;
      * axes (both hands), polearms and staves are never usable.

    The ranged and off-hand slot table supplied the same day adds two refusals: a
    wand belongs to Mage, Priest and Warlock only, and a shield to Warrior,
    Paladin and Shaman only. Bows, guns, crossbows and thrown weapons are a
    Rogue's own, so they need no rule.

    Deliberately absent: cloth and leather need no rule. Relics (librams, totems,
    idols) and "held in off-hand" frills stay unknown because this client's armour
    subclasses for them are unconfirmed.

    specRoles and templates are authored here because a Rogue has only one role:
    Assassination, Combat and Subtlety are all Damage. The three levelling PvE
    starters come first, one per spec, and all use DUAL_WIELD because that is how
    the class levels (and the class default setup). The PvP starter for each spec
    follows on the same setup, because a bundled profile exists for that exact
    spec, role and context. A template names no profile key, so it can never hand
    one player's weights to another.

    No template claims a poison: poisons are behaviour, not class data, and live
    in the optional LunchboxToolkit_Rogue plugin. Poison damage is not scored
    anywhere — the core has no stat key with a unit and conversion for it.

    buffs carries the poison hint as data. This client exposes a poison only as a
    temporary weapon enhancement, never as a player aura, so the entry declares no
    aura names: the generic check then reports "unknown" and the reminder stays
    silent rather than warning from a guess. The readable main-hand check is the
    optional plugin's (T-06), which owns its own option key.

    quirks records the two poison-adjacent gaps: poison damage itself, and the
    off-hand speed that drives poison and instant attacks. weaponSpeed is a channel
    the scorer has, but no Rogue table weights it, so naming it here would mint a
    weight key; both quirks stay unvalued.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit
if not (LT and LT.ClassPacks) then return end

LT.ClassPacks:Register("ROGUE", {
    apiVersion = 1,
    specRoles = {
        Assassination = "Damage",
        Combat        = "Damage",
        Subtlety      = "Damage",
    },
    templates = {
        {
            key         = "rogue_assassination_levelling_pve",
            name        = "Levelling PvE — Assassination",
            spec        = "Assassination",
            role        = "Damage",
            context     = "PVE",
            weaponSetup = "DUAL_WIELD",
        },
        {
            key         = "rogue_combat_levelling_pve",
            name        = "Levelling PvE — Combat",
            spec        = "Combat",
            role        = "Damage",
            context     = "PVE",
            weaponSetup = "DUAL_WIELD",
        },
        {
            key         = "rogue_subtlety_levelling_pve",
            name        = "Levelling PvE — Subtlety",
            spec        = "Subtlety",
            role        = "Damage",
            context     = "PVE",
            weaponSetup = "DUAL_WIELD",
        },
        {
            key         = "rogue_assassination_damage_pvp",
            name        = "PvP — Assassination",
            spec        = "Assassination",
            role        = "Damage",
            context     = "PVP",
            weaponSetup = "DUAL_WIELD",
        },
        {
            key         = "rogue_combat_damage_pvp",
            name        = "PvP — Combat",
            spec        = "Combat",
            role        = "Damage",
            context     = "PVP",
            weaponSetup = "DUAL_WIELD",
        },
        {
            key         = "rogue_subtlety_damage_pvp",
            name        = "PvP — Subtlety",
            spec        = "Subtlety",
            role        = "Damage",
            context     = "PVP",
            weaponSetup = "DUAL_WIELD",
        },
    },
    usable = {
        armour = {
            Mail   = { never = true },
            Plate  = { never = true },
            Shield = { never = true },
        },
        weapons = {
            Axe1H   = { never = true },
            Axe2H   = { never = true },
            Polearm = { never = true },
            Staff   = { never = true },
            Wand    = { never = true },
        },
    },
    buffs = {
        {
            id = "rogue_poison_hint",
            label = "Rogue poison hint",
            optionKey = "roguePoisonHint",
            help = "A hint, not a check: a poison is a temporary weapon "
                .. "enhancement in this client and never a player aura, so this "
                .. "entry has nothing to look for and stays silent. The readable "
                .. "reminder is the optional LunchboxToolkit_Rogue plugin (T-06).",
            -- Deliberately empty: no aura reports a poison on this client, and a
            -- guessed aura name would produce a false "missing" warning.
            auras = {},
            spells = {},
            message = "Rogue poisons cannot be read by this addon yet; check both weapons.",
            expiringThreshold = 5 * 60 * 1000,
            default = false,
        },
    },
    quirks = {
        {
            id = "poison_damage",
            label = "Poison damage",
            unvalued = "nature damage from a poison has no stat channel with a "
                .. "unit and a conversion; adding one would be a new weight",
            note = "T-06 records the same gap. The poison entry above is a hint "
                .. "and never adds a score.",
        },
        {
            id = "offhand_speed",
            label = "Off-hand weapon speed",
            unvalued = "weaponSpeed is a channel the scorer has, but no Rogue "
                .. "table weights it, and naming it a weight here would mint a new "
                .. "weight key",
            note = "The off-hand's effect on poison and instant attacks is "
                .. "therefore not scored, and nothing stands in for it.",
        },
    },
})
