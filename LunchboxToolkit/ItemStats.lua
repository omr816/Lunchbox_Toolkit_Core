--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — ItemStats
    Turns an item link into canonical stat channels.

    Sources, in order of reliability:
      1. C_Item.GetItemStats — localized ITEM_MOD_* keys (verified on Forever),
         normalised here into stable channel names.
      2. Structured tooltip data via C_TooltipInfo.GetHyperlink — the only way
         Forever exposes weapon damage range / speed and shield block value.
      3. C_Item.GetDetailedItemLevelInfo for item level.

    On a client with no stat API at all (Classic Era answers none of the calls
    above) the numbers are read back off the item's own tooltip text with a
    hidden GameTooltip: the same "19 Armor" and "+5 Stamina" lines the player
    sees. That route is only used when the API routes produced nothing.

    Anything the client returns that this addon does not model is collected as
    "unmapped" and reported. It is never silently treated as zero.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local ItemStats = {}
LT.ItemStats = ItemStats
LT.Modules.ItemStats = ItemStats

ItemStats.cache = {}

------------------------------------------------------------------------------
-- Canonical channels
------------------------------------------------------------------------------

LT.StatLabels = {
    strength          = "Strength",
    agility           = "Agility",
    stamina           = "Stamina",
    intellect         = "Intellect",
    spirit            = "Spirit",
    armor             = "Armor",
    defense           = "Defense Rating",
    dodge             = "Dodge Rating",
    parry             = "Parry Rating",
    block             = "Block Rating",
    blockValue        = "Block Value",
    hit               = "Hit Rating",
    crit              = "Crit Rating",
    haste             = "Haste Rating",
    attackPower       = "Attack Power",
    rangedAttackPower = "Ranged Attack Power",
    feralAttackPower  = "Feral Attack Power",
    expertise         = "Expertise Rating",
    armorPen          = "Armor Penetration",
    spellPower        = "Spell Power",
    healingPower      = "Healing Power",
    spellHit          = "Spell Hit Rating",
    spellCrit         = "Spell Crit Rating",
    spellHaste        = "Spell Haste Rating",
    mp5               = "Mana per 5 sec",
    hp5               = "Health per 5 sec",
    itemLevel         = "Item Level",
    weaponDPS         = "Weapon DPS",
    weaponAvgDamage   = "Weapon Average Damage",
    weaponSpeed       = "Weapon Speed",
    weaponSkill       = "Weapon Skill Rating",
    fireResist        = "Fire Resistance",
    frostResist       = "Frost Resistance",
    natureResist      = "Nature Resistance",
    shadowResist      = "Shadow Resistance",
    arcaneResist      = "Arcane Resistance",
}

-- Ordering used by the weight editors and breakdowns, primary stats first.
LT.StatOrder = {
    "strength", "agility", "stamina", "intellect", "spirit",
    "attackPower", "rangedAttackPower", "feralAttackPower",
    "hit", "crit", "haste", "expertise", "armorPen",
    "weaponDPS", "weaponAvgDamage", "weaponSpeed", "weaponSkill",
    "spellPower", "healingPower", "spellHit", "spellCrit", "spellHaste", "mp5", "hp5",
    "armor", "defense", "dodge", "parry", "block", "blockValue",
    "fireResist", "frostResist", "natureResist", "shadowResist", "arcaneResist",
    "itemLevel",
}

local statGroups = {
    { key = "primary",  label = "Primary",  stats = { "strength", "agility", "stamina", "intellect", "spirit" } },
    { key = "melee",    label = "Melee",    stats = { "attackPower", "rangedAttackPower", "feralAttackPower", "hit", "crit", "haste", "expertise", "armorPen", "weaponSkill" } },
    { key = "weapon",   label = "Weapon",   stats = { "weaponDPS", "weaponAvgDamage", "weaponSpeed" } },
    { key = "caster",   label = "Caster",   stats = { "spellPower", "healingPower", "spellHit", "spellCrit", "spellHaste", "mp5", "hp5" } },
    { key = "defense",  label = "Defense",  stats = { "armor", "defense", "dodge", "parry", "block", "blockValue" } },
    { key = "resist",   label = "Resistance", stats = { "fireResist", "frostResist", "natureResist", "shadowResist", "arcaneResist" } },
    { key = "other",    label = "Other",    stats = { "itemLevel" } },
}

ItemStats.statGroups = statGroups

------------------------------------------------------------------------------
-- Key normalisation
--
-- Forever returns localized keys such as ITEM_MOD_STRENGTH_SHORT, and folds
-- melee / ranged / spell hit and crit into shared channels. Weapon-skill keys
-- stay per weapon type: sword skill must never improve an axe.
------------------------------------------------------------------------------

