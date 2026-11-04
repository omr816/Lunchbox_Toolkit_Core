--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Classes\Hunter
    The Hunter class pack. Data only; see ClassPacks.lua for the contract.

    usable comes from the armour and weapon tables the player supplied on
    2026-10-27 (WoW Classic rules, NOT yet verified on Forever), with one fact the
    player confirmed for this client the same day — mail at 40:

      * plate is never usable: no score, one grey "Unusable" line;
      * mail is wearable from level 40 — confirmed by the player on 2026-10-27
        ("shaman and hunter is mail @ level 40") — so mail below 40 still scores
        and is outlined orange;
      * maces are never usable, in either hand.

    The ranged and off-hand slot table supplied the same day adds three more
    refusals: wands (Mage, Priest and Warlock only), shields (Warrior, Paladin and
    Shaman only) and thrown weapons (Warrior and Rogue only). Bows, guns and
    crossbows are a Hunter's own, so they need no rule.

    Cloth and leather need no rule. Relics (librams, totems, idols) and "held in
    off-hand" frills stay unknown: the slot table covers them, but this client's
    armour subclasses for them are unconfirmed.

    specRoles and templates: all three specs are Damage, the only role the class
    declares. templates ships the three levelling PvE starter configurations
    first, one per spec, each on the RANGED setup a Hunter's damage comes from.
    The PvP starter for each spec follows on the same setup, because a bundled
    profile exists for that exact spec, role and context. None names a profile
    key and none carries an imbue: no Hunter weapon-imbue option exists.

    buffs carries four reminders, all off by default. The aspect reminder moved
    here from ClassData with its id and option key unchanged; the aura entry
    stays the shipped "Aspect of" prefix as a pattern. The three checks added on
    2026-10-29 are ammo count, ammo type and pet health: each one is declared
    here as data only, and the client read behind it lives in ClassData.lua's
    specialBuffs table (an ammo count and a pet's health are not auras, so a
    buff entry cannot express them). Every reader they use is pcall'd and has
    never been exercised in game on this client, which is why none of the three
    starts on:
      * ammo count — GetInventoryItemCount on the ammo slot, then the slotted
        item's id through C_Item.GetItemCount / GetItemCount. Warns under 200.
        A thrown weapon is its own stack, so the check reports "does not apply"
        instead of warning;
      * ammo type — the ranged weapon's subclass sets what is needed (bow and
        crossbow: arrows, gun: bullets); the ammo slot's subclass is held
        against it. An unrecognised string on either side is silent, never a
        warning;
      * pet health — dead, or at 5% health or less. No pet at all is fine:
        Lone Wolf is a real talent here and a pet-less Hunter is never nagged.
    Each entry keeps a fixed message for BuffMonitor and returns a message
    carrying the number (or the dead/no-pet distinction) for a surface that can
    show it. Nothing picks, buys, moves or equips ammo or a pet.

    quirks names the three things the score cannot see: the pet's share of the
    damage, trap threat, and ranged attack power — which is reported on its own
    channel while the Hunter tables weight attackPower. None of the three is
    converted into a weight.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit
if not (LT and LT.ClassPacks) then return end

LT.ClassPacks:Register("HUNTER", {
    apiVersion = 1,
    specRoles = {
        ["Beast Mastery"] = "Damage",
        Marksmanship      = "Damage",
        Survival          = "Damage",
    },
    templates = {
        {
            name = "Beast Mastery — Levelling PvE",
            spec = "Beast Mastery", role = "Damage", context = "PVE",
            weaponSetup = "RANGED",
        },
        {
            name = "Marksmanship — Levelling PvE",
            spec = "Marksmanship", role = "Damage", context = "PVE",
            weaponSetup = "RANGED",
        },
        {
            name = "Survival — Levelling PvE",
            spec = "Survival", role = "Damage", context = "PVE",
            weaponSetup = "RANGED",
        },
        {
            key = "hunter_beast_mastery_damage_pvp",
            name = "Beast Mastery — PvP",
            spec = "Beast Mastery", role = "Damage", context = "PVP",
            weaponSetup = "RANGED",
        },
        {
            key = "hunter_marksmanship_damage_pvp",
            name = "Marksmanship — PvP",
            spec = "Marksmanship", role = "Damage", context = "PVP",
            weaponSetup = "RANGED",
        },
        {
            key = "hunter_survival_damage_pvp",
            name = "Survival — PvP",
            spec = "Survival", role = "Damage", context = "PVP",
            weaponSetup = "RANGED",
        },
    },
    usable = {
        armour = {
            Mail   = { fromLevel = 40 },
            Plate  = { never = true },
            Shield = { never = true },
        },
        weapons = {
            Mace1H = { never = true },
            Mace2H = { never = true },
            Thrown = { never = true },
            Wand   = { never = true },
        },
    },
    buffs = {
        {
            id = "hunter_aspect",
            label = "Hunter aspect",
            optionKey = "hunterAspectReminder",
            help = "Warns when no aspect buff is on the player. The aura entry is "
                .. "the shipped \"Aspect of\" pattern; confirm the aspect name in "
                .. "game before relying on it. It never casts an aspect.",
            auras = { "Aspect of" },
            spells = {},
            message = "No Hunter aspect is active.",
            expiringThreshold = 2 * 60 * 1000,
            default = false,
        },
        {
            id = "hunter_ammo_low",
            label = "Ammo supply",
            optionKey = "hunterAmmoLow",
            help = "Warns when the ammo slot holds fewer than 200 rounds. The count "
                .. "comes from GetInventoryItemCount on the ammo slot, falling back "
                .. "to the slotted item's id; neither read has been seen working on "
                .. "this client. A thrown weapon or an empty ranged slot is not "
                .. "checked. It never buys, moves or equips ammo.",
            auras = {},
            spells = {},
            message = "Ammo is running low (under 200 rounds).",
            expiringThreshold = 2 * 60 * 1000,
            default = false,
        },
        {
            id = "hunter_ammo_type",
            label = "Ammo type",
            optionKey = "hunterAmmoType",
            help = "Warns when the ammo slot does not match the ranged weapon: bows "
                .. "and crossbows take arrows, guns take bullets. A thrown weapon "
                .. "needs no ammo, and an unrecognised subclass string on this "
                .. "client stays silent rather than warning on a guess.",
            auras = {},
            spells = {},
            message = "The ammo in the slot does not match the ranged weapon.",
            expiringThreshold = 2 * 60 * 1000,
            default = false,
        },
    },
    quirks = {
        {
            id = "pet_scaling",
            label = "Pet scaling",
            unvalued = "the pet inherits a share of the hunter's attack power and "
                .. "stamina, but nothing on an item says how much of the damage "
                .. "comes from the pet; a pet weight would be a new channel",
            note = "Beast Mastery's attackPower weight (0.75 against 0.70) is the "
                .. "only allowance made, and it is a stated preference, not a "
                .. "conversion — the pet's damage is not scored a second time.",
        },
        {
            id = "trap_threat",
            label = "Trap threat",
            unvalued = "threat is not reported by any item channel and no threat "
                .. "weight exists in this addon",
            note = "Recorded so the gap is visible; nothing is assumed about how "
                .. "much threat a trap adds.",
        },
        {
            id = "ranged_attack_power",
            label = "Ranged attack power",
            unvalued = "the scan reports ranged attack power on its own channel, "
                .. "and no Hunter weight names it; adding one would be a new "
                .. "weight key",
            note = "The Hunter tables weight attackPower. Nothing maps one channel "
                .. "onto the other, so ranged attack power is not silently scored.",
        },
    },
})
