--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Spellbook
    `/lt spells`: which learned abilities are modelled, and which cannot be valued.

    This module reads the spellbook and reports. It registers no adjustment,
    changes no score, writes no SavedVariables and draws nothing.

    Three routes are probed in order, because the spellbook API shape differs
    between clients and Forever's shape has not been probed in game yet:

      1. C_SpellBook.GetSpellBookItemInfo (or the deprecated global alias):
         slot indices are walked directly. GetNumSpellBookSkillLines, when the
         client has it, sharpens a failure reason; the skill-line table shape is
         unconfirmed on this client, so ranges are not trusted for the walk.
      2. GetNumSpellTabs + GetSpellTabInfo (per-tab offset and count)
      3. legacy globals: GetSpellName over slot indices, ids from
         GetSpellBookItemInfo or GetSpellLink

    Each reader returns nil plus a reason when it cannot answer; the next route
    is tried. When no route answers, the command prints every failure and stops.
    A route that answers but yields no readable entry is treated as a failure,
    so a half-present API cannot masquerade as an empty spellbook.

    Classification is deliberately narrow: an ability counts as "modelled" only
    when the per-class table below names it and names the stat channel it moves.
    Everything else is counted as "not evaluated". A name the table does not
    know is never guessed onto a stat key, and multi-channel buffs (Mark of the
    Wild, Inner Fire, Frost Armor) are left unmodelled rather than being
    flattened onto one channel.

    Pure pieces (name normalisation, link parsing, dedupe, report building,
    the route readers with an injectable API table) touch no client state, so
    they can be exercised outside the client.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Spellbook = {}
LT.Spellbook = Spellbook
LT.Modules = LT.Modules or {}
LT.Modules.Spellbook = Spellbook

------------------------------------------------------------------------------
-- Routes
------------------------------------------------------------------------------

Spellbook.ROUTE_MODERN = "C_SpellBook"
-- Route 2 is Classic-only: Forever 1.60.1 has no GetSpellTabInfo (F-11).
-- It stays as the guarded second route so a Classic client still works.
Spellbook.ROUTE_TABS = "GetSpellTabInfo"
Spellbook.ROUTE_LEGACY = "legacy globals"

-- A spellbook this large is not a spellbook; refusing an absurd range keeps a
-- bogus API return from freezing the client in a loop.
Spellbook.MAX_RANGE = 4096

-- A direct slot scan stops after this many consecutive unreadable slots. Valid
-- spellbook indices are contiguous, so this is the end-of-book guard.
Spellbook.SLOT_EMPTY_RUN = 50

-- Legacy slot scan: the bound is a scan guard, not a client API. Reading stops
-- at the bound or after this many consecutive empty slots.
Spellbook.LEGACY_SLOT_BOUND = 1024
Spellbook.LEGACY_EMPTY_RUN = 50

------------------------------------------------------------------------------
-- The per-class model
--
-- Only an ability whose effect maps cleanly onto one canonical channel is
-- listed. Every entry is a claim about the client's spell, not about the
-- addon's weights: "this ability moves this channel". Nothing here registers
-- that movement with the scorer; `/lt spells` reports it and stops.
--
-- Deliberately absent, because one channel cannot describe them:
--   Commanding Shout (maximum health, not Stamina)
--   Mark of the Wild  (armour and several attributes)
--   Inner Fire        (armour and spell power)
--   Frost Armor       (armour and frost resistance)
--   Demon Armor       (armour, shadow resistance and regeneration)
--   Slice and Dice    (melee attack speed, not Haste Rating)
--   stance/aura effects already covered by BuffMonitor presence checks
--
-- Names are matched exactly (after whitespace, case and rank normalisation)
-- against the client's English strings, never by id: this file has no verified
-- Forever ids, and inventing them would be worse than reporting "not evaluated".
-- On a localised client every name misses and the whole spellbook is reported
-- as not evaluated; that is the intended honest failure, never a guessed model.
------------------------------------------------------------------------------

