--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Played
    How long this character has been played, per level, split into active and
    AFK time, with the sessions that produced it.

    Time is attributed at transitions, never accumulated frame by frame:

      * a bucket opens at login, on a level-up and on entering world;
      * a bucket (and the interval inside it) closes at the next transition —
        login, level-up, AFK on, AFK off, zone change, logout;
      * the closed interval is written as a delta into the bucket, the total
        and the current session, and the interval starts again from the
        transition time.

    Two clocks are kept on the open interval so one of them missing degrades
    honestly instead of stopping the ledger:

      * startedAt      — GetTime(), the client's monotonic clock. It starts at
                         zero again on every login, so it is only ever used to
                         measure an interval that lies inside one login.
      * startedAtEpoch — time(), the wall clock. It is the fallback when
                         GetTime() is missing, and the value the bucket's
                         startedAt/endedAt carry, because a bucket outlives one
                         session and needs an absolute date.

    A level bucket is { active, afk, startedAt, endedAt }: the first moment that
    level was played, the last moment it was played, and the active/AFK seconds
    in between. Every transition re-bases the open interval and moves endedAt;
    startedAt stays at the level's first second. The level is capped at the
    client's 60: level 60 and anything above it share the single "60" bucket,
    so "60" means "60 and every level after it" and is still one bucket.

    A bucket also carries deaths: PLAYER_DEAD adds one while the character is
    below the cap, into that level's bucket and into the total. A death at 60
    or above is not counted, so the total is deaths on the way to 60 and stops
    at the ding; DeathsUntil60() adds the buckets 1..59 for the board. Both
    fields are additive, so a record written before deaths existed reads as
    zero deaths without a schema bump.

    AFK is read from UnitIsAFK("player"), re-read when PLAYER_FLAGS_CHANGED
    says the player flags moved. It is never inferred from a lack of input: a
    player reading a guide is not AFK.

    /played reconciliation: RequestTimePlayed / TIME_PLAYED_MSG report the
    character's client-side total. When that total is larger than everything
    this file recorded, the difference is stored in played.untracked. It is
    never added to active: time this file did not witness is not active time.

    Lifetime and level 60: the client total captured at the last
    reconciliation is kept as played.clientBase together with the ledger's
    tracked total at the instant that answer arrived
    (played.clientBaseTracked). That tracked figure includes the interval that
    was still open when the answer arrived, so the request's own flight time is
    cancelled instead of added to the lifetime on every login: the client
    figure and the anchor are the same instant. LifetimeSeconds() is that base
    plus the time tracked since, so a late adopter is ranked by their whole
    /played total rather than by the few hours this ledger witnessed.
    Level60Seconds() freezes the lifetime at the ding that reached level 60 —
    only a level-up records the moment. Login, entering world and a zone change
    on a character that is already 60 record nothing, so the reading falls back
    to the current lifetime as documented instead of freezing at whatever was
    tracked by then. When the client total was not known at the ding the
    tracked snapshot is kept and resolved as soon as it arrives. Neither helper
    writes or asks the client for anything.

    The transition maths lives in Played.Pure, which takes an explicit
    (played, level, now, epoch) and touches no client API, so it runs in the
    Lua harness outside the game. Nothing here creates a frame or a string for
    the screen; Played:Report is chat text, and the values are readable through
    Played:GetPlayed.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local Played = {}
LT.Played = Played
LT.Modules = LT.Modules or {}
LT.Modules.Played = Played

Played.MAX_SESSIONS   = 20    -- kept in played.sessions; the count lives in total
Played.UNT_TOLERANCE  = 5     -- seconds of client/stored drift before a gap is recorded
Played.MAX_LEVEL      = tonumber(LT.MAX_LEVEL) or 60

------------------------------------------------------------------------------
-- Pure transitions
--
-- Every function below is deliberately free of client calls. The caller passes
-- the clocks in, which is what lets a test drive hours of play in milliseconds.
------------------------------------------------------------------------------

local Pure = {}
Played.Pure = Pure

local function asNumber(value, fallback)
    local number = tonumber(value)
    if not number or number ~= number then return fallback end
    return number
end

local function nonNegative(value)
    local number = asNumber(value, 0)
    if number < 0 then return 0 end
    return number
end

-- A stored number that may legitimately be absent: nil stays nil, because
-- "this client never answered" is not the same as zero seconds.
local function optionalNumber(value)
    if value == nil then return nil end
    local number = asNumber(value, nil)
    if not number or number < 0 then return nil end
    return number
end

