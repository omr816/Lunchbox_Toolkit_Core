--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Usability
    Decides whether the player can use an item: now, later, or never.

    Why this is not one question with a yes/no answer:

      never     the class can never use it. A Shaman never wears plate and
                never learns swords, so scoring such an item is noise: the
                tooltip says so and prints no number.
      deferred  usable, but not yet: the armour type is trained at a higher
                level (mail at 40), the weapon proficiency is still learnable,
                or the item itself requires a level the player has not reached.
                The score is still useful here — mail worth keeping until 40
                must not look like rubbish — so it is scored and marked.
      usable    no objection: today's behaviour, unchanged.
      unknown   the pack says nothing about this armour type, weapon type or
                class. The addon then behaves exactly as it did before this
                module existed. "Never" is never guessed from missing data.

    The per-class answers live in Classes/<Class>.lua in a `usable` block
    (Decision 7: class data in the core). This module only decides.

    One deferred cause is not a class claim at all: the weapon type itself. A
    class that does not refuse a weapon must still train the proficiency before
    it can equip one, so when the character does not have the skill the item is
    deferred and the tooltip names the city — "Train Two-Handed Axes in
    Orgrimmar". The seeded table is Classic's weapon masters from Warcraft Wiki
    (page "Weapon master", read 2026-10-27), cross-checked against Wowhead's
    classic weapon-skills guide at the player's request (2026-11-02). It is still
    provisional and player-correctable — a wrong city must be corrected here
    rather than worked around, and /lt test keeps the table honest:

      * skill spell  — /dump IsPlayerSpell(197) with a two-handed axe equipped
                       and again after training one;
      * trainer      — stand at the weapon master and read his name and zone off
                       the tooltip, then fix the entry below.

    The skill check fails safe. An id the client does not resolve, a missing
    proficiency API or a character with no trained state produces no claim at all:
    the item is then judged only by its pack and its own level requirement, exactly
    as before. The hint is faction-aware only when a city can be named; otherwise
    it falls back to "See a weapon master", which answers "can this be learned",
    not "where".

    Nothing here asks the client for the verdict. C_PlayerInfo.CanUseItem is
    already read in ItemStats and answers a narrower question — the client's own
    "can this be equipped", which does not distinguish "never" from "not yet".
    Compare asks this module first (RefusalIsFinal), so a "not yet" item keeps its
    score and is painted green instead of being blanked as unusable.

    The tooltip tells the four answers apart by colour, and this module's answer
    outranks a comparison's: DEFERRED (green) and NEVER (grey) are conclusions the
    panel states even when no build could score the item, so neither may be
    repainted red. Red — "the add-on cannot answer" — is for UNKNOWN with nothing
    scored. Tooltip:ToneFor holds that precedence.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Usability = {}
LT.Usability = Usability
LT.Modules.Usability = Usability

Usability.USABLE   = "usable"
Usability.DEFERRED = "deferred"
Usability.NEVER    = "never"
Usability.UNKNOWN  = "unknown"

-- Item classIDs as C_Item.GetItemInfoInstant reports them.
Usability.ITEM_CLASS_WEAPON = 2
Usability.ITEM_CLASS_ARMOUR = 4

-- Subclass names as the class packs spell them. The numbers are the client's own
-- item-subclass ids; the names are what goes into Classes/<Class>.lua so the
-- data reads like English.
Usability.ARMOUR_SUBCLASS = {
    [1] = "Cloth",
    [2] = "Leather",
    [3] = "Mail",
    [4] = "Plate",
    [6] = "Shield",
}

Usability.WEAPON_SUBCLASS = {
    [0]  = "Axe1H",
    [1]  = "Axe2H",
    [2]  = "Bow",
    [3]  = "Gun",
    [4]  = "Mace1H",
    [5]  = "Mace2H",
    [6]  = "Polearm",
    [7]  = "Sword1H",
    [8]  = "Sword2H",
    [10] = "Staff",
    [13] = "Fist",
    [15] = "Dagger",
    [16] = "Thrown",
    [18] = "Crossbow",
    [19] = "Wand",
}

