--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Classes\Warlock
    The Warlock class pack. Data only; see ClassPacks.lua for the contract.

    usable comes from the armour and weapon tables the player supplied on
    2026-10-27 (WoW Classic rules, NOT yet verified on Forever). It matches the
    Mage's list, which is what the supplied table says:

      * leather, mail and plate are never usable: no score, grey "Unusable" line;
      * axes, maces, polearms, fist weapons, bows, crossbows, guns and thrown are
        never usable. Swords, staves, daggers and wands are: no rule needed.

    The off-hand slot table supplied the same day adds one refusal: a shield
    belongs to Warrior, Paladin and Shaman only. Wands are a Warlock's own, so
    they need no rule.

    Cloth needs no rule. Relics and "held in off-hand" frills carry no claim yet:
    the slot table covers them, but this client's armour subclasses for them are
    unconfirmed, so both stay unknown.

    specRoles maps all three specs ClassData lists to Damage, the only role the
    class has. templates ships one levelling PvE starter per spec on a staff (the
    two-handed setup) first, then the PvP starter for the same spec, role and
    setup; each of those rows has a bundled profile in both contexts. No template
    names a profile key or an imbue, so the bundled base profile is resolved from
    class, spec, role and context.

    buffs carries three reminders, all off by default. The demon-armour entry
    moved here with its id and option key unchanged. The two checks added on
    2026-10-29 are the summoned demon and the soul-shard count; they are declared
    here as data only, and the client reads behind them live in ClassData.lua's
    specialBuffs table (a pet and a bag count are not auras, so a buff entry
    cannot express them):
      * summoned demon — warns when no demon is out, or when it is dead. The
        Demonic Sacrifice talent deliberately removes the demon, which would turn
        this into a false nag, so the reader suppresses the warning for at most
        120 seconds after the aura is seen and stops suppressing the moment the
        player is out of combat. The aura name "Demonic Sacrifice" is the one
        thing the 2026-10-29 notes do not give: it is a best guess, unverified
        in game, and the switch stays off until somebody reads it;
      * soul shards — item 6265 through C_Item.GetItemCount, falling back to
        GetItemCount. Warns at 0 or 1. The item id is the note's and has not
        been re-read in game.
    Each entry keeps a fixed message for BuffMonitor and returns a message
    carrying the number for a surface that can show it. Nothing summons,
    dismisses, casts or consumes anything.

    quirks: shadow damage and the demon's own contribution have no item channel
    and stay unvalued; Life Tap's health-to-mana trade rides the stamina weight
    every Warlock table already carries and is not added twice.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit
if not (LT and LT.ClassPacks) then return end

LT.ClassPacks:Register("WARLOCK", {
    apiVersion = 1,
    specRoles = {
        Affliction  = "Damage",
        Demonology  = "Damage",
        Destruction = "Damage",
    },
    templates = {
        {
            name = "Affliction — Levelling PvE",
            spec = "Affliction", role = "Damage", context = "PVE",
            weaponSetup = "2H",
        },
        {
            name = "Demonology — Levelling PvE",
            spec = "Demonology", role = "Damage", context = "PVE",
            weaponSetup = "2H",
        },
        {
            name = "Destruction — Levelling PvE",
            spec = "Destruction", role = "Damage", context = "PVE",
            weaponSetup = "2H",
        },
        {
            key = "warlock_affliction_damage_pvp",
            name = "Affliction — PvP",
            spec = "Affliction", role = "Damage", context = "PVP",
            weaponSetup = "2H",
        },
        {
            key = "warlock_demonology_damage_pvp",
            name = "Demonology — PvP",
            spec = "Demonology", role = "Damage", context = "PVP",
            weaponSetup = "2H",
        },
        {
            key = "warlock_destruction_damage_pvp",
            name = "Destruction — PvP",
            spec = "Destruction", role = "Damage", context = "PVP",
            weaponSetup = "2H",
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
            id = "warlock_demon_armor",
            label = "Demon armour",
            optionKey = "warlockDemonArmorReminder",
            help = "Warns when neither Demon Skin nor Demon Armor is on the player. "
                .. "A summoned demon is the other part of the pair and has its own "
                .. "switch (Summoned demon); this entry watches the aura only.",
            auras = { "Demon Skin", "Demon Armor" },
            spells = {},
            message = "No demon armour is active (Demon Skin or Demon Armor).",
            expiringThreshold = 5 * 60 * 1000,
            default = false,
        },
        {
            id = "warlock_pet",
            label = "Summoned demon",
            optionKey = "warlockPet",
            help = "Warns when no demon is out or the demon is dead. Demonic "
                .. "Sacrifice removes the demon on purpose, so the warning is "
                .. "suppressed for up to 120 seconds after that aura is seen, and "
                .. "stops being suppressed once you leave combat. The aura name is "
                .. "UNVERIFIED on this client: confirm it in game before leaving "
                .. "this switch on.",
            auras = {},
            spells = {},
            message = "No demon is summoned, or it is dead.",
            expiringThreshold = 2 * 60 * 1000,
            default = false,
        },
        {
            id = "warlock_soul_shards",
            label = "Soul shards",
            optionKey = "warlockShards",
            help = "Warns when the bags hold 0 or 1 soul shards (item 6265), which "
                .. "is when summoning, a healthstone or a soul burn is about to "
                .. "fail. The item id is the one the 2026-10-29 notes give and has "
                .. "not been re-read in game.",
            auras = {},
            spells = {},
            message = "You have one or no soul shards left.",
            expiringThreshold = 2 * 60 * 1000,
            default = false,
        },
    },
    quirks = {
        {
            id = "shadow_damage",
            label = "Shadow damage",
            unvalued = "the item scan reports no shadow-damage channel, so shadow "
                .. "damage on an item cannot be weighted",
            note = "The same gap is noted beside the Affliction weights; spell hit "
                .. "and spell power stand in, and nothing else is added.",
        },
        {
            id = "pet_scaling",
            label = "Demon scaling",
            unvalued = "the demon's damage scales with a share of the warlock's "
                .. "spell power and stamina, but its contribution is not an item "
                .. "channel",
            note = "The demon is a maintenance choice, not a scored stat; no pet "
                .. "weight is invented.",
        },
        {
            id = "life_tap",
            label = "Life Tap",
            stat = "stamina",
            note = "Life Tap trades health for mana, and the stamina weight every "
                .. "Warlock table carries is where that trade is valued; Affliction's "
                .. "spirit weight covers regeneration and the two are not summed twice.",
        },
    },
})