-- Fills in anything a stored record is missing. Called on every read, so a
-- record migrated from schema 7 (which only gained an empty played table)
-- becomes usable without a second migration step.
function Pure.Normalize(played)
    if type(played) ~= "table" then return nil end

    played.levels = type(played.levels) == "table" and played.levels or {}
    played.sessions = type(played.sessions) == "table" and played.sessions or {}
    played.untracked = nonNegative(played.untracked)
    played.clientTotal = asNumber(played.clientTotal, nil)
    -- The client's /played total at the last reconciliation, and how much this
    -- ledger had tracked at that same moment. Nil base = no client answer yet.
    played.clientBase = optionalNumber(played.clientBase)
    played.clientBaseTracked = nonNegative(played.clientBaseTracked)
    -- The moment level 60 was reached: absolute client seconds once known, or
    -- the tracked snapshot kept until the client base arrives. Both nil until
    -- that level is reached, which is what makes "not yet 60" distinct.
    played.level60Seconds = optionalNumber(played.level60Seconds)
    played.level60Tracked = optionalNumber(played.level60Tracked)

    local total = type(played.total) == "table" and played.total or {}
    total.active = nonNegative(total.active)
    total.afk = nonNegative(total.afk)
    total.deaths = math.floor(nonNegative(total.deaths))
    total.sessions = math.floor(nonNegative(total.sessions))
    if type(total.firstSeen) ~= "number" then
        total.firstSeen = asNumber(total.firstSeen, nil)
    end
    played.total = total

    -- Deaths are additive: a bucket stored before the field existed reads as
    -- zero. Only that one field is written here; the time fields keep their
    -- existing behaviour of being repaired by ensureBucket on the next write.
    for _, bucket in pairs(played.levels) do
        if type(bucket) == "table" then
            bucket.deaths = math.floor(nonNegative(bucket.deaths))
        end
    end

    if played.open ~= nil and type(played.open) ~= "table" then played.open = nil end
    if played.session ~= nil and type(played.session) ~= "table" then played.session = nil end

    local cap = tonumber(Played.MAX_SESSIONS) or 20
    while #played.sessions > cap do
        table.remove(played.sessions)
    end

    return played
end

local function ensureBucket(played, level, epoch)
    local bucket = played.levels[level]
    if type(bucket) ~= "table" then
        bucket = { active = 0, afk = 0, deaths = 0, startedAt = epoch, endedAt = epoch }
        played.levels[level] = bucket
    end
    bucket.active = nonNegative(bucket.active)
    bucket.afk = nonNegative(bucket.afk)
    bucket.deaths = math.floor(nonNegative(bucket.deaths))
    if type(bucket.startedAt) ~= "number" then bucket.startedAt = epoch end
    return bucket
end

-- Seconds an open interval has lasted. The monotonic clock wins whenever both
-- it and the stored value are present; the wall clock is the fallback.
function Pure.Elapsed(open, now, epoch)
    if type(open) ~= "table" then return 0 end

    local elapsed
    if type(now) == "number" and type(open.startedAt) == "number" then
        elapsed = now - open.startedAt
    elseif type(epoch) == "number" and type(open.startedAtEpoch) == "number" then
        elapsed = epoch - open.startedAtEpoch
    end

    if not elapsed or elapsed ~= elapsed or elapsed < 0 then return 0 end
    return elapsed
end

-- Writes the interval that just ended into the bucket, the total and the
-- session, then re-bases the open interval on (now, epoch).
function Pure.Flush(played, now, epoch)
    local open = played.open
    if type(open) ~= "table" then return 0 end
    if type(played.levels) ~= "table" then played.levels = {} end
    if type(played.total) ~= "table" then
        played.total = { active = 0, afk = 0, sessions = 0 }
    end

    local elapsed = Pure.Elapsed(open, now, epoch)
    local channel = open.afk and "afk" or "active"

    local bucket = ensureBucket(played, open.level, epoch)
    bucket[channel] = bucket[channel] + elapsed
    if type(epoch) == "number" then bucket.endedAt = epoch end

    played.total[channel] = nonNegative(played.total[channel]) + elapsed
    if type(played.session) == "table" then
        played.session[channel] = nonNegative(played.session[channel]) + elapsed
    end

    if type(now) == "number" then
        open.startedAt = now
    else
        open.startedAt = nil   -- never mix a stale monotonic value with a wall delta
    end
    if type(epoch) == "number" then open.startedAtEpoch = epoch end

    return elapsed
end

-- Opens (or re-opens) the bucket for a level. Called at login, on a level-up
-- and on entering world; a previous interval, if any, is written first.
function Pure.Begin(played, level, now, epoch, afk)
    if type(played) ~= "table" then return nil end
    Pure.Normalize(played)

    level = math.floor(asNumber(level, 1))
    if level < 1 then level = 1 end
    local cap = tonumber(Played.MAX_LEVEL) or 60
    if level > cap then level = cap end

    if played.open then
        Pure.Flush(played, now, epoch)
    end

    local bucket = ensureBucket(played, level, epoch)
    if type(bucket.startedAt) ~= "number" then bucket.startedAt = epoch end

    played.open = {
        level = level,
        startedAt = type(now) == "number" and now or nil,
        startedAtEpoch = type(epoch) == "number" and epoch or nil,
        afk = afk == true,
    }

    if type(played.session) ~= "table" then
        played.session = {
            start = epoch,
            active = 0,
            afk = 0,
            startLevel = level,
        }
    elseif type(played.session.startLevel) ~= "number" then
        played.session.startLevel = level
    end

    if type(played.total.firstSeen) ~= "number" and type(epoch) == "number" then
        played.total.firstSeen = epoch
    end

    return played
