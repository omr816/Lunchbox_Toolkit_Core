--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Leaderboard

    Two boards, and both are local: the Party board and the Guild board. This
    is not a ladder, and it cannot become one. An addon message only reaches
    players who are in the same party, raid, guild or joined custom channel,
    on the same realm, at the moment it is sent. There is no shared store any
    other client can read and no cross-realm delivery, so a character who is
    not in one of those groups is invisible here — a realm-wide or region-wide
    ranking is impossible, not just unimplemented. A board also needs a second
    player: alone in the group, nothing ever arrives. What each client keeps
    in LunchboxToolkitDB is that client's own copy for drawing after a
    reload, never a shared record anyone else sees. Guild chat does not exist
    inside an instance, so the Guild board goes quiet there while instance
    chat keeps the Party board fed.

    The rows are level and time-to-60 reports: reported by other players,
    never assumed. Off by default: until the player turns sharing on, this
    file sends nothing at all.

    What it sends
      One addon message per enabled transport, at most once every 60 seconds,
      and only on a level-up or when the ranks page (or /lt ranks) is opened:

          LBTK|4|P|name|realm|class|race|faction|level|lifetime|at60|deaths

      "race" is the short token UnitRace returns ("Orc", "NightElf") and
      "faction" is exactly Alliance, Horde or Neutral. Either may be empty when
      the client cannot answer; an empty field means "not reported" and is
      never guessed. "lifetime" is the character's own /played total: the
      client figure this account captured at login, plus the time tracked
      since. "at60" is the client total at the moment level 60 was reached, or
      0 while below 60. Both are plain seconds, so a board can rank time
      rather than guess it. "deaths" is the number of deaths before the cap,
      from Played's ledger: a live count below 60 and the frozen total at 60.
      It is decoration, never a sort key, and is clamped to 0..99,999.

      Transports: party chat (instance chat inside an instance, since party
      chat does not exist there), guild chat, and one optional custom channel
      the player joins. A transport is used only when its toggle is on and the
      player is actually in that group, guild or channel.

    What it receives
      Anything on the prefix is treated as hostile input. While sharing is off
      nothing is stored at all. While it is on, the text must be a well-formed
      packet of version 4, or of version 3 (which had no deaths field, stored
      as 0), or of version 2 (which had no race/faction field) or version 1
      (whose two second counts are added into lifetime and whose at60 is 0).
      The older versions store an empty race and faction rather than inventing
      one. The name and realm must be plain text, race and faction must be
      short plain text when present, the level must be a whole number in
      1..60, lifetime/at60 are clamped to 0..5,000,000 and deaths to
      0..99,999. Our own packets are dropped on sight, unknown versions are
      dropped, and a message that fails any rule is counted in
      Leaderboard.refused and otherwise ignored.

    Where rows live
      Account-wide, at LunchboxToolkitDB.roster, split into roster.server (the
      Party board) and roster.guild (the Guild board). The keys keep their
      historical names, so nothing needs migrating. A row carries the board it
      belongs to, the channel it arrived on, and — when the sender reported
      them — its race token and faction, both strings, empty when unknown.
      Party, instance and the custom channel feed the Party board; guild chat
      feeds the Guild board. Friends are a filter over any received row, read
      from the client's friend list by name — never a transport of their own.
      A flat roster written by version 1.4.1 is read as the Party board and
      migrated in place on the first write.

      A third board, roster.demo, holds ten rows this file makes up for
      /lt ranks demo. Anything read from it is marked synthetic = true, it is
      never encoded, sent, stored on the Party or Guild boards, or merged;
      turning the demo off deletes the board.

    Export
      /lt ranks export prints the rows this client currently holds — the
      Party and Guild boards, never the demo rows — as a tab-separated table
      with a header naming both boards, the realm and the export time. The
      text is also written to LunchboxToolkitDB.ranksExport ({ when = <epoch>,
      lines = {...} }), which the client saves on logout or /reload. The
      command is refused in combat. A row whose fields this client reports as
      secret is skipped and counted, never printed.

    What is deliberately not here
      No frame of its own: the one listener is hooked onto LT.frame. No
      widgets: data is exposed through Boards()/OwnRow() and a RANKS_CHANGED
      event, and the UI decides how to draw it. Nothing is equipped, sold,
      moved or destroyed.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Leaderboard = {}
LT.Leaderboard = Leaderboard
LT.Modules = LT.Modules or {}
LT.Modules.Leaderboard = Leaderboard

Leaderboard.PREFIX   = "LBTK"
Leaderboard.VERSION  = "4"          -- deaths appended to the version-3 fields
Leaderboard.V3_VERSION = "3"        -- no deaths field; still accepted, deaths = 0
Leaderboard.V2_VERSION = "2"        -- no race/faction fields; still accepted
Leaderboard.LEGACY_VERSION = "1"
Leaderboard.KIND     = "P"          -- the only packet type any version defines
Leaderboard.CHANNEL  = "PARTY"
Leaderboard.GUILD_CHANNEL    = "GUILD"
Leaderboard.INSTANCE_CHANNEL = "INSTANCE_CHAT"
Leaderboard.DEFAULT_CUSTOM_CHANNEL = "LBTK"

-- Saved-variable keys. They keep the names earlier builds wrote; only the
-- labels printed to the player change.
Leaderboard.SERVER_BOARD = "server"
Leaderboard.GUILD_BOARD  = "guild"
Leaderboard.PARTY_LABEL  = "Party board"
Leaderboard.GUILD_LABEL  = "Guild board"

Leaderboard.THROTTLE_SECONDS = 60       -- one share round per minute
Leaderboard.MAX_LEVEL        = tonumber(LT.MAX_LEVEL) or 60
Leaderboard.MAX_SECONDS      = 5000000  -- ~58 days; anything above is clamped
Leaderboard.MAX_DEATHS       = 99999    -- deaths before 60; anything above is clamped
Leaderboard.ROSTER_CAP       = 200      -- per board, not for both together
Leaderboard.TOP_LIMIT        = 20
Leaderboard.RECORD_LIMIT     = 10
Leaderboard.EXPORT_ROW_CAP   = 200      -- rows one export may hold
Leaderboard.EXPORT_CHUNK     = 250      -- bytes per printed chat chunk

-- A third, separate board for /lt ranks demo. Its rows are made up by this
-- file, are marked synthetic, are never sent and never merged into the Party
-- or Guild boards. Switching the demo off clears the board.
Leaderboard.DEMO_BOARD       = "demo"
Leaderboard.DEMO_COUNT       = 10
Leaderboard.DEMO_REALM       = "Demo-Realm"

-- Returned by Boards() so the UI has an honest sentence for an empty list.
Leaderboard.EMPTY_LEVEL      = "No one else has shared a row yet."
Leaderboard.EMPTY_RECORDS    = "No one has reached 60 yet."
Leaderboard.PACKET_LIMIT     = 255      -- addon messages cannot exceed this
Leaderboard.NAME_LIMIT       = 32
Leaderboard.REALM_LIMIT      = 64
Leaderboard.RACE_LIMIT       = 24       -- a UnitRace token, not a sentence
Leaderboard.FACTION_LIMIT    = 16
Leaderboard.CHANNEL_LIMIT    = 64

-- Character option keys this file reads and writes. They are not in
-- Database.defaultOptions() because that file is not this file's to edit; a
-- missing key reads as the default here, and GetOptions returns the live table
-- a write lands in. The defaults are the documented behaviour: the master is
-- off and everything else is on, so the master alone can be switched.
Leaderboard.OPTION_DEFAULTS = {
    ranksShare   = false,
    ranksServer  = true,
    ranksGuild   = true,
    ranksFriends = true,
}

-- Fired after a row is added or replaced, so a window can refresh without
-- polling. Payload: { status = "added"|"replaced", board = ..., key = ... }.
Leaderboard.EVENT = "RANKS_CHANGED"

------------------------------------------------------------------------------
-- Small guards
--
-- Every value read from the client is checked before anything is done with it.
-- A restricted value is never compared, formatted or arithmetically combined.
------------------------------------------------------------------------------

local function isSecret(value)
    if type(LT.IsSecret) ~= "function" then return false end
    local ok, result = pcall(LT.IsSecret, LT, value)
    return ok and result == true
end

local function asNumber(value, fallback)
    if value == nil or isSecret(value) then return fallback end
    local number = tonumber(value)
    if not number or number ~= number then return fallback end
    return number
end

local function clampSeconds(value)
    local number = asNumber(value, nil)
    if not number then return nil end
    if number < 0 then return 0 end
    local cap = tonumber(Leaderboard.MAX_SECONDS) or 5000000
    if number > cap then return cap end
    return math.floor(number)
end

-- A death count as this file stores it: a whole number in 0..MAX_DEATHS. A
-- value that is not a number is refused with nil, so a packet cannot smuggle
-- a sentence into the field; an out-of-range number is clamped, because the
-- count is decoration and refusing the whole report over it would lose more.
local function clampDeaths(value)
    local number = asNumber(value, nil)
    if not number then return nil end
    if number < 0 then number = 0 end
    local cap = tonumber(Leaderboard.MAX_DEATHS) or 99999
    if number > cap then number = cap end
    return math.floor(number)
end

local KNOWN_CLASSES = {
    WARRIOR = true, PALADIN = true, HUNTER  = true, ROGUE   = true,
    PRIEST  = true, SHAMAN  = true, MAGE    = true, WARLOCK = true,
    DRUID   = true, UNKNOWN = true,
}

local function knownClass(token)
    if type(token) ~= "string" or isSecret(token) then return false end
    return KNOWN_CLASSES[token] == true
end

-- A field that can travel inside a pipe-separated packet: present, not too
-- long, and free of control characters and pipes.
local function cleanText(value, maxLength)
    if type(value) ~= "string" or isSecret(value) then return nil end
    if value == "" or #value > maxLength then return nil end
    if value:find("[%c|]") then return nil end
    return value
end

-- A channel name is text like a player types: spaces are legal, pipes and
-- control characters are not.
local function cleanChannel(value)
    if type(value) ~= "string" or isSecret(value) then return nil end
    local trimmed = value:match("^%s*(.-)%s*$")
    if trimmed == "" or #trimmed > (Leaderboard.CHANNEL_LIMIT or 64) then return nil end
    if trimmed:find("[%c|]") then return nil end
    return trimmed
end

-- The three factions a row may claim. UnitFactionGroup reports the English
-- token on every client (the localised name is its second return and is not
-- used here), so a row can compare against these three safely.
local FACTIONS = {
    alliance = "Alliance",
    horde    = "Horde",
    neutral  = "Neutral",
}