local aliases = {
    ITEM_MOD_STRENGTH_SHORT = "strength", ITEM_MOD_STRENGTH = "strength",
    ITEM_MOD_AGILITY_SHORT = "agility", ITEM_MOD_AGILITY = "agility",
    ITEM_MOD_STAMINA_SHORT = "stamina", ITEM_MOD_STAMINA = "stamina",
    ITEM_MOD_INTELLECT_SHORT = "intellect", ITEM_MOD_INTELLECT = "intellect",
    ITEM_MOD_SPIRIT_SHORT = "spirit", ITEM_MOD_SPIRIT = "spirit",

    ITEM_MOD_ATTACK_POWER_SHORT = "attackPower", ITEM_MOD_ATTACK_POWER = "attackPower",
    ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "rangedAttackPower",
    ITEM_MOD_RANGED_ATTACK_POWER = "rangedAttackPower",
    ITEM_MOD_FERAL_ATTACK_POWER_SHORT = "feralAttackPower",
    ITEM_MOD_FERAL_ATTACK_POWER = "feralAttackPower",

    -- One shared hit channel and one shared crit channel on Forever.
    ITEM_MOD_HIT_RATING_SHORT = "hit", ITEM_MOD_HIT_RATING = "hit",
    ITEM_MOD_HIT_MELEE_RATING = "hit", ITEM_MOD_HIT_MELEE_RATING_SHORT = "hit",
    ITEM_MOD_HIT_RANGED_RATING = "hit", ITEM_MOD_HIT_RANGED_RATING_SHORT = "hit",
    ITEM_MOD_HIT_SPELL_RATING = "spellHit", ITEM_MOD_HIT_SPELL_RATING_SHORT = "spellHit",

    ITEM_MOD_CRIT_RATING_SHORT = "crit", ITEM_MOD_CRIT_RATING = "crit",
    ITEM_MOD_CRIT_MELEE_RATING = "crit", ITEM_MOD_CRIT_MELEE_RATING_SHORT = "crit",
    ITEM_MOD_CRIT_RANGED_RATING = "crit", ITEM_MOD_CRIT_RANGED_RATING_SHORT = "crit",
    ITEM_MOD_CRIT_SPELL_RATING = "spellCrit", ITEM_MOD_CRIT_SPELL_RATING_SHORT = "spellCrit",

    ITEM_MOD_HASTE_RATING_SHORT = "haste", ITEM_MOD_HASTE_RATING = "haste",
    ITEM_MOD_HASTE_MELEE_RATING = "haste", ITEM_MOD_HASTE_MELEE_RATING_SHORT = "haste",
    ITEM_MOD_HASTE_RANGED_RATING = "haste", ITEM_MOD_HASTE_RANGED_RATING_SHORT = "haste",
    ITEM_MOD_HASTE_SPELL_RATING = "spellHaste", ITEM_MOD_HASTE_SPELL_RATING_SHORT = "spellHaste",

    ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "defense", ITEM_MOD_DEFENSE_SKILL_RATING = "defense",
    ITEM_MOD_DODGE_RATING_SHORT = "dodge", ITEM_MOD_DODGE_RATING = "dodge",
    ITEM_MOD_PARRY_RATING_SHORT = "parry", ITEM_MOD_PARRY_RATING = "parry",
    ITEM_MOD_BLOCK_RATING_SHORT = "block", ITEM_MOD_BLOCK_RATING = "block",
    ITEM_MOD_BLOCK_VALUE_SHORT = "blockValue", ITEM_MOD_BLOCK_VALUE = "blockValue",
    ITEM_MOD_EXPERTISE_RATING_SHORT = "expertise", ITEM_MOD_EXPERTISE_RATING = "expertise",
    ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = "armorPen",
    ITEM_MOD_ARMOR_PENETRATION_RATING = "armorPen",

    ITEM_MOD_SPELL_POWER_SHORT = "spellPower", ITEM_MOD_SPELL_POWER = "spellPower",
    ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "spellPower",
    ITEM_MOD_SPELL_HEALING_DONE_SHORT = "healingPower",
    ITEM_MOD_HEALING_DONE_SHORT = "healingPower",
    ITEM_MOD_MANA_REGENERATION_SHORT = "mp5", ITEM_MOD_HEALTH_REGEN_SHORT = "hp5",

    RESISTANCE0_NAME = "armor",
    ITEM_MOD_ARMOR_SHORT = "armor", ITEM_MOD_ARMOR = "armor",

    ITEM_MOD_FIRE_RESISTANCE_SHORT = "fireResist", ITEM_MOD_FIRE_RESISTANCE = "fireResist",
    ITEM_MOD_FROST_RESISTANCE_SHORT = "frostResist", ITEM_MOD_FROST_RESISTANCE = "frostResist",
    ITEM_MOD_NATURE_RESISTANCE_SHORT = "natureResist", ITEM_MOD_NATURE_RESISTANCE = "natureResist",
    ITEM_MOD_SHADOW_RESISTANCE_SHORT = "shadowResist", ITEM_MOD_SHADOW_RESISTANCE = "shadowResist",
    ITEM_MOD_ARCANE_RESISTANCE_SHORT = "arcaneResist", ITEM_MOD_ARCANE_RESISTANCE = "arcaneResist",

    ITEM_MOD_DAMAGE_PER_SECOND_SHORT = "weaponDPS",
}