end

-- AFK on/off is a transition like any other: the interval that just ended is
-- attributed to the state it was lived in, then the flag flips.
function Pure.SetAfk(played, afk, now, epoch)
    if type(played) ~= "table" then return false end
    Pure.Normalize(played)
    if type(played.open) ~= "table" then return false end

    local wanted = afk == true
    if (played.open.afk == true) == wanted then return false end

    Pure.Flush(played, now, epoch)
    played.open.afk = wanted
    return true
end

-- One death at a level below the cap: into that level's bucket and into the
-- total. At or above the cap it is not a death on the way to 60, so nothing is
-- recorded and a level-60 row's frozen total cannot grow afterwards. Neither
-- clock is needed: a death does not open or close an interval.
function Pure.Death(played, level)
    if type(played) ~= "table" then return false end
    Pure.Normalize(played)

    local number = math.floor(asNumber(level, 0))
    local cap = tonumber(Played.MAX_LEVEL) or 60
    if number < 1 or number >= cap then return false end

    local bucket = ensureBucket(played, number, nil)
    bucket.deaths = math.floor(nonNegative(bucket.deaths)) + 1
    played.total.deaths = math.floor(nonNegative(played.total.deaths)) + 1
    return true
end

-- Logout: closes the bucket and turns the current session into a stored one.
function Pure.End(played, now, epoch)
    if type(played) ~= "table" then return false end
    Pure.Normalize(played)
    if type(played.open) ~= "table" then return false end

    Pure.Flush(played, now, epoch)

    local open = played.open
    local bucket = played.levels[open.level]
    if type(bucket) == "table" and type(epoch) == "number" then
        bucket.endedAt = epoch
    end

    local session = played.session
    if type(session) == "table" then
        session.stop = epoch
        session.endLevel = open.level
        table.insert(played.sessions, 1, session)

        local cap = tonumber(Played.MAX_SESSIONS) or 20
        while #played.sessions > cap do
            table.remove(played.sessions)
        end

        played.total.sessions = nonNegative(played.total.sessions) + 1
    end

    played.open = nil
    played.session = nil
    return true
end

-- A record that still holds an open interval at login belongs to a process
-- that never reached logout (a crash, or the game being killed). Its elapsed
-- time is unknown and must not be counted as active. The interval is dropped;
-- the client-total reconciliation is what accounts for the gap.
function Pure.Abandon(played)
    if type(played) ~= "table" then return nil end
    Pure.Normalize(played)

    local open = played.open
    played.open = nil
    played.session = nil
    return open
end

-- The stored level-60 marks that actually carry a moment: the absolute client
-- seconds, or the tracked snapshot still waiting for a client base. A mark of
-- zero is not one of them — reaching 60 takes play, so a stored zero can only
-- be an empty write or the pre-fix mark taken at login, and treating it as a
-- real moment would freeze Level60Seconds() at zero forever. The stored keys
-- are left alone; this only decides what may be read.
local function level60Marks(played)
    local absolute = played.level60Seconds
    if type(absolute) == "number" and absolute > 0 then return absolute, nil end

    local tracked = played.level60Tracked
    if type(tracked) == "number" and tracked > 0 then return nil, tracked end

    return nil, nil
end

-- Puts the difference between the client's /played total and everything stored
-- into played.untracked. Monotonic: the estimate never shrinks, so a tolerance
-- band cannot make the number flicker between logins.
--
-- trackedNow is the ledger's tracked total including the interval that is
-- still open at the moment the answer arrives. The client measured its total
-- at that same moment, so the anchor must include the request's own flight
-- time; anchoring to the closed total instead leaves that slice uncancelled
-- and adds it to the lifetime on every login. Without a snapshot the closed
-- total is the best available reading.
function Pure.Reconcile(played, clientTotal, tolerance, trackedNow)
    if type(played) ~= "table" then return false end
    Pure.Normalize(played)

    local client = asNumber(clientTotal, nil)
    if not client or client < 0 then return false end

    played.clientTotal = client

    local tracked = asNumber(trackedNow, nil)
    if not tracked or tracked < 0 then tracked = Pure.Tracked(played) end

    -- The base is the anchor every later lifetime reading extends: the client's
    -- own total and what this ledger had tracked at the same instant. It is
    -- refreshed on every answer, so a session lost while the addon was off is
    -- corrected at the next login instead of being counted twice.
    played.clientBase = client
    played.clientBaseTracked = tracked

    -- A level-60 moment recorded before the first client answer was kept as a
    -- tracked snapshot; the base now explains it in client seconds. The delta
    -- may be negative when the base was taken after that moment, and
    -- subtracting it is exactly right: the base already includes that stretch.
    local absolute, snapshot = level60Marks(played)
    if snapshot and not absolute then
        local value = client + (snapshot - tracked)
        if value < 0 then value = 0 end
        played.level60Seconds = math.floor(value)
        played.level60Tracked = nil
    end

    local expected = client - tracked
    if expected < 0 then expected = 0 end

    local band = nonNegative(tolerance)
    if expected > nonNegative(played.untracked) + band then
        played.untracked = expected
        return true
    end

    return false