Usability.families = { "armour", "weapons" }

-----------------------------------------------------------------------------
-- Weapon proficiency: what proves it, and where it is trained
-----------------------------------------------------------------------------

-- The item keys are the pack's shorthand; these are what a tooltip should say.
Usability.SKILL_LABEL = {
    Axe1H    = "One-Handed Axes",
    Axe2H    = "Two-Handed Axes",
    Mace1H   = "One-Handed Maces",
    Mace2H   = "Two-Handed Maces",
    Sword1H  = "One-Handed Swords",
    Sword2H  = "Two-Handed Swords",
    Polearm  = "Polearms",
    Staff    = "Staves",
    Dagger   = "Daggers",
    Fist     = "Fist Weapons",
    Bow      = "Bows",
    Gun      = "Guns",
    Crossbow = "Crossbows",
    Thrown   = "Thrown Weapons",
    Wand     = "Wands",
}

-- The order the proficiency list is shown in: the client's own subclass ids, so
-- there is no second hand-maintained list to drift from WEAPON_SUBCLASS. Every
-- type SKILL_LABEL names is listed; anything a future client adds without a
-- label is skipped rather than drawn as a bare key.
Usability.WEAPON_ORDER = {}
do
    local ids = {}
    for subclassID in pairs(Usability.WEAPON_SUBCLASS) do
        ids[#ids + 1] = subclassID
    end

    table.sort(ids)

    for _, subclassID in ipairs(ids) do
        local key = Usability.WEAPON_SUBCLASS[subclassID]
        if Usability.SKILL_LABEL[key] then
            Usability.WEAPON_ORDER[#Usability.WEAPON_ORDER + 1] = key
        end
    end
end

-- The spell a character learns when the proficiency is trained. Vanilla's ids:
-- 196 Axes, 197 Two-Handed Axes, 198 Maces, 199 Two-Handed Maces, 200 Polearms,
-- 201 Swords, 202 Two-Handed Swords, 227 Staves, 264 Bows, 266 Guns,
-- 1180 Daggers, 2567 Thrown, 5009 Wands, 5011 Crossbows, 15590 Fist Weapons.
-- Unconfirmed on Forever: see the header for the two-line probe, and remember
-- that a resolved id is required before any claim is made.
Usability.PROFICIENCY_SPELL = {
    Axe1H    = 196,
    Axe2H    = 197,
    Mace1H   = 198,
    Mace2H   = 199,
    Polearm  = 200,
    Sword1H  = 201,
    Sword2H  = 202,
    Staff    = 227,
    Bow      = 264,
    Gun      = 266,
    Dagger   = 1180,
    Thrown   = 2567,
    Wand     = 5009,
    Crossbow = 5011,
    Fist     = 15590,
}

-- Provisional and player-correctable: Classic's weapon masters as Warcraft Wiki
-- lists them (page "Weapon master", read 2026-10-27). One skill per line, most
-- convenient trainer first; only the first is printed, the rest are kept so a
-- correction has somewhere to go and so the full list can be shown later.
-- Wands appear in no weapon master's list — the class trainer teaches them — so a
-- wand keeps its "not trained yet" reason and prints no trainer line.
Usability.TRAINERS_SOURCE = "Warcraft Wiki, \"Weapon master\", read 2026-10-27"

Usability.TRAINERS = {
    Horde = {
        Axe1H    = { { trainer = "Hanashi",   zone = "Valley of Honor, Orgrimmar" },
                     { trainer = "Sayoc",     zone = "Valley of Honor, Orgrimmar" } },
        Axe2H    = { { trainer = "Hanashi",   zone = "Valley of Honor, Orgrimmar" },
                     { trainer = "Sayoc",     zone = "Valley of Honor, Orgrimmar" } },
        Mace1H   = { { trainer = "Ansekhwa",  zone = "Lower Rise, Thunder Bluff" } },
        Mace2H   = { { trainer = "Ansekhwa",  zone = "Lower Rise, Thunder Bluff" } },
        Sword1H  = { { trainer = "Archibald", zone = "War Quarter, Undercity" } },
        Sword2H  = { { trainer = "Archibald", zone = "War Quarter, Undercity" } },
        Polearm  = { { trainer = "Archibald", zone = "War Quarter, Undercity" } },
        Staff    = { { trainer = "Hanashi",   zone = "Valley of Honor, Orgrimmar" },
                     { trainer = "Sayoc",     zone = "Valley of Honor, Orgrimmar" },
                     { trainer = "Ansekhwa",  zone = "Lower Rise, Thunder Bluff" } },
        Dagger   = { { trainer = "Sayoc",     zone = "Valley of Honor, Orgrimmar" },
                     { trainer = "Archibald", zone = "War Quarter, Undercity" } },
        Fist     = { { trainer = "Sayoc",     zone = "Valley of Honor, Orgrimmar" } },
        Bow      = { { trainer = "Hanashi",   zone = "Valley of Honor, Orgrimmar" },
                     { trainer = "Sayoc",     zone = "Valley of Honor, Orgrimmar" } },
        Gun      = { { trainer = "Ansekhwa",  zone = "Lower Rise, Thunder Bluff" } },
        Crossbow = { { trainer = "Archibald", zone = "War Quarter, Undercity" } },
        Thrown   = { { trainer = "Hanashi",   zone = "Valley of Honor, Orgrimmar" },
                     { trainer = "Sayoc",     zone = "Valley of Honor, Orgrimmar" } },
    },
    Alliance = {
        Axe1H    = { { trainer = "Buliwyf Stonehand", zone = "Military Ward, Ironforge" } },
        Axe2H    = { { trainer = "Buliwyf Stonehand", zone = "Military Ward, Ironforge" } },
        Mace1H   = { { trainer = "Buliwyf Stonehand", zone = "Military Ward, Ironforge" } },
        Mace2H   = { { trainer = "Buliwyf Stonehand", zone = "Military Ward, Ironforge" } },
        Sword1H  = { { trainer = "Woo Ping",          zone = "Trade District, Stormwind" } },
        Sword2H  = { { trainer = "Woo Ping",          zone = "Trade District, Stormwind" } },
        Polearm  = { { trainer = "Woo Ping",          zone = "Trade District, Stormwind" } },
        Staff    = { { trainer = "Ilyenia Moonfire",  zone = "Warrior's Terrace, Darnassus" },
                     { trainer = "Woo Ping",          zone = "Trade District, Stormwind" } },
        Dagger   = { { trainer = "Ilyenia Moonfire",  zone = "Warrior's Terrace, Darnassus" },
                     { trainer = "Bixi Wobblebonk",   zone = "Military Ward, Ironforge" },
                     { trainer = "Woo Ping",          zone = "Trade District, Stormwind" } },
        Fist     = { { trainer = "Ilyenia Moonfire",  zone = "Warrior's Terrace, Darnassus" },
                     { trainer = "Buliwyf Stonehand", zone = "Military Ward, Ironforge" } },
        Bow      = { { trainer = "Ilyenia Moonfire",  zone = "Warrior's Terrace, Darnassus" } },
        Gun      = { { trainer = "Buliwyf Stonehand", zone = "Military Ward, Ironforge" } },
        Crossbow = { { trainer = "Bixi Wobblebonk",   zone = "Military Ward, Ironforge" },
                     { trainer = "Woo Ping",          zone = "Trade District, Stormwind" } },
        Thrown   = { { trainer = "Ilyenia Moonfire",  zone = "Warrior's Terrace, Darnassus" },
                     { trainer = "Bixi Wobblebonk",   zone = "Military Ward, Ironforge" } },
    },
}

-- Which weapon types a weapon master teaches at all, derived from the table above
-- so the two can never disagree. Faction-independent on purpose: the hint answers
-- "can a weapon master teach this", not "in which city".
Usability.WEAPON_MASTER = {}
for _, byFaction in pairs(Usability.TRAINERS) do
    for key in pairs(byFaction) do
        Usability.WEAPON_MASTER[key] = true
    end
end

-- The whole of the hint that is printed. No trainer name and no city: see the
-- header for why the city stays unspoken until it has been read off a tooltip.
Usability.TRAINER_HINT = "See a weapon master"

-- "Two-Handed Axes" for Sword2H; an unknown key passes through unchanged so a new
-- item type never prints an empty name.
function Usability:GetLabel(key)
    return self.SKILL_LABEL[key] or tostring(key)
end

-- Where this faction trains the skill, or nil when nothing is known. NOT PRINTED:
-- see the header. Kept because /lt test uses it to keep the seeded table honest
-- (every entry needs a trainer and a zone) and because a future build may name the
-- city once it has been confirmed in game.
function Usability:GetTraining(key, faction)
    faction = faction or (LT.player and LT.player.faction)

    local byFaction = faction and self.TRAINERS[faction] or nil
    local entries = byFaction and byFaction[key] or nil
    local first = entries and entries[1] or nil

    if not first or not first.trainer or not first.zone then return nil end

    -- The faction token is printed as-is ("Horde"/"Alliance"): the rest of the
    -- addon's text is English, and mixing a localised faction name into an English
    -- sentence reads worse than the plain token.
    return {
        faction     = faction,
        trainer     = first.trainer,
        zone        = first.zone,
        provisional = true,
    }
end

-- Where to train the skill, or nil when no weapon master could teach this type.
-- The player's own word: name the city, not the generic line — a two-handed axe
-- trainer lives in Orgrimmar for Horde, and "train in Orgrimmar" beats "see a
-- weapon master". The zone string already carries the city ("Valley of Honor,
-- Orgrimmar"); the last comma-separated token is the city.
function Usability:DescribeTraining(trainable, key)
    if not trainable then return nil end

    if type(key) == "string" and key ~= "" then
        local training = self:GetTraining(key)
        local zone = training and training.zone

        if type(zone) == "string" and zone ~= "" then
            local city = zone:match("([^,]+)$")
            city = city and city:gsub("^%s+", "") or zone
            return "Train " .. tostring(self:GetLabel(key)) .. " in " .. city
        end
    end

    return self.TRAINER_HINT
end

-- Does the client resolve this spell id at all? Without this the proficiency check
-- could not tell "not trained" from "this id means something else here", and
-- every staff in the world would claim its owner needs training.
function Usability:ResolvesSpell(spellID)
    local getInfo = (type(C_Spell) == "table" and C_Spell.GetSpellInfo) or nil

    if getInfo then
        local ok, info = pcall(getInfo, spellID)
        if ok then return info ~= nil end
        return nil
    end

    if type(GetSpellInfo) == "function" then
        local ok, name = pcall(GetSpellInfo, spellID)
        if ok then return name ~= nil end
    end

    return nil
end

-- true  the character has the proficiency;
-- false the character does not have it;
-- nil   cannot be told — no id, no API, or an id this client does not resolve.
-- Only a clean false may become a claim; everything else is "no claim", so a
-- wrong id can only silence the hint.
function Usability:KnowsProficiency(key, spellID)
    spellID = spellID or self.PROFICIENCY_SPELL[key]
    if not spellID then return nil end

    if self:ResolvesSpell(spellID) ~= true then
        LT:Debug("proficiency check unavailable for " .. tostring(key)
            .. " (spell " .. tostring(spellID) .. " does not resolve)")
        return nil
    end

    local api = (type(IsPlayerSpell) == "function" and IsPlayerSpell)
        or (type(IsSpellKnown) == "function" and IsSpellKnown)
        or nil

    if not api then return nil end

    local ok, known = pcall(api, spellID)
    if not ok or known == nil then return nil end

    return known and true or false
end

-- The seeded weapon-master row for this faction, shaped for a list: the trainer
-- name, the zone as written ("Lower Rise, Thunder Bluff") and just the city a
-- player would look for. nil when no weapon master teaches the type (wands are
-- a class trainer's business) — the row then names no trainer rather than
-- inventing one.
local function trainerEntry(self, key, faction)
    local training = self:GetTraining(key, faction)
    if not training then return nil end

    local zone = training.zone
    local city

    if type(zone) == "string" and zone ~= "" then
        city = zone:match("([^,]+)$")
        if city then city = city:gsub("^%s+", "") end
    end

    return {
        name = training.trainer,
        zone = zone,
        city = city or zone,
    }
end

-- Every weapon type in WEAPON_ORDER, with the character's own state:
--
--   known     the client says the proficiency is trained (IsPlayerSpell);
--   learnable the class may use the type and the client does not say it is known;
--   never     the class pack refuses the type, so no trainer is named.
--
-- `trainer` is the seeded entry for the character's faction ({ name, zone,
-- city }) whenever the weapon-master table has one; it is nil for a `never`
-- type and for a type no weapon master teaches. `spellID` is the id the check
-- used, so a probe can report it.
--
-- A client that cannot answer (no id, no API) never produces a clean "known":
-- KnowsProficiency returns nil and the row stays `learnable`, which is what the
-- class allows and where a weapon master would teach it. Only a `never` rule
-- colours a row red.
function Usability:ListProficiency(classToken)
    classToken = classToken or (LT.player and LT.player.class)
    local faction = LT.player and LT.player.faction
    local list = {}

    for _, key in ipairs(self.WEAPON_ORDER or {}) do
        local rule = classToken and self:GetRule(classToken, "weapons", key) or nil
        local never = type(rule) == "table" and rule.never == true
        local state

        if never then
            state = "never"
        elseif self:KnowsProficiency(key) == true then
            state = "known"
        else
            state = "learnable"
        end

        local entry = {
            kind = key,
            label = self:GetLabel(key),
            state = state,
            spellID = self.PROFICIENCY_SPELL[key],
        }

        if state ~= "never" then
            entry.trainer = trainerEntry(self, key, faction)
        end

        list[#list + 1] = entry
    end

    return list
end

-- Returns the pack key ("Mail", "Sword2H") and its family ("armour", "weapons")
-- for an item, or nil when the item is neither armour nor a weapon.
function Usability:GetItemKey(classID, subClassID)
    if classID == self.ITEM_CLASS_ARMOUR then
        return self.ARMOUR_SUBCLASS[subClassID], "armour"
    end

    if classID == self.ITEM_CLASS_WEAPON then
        return self.WEAPON_SUBCLASS[subClassID], "weapons"
    end

    return nil, nil
end

function Usability:IsKnownSubclass(family, key)
    local map = (family == "armour" and self.ARMOUR_SUBCLASS)
        or (family == "weapons" and self.WEAPON_SUBCLASS)
        or nil

    if not map then return false end

    for _, name in pairs(map) do
        if name == key then return true end
    end

    return false
end

-- The rule the character's class pack carries for this armour/weapon type.
-- nil means "the pack says nothing", which is not the same as "never".
function Usability:GetRule(classToken, family, key)
    local pack = LT.ClassPacks and LT.ClassPacks.Get and LT.ClassPacks:Get(classToken)
    local usable = pack and pack.usable
    local group = usable and usable[family]

    return group and group[key] or nil
end

local function className(classToken)
    if LT.ClassData and LT.ClassData.GetClassName then
        return LT.ClassData:GetClassName(classToken)
    end
    return tostring(classToken)
end

-- Pure verdict, no client calls: everything it needs is passed in, which is what
-- lets SelfTest exercise it without a character in the world. `options` carries
-- what the caller already looked up: options.proficiency is a key -> true/false
-- map from KnowsProficiency.
function Usability:Classify(identity, classToken, playerLevel, options)
    if type(identity) ~= "table" then
        return { verdict = self.UNKNOWN }
    end

    local key, family = self:GetItemKey(identity.classID, identity.subClassID)
    local rule = (key and classToken) and self:GetRule(classToken, family, key) or nil
    local level = tonumber(playerLevel)
    local required = tonumber(identity.requiredLevel)

    -- A class that can never use the type outranks everything else: no level,
    -- no proficiency and no patience ever changes it.
    if type(rule) == "table" and rule.never then
        return {
            verdict = self.NEVER,
            key = key,
            family = family,
            reason = className(classToken) .. " can never use " .. tostring(key),
        }
    end

    -- A weapon the class does not refuse can still be one this character has not
    -- trained. That is the only verdict built from the character's own state, and
    -- only a clean "does not have it" may become a claim (KnowsProficiency).
    -- It outranks the item's level requirement because the training is the step
    -- the player can take first, and `trainable` is what the tooltip turns into
    -- "See a weapon master".
    local known = nil
    if type(options) == "table" and type(options.proficiency) == "table" then
        known = options.proficiency[key]
    end

    if family == "weapons" and known == false then
        return {
            verdict   = self.DEFERRED,
            key       = key,
            family    = family,
            cause     = "proficiency",
            -- Faction-independent: a weapon master teaches this type either way.
            trainable = self.WEAPON_MASTER[key] == true,
            reason    = self:GetLabel(key) .. " are not trained yet",
        }
    end

    -- The item's own level requirement is plain item data, not a class claim, so
    -- it is honoured even for a class with no pack. Only "too low" is reported:
    -- at or above the requirement this says nothing.
    if required and level and required > level then
        return {
            verdict = self.DEFERRED,
            key = key,
            family = family,
            reason = "requires level " .. tostring(required) .. ", you are " .. tostring(level),
        }
    end

    if rule == true then
        return { verdict = self.USABLE, key = key, family = family }
    end

    if type(rule) == "table" and tonumber(rule.fromLevel) then
        local from = tonumber(rule.fromLevel)

        if not level then
            return { verdict = self.UNKNOWN, key = key, family = family }
        end

        if level < from then
            return {
                verdict = self.DEFERRED,
                key = key,
                family = family,
                reason = tostring(key) .. " is trained at level " .. tostring(from)
                    .. ", you are " .. tostring(level),
            }
        end

        return { verdict = self.USABLE, key = key, family = family }
    end

    return { verdict = self.UNKNOWN, key = key, family = family }
end

-- Convenience wrapper for callers that have a link: reads the identity the rest
-- of the addon already caches, uses the player's own class and level, and asks the
-- client about the one proficiency this item needs. The lookup is limited to
-- weapons on purpose — armour types are level-gated class claims, not skills.
function Usability:GetVerdict(itemLink, options)
    options = options or {}

    local identity = options.identity
    if not identity and LT.ItemStats and LT.ItemStats.GetIdentity then
        identity = LT.ItemStats:GetIdentity(itemLink)
    end

    local classToken = options.class or (LT.player and LT.player.class)
    local level = options.level or (LT.player and LT.player.level) or nil

    local call = {}
    local proficiency = options.proficiency

    if not proficiency and type(identity) == "table" then
        local key, family = self:GetItemKey(identity.classID, identity.subClassID)

        if key and family == "weapons" then
            local known = self:KnowsProficiency(key)
            if known ~= nil then
                proficiency = { [key] = known }
            end
        end
    end

    call.proficiency = proficiency

    return self:Classify(identity, classToken, level, call)
end