-- Weapon skill keys all land in one channel because Forever reports them per
-- weapon type and the addon does not yet know which type the build uses.
local weaponSkillKeys = {
    ITEM_MOD_SWORD_SKILL_RATING = true, ITEM_MOD_SWORD_SKILL_RATING_SHORT = true,
    ITEM_MOD_AXE_SKILL_RATING = true, ITEM_MOD_AXE_SKILL_RATING_SHORT = true,
    ITEM_MOD_MACE_SKILL_RATING = true, ITEM_MOD_MACE_SKILL_RATING_SHORT = true,
    ITEM_MOD_DAGGER_SKILL_RATING = true, ITEM_MOD_DAGGER_SKILL_RATING_SHORT = true,
    ITEM_MOD_2H_SWORD_SKILL_RATING = true, ITEM_MOD_2H_SWORD_SKILL_RATING_SHORT = true,
    ITEM_MOD_2H_AXE_SKILL_RATING = true, ITEM_MOD_2H_AXE_SKILL_RATING_SHORT = true,
    ITEM_MOD_2H_MACE_SKILL_RATING = true, ITEM_MOD_2H_MACE_SKILL_RATING_SHORT = true,
}

ItemStats.aliases = aliases

------------------------------------------------------------------------------
-- Equip locations
------------------------------------------------------------------------------