end

-- Levels with a bucket, ascending. Report and tests both read this instead of
-- walking pairs(), so the display order is one decision.
function Pure.LevelList(played)
    local levels = {}
    if type(played) ~= "table" or type(played.levels) ~= "table" then return levels end

    for level in pairs(played.levels) do
        local number = tonumber(level)
        if number then levels[#levels + 1] = number end
    end

    table.sort(levels)
    return levels
end

-- Deaths on the way to 60: the sum of the buckets 1..59. The level-60 bucket
-- is deliberately excluded, because it means "60 and every level after it"
-- and those deaths did not happen during the climb.
function Pure.DeathsUntil60(played)
    if type(played) ~= "table" then return 0 end
    Pure.Normalize(played)

    local total = 0
    local cap = tonumber(Played.MAX_LEVEL) or 60
    local last = math.min(59, cap - 1)
    for level = 1, last do
        local bucket = played.levels[level]
        if type(bucket) == "table" then
            total = total + math.floor(nonNegative(bucket.deaths))
        end
    end
    return total
end

-- Active plus AFK, in seconds: what the client total is compared against.
function Pure.Tracked(played)
    if type(played) ~= "table" then return 0 end
    Pure.Normalize(played)
    return nonNegative(played.total.active) + nonNegative(played.total.afk)
end

-- Active (non-AFK) seconds at one level, including the open interval when it
-- belongs to that level and is not AFK. openElapsed is the caller's reading of
-- the open interval, so this stays pure.
function Pure.ActiveAt(played, level, openElapsed)
    if type(played) ~= "table" then return 0 end
    Pure.Normalize(played)

    local bucket = played.levels[level]
    local active = type(bucket) == "table" and nonNegative(bucket.active) or 0
    local open = played.open
    if type(open) == "table" and asNumber(open.level, nil) == level and open.afk ~= true then
        active = active + nonNegative(openElapsed)
    end
    return active
end

-- XP a level's bucket recorded, when this ledger stores one. nil means the
-- figure was never stored, which is not the same as "no XP was gained".
function Pure.GainedXP(played, level)
    if type(played) ~= "table" then return nil end
    Pure.Normalize(played)

    local bucket = played.levels[level]
    if type(bucket) ~= "table" then return nil end
    return optionalNumber(bucket.xp)
end

-- Turns a tracked snapshot into client seconds: the base the client reported
-- plus the time tracked since that base was taken. The delta may be negative
-- for a snapshot older than the base, and subtracting it is right there — the
-- base already includes that stretch.
local function fromTracked(played, tracked)
    local value = nonNegative(tracked)
    local base = played.clientBase
    if type(base) == "number" then
        value = base + (value - nonNegative(played.clientBaseTracked))
        if value < 0 then value = 0 end
    end
    return math.floor(value)
end
Pure.FromTracked = fromTracked

-- Lifetime in client seconds. With a base: the client total captured at the
-- last reconciliation plus everything tracked since (the caller passes the
-- open interval in trackedNow). Without one: this ledger's own total, which is
-- all a client that never answered /played can offer.
function Pure.Lifetime(played, trackedNow)
    if type(played) ~= "table" then return 0 end
    Pure.Normalize(played)

    local tracked = asNumber(trackedNow, nil)
    if not tracked then tracked = Pure.Tracked(played) end
    if tracked < 0 then tracked = 0 end
    return fromTracked(played, tracked)
end

-- Records the moment level 60 is reached, once and only once. With a base the
-- absolute lifetime is written immediately; without one the tracked snapshot
-- is kept and resolved when the client answers. Returns true only when this
-- call recorded the moment. A snapshot of zero tracks nothing yet, so it is
-- not recorded: a stored zero would answer "reached 60 at 0s" forever, while
-- leaving the mark absent lets Level60Seconds() fall back to the lifetime.
function Pure.MarkLevel60(played, trackedNow)
    if type(played) ~= "table" then return false end
    Pure.Normalize(played)

    local absolute, snapshot = level60Marks(played)
    if absolute or snapshot then return false end

    local tracked = asNumber(trackedNow, nil)
    if not tracked then tracked = Pure.Tracked(played) end
    if tracked < 0 then tracked = 0 end

    if type(played.clientBase) == "number" then
        local value = Pure.Lifetime(played, tracked)
        if value <= 0 then return false end
        played.level60Seconds = value
    else
        if tracked <= 0 then return false end
        played.level60Tracked = math.floor(tracked)
    end
    return true
end

-- The client total at the moment level 60 was reached. Falls back to the
-- current lifetime when no such moment was recorded, which is what a character
-- that was already 60 before this record existed has to show.
function Pure.Level60(played, trackedNow)
    if type(played) ~= "table" then return 0 end
    Pure.Normalize(played)

    local absolute, snapshot = level60Marks(played)
    if absolute then
        return math.floor(absolute)
    end
    if snapshot then
        local value = fromTracked(played, snapshot)
        if value > 0 then return value end
    end
    return Pure.Lifetime(played, trackedNow)
end

------------------------------------------------------------------------------
-- Live module: clocks, AFK flag and record access
------------------------------------------------------------------------------

local function isSecret(value)
    if type(LT.IsSecret) ~= "function" then return false end
    local ok, result = pcall(LT.IsSecret, LT, value)
    return ok and result == true
end

-- Both clocks, each read on its own so one missing value does not lose the
-- other. A secret value is never passed to tonumber().
function Played:ReadClock()
    local now, epoch

    if type(GetTime) == "function" then
        local ok, value = pcall(GetTime)
        if ok and value ~= nil and not isSecret(value) then
            now = tonumber(value)
        end
    end

    if type(time) == "function" then
        local ok, value = pcall(time)
        if ok and value ~= nil and not isSecret(value) then
            epoch = tonumber(value)
        end
    end

    return now, epoch
end

-- AFK is the client's answer or nothing. A missing API or a failed call reads
-- as "not flagged AFK", which is the state the player is in when no flag is
-- set; nothing here infers idleness from inactivity.
function Played:ReadAfk()
    if type(UnitIsAFK) ~= "function" then return false end

    local ok, value = pcall(UnitIsAFK, "player")
    if not ok or value == nil or isSecret(value) then return false end
    return value == true
end

-- The level a death happened at. UnitLevel is the client's answer; the cached
-- player level is the fallback for a client that does not expose it. A secret
-- answer never reaches tonumber().
local function currentLevel()
    if type(UnitLevel) == "function" then
        local ok, value = pcall(UnitLevel, "player")
        if ok and value ~= nil and not isSecret(value) then
            local number = tonumber(value)
            if number then return number end
        end
    end
    if type(LT.player) == "table" then
        return tonumber(LT.player.level)
    end
    return nil
end

function Played:BucketLevel(level)
    local bucketLevel = math.floor(asNumber(level, 1))
    if bucketLevel < 1 then bucketLevel = 1 end
    local cap = tonumber(self.MAX_LEVEL) or 60
    if bucketLevel > cap then bucketLevel = cap end
    return bucketLevel
end

-- The live record. create=false is for reading paths that must not write into
-- a character record that does not exist yet.
function Played:GetPlayed(create)
    local database = LT.Database
    if type(database) ~= "table" or type(database.Get) ~= "function" then return nil end

    local character = database:Get()
    if type(character) ~= "table" then return nil end

    if type(character.played) ~= "table" then
        if not create then return nil end
        character.played = {}
    end

    return Pure.Normalize(character.played)
end

------------------------------------------------------------------------------
-- Read-only readings
--
-- Nothing below writes a preference, opens a request or creates a record: they
-- answer from what the ledger already holds, so a tooltip, a board or a report
-- can ask at any time without a side effect.
------------------------------------------------------------------------------

-- Everything this ledger has tracked, including the interval that is still
-- open. That is the figure the buckets would hold once the next transition
-- runs, so a reading taken between transitions is not short by the session.
function Played:TrackedNow()
    local played = self:GetPlayed(false)
    if not played then return 0 end

    local tracked = Pure.Tracked(played)
    local open = played.open
    if type(open) == "table" then
        local now, epoch = self:ReadClock()
        local ok, elapsed = pcall(Pure.Elapsed, open, now, epoch)
        if ok and type(elapsed) == "number" and elapsed > 0 then
            tracked = tracked + elapsed
        end
    end
    return math.floor(tracked)
end

-- The client's own /played total at the last reconciliation, or nil when this
-- client never answered. Nil is not zero: it means unknown.
function Played:ClientBaseSeconds()
    local played = self:GetPlayed(false)
    if not played then return nil end
    if type(played.clientBase) ~= "number" then return nil end
    return played.clientBase
end

-- Lifetime in client seconds: the base captured at login plus time tracked
-- since. A late adopter therefore reports their real /played total, not just
-- the hours this ledger has seen.
function Played:LifetimeSeconds()
    local played = self:GetPlayed(false)
    if not played then return 0 end
    return Pure.Lifetime(played, self:TrackedNow())
end

-- The client total at the moment level 60 was reached, recorded once and
-- frozen. Falls back to the lifetime when this record never saw that moment.
function Played:Level60Seconds()
    local played = self:GetPlayed(false)
    if not played then return 0 end
    return Pure.Level60(played, self:TrackedNow())
end

-- Deaths before the cap, summed from the stored buckets. Nil when there is no
-- record at all: an absent ledger is not a character that never died.
function Played:DeathsUntil60()
    local played = self:GetPlayed(false)
    if not played then return nil end
    return Pure.DeathsUntil60(played)
end

------------------------------------------------------------------------------
-- Transitions
------------------------------------------------------------------------------

-- A transition writes the interval that ended and opens the next one.
-- reason is the log label, the gate that lets only a ding record level 60, and
-- the trigger for the once-per-login client-total request.
function Played:Transition(reason, level)
    local played = self:GetPlayed(true)
    if not played then return nil end

    local now, epoch = self:ReadClock()
    if now == nil and epoch == nil then return nil end

    local wanted = level
    if wanted == nil then
        wanted = LT.player and LT.player.level
    end

    Pure.Begin(played, self:BucketLevel(wanted), now, epoch, self:ReadAfk())
    LT:Debug("played: bucket at level " .. tostring(played.open.level)
        .. " (" .. tostring(reason or "transition") .. ")")

    -- The instant the cap is reached is the only honest time-to-60, and only a
    -- ding is that instant. Login, entering world and a zone change re-open
    -- the bucket of a character that may already be 60: marking there would
    -- freeze the reading at whatever had been tracked by then — zero on the
    -- first login — instead of leaving the documented lifetime fallback to
    -- answer. Begin has just written the interval that ended into the bucket,
    -- so nothing tracked is left open and the figure cannot double count.
    if reason == "level" and played.open.level >= (tonumber(self.MAX_LEVEL) or 60) then
        Pure.MarkLevel60(played, Pure.Tracked(played))
    end

    if reason == "world" and not self.reconciled then
        self:RequestClientTotal()
    end

    return played
end

function Played:OnLogin()
    -- Two callers can announce the same login: the OnPlayerLogin module stage
    -- (Played is in LT.ModuleOrder) and the hooked PLAYER_LOGIN. A second run
    -- would abandon the interval the first one just opened and count the
    -- session twice, so the first caller wins and the rest are no-ops.
    if self.loginHandled then return end

    local played = self:GetPlayed(true)
    if not played then return end

    local now, epoch = self:ReadClock()
    if now == nil and epoch == nil then return end

    -- A leftover interval means the previous process never reached logout.
    -- Its time cannot be attributed honestly, so it is dropped; the client
    -- total reconciliation accounts for the gap.
    if played.open then
        local stale = Pure.Abandon(played)
        LT:Debug("played: discarded an unclosed interval for level "
            .. tostring(stale and stale.level or "?"))
    end

    self.loginHandled = true
    self.reconciled = false
    self:Transition("login", LT.player and LT.player.level)
    self:RequestClientTotal()
end

-- The client's own /played total. Requested once per login: `reconciled` is
-- raised when the request is sent, not when the reply arrives, so the world
-- transition cannot send a second one. A client without the API simply has no
-- reconciliation and says so through the absence of the client figure in the
-- report.
function Played:RequestClientTotal()
    if self.reconciled then return false end
    if type(RequestTimePlayed) ~= "function" then return false end

    local ok = pcall(RequestTimePlayed)
    if ok then self.reconciled = true end
    return ok
end

-- TIME_PLAYED_MSG's second figure (time at the current level) is deliberately
-- ignored: only the character total can be compared with what this file
-- stored, and the per-level split is this file's own.
function Played:OnTimePlayed(totalTime)
    -- A restricted value must not even reach tonumber(); skip the whole reply.
    if isSecret(totalTime) then return end

    local played = self:GetPlayed(true)
    if not played then return end

    -- The client measured its total at the instant this answer arrives, and by
    -- then the open interval already covers the request's own flight time.
    -- Anchor the base to that same instant: a closed-total anchor would leave
    -- the latency uncancelled, and every login would grow the lifetime by it.
    local changed = Pure.Reconcile(played, totalTime, self.UNT_TOLERANCE,
        self:TrackedNow())
    self.reconciled = true

    if changed then
        LT:Debug("played: client total is larger than stored; untracked is now "
            .. tostring(math.floor(played.untracked)) .. "s")
    end
end

-- PLAYER_DEAD is the only source of a death. It is ignored when there is no
-- record to write into and at or above the cap, and never creates a record:
-- a death before the ledger ever opened is not this ledger's to count.
function Played:OnDeath()
    local played = self:GetPlayed(false)
    if not played then return false end

    local level = currentLevel()
    if not level then return false end

    local ok, recorded = pcall(Pure.Death, played, level)
    if ok and recorded then
        LT:Debug("played: death recorded at level " .. tostring(math.floor(level)))
        return true
    end
    return false
end

function Played:SyncAfk()
    local played = self:GetPlayed(true)
    if not played or type(played.open) ~= "table" then return end

    local afk = self:ReadAfk()
    if (played.open.afk == true) == afk then return end

    local now, epoch = self:ReadClock()
    if now == nil and epoch == nil then return end

    if Pure.SetAfk(played, afk, now, epoch) then
        LT:Debug("played: now " .. (afk and "AFK" or "active"))
    end
end

function Played:OnLogout()
    -- The next login is a new session and is handled again from scratch.
    self.loginHandled = false

    local played = self:GetPlayed(false)
    if not played or type(played.open) ~= "table" then return end

    local now, epoch = self:ReadClock()
    if now == nil and epoch == nil then return end

    -- Leaving the interval open is the safer failure: the next login abandons
    -- it instead of writing a made-up delta.
    if epoch == nil then return end

    Pure.End(played, now, epoch)
    LT:Debug("played: session closed")
end

function Played:HandleEvent(event, arg1)
    if event == "PLAYER_LOGIN" then
        self:OnLogin()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        self:Transition("world")
        return
    end

    if event == "PLAYER_LEVEL_UP" then
        self:Transition("level", tonumber(arg1))
        return
    end

    if event == "PLAYER_DEAD" then
        self:OnDeath()
        return
    end

    if event == "PLAYER_FLAGS_CHANGED" then
        if arg1 == "player" or arg1 == nil then
            self:SyncAfk()
        end
        return
    end

    if event == "ZONE_CHANGED_NEW_AREA" then
        self:Transition("zone")
        return
    end

    if event == "TIME_PLAYED_MSG" then
        self:OnTimePlayed(arg1)
        return
    end

    if event == "PLAYER_LOGOUT" then
        self:OnLogout()
    end
end

-- Hooks the core's event frame rather than creating a second one: the frame
-- already exists and is registered for login, world and level events, and
-- HookScript never creates a widget, so this is safe at any time. A separate
-- frame is only made when the core frame is unusable, and never in combat.
local ownFrame

local function bindFrame()
    local frame = LT.frame
    if (type(frame) == "table" or type(frame) == "userdata")
        and type(frame.RegisterEvent) == "function"
        and type(frame.HookScript) == "function" then
        return frame
    end

    if ownFrame then return ownFrame end
    if type(CreateFrame) ~= "function" then return nil end

    if type(InCombatLockdown) == "function" then
        local ok, inCombat = pcall(InCombatLockdown)
        if ok and inCombat then return nil end
    end

    local ok, created = pcall(CreateFrame, "Frame")
    if ok and created then
        ownFrame = created
        return created
    end

    return nil
end

local WATCHED = {
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "PLAYER_LEVEL_UP",
    "PLAYER_DEAD",
    "PLAYER_FLAGS_CHANGED",
    "ZONE_CHANGED_NEW_AREA",
    "TIME_PLAYED_MSG",
    "PLAYER_LOGOUT",
}

function Played:Attach()
    if self.attached then return true end

    local frame = bindFrame()
    if not frame then
        LT:Debug("played: no event frame available; play time is not tracked.")
        return false
    end

    for _, event in ipairs(WATCHED) do
        pcall(frame.RegisterEvent, frame, event)
    end

    local ok = pcall(frame.HookScript, frame, "OnEvent",
        function(_, event, arg1)
            Played:HandleEvent(event, arg1)
        end)

    if not ok then
        LT:Debug("played: the event frame could not be hooked.")
        return false
    end

    self.frame = frame
    self.attached = true
    return true
end

------------------------------------------------------------------------------
-- Report
------------------------------------------------------------------------------

local function duration(seconds)
    local total = math.floor(nonNegative(seconds))
    local hours = math.floor(total / 3600)
    local minutes = math.floor((total % 3600) / 60)

    if hours > 0 then
        return string.format("%dh %02dm", hours, minutes)
    end
    if minutes > 0 then
        return string.format("%dm %02ds", minutes, total % 60)
    end
    return string.format("%ds", total)
end
Played.FormatDuration = duration

-- One short levelling-pace line for a character below 60: active time at the
-- current level, the average over the three levels before it, and XP/hour over
-- those levels only when every one of them stored an XP figure. Nothing is
-- invented: with no ledger, or no recorded time, the answer is nil.
function Played:LevelPace()
    local played = self:GetPlayed(false)
    if not played then return nil end

    local levels = Pure.LevelList(played)
    if #levels == 0 then return nil end

    local level = currentLevel()
    if not level and type(played.open) == "table" then
        level = played.open.level
    end
    if not level then return nil end

    level = self:BucketLevel(level)
    local cap = tonumber(self.MAX_LEVEL) or 60
    if level >= cap then return nil end

    -- The open interval is read once and handed to the pure helper, which
    -- counts it only for the level it belongs to and only when it is not AFK.
    local openElapsed = 0
    if type(played.open) == "table" and played.open.afk ~= true then
        local now, epoch = self:ReadClock()
        local ok, elapsed = pcall(Pure.Elapsed, played.open, now, epoch)
        if ok and type(elapsed) == "number" and elapsed > 0 then
            openElapsed = elapsed
        end
    end

    local currentActive = Pure.ActiveAt(played, level, openElapsed)

    local previous = {}
    local previousTotal = 0
    for offset = 3, 1, -1 do
        local candidate = level - offset
        if candidate >= 1 and type(played.levels[candidate]) == "table" then
            local active = Pure.ActiveAt(played, candidate, 0)
            if active > 0 then
                table.insert(previous, { level = candidate, active = active })
                previousTotal = previousTotal + active
            end
        end
    end

    if currentActive <= 0 and #previous == 0 then return nil end

    local line = "Level " .. tostring(level) .. ": " .. duration(currentActive)
        .. " this level"
    if #previous > 0 then
        local first = previous[1].level
        local last = previous[#previous].level
        local span = first == last and tostring(first) or (tostring(first) .. "-" .. tostring(last))
        line = line .. "; average " .. duration(previousTotal / #previous)
            .. " over the last " .. tostring(#previous)
            .. (#previous == 1 and " level" or " levels")
            .. " (" .. span .. ")"
    end

    if #previous > 0 and previousTotal > 0 then
        local gained = 0
        local known = true
        for _, entry in ipairs(previous) do
            local xp = Pure.GainedXP(played, entry.level)
            if not xp then
                known = false
                break
            end
            gained = gained + xp
        end
        if known and gained > 0 then
            line = line .. ", ~" .. string.format("%.0f", gained / (previousTotal / 3600))
                .. " XP/hour over those levels"
        end
    end

    return line
end

local function stamp(epoch)
    if type(epoch) ~= "number" then return "unknown" end

    if type(date) == "function" then
        local ok, text = pcall(date, "%Y-%m-%d %H:%M", epoch)
        if ok and type(text) == "string" and text ~= "" then return text end
    end

    return tostring(math.floor(epoch))
end

function Played:Report()
    local played = self:GetPlayed(false)
    if not played then
        LT:Print("No play time is recorded for this character yet.")
        return
    end

    local levels = Pure.LevelList(played)
    if #levels == 0 then
        LT:Print("No play time is recorded for this character yet.")
        return
    end

    LT:Print("Play time by level:")
    local capped = false
    for _, level in ipairs(levels) do
        local bucket = played.levels[level]
        if type(bucket) ~= "table" then bucket = {} end
        local atCap = level >= (tonumber(self.MAX_LEVEL) or 60)
        if atCap then capped = true end

        LT:Print("  Level " .. tostring(level) .. (atCap and "+" or "") .. ": "
            .. duration(bucket.active) .. " active, " .. duration(bucket.afk) .. " AFK, "
            .. tostring(math.floor(nonNegative(bucket.deaths))) .. " deaths")
    end

    LT:Print("Total: " .. duration(played.total.active) .. " active, "
        .. duration(played.total.afk) .. " AFK over "
        .. tostring(played.total.sessions) .. " session(s), first seen "
        .. stamp(played.total.firstSeen) .. ".")

    LT:Print("Deaths until 60: "
        .. tostring(self:DeathsUntil60() or 0) .. ".")

    LT:Print("Untracked: " .. duration(played.untracked)
        .. " not explained by these transitions"
        .. (type(played.clientTotal) == "number"
            and (" (client /played: " .. duration(played.clientTotal) .. ")") or "")
        .. ".")

    local absolute, snapshot = level60Marks(played)
    local at60
    if absolute or snapshot then
        at60 = self:Level60Seconds()
    end
    LT:Print("Lifetime: " .. duration(self:LifetimeSeconds())
        .. (type(played.clientBase) == "number"
            and (" (client /played base " .. duration(played.clientBase)
                .. " + tracked since)") or " (tracked only; no client /played answer yet)")
        .. (at60 and (", level 60 reached at " .. duration(at60)) or "") .. ".")

    if played.open then
        LT:Print("Current bucket: level " .. tostring(played.open.level)
            .. ", open since " .. stamp(played.open.startedAtEpoch)
            .. (played.open.afk and " (AFK)" or "") .. ".")
    end

    if #played.sessions > 0 then
        LT:Print("Last sessions:")
        for index = 1, math.min(#played.sessions, 5) do
            local session = played.sessions[index]
            if type(session) == "table" then
                LT:Print("  " .. tostring(index) .. ". " .. stamp(session.start)
                    .. " to " .. stamp(session.stop) .. " — "
                    .. duration(session.active) .. " active, "
                    .. duration(session.afk) .. " AFK (levels "
                    .. tostring(session.startLevel or "?") .. " to "
                    .. tostring(session.endLevel or "?") .. ")")
            end
        end
    end

    if capped then
        LT:Print("Levels at or above 60 share the single level-60 bucket.")
    end
end

------------------------------------------------------------------------------
-- Wiring
------------------------------------------------------------------------------

Played:Attach()