local function knownFaction(value)
    if type(value) ~= "string" or isSecret(value) then return nil end
    return FACTIONS[string.lower(value)]
end

-- A race field as this file stores it: the short token UnitRace returns
-- ("Human", "NightElf"), or "" when nothing was reported. A field that is not
-- clean short text is refused with nil, because a race never needs a pipe, a
-- control character or a sentence; an unknown but clean token is kept, since
-- allied races exist and this file does not list them.
local function parseRace(value)
    if value == nil or value == "" then return "" end
    local race = cleanText(value, Leaderboard.RACE_LIMIT)
    if not race then return nil end
    -- Core caches "UNKNOWN" when the client cannot answer. That is not a race
    -- token, so it travels as "not reported" rather than as a fake one.
    if race == "UNKNOWN" then return "" end
    return race
end

-- A faction field as this file stores it: exactly Alliance, Horde or Neutral,
-- or "" when the packet predates the field or named a side this file does not
-- know. "" is honest where "Neutral" would be a claim. A field that is not
-- clean short text is refused with nil.
local function parseFaction(value)
    if value == nil or value == "" then return "" end
    if type(value) ~= "string" or isSecret(value) then return nil end
    if #value > (Leaderboard.FACTION_LIMIT or 16) then return nil end
    if value:find("[%c|]") then return nil end
    return knownFaction(value) or ""
end

------------------------------------------------------------------------------
-- Pure packet, board and ranking logic
--
-- Nothing below touches the client. The harness runs these directly, with the
-- packets, rosters and friend name sets passed in, which is what makes the
-- rules checkable without a running game.
------------------------------------------------------------------------------

local Pure = {}
Leaderboard.Pure = Pure

-- Case-insensitive identity, with a separator no player can type. Realm names
-- are compared exactly as the client reports them, modulo case.
function Pure.Key(name, realm)
    return string.lower(tostring(name)) .. "\31" .. string.lower(tostring(realm))
end

-- Lifetime of a row, whether it was stored in the current shape (lifetime) or
-- the version-1 shape (active + afk). Never returns nil so a sort cannot fail.
local function secondsOf(row)
    if type(row) ~= "table" then return 0 end
    if type(row.lifetime) == "number" then return row.lifetime end
    return asNumber(row.active, 0) + asNumber(row.afk, 0)
end

local function levelCap()
    return tonumber(Leaderboard.MAX_LEVEL) or 60
end

-- One version-4 packet from one row, or nil when the row cannot honestly be
-- sent. A client without a lifetime reading sends nothing rather than a zero
-- that would rank it as the fastest player on the board. Race, faction and
-- deaths are decoration: a row that cannot supply them still travels, with an
-- empty field or zero, because losing the report over a decoration would be
-- worse.
function Pure.Encode(row)
    if type(row) ~= "table" then return nil end

    local name = cleanText(row.name, Leaderboard.NAME_LIMIT)
    local realm = cleanText(row.realm, Leaderboard.REALM_LIMIT)
    if not name or not realm then return nil end
    if not knownClass(row.class) then return nil end

    local cap = levelCap()
    local level = math.floor(asNumber(row.level, -1))
    if level < 1 or level > cap then return nil end

    local lifetime = clampSeconds(row.lifetime)
    if lifetime == nil then return nil end

    local at60 = clampSeconds(row.at60) or 0
    if level < cap then at60 = 0 end

    local race = parseRace(row.race) or ""
    local faction = parseFaction(row.faction) or ""
    local deaths = clampDeaths(row.deaths) or 0

    local packet = string.format("%s|%s|%s|%s|%s|%s|%s|%s|%d|%d|%d|%d",
        Leaderboard.PREFIX, Leaderboard.VERSION, Leaderboard.KIND,
        name, realm, row.class, race, faction, level, lifetime, at60, deaths)

    if #packet > (tonumber(Leaderboard.PACKET_LIMIT) or 255) then return nil end
    return packet
end