local equipSlots = {
    INVTYPE_HEAD        = { 1 },
    INVTYPE_NECK        = { 2 },
    INVTYPE_SHOULDER    = { 3 },
    INVTYPE_BODY        = { 4 },
    INVTYPE_CHEST       = { 5 },
    INVTYPE_ROBE        = { 5 },
    INVTYPE_WAIST       = { 6 },
    INVTYPE_LEGS        = { 7 },
    INVTYPE_FEET        = { 8 },
    INVTYPE_WRIST       = { 9 },
    INVTYPE_HAND        = { 10 },
    INVTYPE_FINGER      = { 11, 12 },
    INVTYPE_TRINKET     = { 13, 14 },
    INVTYPE_CLOAK       = { 15 },
    INVTYPE_WEAPON      = { 16, 17 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND  = { 17 },
    INVTYPE_2HWEAPON    = { 16 },
    INVTYPE_SHIELD      = { 17 },
    INVTYPE_HOLDABLE    = { 17 },
    INVTYPE_RANGED      = { 18 },
    INVTYPE_RANGEDRIGHT = { 18 },
    INVTYPE_THROWN      = { 18 },
    INVTYPE_RELIC       = { 18 },
}

ItemStats.equipSlots = equipSlots

-- Slot numbers are used numerically because Forever's slot constants are not
-- guaranteed to match a retail layout.
LT.InventorySlots = {
    { slot = 1,  label = "Head",       name = "head" },
    { slot = 2,  label = "Neck",       name = "neck" },
    { slot = 3,  label = "Shoulder",   name = "shoulder" },
    { slot = 4,  label = "Shirt",      name = "shirt",   cosmetic = true },
    { slot = 5,  label = "Chest",      name = "chest" },
    { slot = 6,  label = "Waist",      name = "waist" },
    { slot = 7,  label = "Legs",       name = "legs" },
    { slot = 8,  label = "Feet",       name = "feet" },
    { slot = 9,  label = "Wrist",      name = "wrist" },
    { slot = 10, label = "Hands",      name = "hands" },
    { slot = 11, label = "Ring 1",     name = "ring1" },
    { slot = 12, label = "Ring 2",     name = "ring2" },
    { slot = 13, label = "Trinket 1",  name = "trinket1" },
    { slot = 14, label = "Trinket 2",  name = "trinket2" },
    { slot = 15, label = "Back",       name = "back" },
    { slot = 16, label = "Main Hand",  name = "mainHand",  weapon = true },
    { slot = 17, label = "Off Hand",   name = "offHand",   weapon = true },
    { slot = 18, label = "Ranged",     name = "ranged" },
    { slot = 19, label = "Tabard",     name = "tabard",    cosmetic = true },
}

function ItemStats:GetEquippableSlots(equipLoc)
    return equipSlots[equipLoc or ""]
end

function ItemStats:GetSlotLabel(slot)
    for _, entry in ipairs(LT.InventorySlots) do
        if entry.slot == slot then return entry.label end
    end
    return "Slot " .. tostring(slot)
end

------------------------------------------------------------------------------
-- Item identity
------------------------------------------------------------------------------

function ItemStats:GetIdentity(itemLink)
    if not itemLink or LT:IsSecret(itemLink) then return nil end

    if not C_Item or type(C_Item.GetItemInfoInstant) ~= "function" then return nil end

    local ok, itemID, itemType, itemSubType, equipLoc, texture, classID, subClassID =
        pcall(C_Item.GetItemInfoInstant, itemLink)

    if not ok or not itemID then return nil end

    local identity = {
        itemID      = itemID,
        itemType    = itemType,
        itemSubType = itemSubType,
        equipLoc     = equipLoc,
        texture     = texture,
        classID     = classID,
        subClassID  = subClassID,
        link        = itemLink,
    }

    -- Item name / quality are only available once the client has cached the
    -- item; GetItemInfo can return nil on the first request.
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local okInfo, name, _, quality, itemLevel, requiredLevel = pcall(C_Item.GetItemInfo, itemLink)
        if okInfo then
            identity.name = LT:IsSecret(name) and nil or name
            identity.quality = quality
            identity.itemLevel = tonumber(itemLevel)
            -- The client's own level requirement, when it reports one. Used by
            -- Usability to say "not yet" instead of "never".
            identity.requiredLevel = tonumber(requiredLevel)
        end
    end

    if not identity.itemLevel and C_Item and type(C_Item.GetDetailedItemLevelInfo) == "function" then
        local okLevel, level = pcall(C_Item.GetDetailedItemLevelInfo, itemLink)
        if okLevel and tonumber(level) then
            identity.itemLevel = tonumber(level)
        end
    end

    if type(C_PlayerInfo) == "table" and type(C_PlayerInfo.CanUseItem) == "function" then
        local okUse, canUse = pcall(C_PlayerInfo.CanUseItem, itemLink)
        if okUse then
            identity.canUse = (canUse ~= false)
        end
    end

    return identity
end

------------------------------------------------------------------------------
-- Tooltip-derived values
------------------------------------------------------------------------------

local function parseNumber(text)
    if text == nil or LT:IsSecret(text) then return nil end
    local numberText = tostring(text):match("(%d+[.,]?%d*)")
    if not numberText then return nil end
    return tonumber((numberText:gsub(",", ".")))
end

local function parseDamageRange(text)
    if text == nil or LT:IsSecret(text) then return nil end

    local value = tostring(text)
    local low, high = value:match("(%d+[.,]?%d*)%s*%-%s*(%d+[.,]?%d*)")
    if not low then
        low, high = value:match("(%d+[.,]?%d*)%s*–%s*(%d+[.,]?%d*)")
    end
    if not low then
        low, high = value:match("(%d+[.,]?%d*)%s*—%s*(%d+[.,]?%d*)")
    end
    if not low or not high then return nil end

    low = tonumber((low:gsub(",", ".")))
    high = tonumber((high:gsub(",", ".")))
    if not low or not high then return nil end
    if low > high then low, high = high, low end

    return low, high
end

-- The client's own tooltip, drawn into a frame of our own so the pointer's
-- tooltip is never touched. This is the route that exists on every build: a
-- client with no stat API still writes "19 Armor" and "+5 Stamina" on the item's
-- tooltip, and those lines are the whole reason the item can be scored at all.
local scanTooltip

-- One scan per link, kept: Get asks for the lines twice (stats, then the
-- proc/on-use check) and a tooltip scan costs far more than a lookup.
local lineCache = {}

-- Both per-link tables below are asked about every item the pointer crosses, so
-- both are bounded: when the limit is reached the oldest key goes. A session
-- must not grow a table with every item ever hovered.
local CACHE_LIMIT = 400

local cacheOrder = {}
local lineOrder = {}

local function boundedStore(store, order, key, value, limit)
    if store[key] == nil then
        table.insert(order, key)
    end

    store[key] = value

    limit = limit or CACHE_LIMIT
    while #order > limit do
        store[table.remove(order, 1)] = nil
    end
end

local function frameText(fontString)
    if type(fontString) ~= "table" or type(fontString.GetText) ~= "function" then return nil end

    local ok, text = pcall(fontString.GetText, fontString)
    if not ok or type(text) ~= "string" or text == "" or LT:IsSecret(text) then return nil end

    return text
end

local function scanTooltipLines(itemLink)
    if type(CreateFrame) ~= "function" or type(UIParent) ~= "table" then return nil end

    if not scanTooltip then
        local ok, frame = pcall(CreateFrame, "GameTooltip",
            "LunchboxToolkitScanTooltip", UIParent, "GameTooltipTemplate")
        if not ok or type(frame) ~= "table" then return nil end
        scanTooltip = frame
    end

    -- ANCHOR_NONE and a hidden owner: the scan frame must never appear on
    -- screen, and must never take the pointer away from the real tooltip.
    if not pcall(scanTooltip.SetOwner, scanTooltip, UIParent, "ANCHOR_NONE") then
        return nil
    end

    pcall(scanTooltip.ClearLines, scanTooltip)

    if not pcall(scanTooltip.SetHyperlink, scanTooltip, itemLink) then
        pcall(scanTooltip.Hide, scanTooltip)
        return nil
    end

    local name
    local okName, reportedName = pcall(scanTooltip.GetName, scanTooltip)
    if okName and type(reportedName) == "string" then name = reportedName end

    local lines = {}

    if name then
        local count = 0
        local okCount, reported = pcall(scanTooltip.NumLines, scanTooltip)
        if okCount and type(reported) == "number" then count = reported end

        -- A client that will not report a count still has the font strings, so
        -- the cap below is walked instead: it keeps a wrong count from turning
        -- into an endless loop.
        if count <= 0 or count > 40 then count = 40 end

        for index = 1, count do
            local leftText = frameText(_G[name .. "TextLeft" .. index])
            local rightText = frameText(_G[name .. "TextRight" .. index])

            if leftText or rightText then
                table.insert(lines, { leftText = leftText, rightText = rightText })
            end
        end
    end

    pcall(scanTooltip.Hide, scanTooltip)

    if #lines == 0 then return nil end

    return lines
end

-- The modern data route when the client has it, the scan above when it does
-- not. Both answer in the same shape: a list of lines with a leftText.
local function getTooltipLines(itemLink)
    local cached = lineCache[itemLink]

    if cached ~= nil then
        return cached or nil
    end

    local lines

    if type(C_TooltipInfo) == "table" and type(C_TooltipInfo.GetHyperlink) == "function" then
        local ok, data = pcall(C_TooltipInfo.GetHyperlink, itemLink, nil, nil, true)
        if ok and type(data) == "table" and type(data.lines) == "table" and #data.lines > 0 then
            lines = data.lines
        end
    end

    if not lines then
        lines = scanTooltipLines(itemLink)
    end

    boundedStore(lineCache, lineOrder, itemLink, lines or false)

    return lines
end

-- Speed lines are labelled by the client's own WEAPON_SPEED string, so this
-- works on a localized client without a per-language table.
local function looksLikeSpeed(text)
    if text == nil or LT:IsSecret(text) then return false end

    local value = tostring(text)
    if type(WEAPON_SPEED) == "string" then
        local label = WEAPON_SPEED:match("^(.-)%%")
        if label and label ~= "" then
            label = label:gsub("%s+$", "")
            if label ~= "" and value:find(label, 1, true) then return true end
        end
    end

    local lower = value:lower()
    return lower:find("speed", 1, true) ~= nil
        or lower:find("tempo", 1, true) ~= nil
        or lower:find("geschwindigkeit", 1, true) ~= nil
end

local blockValueLabels = {
    ["block"] = true, ["blocken"] = true, ["blockwert"] = true,
    ["block value"] = true, ["valor de bloqueo"] = true, ["valeur de blocage"] = true,
}

local function parseBlockValue(text)
    if text == nil or LT:IsSecret(text) then return nil end

    local lower = tostring(text):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if lower:find("%%", 1, true) then return nil end
    if lower:find("rating", 1, true) or lower:find("wertung", 1, true) then return nil end

    local number, label = lower:match("^(%d+[.,]?%d*)%s+(.+)$")
    if not number or not label then return nil end

    label = label:gsub("^%s+", ""):gsub("%s+$", "")
    if not blockValueLabels[label] then return nil end

    return tonumber((number:gsub(",", ".")))
end

function ItemStats:GetWeaponValues(itemLink, equipLoc)
    local weaponLocations = {
        INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true,
        INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true,
        INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true,
    }
    if not weaponLocations[equipLoc or ""] then return nil end

    local lines = getTooltipLines(itemLink)
    if not lines then return nil end

    local minDamage, maxDamage, speed
    local scanned = math.min(#lines, 12)

    for index = 1, scanned do
        local line = lines[index]
        if line then
            if not minDamage then
                local low, high = parseDamageRange(line.leftText)
                if low and high then
                    minDamage, maxDamage = low, high

                    local rightSpeed = parseNumber(line.rightText)
                    if rightSpeed and rightSpeed >= 0.4 and rightSpeed <= 10 then
                        speed = rightSpeed
                    end
                end
            end

            if not speed then
                if looksLikeSpeed(line.leftText) then
                    local value = parseNumber(line.leftText)
                    if value and value >= 0.4 and value <= 10 then speed = value end
                elseif looksLikeSpeed(line.rightText) then
                    local value = parseNumber(line.rightText)
                    if value and value >= 0.4 and value <= 10 then speed = value end
                end
            end
        end
    end

    if not minDamage or not maxDamage then return nil end

    local average = (minDamage + maxDamage) / 2
    local dps = (speed and speed > 0) and (average / speed) or nil

    return {
        weaponMinDamage   = minDamage,
        weaponMaxDamage   = maxDamage,
        weaponAvgDamage   = average,
        weaponSpeed       = speed,
        weaponDPS         = dps,
        speedKnown        = speed ~= nil,
    }
end

function ItemStats:GetBlockValue(itemLink, equipLoc)
    if equipLoc ~= "INVTYPE_SHIELD" then return nil end

    local lines = getTooltipLines(itemLink)
    if not lines then return nil end

    local scanned = math.min(#lines, 12)
    for index = 1, scanned do
        local line = lines[index]
        if line then
            local value = parseBlockValue(line.leftText) or parseBlockValue(line.rightText)
            if value and value > 0 then return value end
        end
    end

    return nil
end

------------------------------------------------------------------------------
-- Main entry point
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Where the numbers come from
------------------------------------------------------------------------------

-- One raw stats table into canonical channels. Pure: it touches no client API,
-- so SelfTest can feed it a made-up table. Returns how many keys it mapped.
local function mergeRawStats(raw, stats, unmapped)
    local merged = 0

    if type(raw) ~= "table" then return merged end

    for key, value in pairs(raw) do
        if type(value) == "number" then
            local channel = aliases[key]
            if not channel and weaponSkillKeys[key] then
                channel = "weaponSkill"
            end

            if channel then
                stats[channel] = (stats[channel] or 0) + value
                merged = merged + 1
            else
                unmapped[key] = value
            end
        end
    end

    return merged
end

ItemStats.MergeRaw = mergeRawStats

------------------------------------------------------------------------------
-- Unmapped client keys
--
-- What the client reported that the alias table (and the weapon-skill table)
-- could not map is recorded per item link, so `/lt unknown` can name the keys
-- worth adding. This is a diagnostic, never a scoring input: nothing here
-- changes a score, and nothing is written to SavedVariables.
--
-- A key's count is the number of tracked item links that reported it, so an
-- item counts once however often it is rescanned. Only the last
-- UNKNOWN_LINK_LIMIT links are kept; the oldest is dropped, and the summary is
-- rebuilt from what remains. The store resets only through `/lt unknown clear`.
------------------------------------------------------------------------------

local UNKNOWN_LINK_LIMIT = 200

local unknownLinks = {}
local unknownOrder = {}
local unknownSequence = 0

-- The client's key as a readable string, or nil when it is not a usable key.
local function unknownKeyText(key)
    if type(key) ~= "string" or key == "" then return nil end
    if LT:IsSecret(key) then return nil end
    return key
end

-- The player's level when the key was seen. LT.player is filled by Core, so
-- the ordinary path makes no client call; UnitLevel is the guarded fallback.
local function seenLevel()
    if LT.player then
        local level = tonumber(LT.player.level)
        if level and level > 0 then return level end
    end

    if type(UnitLevel) == "function" then
        local ok, level = pcall(UnitLevel, "player")
        if ok then return tonumber(level) end
    end

    return nil
end

-- Pure: no client call. One item link, the client keys it reported that the
-- alias table could not map, and the level it was seen at. The record is
-- keyed by link, so a rescan updates the level without inflating the count.
function ItemStats:RecordUnknowns(itemLink, keys, level)
    if type(itemLink) ~= "string" or LT:IsSecret(itemLink) then return end
    if type(keys) ~= "table" then return end

    local cleaned = {}
    for _, key in ipairs(keys) do
        key = unknownKeyText(key)
        if key then table.insert(cleaned, key) end
    end

    if #cleaned == 0 then return end

    unknownSequence = unknownSequence + 1

    local record = unknownLinks[itemLink]
    if record then
        record.lastLevel = level or record.lastLevel
        record.lastSequence = unknownSequence
        if record.firstLevel == nil then record.firstLevel = level end
    else
        record = {
            keys = {},
            firstLevel = level,
            lastLevel = level,
            lastSequence = unknownSequence,
        }
        boundedStore(unknownLinks, unknownOrder, itemLink, record, UNKNOWN_LINK_LIMIT)
    end

    for _, key in ipairs(cleaned) do
        record.keys[key] = true
    end
end

-- A stable copy of the summary, `key -> { count, firstLevel, lastLevel, link }`.
-- The count is the number of tracked links reporting the key and `link` is the
-- first of those still tracked. Mutating the copy never touches the store.
function ItemStats:KnownUnknowns()
    local summary = {}

    for _, itemLink in ipairs(unknownOrder) do
        local record = unknownLinks[itemLink]
        if record then
            for key in pairs(record.keys) do
                local entry = summary[key]
                if not entry then
                    entry = {
                        count = 0,
                        firstLevel = record.firstLevel,
                        lastLevel = record.lastLevel,
                        link = itemLink,
                        lastSequence = record.lastSequence,
                    }
                    summary[key] = entry
                end

                entry.count = entry.count + 1
                if entry.firstLevel == nil then
                    entry.firstLevel = record.firstLevel
                end
                if record.lastSequence >= entry.lastSequence then
                    entry.lastLevel = record.lastLevel
                    entry.lastSequence = record.lastSequence
                end
            end
        end
    end

    local copy = {}
    for key, entry in pairs(summary) do
        copy[key] = {
            count = entry.count,
            firstLevel = entry.firstLevel,
            lastLevel = entry.lastLevel,
            link = entry.link,
        }
    end

    return copy
end

-- The only reset. Cache invalidation deliberately leaves the store alone: it
-- is diagnostic history for this session.
function ItemStats:ClearKnownUnknowns()
    unknownLinks = {}
    unknownOrder = {}
    unknownSequence = 0
end

local STAT_SOURCE_MISSING =
    "This client exposes no item stats to addons, so every item scores 0.0."

-- Route 1: C_Item.GetItemStats (Forever, and every client with the C_Item
-- namespace). Route 2: the global GetItemStats(link, table) that a pre-C_Item
-- client carries, with the same ITEM_MOD_* keys -- it fills a table that is
-- handed to it, and some builds return that same table. Returns the name of the
-- route that answered, or nil when the client has neither.
local function mergeClientStats(itemLink, stats, unmapped)
    if type(C_Item) == "table" and type(C_Item.GetItemStats) == "function" then
        local ok, raw = pcall(C_Item.GetItemStats, itemLink)
        if ok and type(raw) == "table" then
            mergeRawStats(raw, stats, unmapped)
            return "C_Item.GetItemStats"
        end
    end

    if type(GetItemStats) == "function" then
        local raw = {}
        local ok, returned = pcall(GetItemStats, itemLink, raw)

        if ok and type(returned) == "table" then raw = returned end

        if ok and type(raw) == "table" and next(raw) then
            mergeRawStats(raw, stats, unmapped)
            return "GetItemStats"
        end
    end

    return nil
end

-- The English labels a client prints on an item's own tooltip line, mapped to
-- the same canonical channels the ITEM_MOD_* keys land in. Deliberately narrow:
-- a line that is not listed is reported, never guessed at, because a wrong
-- number is worse than a missing one.
local tooltipLabels = {
    ["strength"] = "strength",
    ["agility"] = "agility",
    ["stamina"] = "stamina",
    ["intellect"] = "intellect",
    ["spirit"] = "spirit",
    ["armor"] = "armor",

    ["attack power"] = "attackPower",
    ["ranged attack power"] = "rangedAttackPower",
    ["spell power"] = "spellPower",
    ["spell damage"] = "spellPower",
    ["healing"] = "healingPower",
    ["mana per 5 sec"] = "mp5",
    ["mana per 5 sec."] = "mp5",
    ["health per 5 sec"] = "hp5",
    ["health per 5 sec."] = "hp5",

    ["defense"] = "defense",
    ["defense skill"] = "defense",
    ["dodge"] = "dodge",
    ["parry"] = "parry",
    ["block"] = "block",
    ["block value"] = "blockValue",
    ["hit"] = "hit",
    ["critical strike"] = "crit",
    ["spell critical strike"] = "spellCrit",

    ["fire resistance"] = "fireResist",
    ["frost resistance"] = "frostResist",
    ["nature resistance"] = "natureResist",
    ["shadow resistance"] = "shadowResist",
    ["arcane resistance"] = "arcaneResist",
}

ItemStats.tooltipLabels = tooltipLabels

-- Tooltip lines that carry a number and are not stats: the weapon block is read
-- by GetWeaponValues, and listing damage or speed as "unmodelled stats" would
-- put a note on every weapon in the game.
local function isWeaponBlock(label)
    return label:find("damage", 1, true) ~= nil
        or label:find("speed", 1, true) ~= nil
        or label:find("durability", 1, true) ~= nil
end

-- Pure: a list of tooltip lines into canonical channels. Only the "N Label" and
-- "+N Label" shape is read, which is what an item's own tooltip writes for a
-- flat stat. A percentage is recorded as unread instead of being folded into a
-- rating channel: "+1% Critical Strike" and crit rating are not the same number,
-- and the weights are per rating.
local function parseTooltipLines(lines, stats, unmapped)
    if type(lines) ~= "table" then return 0 end

    local read = 0

    for _, line in ipairs(lines) do
        local text = type(line) == "table" and line.leftText or nil

        if type(text) == "string" and not LT:IsSecret(text) then
            local plain = tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            plain = plain:gsub("^%s+", ""):gsub("%s+$", "")

            local percentLabel = plain:match("^[%+%-]?%d+%%%s+(.+)$")
            local amountText, label = plain:match("^([%+%-]?%d+)%s+(.+)$")

            if percentLabel then
                unmapped["tooltip: " .. plain] = true
            elseif amountText then
                local key = label:lower():gsub("%s+$", "")
                local channel = tooltipLabels[key]

                if channel then
                    local amount = tonumber((amountText:gsub("%+", "")))
                    if amount then
                        stats[channel] = (stats[channel] or 0) + amount
                        read = read + 1
                    end
                elseif key:find("%a") and not isWeaponBlock(key) then
                    unmapped["tooltip: " .. plain] = true
                end
            end
        end
    end

    return read
end

ItemStats.ParseTooltipLines = parseTooltipLines

-- Route 3: the item's own tooltip text. Used only when neither API route
-- answered, so a precise number is never replaced by a parsed one.
local function mergeTooltipStats(itemLink, stats, unmapped)
    local lines = getTooltipLines(itemLink)
    if not lines then return 0 end

    return parseTooltipLines(lines, stats, unmapped)
end

-- /lt quest and /lt test: which stat routes this client offers at all. A build
-- with no API route still has the tooltip-text one, so this line names where the
-- numbers come from -- worth seeing when a score looks wrong.
function ItemStats:DescribeSources()
    local routes = {}

    if type(C_Item) == "table" and type(C_Item.GetItemStats) == "function" then
        table.insert(routes, "C_Item.GetItemStats")
    end

    if type(GetItemStats) == "function" then
        table.insert(routes, "GetItemStats")
    end

    if type(C_TooltipInfo) == "table" and type(C_TooltipInfo.GetHyperlink) == "function" then
        table.insert(routes, "C_TooltipInfo")
    end

    -- The tooltip-text route is always there, because every client draws the
    -- item's own tooltip; it is the one that answers on a build with no stat API.
    table.insert(routes, "the item's own tooltip text")

    return "item stats through " .. table.concat(routes, ", ") .. "."
end

-- Returns stats, identity, limitations.
--   stats:      canonical channel -> number
--   identity:   item id / equip location / name and so on
--   limitations: list of strings describing what could not be evaluated
function ItemStats:Get(itemLink, options)
    local limitations = {}
    options = options or {}

    if not itemLink or LT:IsSecret(itemLink) then
        return nil, nil, { "No readable item link." }
    end

    if not options.noCache and self.cache[itemLink] then
        local cached = self.cache[itemLink]
        return cached.stats, cached.identity, LT:Copy(cached.limitations)
    end

    local identity = self:GetIdentity(itemLink)
    if not identity then
        return nil, nil, { "The client did not return item information for this link." }
    end

    local stats = {}
    local unmapped = {}

    -- Which route answered, or nil when this client offers neither. Reported
    -- rather than assumed: a client without a stat route scores every item 0.0,
    -- and "0.0 vs 0.0" is indistinguishable from "even" on the reward window.
    local source = mergeClientStats(itemLink, stats, unmapped)

    -- Neither API route answered. The item's own tooltip still says "19 Armor"
    -- and "+5 Stamina", so the numbers are read back off it: that is the route
    -- which exists on a client with no stat API at all.
    if not next(stats) then
        local read = mergeTooltipStats(itemLink, stats, unmapped)
        if read > 0 then
            source = "the item's own tooltip text"
        end
    end

    if not source and not next(unmapped) then
        table.insert(limitations, STAT_SOURCE_MISSING)
    elseif not next(stats) then
        table.insert(limitations, "No stat this addon models could be read from the "
            .. "client or from the item's own tooltip, so this score covers item "
            .. "level only.")
    end

    local weaponValues = self:GetWeaponValues(itemLink, identity.equipLoc)
    if weaponValues then
        stats.weaponAvgDamage = weaponValues.weaponAvgDamage
        stats.weaponSpeed = weaponValues.weaponSpeed
        if weaponValues.weaponDPS then
            stats.weaponDPS = weaponValues.weaponDPS
        else
            table.insert(limitations,
                "Weapon speed was not readable, so weapon DPS could not be derived.")
        end
    end

    if (not stats.blockValue or stats.blockValue == 0) then
        local blockValue = self:GetBlockValue(itemLink, identity.equipLoc)
        if blockValue then
            stats.blockValue = blockValue
        end
    end

    if identity.itemLevel and identity.itemLevel > 0 then
        stats.itemLevel = identity.itemLevel
    end

    if next(unmapped) then
        local keys = {}
        local clientKeys = {}

        for key in pairs(unmapped) do
            table.insert(keys, tostring(key))
            -- Tooltip labels are free text, not client stat keys: they stay in
            -- the item's limitations but out of the /lt unknown store, whose
            -- keys are the client's own ITEM_MOD_* names.
            if type(key) == "string" and key:sub(1, 9) ~= "tooltip: " then
                table.insert(clientKeys, key)
            end
        end

        table.sort(keys)
        table.insert(limitations,
            "Unmodelled stats on this item: " .. table.concat(keys, ", "))

        self:RecordUnknowns(itemLink, clientKeys, seenLevel())
    end

    -- Procs, set bonuses and on-use effects are not exposed as stats at all.
    -- The addon states this rather than pretending the score covers them.
    if options.checkTooltipText ~= false then
        local lines = getTooltipLines(itemLink)
        if lines then
            local effectText = 0
            for _, line in ipairs(lines) do
                local left = line.leftText
                if left and not LT:IsSecret(left) then
                    local lower = tostring(left):lower()
                    if lower:find("equip:", 1, true)
                        or lower:find("use:", 1, true)
                        or lower:find("chance on hit", 1, true)
                        or lower:find("set:", 1, true) then
                        effectText = effectText + 1
                    end
                end
            end

            if effectText > 0 then
                table.insert(limitations,
                    tostring(effectText) .. " proc / on-use / set effect(s) on this item "
                    .. "are not part of the score — no defensible model for them yet.")
            end
        end
    end

    if identity.canUse == false then
        table.insert(limitations, "This character cannot use this item.")
    end

    boundedStore(self.cache, cacheOrder, itemLink, {
        stats = LT:Copy(stats),
        identity = LT:Copy(identity),
        limitations = LT:Copy(limitations),
    })

    return stats, identity, limitations
end

function ItemStats:InvalidateCache()
    self.cache = {}
    cacheOrder = {}
    lineCache = {}
    lineOrder = {}
end

function ItemStats:GetUnmappedKeys()
    local keys = {}
    for _, entry in pairs(self.cache) do
        for _, limitation in ipairs(entry.limitations or {}) do
            local found = limitation:match("Unmodelled stats on this item: (.+)$")
            if found then
                for key in found:gmatch("[^,]+") do
                    keys[key:gsub("^%s+", ""):gsub("%s+$", "")] = true
                end
            end
        end
    end

    local list = {}
    for key in pairs(keys) do table.insert(list, key) end
    table.sort(list)
    return list
end

-- The client caches items lazily; a miss on the first request usually
-- resolves a moment later.
LT:On("INVENTORY_CHANGED", function()
    ItemStats:InvalidateCache()
end, "ItemStats")

-- "Can this character use it" is answered from the character's level, so a
-- level change makes a stored identity stale as well.
LT:On(LT.EVENT_LEVEL, function()
    ItemStats:InvalidateCache()
end, "ItemStats")