local MODELLED = {
    WARRIOR = {
        { name = "Battle Shout", stat = "attackPower",
          note = "flat attack power; BuffMonitor only watches whether it is up" },
    },
    PALADIN = {
        { name = "Blessing of Might", stat = "attackPower",
          note = "flat attack power" },
        { name = "Devotion Aura", stat = "armor",
          note = "increases armour" },
    },
    HUNTER = {
        { name = "Aspect of the Hawk", stat = "rangedAttackPower",
          note = "ranged attack power" },
    },
    ROGUE = {
        -- No learned rogue ability maps cleanly onto a weight channel.
    },
    PRIEST = {
        { name = "Power Word: Fortitude", stat = "stamina",
          note = "increases Stamina" },
        { name = "Divine Spirit", stat = "spirit",
          note = "increases Spirit" },
        { name = "Shadow Protection", stat = "shadowResist",
          note = "increases Shadow Resistance" },
    },
    SHAMAN = {
        { name = "Strength of Earth Totem", stat = "strength",
          note = "increases Strength" },
        { name = "Grace of Air Totem", stat = "agility",
          note = "increases Agility" },
    },
    MAGE = {
        { name = "Arcane Intellect", stat = "intellect",
          note = "increases Intellect" },
    },
    WARLOCK = {
        { name = "Demon Skin", stat = "armor",
          note = "increases armour" },
    },
    DRUID = {
        -- Mark of the Wild moves armour and several attributes; not modelled.
    },
}

Spellbook.MODELLED = MODELLED

------------------------------------------------------------------------------
-- Value guards
------------------------------------------------------------------------------

-- A hidden value must never be compared or used as a loop bound. The wrapper is
-- optional so the pure functions still run in a plain Lua interpreter.
local function isSecret(value)
    if type(LT) ~= "table" or type(LT.IsSecret) ~= "function" then return false end
    local ok, result = pcall(LT.IsSecret, LT, value)
    return ok and result == true
end

-- Returns number or nil, and true when the value existed but was hidden.
local function safeNumber(value)
    if isSecret(value) then return nil, true end
    local number = tonumber(value)
    if not number then return nil, false end
    return number, false
end

local function safeString(value)
    if type(value) ~= "string" then return nil, false end
    if isSecret(value) then return nil, true end
    return value, false
end

------------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------------

-- Comparison key for a spell name. Rank markers are stripped because legacy
-- clients return the rank separately while other shapes append it to the name.
-- Nothing else is rewritten: a near-miss is reported as not evaluated.
function Spellbook:NormalizeName(name)
    if type(name) ~= "string" or name == "" then return nil end
    if isSecret(name) then return nil end

    local text = name:gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    text = text:gsub("%s*%(%s*[Rr]ank%s*%d+%s*%)%s*$", "")
    text = text:gsub("%s+[Rr]ank%s*%d+%s*$", "")
    text = text:gsub("%s+$", "")

    if text == "" then return nil end
    return string.lower(text)
end

-- "|cffffd000|Hspell:809|h[Arcane Intellect]|h|r" -> 809, "Arcane Intellect"
function Spellbook:ParseSpellLink(link)
    if type(link) ~= "string" or link == "" then return nil, nil end
    if isSecret(link) then return nil, nil end

    local id = tonumber(link:match("|Hspell:(%d+)")) or tonumber(link:match("spell:(%d+)"))
    local name = link:match("|h%[(.-)%]|h")
    return id, name
end

-- The rows for a class token, or an empty list. An unknown class has no rows,
-- which is exactly how "nothing is modelled for it" must read.
function Spellbook:ClassRows(classToken)
    if type(classToken) ~= "string" or classToken == "" then return {} end
    return MODELLED[string.upper(classToken)] or {}
end

-- The table entry that names this spell, or nil. Matching is exact after
-- normalisation; there is no fuzzy or partial match.
function Spellbook:Classify(name, classToken)
    local key = self:NormalizeName(name)
    if not key then return nil end

    local rows = self:ClassRows(classToken)
    for _, row in ipairs(rows) do
        if self:NormalizeName(row.name) == key then return row end
    end
    return nil
end