-- A received packet as a row table, or nil plus the rule that refused it.
-- Version 4 carries twelve fields, ordered
-- name|realm|class|race|faction|level|lifetime|at60|deaths. Version 3 carried
-- eleven of them, without deaths, so a version-3 packet stores 0. Version 2
-- carried nine, name|realm|class|level|lifetime|at60, with no race or faction;
-- version 1 carried nine too, name|class|level|active|afk|realm, and has
-- at60 = 0 by definition because that version could not report it. A version
-- without the race/faction fields stores them as "" rather than inventing a
-- value; one without deaths stores 0.
function Pure.Parse(text)
    if type(text) ~= "string" then return nil, "not text" end
    if isSecret(text) then return nil, "restricted" end
    if text == "" then return nil, "empty" end
    if #text > (tonumber(Leaderboard.PACKET_LIMIT) or 255) then return nil, "too long" end

    local fields = {}
    for field in string.gmatch(text .. "|", "([^|]*)|") do
        fields[#fields + 1] = field
    end

    if fields[1] ~= Leaderboard.PREFIX then return nil, "prefix" end

    local version = fields[2]
    local expected
    if version == Leaderboard.VERSION then
        expected = 12
    elseif version == Leaderboard.V3_VERSION then
        expected = 11
    elseif version == Leaderboard.V2_VERSION or version == Leaderboard.LEGACY_VERSION then
        expected = 9
    else
        return nil, "version"
    end
    if #fields ~= expected then return nil, "field count" end
    if fields[3] ~= Leaderboard.KIND then return nil, "type" end

    local name = cleanText(fields[4], Leaderboard.NAME_LIMIT)
    if not name then return nil, "name" end

    local realm, class, race, faction, level, lifetime, at60, deaths
    if version == Leaderboard.VERSION or version == Leaderboard.V3_VERSION then
        realm = cleanText(fields[5], Leaderboard.REALM_LIMIT)
        if not realm then return nil, "realm" end
        class = fields[6]
        race = parseRace(fields[7])
        if race == nil then return nil, "race" end
        faction = parseFaction(fields[8])
        if faction == nil then return nil, "faction" end
        level = asNumber(fields[9], nil)
        lifetime = clampSeconds(fields[10])
        if lifetime == nil then return nil, "lifetime" end
        at60 = clampSeconds(fields[11])
        if at60 == nil then return nil, "at60" end

        if version == Leaderboard.VERSION then
            deaths = clampDeaths(fields[12])
            if deaths == nil then return nil, "deaths" end
        else
            deaths = 0
        end
    elseif version == Leaderboard.V2_VERSION then
        realm = cleanText(fields[5], Leaderboard.REALM_LIMIT)
        if not realm then return nil, "realm" end
        class = fields[6]
        race, faction = "", ""
        level = asNumber(fields[7], nil)
        lifetime = clampSeconds(fields[8])
        if lifetime == nil then return nil, "lifetime" end
        at60 = clampSeconds(fields[9])
        if at60 == nil then return nil, "at60" end
        deaths = 0
    else
        class = fields[5]
        race, faction = "", ""
        level = asNumber(fields[6], nil)
        local active = clampSeconds(fields[7])
        if active == nil then return nil, "active" end
        local afk = clampSeconds(fields[8])
        if afk == nil then return nil, "afk" end
        realm = cleanText(fields[9], Leaderboard.REALM_LIMIT)
        if not realm then return nil, "realm" end

        lifetime = active + afk
        local max = tonumber(Leaderboard.MAX_SECONDS) or 5000000
        if lifetime > max then lifetime = max end
        at60 = 0
        deaths = 0
    end

    if not knownClass(class) then return nil, "class" end
    if not level then return nil, "level" end

    level = math.floor(level)
    local cap = levelCap()
    if level < 1 or level > cap then return nil, "level range" end
    if level < cap then at60 = 0 end

    return {
        name = name, realm = realm, class = class,
        race = race, faction = faction,
        level = level, lifetime = lifetime, at60 = at60,
        deaths = deaths,
        version = version,
    }
end

-- Which board a channel feeds, or nil for a channel this file does not use.
-- Party, instance and the custom channel are same-realm reports, so they feed
-- the Party board; guild chat is the Guild board. RAID is accepted on the
-- receive side only, because a client can deliver a grouped message under it;
-- this file never sends there.
function Pure.BoardForChannel(channel, customName)
    if type(channel) ~= "string" or isSecret(channel) then return nil end

    local upper = string.upper(channel)
    if upper == Leaderboard.GUILD_CHANNEL then return Leaderboard.GUILD_BOARD end
    if upper == Leaderboard.CHANNEL or upper == Leaderboard.INSTANCE_CHANNEL
        or upper == "RAID" then
        return Leaderboard.SERVER_BOARD
    end

    if type(customName) == "string" and customName ~= ""
        and string.lower(channel) == string.lower(customName) then
        return Leaderboard.SERVER_BOARD
    end
    return nil
end

-- "Further along" is the only reason to overwrite a report. A higher level
-- always wins. At the same level a recorded time-to-60 beats no record, a
-- faster recorded time beats a slower one, and only then does a lower
-- lifetime win. Deaths are decoration and take no part in this decision:
-- only the winning report's deaths travel with the row. Equal plays keep what
-- is stored, so two clients alternating reports cannot make one row churn.
function Pure.FurtherAlong(candidate, existing)
    if type(candidate) ~= "table" or type(existing) ~= "table" then return false end

    local newLevel = asNumber(candidate.level, 0)
    local oldLevel = asNumber(existing.level, 0)
    if newLevel ~= oldLevel then return newLevel > oldLevel end

    local newAt = asNumber(candidate.at60, 0)
    local oldAt = asNumber(existing.at60, 0)
    local newHas, oldHas = newAt > 0, oldAt > 0
    if newHas ~= oldHas then return newHas end
    if newHas and oldHas and newAt ~= oldAt then return newAt < oldAt end

    return secondsOf(candidate) < secondsOf(existing)
end

-- Rebuilds one stored row from whatever the saved variables hold. Anything
-- that cannot be a row is discarded rather than repaired into a lie; a class
-- token this file does not know degrades to UNKNOWN because the class is
-- decoration, not identity.
local function storedRow(raw, boardName)
    if type(raw) ~= "table" then return nil end

    local name = cleanText(raw.name, Leaderboard.NAME_LIMIT)
    local realm = cleanText(raw.realm, Leaderboard.REALM_LIMIT)
    if not name or not realm then return nil end

    local cap = levelCap()
    local level = math.floor(asNumber(raw.level, 0))
    if level < 1 then return nil end
    if level > cap then level = cap end

    local lifetime = clampSeconds(raw.lifetime)
    if lifetime == nil then
        local active = clampSeconds(raw.active)
        if active == nil then return nil end
        lifetime = active + (clampSeconds(raw.afk) or 0)
        if lifetime > (tonumber(Leaderboard.MAX_SECONDS) or 5000000) then
            lifetime = tonumber(Leaderboard.MAX_SECONDS) or 5000000
        end
    end

    local at60 = clampSeconds(raw.at60) or 0
    if level < cap then at60 = 0 end

    local deaths = clampDeaths(raw.deaths) or 0

    local board = (boardName == Leaderboard.GUILD_BOARD)
        and Leaderboard.GUILD_BOARD or Leaderboard.SERVER_BOARD

    return {
        name = name,
        realm = realm,
        class = knownClass(raw.class) and raw.class or "UNKNOWN",
        race = parseRace(raw.race) or "",
        faction = parseFaction(raw.faction) or "",
        level = level,
        lifetime = lifetime,
        at60 = at60,
        deaths = deaths,
        board = board,
        channel = cleanChannel(raw.channel)
            or ((board == Leaderboard.GUILD_BOARD) and Leaderboard.GUILD_CHANNEL
                or Leaderboard.CHANNEL),
        at = asNumber(raw.at, 0),
        you = false,
        synthetic = false,
        reported = true,
        verified = false,
    }
end

local function emptyBoard()
    return { rows = {}, count = 0 }
end

local function boardTable(roster, boardName)
    local board = roster[boardName]
    if type(board) ~= "table" then
        board = emptyBoard()
        roster[boardName] = board
    end
    if type(board.rows) ~= "table" then board.rows = {} end
    return board
end

local function countRows(rows)
    local count = 0
    for _ in pairs(rows) do count = count + 1 end
    return count
end

-- Sorts weakest first: the row a full board gives up first. A row without a
-- 60 record is less useful than one with it; within the same level the slower
-- lifetime is weaker, and the older report breaks the last tie.
local function weakestKey(rows)
    local chosenKey, chosen
    for key, row in pairs(rows) do
        if not chosen then
            chosenKey, chosen = key, row
        else
            local level = asNumber(row.level, 0)
            local chosenLevel = asNumber(chosen.level, 0)
            local weaker
            if level ~= chosenLevel then
                weaker = level < chosenLevel
            else
                local at = asNumber(row.at60, 0)
                local chosenAt = asNumber(chosen.at60, 0)
                if (at > 0) ~= (chosenAt > 0) then
                    weaker = at <= 0
                elseif secondsOf(row) ~= secondsOf(chosen) then
                    weaker = secondsOf(row) > secondsOf(chosen)
                elseif asNumber(row.at, 0) ~= asNumber(chosen.at, 0) then
                    weaker = asNumber(row.at, 0) < asNumber(chosen.at, 0)
                else
                    weaker = tostring(key) < tostring(chosenKey)
                end
            end
            if weaker then chosenKey, chosen = key, row end
        end
    end
    return chosenKey
end

-- Brings the roster to the shape this file expects: two boards, each holding
-- only well-formed rows keyed by name+realm. A version-1 flat roster is read
-- as the Party board and its rows are moved, so no stored report is lost.
function Pure.Sanitize(roster)
    if type(roster) ~= "table" then return nil end

    local legacy = type(roster.rows) == "table" and roster.rows or nil

    for _, boardName in ipairs({ Leaderboard.SERVER_BOARD, Leaderboard.GUILD_BOARD }) do
        local board = boardTable(roster, boardName)
        local rows = {}
        for _, raw in pairs(board.rows) do
            local row = storedRow(raw, boardName)
            if row then rows[Pure.Key(row.name, row.realm)] = row end
        end
        board.rows = rows
        board.count = countRows(rows)
    end

    if legacy then
        local board = boardTable(roster, Leaderboard.SERVER_BOARD)
        for _, raw in pairs(legacy) do
            local row = storedRow(raw, Leaderboard.SERVER_BOARD)
            if row then
                local key = Pure.Key(row.name, row.realm)
                local existing = board.rows[key]
                if not existing or Pure.FurtherAlong(row, existing) then
                    board.rows[key] = row
                end
            end
        end
        board.count = countRows(board.rows)
        roster.rows = nil
        roster.count = nil
    end

    return roster
end

-- The shape Store writes for a row, checked without rebuilding it. A packet
-- that arrives on a board already holding rows of this shape needs no
-- Sanitize; that rebuild is for the legacy roster or a damaged one.
local function rowHasStoredShape(raw)
    if type(raw) ~= "table" then return false end
    if not cleanText(raw.name, Leaderboard.NAME_LIMIT) then return false end
    if not cleanText(raw.realm, Leaderboard.REALM_LIMIT) then return false end

    -- Every row this file writes carries both as strings, "" included. A row
    -- saved before version 3 has neither, so one rebuild adds them once.
    if type(raw.race) ~= "string" then return false end
    if type(raw.faction) ~= "string" then return false end

    local level = asNumber(raw.level, nil)
    if not level or level < 1 or level > levelCap() then return false end

    if raw.lifetime ~= nil then
        if asNumber(raw.lifetime, nil) == nil then return false end
    elseif asNumber(raw.active, nil) == nil then
        return false
    end

    -- Every row this file writes carries a whole death count, 0 included. A
    -- row saved before version 4 has none, so one rebuild adds it once.
    if type(raw.deaths) ~= "number" then return false end
    return true
end

local function boardNeedsSanitize(roster, boardName)
    local board = roster[boardName]
    if board == nil then return false end
    if type(board) ~= "table" then return true end
    if board.rows == nil then return false end
    if type(board.rows) ~= "table" then return true end

    for key, raw in pairs(board.rows) do
        if not rowHasStoredShape(raw) then return true end
        if key ~= Pure.Key(raw.name, raw.realm) then return true end
    end
    return false
end

-- True only when the full rebuild would change something: the version-1 flat
-- roster is still present, or a board holds a row this file would not write.
local function rosterNeedsSanitize(roster)
    if type(roster) ~= "table" then return false end
    if type(roster.rows) == "table" then return true end
    return boardNeedsSanitize(roster, Leaderboard.SERVER_BOARD)
        or boardNeedsSanitize(roster, Leaderboard.GUILD_BOARD)
end

-- Drops the weakest rows until one board fits. Returns how many were dropped.
function Pure.Trim(board, cap)
    if type(board) ~= "table" or type(board.rows) ~= "table" then return 0 end

    local limit = math.floor(asNumber(cap, Leaderboard.ROSTER_CAP) or Leaderboard.ROSTER_CAP)
    if limit < 1 then limit = 1 end

    board.count = countRows(board.rows)
    local dropped = 0
    while board.count > limit do
        local key = weakestKey(board.rows)
        if key == nil then break end
        board.rows[key] = nil
        board.count = board.count - 1
        dropped = dropped + 1
    end
    return dropped
end

-- Stores one received row on one board. Returns one of:
--   "added"     the row is new and on the board
--   "replaced"  the row was already there and is now further along
--   "kept"      the row was there and this report is not further along
--   "dropped"   the row was new but the full board is ahead of it
--   "refused"   the roster, the board or the row was unusable
function Pure.Store(roster, row, boardName, cap, at, channel)
    if type(row) ~= "table" then return "refused" end
    if boardName ~= Leaderboard.SERVER_BOARD and boardName ~= Leaderboard.GUILD_BOARD then
        return "refused"
    end

    if type(roster) ~= "table" then return "refused" end

    -- A normal packet lands on boards that already hold well-formed rows;
    -- rebuilding every row here would allocate a new table per stored row for
    -- every message. Only the legacy roster or damaged data needs Sanitize;
    -- the incoming row is still validated below.
    if rosterNeedsSanitize(roster) then Pure.Sanitize(roster) end

    local name = cleanText(row.name, Leaderboard.NAME_LIMIT)
    local realm = cleanText(row.realm, Leaderboard.REALM_LIMIT)
    if not name or not realm then return "refused" end

    local capLevel = levelCap()
    local level = math.floor(asNumber(row.level, 0))
    if level < 1 then return "refused" end
    if level > capLevel then level = capLevel end

    local lifetime = clampSeconds(row.lifetime)
    if lifetime == nil then return "refused" end

    local at60 = clampSeconds(row.at60) or 0
    if level < capLevel then at60 = 0 end

    local deaths = clampDeaths(row.deaths) or 0

    local board = boardTable(roster, boardName)
    local key = Pure.Key(name, realm)
    local candidate = {
        name = name,
        realm = realm,
        class = knownClass(row.class) and row.class or "UNKNOWN",
        race = parseRace(row.race) or "",
        faction = parseFaction(row.faction) or "",
        level = level,
        lifetime = lifetime,
        at60 = at60,
        deaths = deaths,
        board = boardName,
        channel = cleanChannel(channel)
            or ((boardName == Leaderboard.GUILD_BOARD) and Leaderboard.GUILD_CHANNEL
                or Leaderboard.CHANNEL),
        at = math.floor(asNumber(at, 0)),
        you = false,
        synthetic = false,
        reported = true,
        verified = false,
    }

    local existing = board.rows[key]
    if existing then
        if not Pure.FurtherAlong(candidate, existing) then
            return "kept", existing
        end
        board.rows[key] = candidate
        board.count = countRows(board.rows)
        return "replaced", candidate
    end

    board.rows[key] = candidate
    Pure.Trim(board, cap)

    if board.rows[key] then
        return "added", candidate
    end
    return "dropped"
end

-- Every well-formed row on one board, in no particular order.
function Pure.Rows(board, boardName)
    local list = {}
    if type(board) ~= "table" or type(board.rows) ~= "table" then return list end

    local name = (boardName == Leaderboard.GUILD_BOARD)
        and Leaderboard.GUILD_BOARD or Leaderboard.SERVER_BOARD
    for _, raw in pairs(board.rows) do
        local row = storedRow(raw, name)
        if row then list[#list + 1] = row end
    end
    return list
end

function Pure.Count(board, boardName)
    return #Pure.Rows(board, boardName)
end

-- Every stored row from both boards, plus the flat roster a version-1 build
-- left behind (read-only; Sanitize moves it on the first write).
function Pure.AllRows(roster)
    local list = {}
    if type(roster) ~= "table" then return list end

    for _, boardName in ipairs({ Leaderboard.SERVER_BOARD, Leaderboard.GUILD_BOARD }) do
        local board = roster[boardName]
        if type(board) == "table" and type(board.rows) == "table" then
            for _, raw in pairs(board.rows) do
                local row = storedRow(raw, boardName)
                if row then list[#list + 1] = row end
            end
        end
    end

    if type(roster.rows) == "table" then
        for _, raw in pairs(roster.rows) do
            local row = storedRow(raw, Leaderboard.SERVER_BOARD)
            if row then list[#list + 1] = row end
        end
    end
    return list
end

-- One row per character across both boards. The better report wins, so a
-- slower guild report cannot hide a faster server report.
function Pure.Merge(roster)
    local chosen, order = {}, {}
    for _, row in ipairs(Pure.AllRows(roster)) do
        local key = Pure.Key(row.name, row.realm)
        if not chosen[key] then
            chosen[key] = row
            order[#order + 1] = key
        elseif Pure.FurtherAlong(row, chosen[key]) then
            chosen[key] = row
        end
    end

    local list = {}
    for index, key in ipairs(order) do
        list[index] = chosen[key]
    end
    return list
end

-- A copy of `rows` with this character's own row attached and marked
-- `you = true`. A stored row for the same identity is dropped first, so one
-- character cannot be listed twice. Pure: the caller passes both tables in.
function Pure.WithOwn(rows, own)
    local list = {}
    if type(own) ~= "table" then
        for _, row in ipairs(rows or {}) do list[#list + 1] = row end
        return list
    end

    local key = Pure.Key(own.name, own.realm)
    for _, row in ipairs(rows or {}) do
        if type(row) ~= "table" or Pure.Key(row.name, row.realm) ~= key then
            list[#list + 1] = row
        end
    end

    list[#list + 1] = {
        name = own.name,
        realm = own.realm,
        class = own.class,
        race = (type(own.race) == "string") and own.race or "",
        faction = (type(own.faction) == "string") and own.faction or "",
        level = own.level,
        lifetime = own.lifetime,
        at60 = own.at60,
        deaths = clampDeaths(own.deaths) or 0,
        you = true,
        synthetic = false,
        reported = false,
        verified = false,
    }
    return list
end

-- The demo look: ten characters worth of class, race and faction, all of them
-- distinct where the game allows it, so the scoreboard shows the range of
-- labels it can draw without anyone else being online. The Skyborne (both
-- Alliance and Horde versions) is included; names, realm and the synthetic flag
-- still say plainly that no player reported any of this.
local DEMO_ROWS = {
    { class = "WARRIOR", race = "Human",            faction = "Alliance" },
    { class = "PALADIN", race = "Dwarf",            faction = "Alliance" },
    { class = "HUNTER",  race = "SkyborneAlliance", faction = "Alliance" },
    { class = "ROGUE",   race = "Gnome",            faction = "Alliance" },
    { class = "PRIEST",  race = "Undead",           faction = "Horde" },
    { class = "SHAMAN",  race = "Orc",              faction = "Horde" },
    { class = "MAGE",    race = "Troll",            faction = "Horde" },
    { class = "WARLOCK", race = "SkyborneHorde",    faction = "Horde" },
    { class = "DRUID",   race = "Tauren",           faction = "Horde" },
    { class = "WARRIOR", race = "SkyborneHorde",    faction = "Horde" },
}

-- One made-up row for the demo board. Every row is at the level cap with a
-- recorded time-to-60, so the demo fills both boards; every number differs, so
-- the order is stable. Names, realm and the synthetic flag say plainly that no
-- player reported this.
function Pure.DemoRow(index, cap)
    local position = math.floor(asNumber(index, 0) or 0)
    if position < 1 then position = 1 end

    local level = math.floor(asNumber(cap, levelCap()) or levelCap())
    if level < 1 then level = 1 end

    local template = DEMO_ROWS[((position - 1) % #DEMO_ROWS) + 1]
    local at60 = 4 * 3600 + (position - 1) * 900
    return {
        name = string.format("Demorow%02d", position),
        realm = Leaderboard.DEMO_REALM,
        class = template.class,
        race = template.race,
        faction = template.faction,
        level = level,
        lifetime = at60 + 3600 + (position - 1) * 600,
        at60 = at60,
        -- Varied so the demo column shows a range of numbers, never a count
        -- that pretends to be a record of anybody's play.
        deaths = 2 + (position - 1) * 7,
        you = false,
        synthetic = true,
        reported = false,
        verified = false,
    }
end

-- The rows currently held on roster.demo, each marked synthetic. An absent or
-- damaged demo board is an empty list, never an error. Nothing here is ever
-- merged: Pure.Merge reads only the Party and Guild boards.
function Pure.DemoRows(roster)
    local list = {}
    if type(roster) ~= "table" then return list end

    local board = roster[Leaderboard.DEMO_BOARD]
    if type(board) ~= "table" or type(board.rows) ~= "table" then return list end

    for _, raw in pairs(board.rows) do
        local row = storedRow(raw, Leaderboard.SERVER_BOARD)
        if row then
            row.synthetic = true
            row.reported = false
            row.board = Leaderboard.DEMO_BOARD
            list[#list + 1] = row
        end
    end
    return list
end

local function identityOrder(a, b)
    return string.lower(tostring(a.name)) .. "\31" .. string.lower(tostring(a.realm))
        < string.lower(tostring(b.name)) .. "\31" .. string.lower(tostring(b.realm))
end

-- Farthest along first: higher level, then the lower lifetime, then the name
-- so the order is stable between two openings of the same board.
local function levelOrder(a, b)
    local levelA = asNumber(a.level, 0)
    local levelB = asNumber(b.level, 0)
    if levelA ~= levelB then return levelA > levelB end

    local secondsA = secondsOf(a)
    local secondsB = secondsOf(b)
    if secondsA ~= secondsB then return secondsA < secondsB end

    return identityOrder(a, b)
end
Pure.LevelOrder = levelOrder

-- Fastest time-to-60 first. Only rows at the cap with a recorded time take
-- part; the caller filters as well.
local function recordOrder(a, b)
    local atA = asNumber(a.at60, 0)
    local atB = asNumber(b.at60, 0)
    if atA ~= atB then return atA < atB end
    return identityOrder(a, b)
end
Pure.RecordOrder = recordOrder

-- A sorted copy of the first `limit` rows, sorted by `order`.
function Pure.TopRows(rows, limit, order)
    local list = {}
    if type(rows) == "table" then
        for index, row in ipairs(rows) do list[index] = row end
    end

    table.sort(list, order or levelOrder)

    local wanted = math.floor(asNumber(limit, Leaderboard.TOP_LIMIT) or Leaderboard.TOP_LIMIT)
    if wanted < 0 then wanted = 0 end
    while #list > wanted do
        table.remove(list)
    end
    return list
end

-- The record board: level 60 rows with a recorded time, fastest first.
function Pure.RecordRows(rows, limit, cap)
    local required = tonumber(cap) or levelCap()
    local eligible = {}
    for _, row in ipairs(rows or {}) do
        if asNumber(row.level, 0) >= required and asNumber(row.at60, 0) > 0 then
            eligible[#eligible + 1] = row
        end
    end
    return Pure.TopRows(eligible, limit, recordOrder)
end

local function rankOf(rows, own, order, eligible)
    if type(own) ~= "table" then return nil end
    if eligible and not eligible(own) then return nil end

    local key = Pure.Key(own.name, own.realm)
    local list = {}
    for _, row in ipairs(rows or {}) do
        if (not eligible or eligible(row))
            and Pure.Key(row.name, row.realm) ~= key then
            list[#list + 1] = row
        end
    end
    list[#list + 1] = own
    table.sort(list, order)

    for index, row in ipairs(list) do
        if Pure.Key(row.name, row.realm) == key then return index end
    end
    return nil
end

-- Where this character stands among the received rows plus its own row.
function Pure.LevelRank(rows, own)
    return rankOf(rows, own, levelOrder)
end

function Pure.RecordRank(rows, own, cap)
    local required = tonumber(cap) or levelCap()
    return rankOf(rows, own, recordOrder, function(row)
        return asNumber(row.level, 0) >= required and asNumber(row.at60, 0) > 0
    end)
end

-- The friends filter: rows whose name appears in a set of lowercase names.
-- A filter only; the rows themselves are unchanged.
function Pure.Friends(rows, names)
    local list = {}
    if type(rows) ~= "table" or type(names) ~= "table" then return list end

    for _, row in ipairs(rows) do
        local name = type(row) == "table" and row.name or nil
        if type(name) == "string" and names[string.lower(name)] then
            list[#list + 1] = row
        end
    end
    return list
end

-- "1h 02m", "12m 03s", "42s".
function Pure.Duration(seconds)
    local total = math.floor(asNumber(seconds, 0))
    if total < 0 then total = 0 end

    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)
    local secs = total % 60

    if hours > 0 then return string.format("%dh %02dm", hours, minutes) end
    if minutes > 0 then return string.format("%dm %02ds", minutes, secs) end
    return string.format("%ds", secs)
end

------------------------------------------------------------------------------
-- Options
--
-- The four keys live in this character's options table. Missing keys read as
-- the defaults in Leaderboard.OPTION_DEFAULTS; nothing is written outside the
-- character record.
------------------------------------------------------------------------------

local function optionsTable()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return nil
    end

    local ok, options = pcall(database.GetOptions, database)
    if ok and type(options) == "table" then return options end
    return nil
end

local function readToggle(key)
    local default = Leaderboard.OPTION_DEFAULTS[key] == true
    local options = optionsTable()
    if not options then return default end

    local value = options[key]
    if value == nil then return default end
    if type(value) == "boolean" then return value end
    return default
end

local function writeToggle(key, enabled)
    local options = optionsTable()
    if not options then
        return false, "the character record is not loaded yet"
    end

    options[key] = (enabled == true)
    return true
end

function Leaderboard:IsSharing()
    return readToggle("ranksShare")
end

function Leaderboard:IsServerSharing()
    return readToggle("ranksServer")
end

function Leaderboard:IsGuildSharing()
    return readToggle("ranksGuild")
end

function Leaderboard:IsFriendFilter()
    return readToggle("ranksFriends")
end

function Leaderboard:SetSharing(enabled)
    return writeToggle("ranksShare", enabled)
end

function Leaderboard:SetServerSharing(enabled)
    return writeToggle("ranksServer", enabled)
end

function Leaderboard:SetGuildSharing(enabled)
    return writeToggle("ranksGuild", enabled)
end

function Leaderboard:SetFriendFilter(enabled)
    return writeToggle("ranksFriends", enabled)
end

------------------------------------------------------------------------------
-- Custom channel
--
-- The name is remembered in the character options so every character can pick
-- its own. Membership is read from the client whenever it can answer, and the
-- remembered flag is only a fallback for a client without GetChannelName.
------------------------------------------------------------------------------

function Leaderboard:ChannelName()
    local options = optionsTable()
    local stored = options and options.ranksChannel or nil
    local channel = cleanChannel(stored)
    if channel then return channel end
    return Leaderboard.DEFAULT_CUSTOM_CHANNEL
end

function Leaderboard:IsChannelJoined()
    local channel = self:ChannelName()
    if not channel then return false end

    if type(GetChannelName) == "function" then
        local ok, id = pcall(GetChannelName, channel)
        local number = ok and asNumber(id, nil) or nil
        if number then return number > 0 end
    end

    local options = optionsTable()
    return options ~= nil and options.ranksChannelJoined == true
end

function Leaderboard:Channel()
    return { name = self:ChannelName(), joined = self:IsChannelJoined() }
end

local function joinFunction()
    if type(JoinChannelByName) == "function" then return JoinChannelByName end
    if type(JoinPermanentChannel) == "function" then return JoinPermanentChannel end
    return nil
end

function Leaderboard:JoinChannel(name)
    local channel = cleanChannel(name)
    if not channel then
        return false, "that is not a usable channel name"
    end

    local current = self:ChannelName()
    if current and string.lower(current) == string.lower(channel)
        and self:IsChannelJoined() then
        return true, "already joined " .. channel
    end

    local join = joinFunction()
    if not join then
        return false, "this client cannot join chat channels"
    end

    local ok = pcall(join, channel)
    if not ok then
        return false, "the client refused to join that channel"
    end

    local options = optionsTable()
    if options then
        options.ranksChannel = channel
        options.ranksChannelJoined = true
    end

    -- When the client can answer, trust its answer over the call's return.
    if type(GetChannelName) == "function" then
        local checked, id = pcall(GetChannelName, channel)
        local number = checked and asNumber(id, nil) or nil
        if number and number <= 0 then
            return false, "the client did not list the channel after joining it"
        end
    end

    return true, "joined " .. channel
end

function Leaderboard:LeaveChannel()
    local channel = self:ChannelName()
    if not channel then
        return false, "no custom channel is set"
    end

    if type(LeaveChannelByName) ~= "function" then
        return false, "this client cannot leave chat channels"
    end

    local ok = pcall(LeaveChannelByName, channel)
    if not ok then
        return false, "the client refused to leave that channel"
    end

    -- Only a leave the client accepted clears the flag; a refused call may
    -- still be in the channel, so the record keeps saying joined.
    local options = optionsTable()
    if options then options.ranksChannelJoined = false end
    return true, "left " .. channel
end

------------------------------------------------------------------------------
-- Transport
--
-- Two generations of the same call. C_ChatInfo is the modern home; the
-- pre-8.0 client has the plain global. If neither exists, sharing is
-- unavailable and says so rather than failing at the moment of a level-up.
------------------------------------------------------------------------------

function Leaderboard:Transport()
    local chat = C_ChatInfo
    if type(chat) == "table" and type(chat.SendAddonMessage) == "function" then
        return chat.SendAddonMessage, chat, "C_ChatInfo"
    end
    if type(SendAddonMessage) == "function" then
        return SendAddonMessage, nil, "legacy"
    end
    return nil, nil, nil
end

function Leaderboard:IsShareAvailable()
    local send, _, flavour = self:Transport()
    if not send then
        return false, "this client has no addon-message function"
    end
    return true, flavour
end

-- Registers the prefix so incoming messages are delivered. The client returns
-- true only when the prefix is now registered; a false return is a refusal and
-- is not treated as success. One retry is allowed, because a refusal can be a
-- transient client state; after the second refusal the prefix is unavailable
-- and is not tried again.
function Leaderboard:RegisterPrefix()
    if self.prefixState == "registered" then return true end
    if self.prefixState == "unavailable" then return false end

    local function attempt(register)
        local ok, accepted = pcall(register, self.PREFIX)
        if ok and accepted ~= false then
            self.prefixState = "registered"
            return true
        end

        local attempts = (self.prefixAttempts or 0) + 1
        self.prefixAttempts = attempts
        self.prefixState = (attempts >= 2) and "unavailable" or "failed"
        return false
    end

    local chat = C_ChatInfo
    if type(chat) == "table" and type(chat.RegisterAddonMessagePrefix) == "function" then
        return attempt(chat.RegisterAddonMessagePrefix)
    end

    if type(RegisterAddonMessagePrefix) == "function" then
        return attempt(RegisterAddonMessagePrefix)
    end

    self.prefixState = "unavailable"
    return false
end

------------------------------------------------------------------------------
-- Clocks and identity
------------------------------------------------------------------------------

-- One clock for the throttle: the monotonic one when the client has it, the
-- wall clock otherwise. Nil means neither exists, and then no send is made,
-- because the once-a-minute rule could not be honoured.
function Leaderboard:Clock()
    if type(GetTime) == "function" then
        local ok, value = pcall(GetTime)
        local number = asNumber(value, nil)
        if ok and number then return number end
    end

    if type(time) == "function" then
        local ok, value = pcall(time)
        local number = asNumber(value, nil)
        if ok and number then return number end
    end

    return nil
end

function Leaderboard:Epoch()
    if type(time) ~= "function" then return 0 end
    local ok, value = pcall(time)
    local number = asNumber(value, nil)
    if ok and number then return math.floor(number) end
    return 0
end

local function readBoolean(fn)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn)
    if not ok or isSecret(value) then return nil end
    return value == true
end

function Leaderboard:InGroup()
    return readBoolean(IsInGroup) == true
end

function Leaderboard:InInstance()
    return readBoolean(IsInInstance) == true
end

function Leaderboard:InRaid()
    return readBoolean(IsInRaid) == true
end

function Leaderboard:InGuild()
    local direct = readBoolean(IsInGuild)
    if direct ~= nil then return direct end

    if type(GetGuildInfo) == "function" then
        local ok, name = pcall(GetGuildInfo, "player")
        if ok and not isSecret(name) and type(name) == "string" and name ~= "" then
            return true
        end
    end
    return false
end

-- Party chat does not exist in a raid outside an instance, and instance chat
-- is the only grouped channel there. Nil means this character has no grouped
-- transport right now.
function Leaderboard:GroupChannel()
    if self:InInstance() then return self.INSTANCE_CHANNEL end
    if self:InRaid() then return nil end
    return self.CHANNEL
end

local function readPlayerName(fallback)
    if type(UnitName) == "function" then
        local ok, value = pcall(UnitName, "player")
        if ok and not isSecret(value) and type(value) == "string" and value ~= "" then
            return value
        end
    end
    if type(fallback) == "string" and fallback ~= "" and not isSecret(fallback) then
        return fallback
    end
    return "Unknown"
end

local function readRealm(fallback)
    if type(GetRealmName) == "function" then
        local ok, value = pcall(GetRealmName)
        if ok and not isSecret(value) and type(value) == "string" and value ~= "" then
            return value
        end
    end
    if type(fallback) == "string" and fallback ~= "" and not isSecret(fallback) then
        return fallback
    end
    return "Unknown"
end

local function readPlayerClass(fallback)
    if type(UnitClass) == "function" then
        local ok, _, token = pcall(UnitClass, "player")
        if ok and not isSecret(token) and knownClass(token) then return token end
    end
    if knownClass(fallback) then return fallback end
    return "UNKNOWN"
end

-- The race token, not the localised name: the second return of UnitRace is the
-- token this file stores and sends. A client that cannot answer, or answers
-- with something that is not clean short text, yields "" (not reported) rather
-- than a made-up race.
local function readPlayerRace(fallback)
    if type(UnitRace) == "function" then
        local ok, _, token = pcall(UnitRace, "player")
        if ok and not isSecret(token) then
            local race = parseRace(token)
            if race and race ~= "" then return race end
        end
    end

    local race = parseRace(fallback)
    if race and race ~= "" then return race end
    return ""
end

-- Alliance, Horde or Neutral, or "" when neither the client nor the cached
-- player record can name a side. Never "Neutral" by default: that would be a
-- claim the client did not make.
local function readPlayerFaction(fallback)
    if type(UnitFactionGroup) == "function" then
        local ok, token = pcall(UnitFactionGroup, "player")
        if ok and not isSecret(token) then
            local faction = parseFaction(token)
            if faction and faction ~= "" then return faction end
        end
    end

    local faction = parseFaction(fallback)
    if faction and faction ~= "" then return faction end
    return ""
end

local function readPlayerLevel(fallback)
    if type(UnitLevel) == "function" then
        local ok, value = pcall(UnitLevel, "player")
        local number = asNumber(value, nil)
        if ok and number and number > 0 then return number end
    end
    return asNumber(fallback, 1)
end

-- Seconds this account has seen played, active and AFK. Used only as the
-- fallback when Played cannot answer: Played knows the client's own /played
-- total, which one session's ledger cannot reconstruct. Returns nil when
-- there is no ledger reading at all, never a zero that would claim one.
function Leaderboard:OwnPlaytime()
    local module = LT.Played
    if type(module) ~= "table" or type(module.GetPlayed) ~= "function" then
        return nil
    end

    local ok, played = pcall(module.GetPlayed, module, false)
    if not ok or type(played) ~= "table" then return nil end

    local total = played.total
    if type(total) ~= "table" then return nil end

    local active = asNumber(total.active, 0)
    local afk = asNumber(total.afk, 0)
    if active < 0 then active = 0 end
    if afk < 0 then afk = 0 end

    local open = played.open
    local pure = module.Pure
    if type(open) == "table" and type(pure) == "table" and type(pure.Elapsed) == "function" then
        local now, epoch
        if type(module.ReadClock) == "function" then
            local clocked, n, e = pcall(module.ReadClock, module)
            if clocked then now, epoch = n, e end
        end

        local elapsedOk, elapsed = pcall(pure.Elapsed, open, now, epoch)
        if elapsedOk and type(elapsed) == "number" and elapsed > 0 then
            if open.afk == true then afk = afk + elapsed else active = active + elapsed end
        end
    end

    return math.floor(active), math.floor(afk)
end

function Leaderboard:OwnIdentity()
    local player = LT.player or {}
    return {
        name = readPlayerName(player.name),
        realm = readRealm(player.realm),
        class = readPlayerClass(player.class),
        race = readPlayerRace(player.race),
        faction = readPlayerFaction(player.faction),
        level = readPlayerLevel(player.level),
    }
end

-- The character's lifetime seconds: the client /played figure Played captured
-- at login, extended by everything tracked since. Falls back to this file's
-- own ledger only when Played is not loaded or has no reading. Returns nil
-- when neither can answer, so a caller refuses to share rather than encoding
-- a lifetime of zero.
function Leaderboard:OwnLifetime()
    local module = LT.Played
    if type(module) == "table" and type(module.LifetimeSeconds) == "function" then
        local ok, value = pcall(module.LifetimeSeconds, module)
        local seconds = ok and asNumber(value, nil) or nil
        if seconds then
            if seconds < 0 then seconds = 0 end
            return math.floor(seconds)
        end
    end

    local active, afk = self:OwnPlaytime()
    if active == nil then return nil end
    return math.max(0, active + afk)
end

-- The time-to-60 figure, and only at the cap: below 60 there is no such
-- number, so a partner cannot mistake a growing lifetime for a record.
function Leaderboard:OwnAt60(level)
    local cap = tonumber(self.MAX_LEVEL) or 60
    if asNumber(level, 0) < cap then return 0 end

    local module = LT.Played
    if type(module) == "table" and type(module.Level60Seconds) == "function" then
        local ok, value = pcall(module.Level60Seconds, module)
        local seconds = ok and asNumber(value, nil) or nil
        if seconds then
            local clamped = clampSeconds(seconds)
            if clamped then return clamped end
        end
    end
    return 0
end

-- Deaths before the cap, from Played's ledger. Always a number: a client
-- without a ledger reports 0 rather than a field the board cannot draw, and
-- the count is clamped to the same range the packet accepts.
function Leaderboard:OwnDeaths()
    local module = LT.Played
    if type(module) == "table" and type(module.DeathsUntil60) == "function" then
        local ok, value = pcall(module.DeathsUntil60, module)
        local deaths = ok and asNumber(value, nil) or nil
        if deaths then
            if deaths < 0 then deaths = 0 end
            local cap = tonumber(self.MAX_DEATHS) or 99999
            if deaths > cap then deaths = cap end
            return math.floor(deaths)
        end
    end
    return 0
end

function Leaderboard:OwnRow()
    local identity = self:OwnIdentity()

    local cap = tonumber(self.MAX_LEVEL) or 60
    local level = math.floor(asNumber(identity.level, 1))
    if level < 1 then level = 1 end
    if level > cap then level = cap end

    return {
        name = identity.name,
        realm = identity.realm,
        class = identity.class,
        race = identity.race,
        faction = identity.faction,
        level = level,
        lifetime = clampSeconds(self:OwnLifetime()),
        at60 = self:OwnAt60(level),
        deaths = self:OwnDeaths(),
    }
end

------------------------------------------------------------------------------
-- Roster access
--
-- Account-wide at LunchboxToolkitDB.roster, split into the server and guild
-- boards. Reading never creates anything; a received row or an explicit write
-- is what fills it.
------------------------------------------------------------------------------

function Leaderboard:GetRoster(create)
    if type(LunchboxToolkitDB) ~= "table" then
        if not create then return nil end
        LunchboxToolkitDB = {}
    end

    local store = LunchboxToolkitDB
    if type(store.roster) ~= "table" then
        if not create then return nil end
        store.roster = {}
    end

    local roster = store.roster
    if create then
        if rosterNeedsSanitize(roster) then
            Pure.Sanitize(roster)
        else
            -- The create contract still hands back both boards; only the row
            -- rebuild that a normal packet does not need is skipped.
            boardTable(roster, Leaderboard.SERVER_BOARD)
            boardTable(roster, Leaderboard.GUILD_BOARD)
        end
    end
    return roster
end

-- Whether the made-up demo board is present on the roster. On/off is the
-- board's existence, so the state survives a reload with the account record
-- and no separate option key is needed.
function Leaderboard:IsDemo()
    local roster = self:GetRoster(false)
    if type(roster) ~= "table" then return false end

    local board = roster[Leaderboard.DEMO_BOARD]
    return type(board) == "table" and type(board.rows) == "table"
        and next(board.rows) ~= nil
end

-- Writes the made-up rows to roster.demo, or clears that board. Returns the
-- row count as the second value. Nothing here touches the server or guild
-- boards, and no transport is called.
function Leaderboard:SetDemo(enabled)
    if enabled then
        local roster = self:GetRoster(true)
        if type(roster) ~= "table" then
            return false, "the character record is not loaded yet"
        end

        local board = { rows = {}, count = 0 }
        local count = math.floor(asNumber(Leaderboard.DEMO_COUNT, 10) or 10)
        if count < 1 then count = 1 end

        for index = 1, count do
            local row = Pure.DemoRow(index, self.MAX_LEVEL)
            board.rows[Pure.Key(row.name, row.realm)] = row
        end
        board.count = countRows(board.rows)
        roster[Leaderboard.DEMO_BOARD] = board

        if type(LT.Fire) == "function" then
            pcall(LT.Fire, LT, self.EVENT, {
                status = "demo", board = Leaderboard.DEMO_BOARD, demo = true,
            })
        end
        return true, board.count
    end

    local roster = self:GetRoster(false)
    if type(roster) == "table" then roster[Leaderboard.DEMO_BOARD] = nil end

    if type(LT.Fire) == "function" then
        pcall(LT.Fire, LT, self.EVENT, {
            status = "demo", board = Leaderboard.DEMO_BOARD, demo = false,
        })
    end
    return true, 0
end

-- The data the UI draws, and nothing else:
--   level   the top TOP_LIMIT rows, level high to low then lifetime low to
--           high; this character's own row is always present and marked
--           you = true, so the board is never blank when only one player exists
--   records the top RECORD_LIMIT rows at the cap with a recorded time-to-60,
--           fastest first; the own row takes part only at the cap, through the
--           same eligibility rule as every other row
--   mine    this character's rank on both boards and its own numbers
--   channel the custom channel's name and whether this client is joined
--   share   the same four switches the options hold, plus the channel and its
--           joined flag, as one table: { sharing, server, guild, friends,
--           channel, joined }. A sharing popup can be drawn from this without
--           reading Database options or Leaderboard's option keys itself.
--           Values are the effective ones, so an absent key reads as its
--           documented default exactly as the send rules do.
--   friendsOnly      the filter this call was asked for
--   friendsAvailable whether the client could answer the friend filter
--   demo    true while the made-up roster.demo board is showing instead of
--           the server and guild rows
--   emptyLevel / emptyRecords  a sentence for each board the UI may print when
--           that list is empty
--
-- Every row on level and records carries name, realm, class, race, faction,
-- level, lifetime, at60, deaths, and you/synthetic flags. race and faction are
-- always strings there; "" means that sender did not report them (a version-2
-- or version-1 peer, or a client without UnitRace/UnitFactionGroup). deaths is
-- always a number: 0 for a version-3 or older peer, or for a ledger that
-- cannot answer.
--
-- options.friendsOnly filters the whole received set before the top-N cap, so
-- a friend ranked past TOP_LIMIT still makes the board. Without options the
-- call behaves exactly as before. While the demo is on, the made-up rows are
-- used, marked synthetic = true, and the friends filter is not applied to
-- them: the point of the demo is that both boards draw.
function Leaderboard:Boards(options)
    local roster = self:GetRoster(false)
    local demo = self:IsDemo()
    local received = demo and Pure.DemoRows(roster) or Pure.Merge(roster)

    local friendsOnly = type(options) == "table" and options.friendsOnly == true
    local friendsAvailable
    if friendsOnly and not demo then
        -- Filter first, cap second: filtering the capped list would hide a
        -- friend at rank 21 even though the filter is what asked for them.
        received, friendsAvailable = self:Friends(received)
    end

    local own = self:OwnRow()
    local rows = Pure.WithOwn(received, own)

    -- Read the switches once: the popup and the channel line must show the
    -- same answer, and the send rules use these same readers.
    local channelName = self:ChannelName()
    local channelJoined = self:IsChannelJoined()

    return {
        level = Pure.TopRows(rows, self.TOP_LIMIT),
        records = Pure.RecordRows(rows, self.RECORD_LIMIT, self.MAX_LEVEL),
        mine = {
            levelRank = Pure.LevelRank(received, own),
            recordRank = Pure.RecordRank(received, own, self.MAX_LEVEL),
            level = own.level,
            lifetime = own.lifetime,
            at60 = own.at60,
        },
        channel = { name = channelName, joined = channelJoined },
        share = {
            sharing = self:IsSharing(),
            server = self:IsServerSharing(),
            guild = self:IsGuildSharing(),
            friends = self:IsFriendFilter(),
            channel = channelName,
            joined = channelJoined,
        },
        friendsOnly = friendsOnly,
        friendsAvailable = friendsAvailable,
        demo = demo,
        emptyLevel = Leaderboard.EMPTY_LEVEL,
        emptyRecords = Leaderboard.EMPTY_RECORDS,
    }
end

------------------------------------------------------------------------------
-- Friends
--
-- A filter over rows already received, read from the client's friend list by
-- name. No friend ever receives anything from this file on that account, and
-- the guild/server rows are untouched.
------------------------------------------------------------------------------

-- A set of lowercase friend names, or nil when this client cannot enumerate
-- the list. Every client read is guarded; a failed call drops that friend,
-- never the whole board.
function Leaderboard:FriendNames()
    local list = C_FriendList
    if type(list) == "table"
        and type(list.GetNumFriends) == "function"
        and type(list.GetFriendInfoByIndex) == "function" then
        local ok, count = pcall(list.GetNumFriends)
        local total = ok and asNumber(count, 0) or 0
        if total < 0 then total = 0 end

        local names = {}
        for index = 1, total do
            local got, info = pcall(list.GetFriendInfoByIndex, index)
            if got and type(info) == "table" and not isSecret(info.name)
                and type(info.name) == "string" and info.name ~= "" then
                names[string.lower(info.name)] = true
            end
        end
        return names
    end

    if type(GetNumFriends) == "function" and type(GetFriendInfo) == "function" then
        local ok, count = pcall(GetNumFriends)
        local total = ok and asNumber(count, 0) or 0
        if total < 0 then total = 0 end

        local names = {}
        for index = 1, total do
            local got, name = pcall(GetFriendInfo, index)
            if got and not isSecret(name)
                and type(name) == "string" and name ~= "" then
                names[string.lower(name)] = true
            end
        end
        return names
    end

    return nil
end

-- Rows that belong to a friend. With no rows argument the whole received set
-- is filtered. Second return: whether this client could read a friend list at
-- all, so the UI can say "unavailable" instead of "no friends".
function Leaderboard:Friends(rows)
    if rows == nil then
        rows = Pure.Merge(self:GetRoster(false))
    end

    local names = self:FriendNames()
    if names then return Pure.Friends(rows, names), true end

    -- A client with only a per-name lookup can still answer, one row at a
    -- time; there is no list to enumerate and no error to report. Both the
    -- namespace and the era global are plain functions, so neither takes self.
    local lookup
    local list = C_FriendList
    if type(list) == "table" and type(list.GetFriendInfo) == "function" then
        lookup = list.GetFriendInfo
    elseif type(GetFriendInfo) == "function" then
        lookup = GetFriendInfo
    end
    if not lookup then return {}, false end

    local filtered = {}
    for _, row in ipairs(rows or {}) do
        local name = type(row) == "table" and row.name or nil
        if type(name) == "string" and not isSecret(name) then
            local ok, info = pcall(lookup, name)
            local found = ok and (info == true or info == name
                or (type(info) == "table" and info.name == name))
            if found then filtered[#filtered + 1] = row end
        end
    end
    return filtered, true
end

------------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------------

-- Every transport this character may use right now. Duplicates are removed so
-- a channel named after a built-in one cannot send twice.
function Leaderboard:Targets()
    local targets, seen = {}, {}

    local function add(channel)
        if type(channel) ~= "string" or channel == "" then return end
        local key = string.lower(channel)
        if seen[key] then return end
        seen[key] = true
        targets[#targets + 1] = channel
    end

    if self:IsServerSharing() then
        if self:InGroup() then add(self:GroupChannel()) end
        local custom = self:ChannelName()
        if custom and self:IsChannelJoined() then add(custom) end
    end

    if self:IsGuildSharing() and self:InGuild() then
        add(self.GUILD_CHANNEL)
    end

    return targets
end

-- One share round, if every rule allows it: master on, a transport available
-- and wanted, and no round in the last minute. The attempt is recorded against
-- the throttle even when the client call fails, because the rule is a rate
-- limit, not a promise that the message arrived.
function Leaderboard:Share(reason)
    if not self:IsSharing() then return false, "sharing is off" end

    -- Addon-message comms are blocked and secret inside instances (Forever
    -- §8/§11): a share there would silently no-op, so refuse it and say why.
    if self:InInstance() then
        return false, "leaderboard sharing is disabled inside instances"
    end

    local send = self:Transport()
    if not send then return false, "this client has no addon-message function" end

    local now = self:Clock()
    if not now then return false, "no clock to enforce the one-a-minute limit" end

    if self.lastSentAt and (now - self.lastSentAt) < self.THROTTLE_SECONDS then
        return false, "shared less than a minute ago"
    end

    local targets = self:Targets()
    if #targets == 0 then return false, "no shared channel is available" end

    local packet = Pure.Encode(self:OwnRow())
    if not packet then return false, "the row could not be encoded" end

    self.lastSentAt = now
    self:RegisterPrefix()

    local sent = 0
    for _, channel in ipairs(targets) do
        local called = pcall(send, self.PREFIX, packet, channel)
        if called then sent = sent + 1 end
    end

    self.lastSentReason = reason
    if sent == 0 then
        LT:Debug("ranks: addon-message calls failed (" .. tostring(reason) .. ")")
        return false, "the addon-message call failed"
    end

    LT:Debug("ranks: shared a row on " .. tostring(sent)
        .. " channel(s) (" .. tostring(reason) .. ")")
    return true, packet
end

-- The page-opening call the UI makes. It shares when the throttle allows and
-- returns the result without printing; the caller owns the screen.
function Leaderboard:PageOpened()
    if not self:IsSharing() then return false, "sharing is off" end
    return self:Share("ranks page")
end

------------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------------

function Leaderboard:IsOwn(row)
    if type(row) ~= "table" then return false end
    local identity = self:OwnIdentity()

    return string.lower(tostring(row.name)) == string.lower(tostring(identity.name))
        and string.lower(tostring(row.realm)) == string.lower(tostring(identity.realm))
end

-- One addon message off the wire. Returns true only when a row was stored.
-- Nothing is stored while sharing is off: the boards are opt-in, so a message
-- that arrives before the player turns it on cannot grow them. The channel
-- decides the board; a channel this file does not use is ignored, and each
-- board's toggle is honoured on receipt as well as on send.
function Leaderboard:OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= self.PREFIX then return false end

    if not self:IsSharing() then
        LT:Debug("ranks: ignored a packet while sharing is off")
        return false
    end

    local row, reason = Pure.Parse(text)
    if not row then
        self.refused = (self.refused or 0) + 1
        LT:Debug("ranks: refused a packet (" .. tostring(reason) .. ") from "
            .. tostring(sender))
        return false
    end

    -- Our own row is already reported as the player's own line; storing it
    -- would make this character look like a report about somebody else.
    if self:IsOwn(row) then return false end

    local boardName = Pure.BoardForChannel(channel, self:ChannelName())
    if not boardName then
        self.refused = (self.refused or 0) + 1
        LT:Debug("ranks: ignored a packet from a channel this file does not use")
        return false
    end

    if boardName == self.GUILD_BOARD and not self:IsGuildSharing() then return false end
    if boardName == self.SERVER_BOARD and not self:IsServerSharing() then return false end

    local roster = self:GetRoster(true)
    if not roster then return false end

    local status, stored = Pure.Store(roster, row, boardName,
        self.ROSTER_CAP, self:Epoch(), channel)

    if status == "added" or status == "replaced" then
        self.accepted = (self.accepted or 0) + 1
        LT:Fire(self.EVENT, {
            status = status,
            board = boardName,
            key = stored and Pure.Key(stored.name, stored.realm) or nil,
        })
        return true
    end

    if status == "dropped" then
        LT:Debug("ranks: board is full; a weaker row was not kept")
    end
    return false
end

-- The hook target. Wrapped so a bad packet can never reach the event handler.
function Leaderboard:HandleMessage(prefix, text, channel, sender)
    local ok, err = pcall(self.OnAddonMessage, self, prefix, text, channel, sender)
    if not ok then
        LT:Debug("ranks: packet handling failed: " .. tostring(err))
    end
end

------------------------------------------------------------------------------
-- Report
------------------------------------------------------------------------------

local function identityLabel(row, ownRealm)
    if string.lower(tostring(row.realm)) == string.lower(tostring(ownRealm)) then
        return row.name
    end
    return tostring(row.name) .. "-" .. tostring(row.realm)
end

-- Prints, never draws. An empty board says why rather than printing a heading
-- with nothing under it.
function Leaderboard:Report()
    local sharing = self:IsSharing()
    local available, detail = self:IsShareAvailable()
    local own = self:OwnRow()
    local boards = self:Boards()
    local roster = self:GetRoster(false)
    local count = roster and #Pure.Merge(roster) or 0
    if boards.demo then count = #Pure.DemoRows(roster) end

    if not available then
        LT:Print("sharing is unavailable on this client (" .. tostring(detail)
            .. "); the boards still show what was already reported.")
    else
        LT:Print(string.format("ranks — sharing is %s (%s %s, %s %s, channel %s: %s)",
            sharing and "on" or "off",
            Leaderboard.PARTY_LABEL,
            self:IsServerSharing() and "on" or "off",
            Leaderboard.GUILD_LABEL,
            self:IsGuildSharing() and "on" or "off",
            tostring(boards.channel.name),
            boards.channel.joined and "joined" or "not joined"))
        if not sharing then
            LT:Print("nothing is sent or stored until sharing is turned on.")
        end
    end

    local lifetimeText = (own.lifetime ~= nil)
        and (Pure.Duration(own.lifetime) .. " played")
        or "played time unknown"
    LT:Print(string.format("Your row: %s · level %d · %s%s",
        tostring(own.name), own.level, lifetimeText,
        (own.at60 > 0) and (", level 60 at " .. Pure.Duration(own.at60)) or ""))

    if boards.mine.levelRank then
        LT:Print("Your level rank: " .. tostring(boards.mine.levelRank)
            .. " of " .. tostring(count + 1))
    end
    if boards.mine.recordRank then
        LT:Print("Your time-to-60 rank: " .. tostring(boards.mine.recordRank))
    end

    if #boards.level == 0 then
        LT:Print(boards.emptyLevel)
        if not available then
            LT:Print("This client cannot receive shared rows, so nothing can arrive either.")
        elseif not sharing then
            LT:Print("/lt ranks on shares your row and lets theirs reach you.")
        elseif not self:InGroup() and not self:InGuild()
            and not boards.channel.joined then
            LT:Print("Join a party, a guild or the shared channel first; there is nowhere to send.")
        else
            LT:Print("Nobody has shared a row yet; each player sends one on a level-up or when they open the ranks page.")
        end
        return
    end

    LT:Print(string.format("Level rows — Party board + Guild board (top %d of %d rows):",
        #boards.level, math.max(count, #boards.level)))
    for index, row in ipairs(boards.level) do
        local label = row.you and "You" or identityLabel(row, own.realm)
        LT:Print(string.format("%2d. %s · level %d · %s played",
            index, label, row.level, Pure.Duration(row.lifetime)))
    end

    if #boards.records > 0 then
        LT:Print("Time to 60 (fastest " .. tostring(#boards.records) .. "):")
        for index, row in ipairs(boards.records) do
            local label = row.you and "You" or identityLabel(row, own.realm)
            LT:Print(string.format("%2d. %s · %s",
                index, label, Pure.Duration(row.at60)))
        end
    else
        LT:Print(boards.emptyRecords)
    end

    if boards.demo then
        LT:Print("This is the demo board: made-up rows only, never sent and never mixed into the stored boards. /lt ranks demo off clears it.")
    else
        LT:Print("Every row above was reported by another player or is your own, unverified. Friends are a filter, not a separate board.")
    end
end

------------------------------------------------------------------------------
-- Export
--
-- A WoW addon cannot write a text file. Saved variables are the only file the
-- client produces, and they are written on logout / reload, so the export is
-- also kept at LunchboxToolkitDB.ranksExport. Nothing else reads that key.
-- The rows are the ones this client already holds: the Party board and the
-- Guild board, never the made-up demo rows and never a row the client marks
-- secret.
------------------------------------------------------------------------------

local EXPORT_FIELDS = {
    "name", "realm", "class", "race", "faction",
    "level", "lifetime", "at60", "deaths", "board",
}

local function exportRowHasSecret(row)
    if type(row) ~= "table" then return true end
    for _, field in ipairs(EXPORT_FIELDS) do
        if isSecret(row[field]) then return true end
    end
    return false
end

local function exportText(value)
    if value == nil then return "" end
    return tostring(value)
end

local function exportTime(epoch)
    if type(date) == "function" then
        local ok, text = pcall(date, "%Y-%m-%d %H:%M:%S", epoch)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return "epoch " .. tostring(epoch)
end

-- The board as the player knows it, not the saved-variable key.
local function exportBoard(row)
    if row.board == Leaderboard.GUILD_BOARD then
        return Leaderboard.GUILD_LABEL or "Guild board"
    end
    return Leaderboard.PARTY_LABEL or "Party board"
end

-- A plain-text table of the rows currently held: one tab-separated line per
-- row, headed by the board names, this realm and the export time. The second
-- return is the epoch the header was written with, so a caller can store the
-- same moment. Nothing is created, sent or written here.
function Leaderboard:ExportText()
    local when = self:Epoch()
    local realm = self:OwnIdentity().realm
    local rows = Pure.Merge(self:GetRoster(false))

    local cap = math.floor(asNumber(self.EXPORT_ROW_CAP, 200) or 200)
    if cap < 0 then cap = 0 end

    local lines = {
        "Lunchbox Toolkit ranks export — Party board and Guild board"
            .. " — realm " .. exportText(realm)
            .. " — exported " .. exportTime(when)
            .. " — columns: name, realm, class, race, faction, level,"
            .. " lifetime_s, at60_s, deaths, board",
    }

    local emitted, skipped, truncated = 0, 0, 0
    for _, row in ipairs(rows) do
        if exportRowHasSecret(row) then
            skipped = skipped + 1
        elseif emitted < cap then
            lines[#lines + 1] = table.concat({
                exportText(row.name),
                exportText(row.realm),
                exportText(row.class),
                exportText(row.race),
                exportText(row.faction),
                exportText(row.level),
                exportText(row.lifetime),
                exportText(row.at60),
                exportText(row.deaths),
                exportBoard(row),
            }, "\t")
            emitted = emitted + 1
        else
            truncated = truncated + 1
        end
    end

    if emitted == 0 then
        lines[#lines + 1] = "# no rows are held"
    end
    if truncated > 0 then
        lines[#lines + 1] = "# truncated: " .. tostring(truncated)
            .. " more row(s) not exported (cap " .. tostring(cap) .. ")"
    end
    if skipped > 0 then
        lines[#lines + 1] = "# skipped: " .. tostring(skipped)
            .. " row(s) with a field this client reports as secret"
    end

    return lines, when
end

-- Splits on byte count without cutting a UTF-8 character in half: `stop` is
-- walked back while the byte after it is a continuation byte (10xxxxxx).
local function utf8Chunks(text, limit)
    local chunks = {}
    local length = #text
    local size = math.floor(asNumber(limit, 250) or 250)
    if size < 1 then size = 1 end

    local start = 1
    while start <= length do
        local stop = math.min(start + size - 1, length)
        while stop > start do
            local after = text:byte(stop + 1)
            if not after or after < 0x80 or after > 0xBF then break end
            stop = stop - 1
        end

        -- A single character wider than the whole chunk is kept whole rather
        -- than split; this only matters for pathological input.
        if stop == start and stop < length then
            local after = text:byte(stop + 1)
            if after and after >= 0x80 and after <= 0xBF then
                while stop < length do
                    local byte = text:byte(stop + 1)
                    if not byte or byte < 0x80 or byte > 0xBF then break end
                    stop = stop + 1
                end
            end
        end

        chunks[#chunks + 1] = text:sub(start, stop)
        start = stop + 1
    end
    return chunks
end

local function inCombat()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

-- Prints the export between [begin] and [end] markers and stores the same
-- lines in the account record. Printing is safe in combat, but writing saved
-- variables from a combat-tainted command is refused by policy here, exactly
-- as the task states: nothing is exported until combat ends.
function Leaderboard:Export()
    if inCombat() then
        return false, "refused in combat; try /lt ranks export again out of combat"
    end

    local lines, when = self:ExportText()
    LunchboxToolkitDB = LunchboxToolkitDB or {}
    LunchboxToolkitDB.ranksExport = {
        when = asNumber(when, 0) or 0,
        lines = lines,
    }

    local text = table.concat(lines, "\n")
    LT:Print("[begin] ranks export — " .. tostring(#lines) .. " lines, "
        .. tostring(#text) .. " bytes")
    for _, chunk in ipairs(utf8Chunks(text, self.EXPORT_CHUNK)) do
        LT:Print(chunk)
    end
    LT:Print("[end] ranks export — stored in LunchboxToolkitDB.ranksExport, survives /reload")
    return true
end

------------------------------------------------------------------------------
-- Slash command
--
-- Registered through Slash.lua, which may load after this file; the call is
-- repeated at login and after ADDON_LOADED and succeeds once. Opening the
-- command is one of the two moments a row may be sent.
------------------------------------------------------------------------------

local HELP = "/lt ranks [on|off] [server|guild on|off] [friends on|off] [demo on|off] [channel <name>|leave] [export] — Guild board and Party board from party/guild chat (off by default; the \"server\" key is the Party board)"

function Leaderboard:RegisterSlash()
    if self.slashRegistered then return true end

    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then
        return false
    end

    local ok, result = pcall(slash.RegisterCommand, slash, "ranks",
        function(words) Leaderboard:Command(words) end, HELP)

    if ok and result == true then
        self.slashRegistered = true
        return true
    end

    -- Only a true return is a registration. A false return from the registry
    -- means the word was already taken, which is reported rather than hidden;
    -- a thrown error is reported as well.
    if ok then
        LT:Debug("ranks: /lt ranks was not registered; the command word is already taken")
    else
        LT:Debug("ranks: /lt ranks registration failed (" .. tostring(result) .. ")")
    end
    return false
end

function Leaderboard:Open()
    -- A file loaded before the core frame existed would otherwise never
    -- receive; one retry here costs nothing.
    self:Attach()

    -- The share attempt is silent: throttled, ungrouped and switched-off are
    -- all normal, and the report's status line already says which state the
    -- player is in.
    self:PageOpened()
    self:Report()
end

local function readOnOff(word)
    if type(word) ~= "string" then return nil end
    local lower = string.lower(word)
    if lower == "on" then return true end
    if lower == "off" then return false end
    return nil
end

function Leaderboard:Command(words)
    local action = words and words[2]
    if type(action) == "string" then action = string.lower(action) end
    local rawValue = words and words[3]
    local value = readOnOff(rawValue)

    if action == "on" or action == "off" then
        local ok, reason = self:SetSharing(action == "on")
        if not ok then
            LT:Warn(reason or "the sharing setting could not be written")
            return
        end

        if action == "on" then
            local available, detail = self:IsShareAvailable()
            if not available then
                LT:Warn("sharing is unavailable on this client (" .. tostring(detail)
                    .. "); the setting is stored but nothing can be sent.")
            end
            self:Open()
            return
        end

        self:Report()
        return
    end

    if action == "demo" then
        if value == nil then
            LT:Print("/lt ranks demo on | off — made-up boards, never sent")
            return
        end

        local ok, detail = self:SetDemo(value)
        if not ok then
            LT:Warn(detail or "the demo board could not be written")
            return
        end

        if value then
            LT:Print("ranks: demo board on — " .. tostring(detail)
                .. " made-up rows; nothing is sent and no stored row changes.")
        else
            LT:Print("ranks: demo board off and cleared.")
        end
        self:Report()
        return
    end

    if action == "server" or action == "guild" or action == "friends" then
        -- The command words are the option keys and stay as they are; only the
        -- label printed back uses the board's real name.
        local labels = {
            server = Leaderboard.PARTY_LABEL,
            guild = Leaderboard.GUILD_LABEL,
        }
        if value == nil then
            LT:Print("/lt ranks " .. action .. " on | off"
                .. (labels[action] and (" — " .. labels[action]) or ""))
            return
        end

        local setters = {
            server = "SetServerSharing",
            guild = "SetGuildSharing",
            friends = "SetFriendFilter",
        }
        local ok, reason = self[setters[action]](self, value)
        if not ok then
            LT:Warn(reason or "the setting could not be written")
            return
        end

        LT:Print("ranks: " .. (labels[action] or action) .. " sharing is "
            .. (value and "on" or "off") .. ".")
        self:Report()
        return
    end

    if action == "export" then
        local ok, reason = self:Export()
        if not ok then
            LT:Warn("ranks: export " .. tostring(reason) .. ".")
        end
        return
    end

    if action == "channel" then
        if type(rawValue) ~= "string" or rawValue == "" then
            LT:Print("/lt ranks channel <name> — join the shared channel named <name>.")
            return
        end

        local ok, message = self:JoinChannel(rawValue)
        if ok then
            LT:Print("ranks: " .. tostring(message) .. ".")
        else
            LT:Warn("ranks: " .. tostring(message) .. ".")
        end
        self:Report()
        return
    end

    if action == "leave" then
        local ok, message = self:LeaveChannel()
        if ok then
            LT:Print("ranks: " .. tostring(message) .. ".")
        else
            LT:Warn("ranks: " .. tostring(message) .. ".")
        end
        self:Report()
        return
    end

    if action and action ~= "" then
        LT:Print(HELP)
        return
    end

    self:Open()
end

------------------------------------------------------------------------------
-- Level-up
--
-- The second and last reason to send. The core fires this after its refresh,
-- so the new level is already the one being reported.
------------------------------------------------------------------------------

function Leaderboard:OnLevelUp()
    if not self:IsSharing() then return end
    self:Share("level-up")
end

------------------------------------------------------------------------------
-- Wiring
--
-- No frame is created. The core's frame already exists and is registered for
-- ADDON_LOADED and PLAYER_LOGIN; CHAT_MSG_ADDON is added to it and a hook
-- reads the event. HookScript appends, so the core's handler keeps running
-- first, and nothing here can be tainted by combat.
------------------------------------------------------------------------------

function Leaderboard:Attach()
    if self.attached then return true end

    local frame = LT.frame
    if frame == nil then return false end
    if type(frame.RegisterEvent) ~= "function" or type(frame.HookScript) ~= "function" then
        return false
    end

    local registered = pcall(frame.RegisterEvent, frame, "CHAT_MSG_ADDON")
    if not registered then return false end

    local hooked = pcall(frame.HookScript, frame, "OnEvent",
        function(_, event, ...)
            if event == "CHAT_MSG_ADDON" then
                local prefix, text, channel, sender = ...
                Leaderboard:HandleMessage(prefix, text, channel, sender)
                return
            end

            if event == "ADDON_LOADED" then
                local loaded = ...
                if loaded == LT.name then Leaderboard:RegisterSlash() end
                return
            end

            if event == "PLAYER_LOGIN" then
                Leaderboard:RegisterSlash()
                Leaderboard:RegisterPrefix()
            end
        end)

    if not hooked then return false end

    self.attached = true
    return true
end

if type(LT.On) == "function" then
    pcall(LT.On, LT, "PLAYER_LEVEL_UP", function() Leaderboard:OnLevelUp() end, Leaderboard)
end

Leaderboard:Attach()
Leaderboard:RegisterSlash()