-- One entry per spell id. Entries without an id fall back to the normalised
-- name, so a legacy route that cannot read ids still cannot count one ability
-- twice. The two key spaces are kept apart on purpose: without an id there is
-- no proof that a named entry is the same spell as an id-bearing one.
function Spellbook:Dedupe(entries)
    local unique, seen = {}, {}
    local duplicates = 0

    for _, entry in ipairs(entries or {}) do
        if type(entry) == "table" then
            local key
            if not isSecret(entry.id) and type(entry.id) == "number" then
                key = "id:" .. tostring(entry.id)
            else
                local normalised = self:NormalizeName(entry.name)
                if normalised then key = "name:" .. normalised end
            end

            if key then
                if seen[key] then
                    duplicates = duplicates + 1
                else
                    seen[key] = true
                    unique[#unique + 1] = entry
                end
            end
        end
    end

    return unique, duplicates
end

-- Plain report data. No frames, no strings for a widget: the caller prints.
-- extra may carry duplicates and hidden.
function Spellbook:BuildReport(spells, classToken, route, extra)
    extra = extra or {}

    local report = {
        route = route or "unknown",
        classToken = type(classToken) == "string" and classToken or nil,
        hasClassTable = type(classToken) == "string" and MODELLED[string.upper(classToken)] ~= nil,
        seen = 0,
        duplicates = tonumber(extra.duplicates) or 0,
        hidden = tonumber(extra.hidden) or 0,
        modelled = {},
        notEvaluated = 0,
    }

    for _, spell in ipairs(spells or {}) do
        report.seen = report.seen + 1

        local row = self:Classify(spell.name, classToken)
        if row then
            report.modelled[#report.modelled + 1] = {
                id = spell.id,
                name = spell.name,
                stat = row.stat,
                note = row.note,
            }
        else
            report.notEvaluated = report.notEvaluated + 1
        end
    end

    table.sort(report.modelled, function(a, b)
        local left = self:NormalizeName(a.name) or ""
        local right = self:NormalizeName(b.name) or ""
        if left == right then return (a.id or 0) < (b.id or 0) end
        return left < right
    end)

    return report
end

-- Static check of this file's own table. A typo in a stat key would otherwise
-- silently model nothing, so it is reported instead.
function Spellbook:ModelProblems()
    local problems = {}
    local labels = LT.StatLabels

    for classToken, rows in pairs(MODELLED) do
        local seen = {}
        for index, row in ipairs(rows) do
            local normalised = self:NormalizeName(row.name)
            if not normalised then
                problems[#problems + 1] = classToken .. " row " .. index .. " has no usable name"
            elseif seen[normalised] then
                problems[#problems + 1] = classToken .. " names \"" .. tostring(row.name) .. "\" twice"
            else
                seen[normalised] = true
            end

            if type(row.stat) ~= "string" or row.stat == "" then
                problems[#problems + 1] = classToken .. " row " .. index .. " has no stat key"
            elseif labels and not labels[row.stat] then
                problems[#problems + 1] = classToken .. " row " .. index
                    .. " uses unknown stat key \"" .. row.stat .. "\""
            end
        end
    end

    table.sort(problems)
    return problems
end

------------------------------------------------------------------------------
-- Route plumbing
------------------------------------------------------------------------------

-- Bank/book arguments differ between shapes. Every candidate is tried in order;
-- a rejected argument raises in pcall and the next one is used.
function Spellbook:SpellBanks(api)
    local banks = {}

    if type(api) == "table" and type(api.Enum) == "table" then
        local enum = api.Enum.SpellBookSpellBank
        if type(enum) == "table" then
            if enum.Player ~= nil then banks[#banks + 1] = enum.Player end
            if enum.SpellBook ~= nil and enum.SpellBook ~= enum.Player then
                banks[#banks + 1] = enum.SpellBook
            end
        end
    end

    if type(api) == "table" and api.BOOKTYPE_SPELL ~= nil then
        banks[#banks + 1] = api.BOOKTYPE_SPELL
    end

    banks[#banks + 1] = "spell"
    return banks
end

local function positiveID(value)
    local number = safeNumber(value)
    if number and number > 0 and number < 1e9 and number == math.floor(number) then
        return number
    end
    return nil
end

-- The first plausible spell id in an item-info return list. Type/ownership
-- values are skipped: only positive numbers after the type slot, then the slot
-- itself, are candidates. A table result may carry spellID/actionID/itemID/id.
function Spellbook:IDFromReturns(a, b, c, d)
    if type(a) == "table" then
        local id = positiveID(a.spellID) or positiveID(a.actionID)
            or positiveID(a.itemID) or positiveID(a.id)
        if id then return id end
    end

    return positiveID(b) or positiveID(c) or positiveID(d) or positiveID(a)
end

-- A table-shaped item-info result may already carry the name.
function Spellbook:NameFromReturns(value)
    if type(value) ~= "table" then return nil end
    return select(1, safeString(value.name))
end

-- Item info, trying every bank spelling and then the one-argument shape.
-- Returns id, name, answered, error. `answered` is true when the API returned
-- at all, even with no id: that separates an empty slot from a broken call.
function Spellbook:ItemInfo(itemFn, index, banks)
    local answered, lastError = false, nil

    for _, bank in ipairs(banks) do
        local ok, a, b, c, d = pcall(itemFn, index, bank)
        if ok then
            answered = true
            local id = self:IDFromReturns(a, b, c, d)
            local name = self:NameFromReturns(a)
            if id or name then return id, name, true, nil end
        else
            lastError = tostring(a)
        end
    end

    local ok, a, b, c, d = pcall(itemFn, index)
    if ok then
        answered = true
        local id = self:IDFromReturns(a, b, c, d)
        local name = self:NameFromReturns(a)
        if id or name then return id, name, true, nil end
    else
        lastError = tostring(a)
    end

    return nil, nil, answered, (answered and nil or lastError)
end

-- Per-slot display name with the same bank and arity fallbacks.
function Spellbook:ItemName(nameFn, index, banks)
    if type(nameFn) ~= "function" then return nil end

    for _, bank in ipairs(banks) do
        local ok, a = pcall(nameFn, index, bank)
        if ok then
            local name = select(1, safeString(a))
            if name then return name end
        end
    end

    local ok, a = pcall(nameFn, index)
    if ok then return select(1, safeString(a)) end
    return nil
end

-- Name for an id through whichever spell-name API the client exposes.
function Spellbook:NameFromID(api, id)
    if type(id) ~= "number" then return nil end

    if type(api) == "table" and type(api.C_Spell) == "table" then
        local spell = api.C_Spell
        if type(spell.GetSpellName) == "function" then
            local ok, name = pcall(spell.GetSpellName, id)
            if ok and type(name) == "string" then return name end
        end
        if type(spell.GetSpellInfo) == "function" then
            local ok, info = pcall(spell.GetSpellInfo, id)
            if ok and type(info) == "table" and type(info.name) == "string" then
                return info.name
            end
        end
    end

    if type(api) == "table" and type(api.GetSpellInfo) == "function" then
        local ok, name = pcall(api.GetSpellInfo, id)
        if ok and type(name) == "string" then return name end
    end

    return nil
end

-- Adds a sanitised entry. A hidden value is dropped, never compared or printed;
-- a slot with nothing readable left is counted as hidden and skipped.
function Spellbook:AddEntry(entries, stats, id, name, slot)
    local cleanID = select(1, safeNumber(id))
    local cleanName, nameHidden = safeString(name)
    local hidden = nameHidden

    if isSecret(id) then hidden = true end

    if cleanID == nil and cleanName == nil then
        if hidden then stats.hidden = stats.hidden + 1 end
        return
    end

    entries[#entries + 1] = { id = cleanID, name = cleanName, slot = slot }
end

------------------------------------------------------------------------------
-- Route 1: C_SpellBook
------------------------------------------------------------------------------

function Spellbook:ReadModern(api)
    api = api or _G

    local book = type(api) == "table" and api.C_SpellBook or nil
    local bookTable = type(book) == "table"

    -- Two surfaces are accepted: the C_SpellBook table and the deprecated
    -- globals that alias it. Item info is the part that must exist; the count
    -- and name helpers are optional across builds.
    local itemFn = (bookTable and book.GetSpellBookItemInfo)
        or (type(api) == "table" and api.GetSpellBookItemInfo) or nil
    if type(itemFn) ~= "function" then
        return nil, "C_SpellBook.GetSpellBookItemInfo is missing, and no global alias answers"
    end

    local nameFn = (bookTable and book.GetSpellBookItemName)
        or (type(api) == "table" and api.GetSpellBookItemName) or nil
    local countFn = (bookTable and book.GetNumSpellBookSkillLines)
        or (type(api) == "table" and api.GetNumSpellBookSkillLines) or nil

    -- The count is not required for the walk, but when it answers it makes a
    -- failed walk's reason specific about what the client claimed to hold.
    local lineNote = nil
    if type(countFn) == "function" then
        local countOK, count = pcall(countFn)
        if countOK then
            local lineCount, countHidden = safeNumber(count)
            if lineCount and lineCount > 0 and not countHidden then
                lineNote = tostring(lineCount) .. " skill line(s)"
            end
        end
    end

    local banks = self:SpellBanks(api)
    local entries, stats = {}, { hidden = 0, slots = 0, errors = 0, lastError = nil }

    local function readSlot(index)
        stats.slots = stats.slots + 1
        if stats.slots > self.MAX_RANGE then return false end

        local id, infoName, answered, err = self:ItemInfo(itemFn, index, banks)
        if not answered and err then
            stats.errors = stats.errors + 1
            stats.lastError = err
        end

        local name = infoName or self:ItemName(nameFn, index, banks)
        if name == nil and id ~= nil then
            name = select(1, safeString(self:NameFromID(api, id)))
        end

        self:AddEntry(entries, stats, id, name, index)
        return id ~= nil or name ~= nil
    end

    -- Slot indices are contiguous, so the walk ends after a run of empty slots.
    -- Skill-line ranges are not trusted for this client: the shape of the
    -- skill-line table is unconfirmed, while the slot index is the function
    -- argument the API documents.
    local emptyRun = 0
    local index = 1
    while index <= self.MAX_RANGE and emptyRun < self.SLOT_EMPTY_RUN do
        if readSlot(index) then
            emptyRun = 0
        else
            emptyRun = emptyRun + 1
        end
        index = index + 1
    end

    if #entries == 0 then
        if stats.slots > 0 and stats.errors == stats.slots and stats.lastError then
            return nil, "C_SpellBook.GetSpellBookItemInfo failed for every slot ("
                .. stats.lastError .. ")"
        end

        local reason = "C_SpellBook.GetSpellBookItemInfo returned no readable spell in "
            .. tostring(stats.slots) .. " slot(s)"
        if lineNote then reason = reason .. " after the client reported " .. lineNote end
        return nil, reason
    end

    return entries, nil, stats.hidden
end

------------------------------------------------------------------------------
-- Route 2: GetNumSpellTabs / GetSpellTabInfo
------------------------------------------------------------------------------

function Spellbook:ReadTabs(api)
    api = api or _G

    local numFn = type(api) == "table" and api.GetNumSpellTabs or nil
    if type(numFn) ~= "function" then
        return nil, "GetNumSpellTabs is missing"
    end

    local tabFn = type(api) == "table" and api.GetSpellTabInfo or nil
    if type(tabFn) ~= "function" then
        return nil, "GetSpellTabInfo is missing"
    end

    local ok, count = pcall(numFn)
    if not ok then
        return nil, "GetNumSpellTabs failed: " .. tostring(count)
    end

    local tabCount, countHidden = safeNumber(count)
    if countHidden then return nil, "GetNumSpellTabs returned a hidden value" end
    if not tabCount or tabCount <= 0 then
        return nil, "GetNumSpellTabs returned " .. tostring(count)
    end

    local nameFn = type(api) == "table" and api.GetSpellBookItemName or nil
    local itemFn = type(api) == "table" and api.GetSpellBookItemInfo or nil
    local linkFn = type(api) == "table" and api.GetSpellLink or nil

    if type(nameFn) ~= "function" and type(itemFn) ~= "function" and type(linkFn) ~= "function" then
        return nil, "no per-slot name or id function is present"
    end

    local banks = self:SpellBanks(api)
    local legacyBook = type(api) == "table" and api.BOOKTYPE_SPELL or nil
    local bookType = legacyBook or "spell"
    local entries, stats = {}, { hidden = 0, slots = 0 }

    for tab = 1, tabCount do
        local good, tabName, _texture, offset, numSpells = pcall(tabFn, tab)
        if not good then
            return nil, "GetSpellTabInfo(" .. tostring(tab) .. ") failed: " .. tostring(tabName)
        end

        local firstSlot, offsetHidden = safeNumber(offset)
        local slotCount, rangeHidden = safeNumber(numSpells)
        if offsetHidden or rangeHidden then
            return nil, "GetSpellTabInfo(" .. tostring(tab) .. ") returned a hidden range"
        end
        if firstSlot == nil or slotCount == nil then
            return nil, "GetSpellTabInfo(" .. tostring(tab) .. ") did not return offset/numSpells"
        end
        if slotCount < 0 or slotCount > self.MAX_RANGE then
            return nil, "GetSpellTabInfo(" .. tostring(tab) .. ") returned an unusable range ("
                .. tostring(slotCount) .. ")"
        end

        if slotCount > 0 then
            local first = math.max(firstSlot, 1)
            local last = first + slotCount - 1

            for index = first, last do
                stats.slots = stats.slots + 1
                if stats.slots > self.MAX_RANGE then
                    return nil, "the tab API reported more slots than this reader will walk"
                end

                local name
                if type(nameFn) == "function" then
                    local nameOK, resolved = pcall(nameFn, index, bookType)
                    if nameOK then name = select(1, safeString(resolved)) end
                end

                local id
                if type(itemFn) == "function" then
                    local infoName
                    id, infoName = self:ItemInfo(itemFn, index, banks)
                    name = name or infoName
                end

                -- The legacy GetSpellLink takes a slot index and book type; it
                -- is only called on this route, and only when BOOKTYPE_SPELL is
                -- present, because a modern GetSpellLink takes a spell id and
                -- would misinterpret a slot index.
                if type(linkFn) == "function" and legacyBook ~= nil
                    and (id == nil or name == nil) then
                    local linkOK, link = pcall(linkFn, index, bookType)
                    if linkOK then
                        local linkID, linkName = self:ParseSpellLink(link)
                        id = id or linkID
                        name = name or linkName
                    end
                end

                if name == nil and id ~= nil then
                    name = select(1, safeString(self:NameFromID(api, id)))
                end

                self:AddEntry(entries, stats, id, name, index)
            end
        end
    end

    if stats.slots > 0 and #entries == 0 then
        return nil, "the tab API reported " .. tostring(stats.slots)
            .. " slots but none yielded a readable spell"
    end

    return entries, nil, stats.hidden
end

------------------------------------------------------------------------------
-- Route 3: legacy globals
------------------------------------------------------------------------------

function Spellbook:ReadLegacy(api)
    api = api or _G

    local nameFn = type(api) == "table" and api.GetSpellName or nil
    if type(nameFn) ~= "function" then
        return nil, "GetSpellName is missing"
    end

    local itemFn = type(api) == "table" and api.GetSpellBookItemInfo or nil
    local linkFn = type(api) == "table" and api.GetSpellLink or nil
    local legacyBook = type(api) == "table" and api.BOOKTYPE_SPELL or nil
    local bookType = legacyBook or "spell"

    -- Ids improve dedupe, but the audit can run on names alone: the model is
    -- name-based, and names are deduped the same way. No id source is fatal.
    local limit = select(1, safeNumber(type(api) == "table" and api.MAX_SPELLBOOK_SLOTS or nil))
        or self.LEGACY_SLOT_BOUND
    if limit > self.MAX_RANGE then limit = self.MAX_RANGE end

    local entries, stats = {}, { hidden = 0, slots = 0 }
    local emptyRun = 0

    for index = 1, limit do
        local ok, rawName = pcall(nameFn, index, bookType)
        if not ok then
            return nil, "GetSpellName(" .. tostring(index) .. ") failed: " .. tostring(rawName)
        end

        local name = select(1, safeString(rawName))
        if name == nil or name == "" then
            emptyRun = emptyRun + 1
            if emptyRun >= self.LEGACY_EMPTY_RUN then
                if #entries == 0 then
                    return nil, "GetSpellName returned no names in slots 1.." .. tostring(index)
                end
                break
            end
        else
            emptyRun = 0
            stats.slots = stats.slots + 1

            local id
            if type(itemFn) == "function" then
                local infoName
                id, infoName = self:ItemInfo(itemFn, index, { bookType })
                name = name or infoName
            end

            if id == nil and type(linkFn) == "function" and legacyBook ~= nil then
                local linkOK, link = pcall(linkFn, index, bookType)
                if linkOK then
                    local linkID, linkName = self:ParseSpellLink(link)
                    id = linkID
                    if type(name) ~= "string" then name = linkName end
                end
            end

            self:AddEntry(entries, stats, id, name, index)
        end
    end

    if #entries == 0 then
        return nil, "GetSpellName returned no names in slots 1.." .. tostring(limit)
    end

    return entries, nil, stats.hidden
end

------------------------------------------------------------------------------
-- Route ladder
------------------------------------------------------------------------------

-- Returns entries, route, attempts, hidden. entries is nil only when every
-- route failed; attempts always carries the reason for each failure.
function Spellbook:Collect(api)
    api = api or _G

    local attempts = {}
    local routes = {
        { name = self.ROUTE_MODERN, read = self.ReadModern },
        { name = self.ROUTE_TABS,   read = self.ReadTabs },
        { name = self.ROUTE_LEGACY, read = self.ReadLegacy },
    }

    for _, route in ipairs(routes) do
        local entries, reason, hidden = route.read(self, api)

        attempts[#attempts + 1] = {
            route = route.name,
            ok = entries ~= nil,
            reason = reason,
            count = entries and #entries or 0,
        }

        if entries then
            return entries, route.name, attempts, hidden or 0
        end
    end

    return nil, nil, attempts, 0
end

------------------------------------------------------------------------------
-- Player class
------------------------------------------------------------------------------

function Spellbook:PlayerClass()
    if type(LT) == "table" and type(LT.player) == "table" then
        local token = LT.player.class
        if type(token) == "string" and not isSecret(token) and token ~= ""
            and token ~= "UNKNOWN" then
            return token
        end
    end

    if type(UnitClass) == "function" then
        local ok, _className, token = pcall(UnitClass, "player")
        if ok and type(token) == "string" and not isSecret(token) and token ~= "" then
            return token
        end
    end

    return nil
end

------------------------------------------------------------------------------
-- Output
--
-- Only strings leave this module. No widget is created and no frame is touched.
------------------------------------------------------------------------------

function Spellbook:PrintLine(message)
    local text = tostring(message)
    if type(LT) == "table" and type(LT.Print) == "function" then
        if pcall(LT.Print, LT, text) then return end
    end
    if type(print) == "function" then
        pcall(print, "Lunchbox Toolkit: " .. text)
    end
end

function Spellbook:WarnLine(message)
    local text = tostring(message)
    if type(LT) == "table" and type(LT.Warn) == "function" then
        if pcall(LT.Warn, LT, text) then return end
    end
    if type(print) == "function" then
        pcall(print, "Lunchbox Toolkit (warning): " .. text)
    end
end

function Spellbook:PrintReport(report, attempts)
    local classText = report.classToken or "unknown"
    if report.classToken and not report.hasClassTable then
        classText = classText .. " (no modelled table in this file)"
    end

    self:PrintLine("spellbook audit — class: " .. classText .. ", route: " .. tostring(report.route))

    local earlier = {}
    for _, attempt in ipairs(attempts or {}) do
        if attempt.route ~= report.route and not attempt.ok then
            earlier[#earlier + 1] = attempt.route .. " failed (" .. tostring(attempt.reason) .. ")"
        end
    end
    if #earlier > 0 then
        self:PrintLine("  earlier routes: " .. table.concat(earlier, "; "))
    end

    local seenText = "spells seen: " .. tostring(report.seen)
    if report.duplicates > 0 then
        seenText = seenText .. " (" .. tostring(report.duplicates) .. " duplicate slot(s) ignored)"
    end
    if report.hidden > 0 then
        seenText = seenText .. " (" .. tostring(report.hidden) .. " hidden slot(s) skipped)"
    end
    self:PrintLine(seenText)

    if #report.modelled == 0 then
        self:PrintLine("modelled: none — no named ability in this file's table appeared")
    else
        self:PrintLine("modelled: " .. tostring(#report.modelled) .. " ability/abilities")
        for _, row in ipairs(report.modelled) do
            local line = "  " .. tostring(row.name)
            if row.id then line = line .. " (spell " .. tostring(row.id) .. ")" end
            line = line .. " → " .. tostring(row.stat)
            if type(LT) == "table" and type(LT.Label) == "function" then
                local ok, label = pcall(LT.Label, LT, row.stat)
                if ok and type(label) == "string" then line = line .. " (" .. label .. ")" end
            end
            if row.note then line = line .. " — " .. tostring(row.note) end
            self:PrintLine(line)
        end
    end

    self:PrintLine("not evaluated: " .. tostring(report.notEvaluated)
        .. " ability/abilities — no stat key is guessed for them")
    self:PrintLine("T-26 hand-off: unvalued abilities become estimate records in the unscored list; "
        .. "nothing was registered and no score changed.")
end

function Spellbook:PrintNoRoute(attempts)
    self:WarnLine("spellbook audit unavailable: no spellbook route answered.")
    for _, attempt in ipairs(attempts or {}) do
        self:PrintLine("  route " .. tostring(attempt.route) .. " failed: " .. tostring(attempt.reason))
    end
    self:PrintLine("T-26 hand-off: nothing was read, so nothing was counted; no estimate records can be made from this run.")
end

------------------------------------------------------------------------------
-- Command
------------------------------------------------------------------------------

function Spellbook:HandleCommand(_words, api)
    api = api or _G

    local entries, route, attempts, hidden = self:Collect(api)
    if not entries then
        self.lastReport = nil
        self:PrintNoRoute(attempts)
        return false
    end

    local unique, duplicates = self:Dedupe(entries)
    local classToken = self:PlayerClass()
    local report = self:BuildReport(unique, classToken, route, {
        duplicates = duplicates,
        hidden = hidden,
    })

    -- In-memory only, for the caller; nothing is persisted.
    self.lastReport = report
    self:PrintReport(report, attempts)
    return true
end

------------------------------------------------------------------------------
-- Slash command
--
-- Slash.lua may load before or after this file. Registration is therefore
-- deferred to PLAYER_LOGIN, and the registry refuses a duplicate word, so a
-- reload cannot register it twice.
------------------------------------------------------------------------------

local HELP = "/lt spells — audit known abilities: modelled stat channels and the unvalued count"

function Spellbook:RegisterSlash()
    local slash = type(LT) == "table" and LT.Slash or nil
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then
        return false, "The slash command module is not loaded."
    end

    local ok, result = pcall(slash.RegisterCommand, slash, "spells",
        function(words) Spellbook:HandleCommand(words) end, HELP)

    if ok and result == true then
        return true
    end

    return false, "The spells command is already registered."
end

do
    local frame = type(LT) == "table" and LT.frame or nil
    local frameType = type(frame)

    if (frameType == "table" or frameType == "userdata") and type(frame.HookScript) == "function" then
        local hooked = pcall(frame.HookScript, frame, "OnEvent", function(_, event)
            if event == "PLAYER_LOGIN" then
                local registered, reason = Spellbook:RegisterSlash()
                if not registered and type(LT) == "table" and type(LT.Debug) == "function" then
                    pcall(LT.Debug, LT, "Spellbook: " .. tostring(reason))
                end
            end
        end)
        if not hooked then Spellbook:RegisterSlash() end
    else
        -- No core event frame to hook: register now if the registry is loaded.
        Spellbook:RegisterSlash()
    end
end

do
    local problems = Spellbook:ModelProblems()
    if #problems > 0 and type(LT) == "table" and type(LT.Warn) == "function" then
        pcall(LT.Warn, LT, "Spellbook: " .. table.concat(problems, "; "))
    end
end
