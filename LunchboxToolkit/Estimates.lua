--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Estimates
    A registry of things this build knows exist but cannot measure, and a
    read-only channel for an estimate pack another addon publishes.

    Three surfaces, kept apart on purpose:
      * records    what a module (Racials, Ranks, ...) declares it knows about:
                   an id, a name, a kind, class/spec, a sentence, the unknowns
                   and the weights it would like to move. Bounded at 200.
      * the pack   LT.EstimatesPack, written by another addon. ApplyPack
                   validates it and stores it; this file scores nothing from it.
      * the gate   estimatesEnabled. Off unless the host turns it on, so an
                   estimate can never quietly become a weight.

    Value(id) is the only read a consumer needs: a copy with estimated = true,
    or nil. Whether to show "≈ estimated" and where is the UI's decision; this
    file prints only from its own slash command.

    No SavedVariables are declared or written here. The gate lives in memory;
    a host that wants it remembered adds its own option, and this file reads
    that option where it exists rather than writing it.
--------------------------------------------------------------------------]]

if type(LunchboxToolkit) ~= "table" then
    return
end

local LT = LunchboxToolkit

local Estimates = {}
LT.Estimates = Estimates
LT.Modules = LT.Modules or {}
LT.Modules.Estimates = Estimates

Estimates.SCHEMA            = 1
Estimates.HEADER            = "LT-ESTIMATES"
Estimates.MAX_RECORDS       = 200
Estimates.MAX_ENTRIES       = 200
Estimates.MAX_REFUSALS      = 40
Estimates.MAX_UNKNOWNS      = 12
Estimates.MAX_WEIGHTS       = 64
Estimates.MAX_TEXT          = 600
Estimates.MAX_ID            = 80
Estimates.MAX_NAME          = 120
Estimates.MAX_SHORT         = 40

Estimates.records      = {}
Estimates.byId         = {}
Estimates.pack         = {}     -- stat -> { value, reason, confidence }
Estimates.provenance   = nil
Estimates.estimatesEnabled = false   -- default off; see IsEnabled
Estimates.enabledExplicit  = false

------------------------------------------------------------------------------
-- Small helpers. None of these touch the client.
------------------------------------------------------------------------------

local function out(text)
    if type(LT.Print) == "function" then
        if pcall(LT.Print, LT, tostring(text)) then return end
    end
    print(text)
end

local function warn(text)
    if type(LT.Warn) == "function" then
        if pcall(LT.Warn, LT, tostring(text)) then return end
    end
    print("Lunchbox Toolkit (warning): " .. tostring(text))
end

local function debug(text)
    if type(LT.Debug) == "function" then
        pcall(LT.Debug, LT, tostring(text))
    end
end

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Restricted values must never be compared or turned into numbers.
local function isSecret(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(issecretvalue, value)
    if not ok then return false end
    return secret == true
end

local function isFiniteNumber(value)
    if type(value) ~= "number" then return false end
    if value ~= value then return false end          -- NaN
    if value == math.huge or value == -math.huge then return false end
    return true
end

local function copyList(list)
    local copy = {}
    for index = 1, #(list or {}) do
        copy[index] = list[index]
    end
    return copy
end

local function copyWeights(weights)
    local copy = {}
    for stat, value in pairs(weights or {}) do
        copy[stat] = value
    end
    return copy
end

local function copyRecord(record)
    return {
        id       = record.id,
        name     = record.name,
        kind     = record.kind,
        class    = record.class,
        spec     = record.spec,
        text     = record.text,
        unknowns = copyList(record.unknowns),
        weights  = copyWeights(record.weights),
    }
end

local function sortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

-- Split on a literal separator, keeping empty fields: "a\t\tb" has three.
local function splitText(text, separator)
    local parts = {}
    if type(text) ~= "string" or text == "" then return parts end

    local start = 1
    while true do
        local position = text:find(separator, start, true)
        if not position then
            parts[#parts + 1] = text:sub(start)
            return parts
        end
        parts[#parts + 1] = text:sub(start, position - 1)
        start = position + 1
    end
end

------------------------------------------------------------------------------
-- Line encoding
--
-- One record per line, tab separated, with a schema header. Tabs and newlines
-- inside a field are escaped so the format is line-stable; items inside the
-- unknowns and weights fields additionally escape ";" and "=".
------------------------------------------------------------------------------

local fieldEscapes = {
    ["\\"] = "\\\\",
    ["\t"] = "\\t",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
}

local itemEscapes = {
    ["\\"] = "\\\\",
    [";"]  = "\\s",
    ["="]  = "\\e",
    ["\t"] = "\\t",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
}

local function encodeField(text)
    return (tostring(text or ""):gsub("[\\\t\n\r]", fieldEscapes))
end

local function encodeItem(text)
    return (tostring(text or ""):gsub("[\\;=\t\n\r]", itemEscapes))
end

local function decodeEscapes(text)
    return (tostring(text or ""):gsub("\\(.)", function(char)
        if char == "t" then return "\t" end
        if char == "n" then return "\n" end
        if char == "r" then return "\r" end
        if char == "s" then return ";" end
        if char == "e" then return "=" end
        if char == "\\" then return "\\" end
        return char
    end))
end

-- %.17g round-trips a double exactly; integers stay readable.
local function encodeNumber(value)
    if value == math.floor(value) and math.abs(value) < 1e15 then
        return string.format("%.0f", value)
    end
    return string.format("%.17g", value)
end

local function encodeList(list)
    local parts = {}
    for index = 1, #(list or {}) do
        parts[#parts + 1] = encodeItem(list[index])
    end
    return table.concat(parts, ";")
end

local function decodeList(text)
    local list = {}
    for _, part in ipairs(splitText(text, ";")) do
        local item = decodeEscapes(part)
        if item ~= "" then
            list[#list + 1] = item
        end
    end
    return list
end

local function encodeWeights(weights)
    local parts = {}
    for _, stat in ipairs(sortedKeys(weights)) do
        parts[#parts + 1] = encodeItem(stat) .. "=" .. encodeNumber(weights[stat])
    end
    return table.concat(parts, ";")
end

local function decodeWeights(text)
    local weights = {}
    for _, part in ipairs(splitText(text, ";")) do
        if part ~= "" then
            local rawStat, rawValue = part:match("^([^=]+)=(.*)$")
            if not rawStat then
                return nil, "Malformed weight entry \"" .. part .. "\"."
            end
            local number = tonumber(rawValue)
            if not isFiniteNumber(number) then
                return nil, "Weight \"" .. tostring(decodeEscapes(rawStat))
                    .. "\" is not a finite number."
            end
            weights[decodeEscapes(rawStat)] = number
        end
    end
    return weights
end

local function recordLine(record)
    local parts = {
        "R",
        encodeField(record.id),
        encodeField(record.name),
        encodeField(record.kind),
        encodeField(record.class or ""),
        encodeField(record.spec or ""),
        encodeField(record.text or ""),
        encodeList(record.unknowns),
        encodeWeights(record.weights),
    }
    return table.concat(parts, "\t")
end

------------------------------------------------------------------------------
-- Record validation
--
-- Shared by AddRecord and Parse, so anything the parser accepts is a record
-- the registry will also accept, and anything exported re-parses unchanged.
------------------------------------------------------------------------------

local function normalizeShort(value, field, limit)
    if value == nil then return nil end
    if type(value) ~= "string" then
        return false, field .. " must be text."
    end
    local text = trim(value)
    if text == "" then return nil end
    if #text > limit then
        return false, field .. " is longer than " .. tostring(limit) .. " characters."
    end
    return text
end

local function normalizeRecord(source)
    if type(source) ~= "table" then
        return nil, "A record must be a table."
    end
    if type(source.id) ~= "string" then
        return nil, "A record needs a string id."
    end

    local id = trim(source.id)
    if id == "" then
        return nil, "A record needs a non-empty id."
    end
    if #id > Estimates.MAX_ID then
        return nil, "A record id is longer than " .. tostring(Estimates.MAX_ID) .. " characters."
    end

    local name
    if source.name == nil then
        name = id
    elseif type(source.name) ~= "string" then
        return nil, "A record name must be text."
    else
        name = trim(source.name)
        if name == "" then name = id end
        if #name > Estimates.MAX_NAME then
            return nil, "A record name is longer than " .. tostring(Estimates.MAX_NAME) .. " characters."
        end
    end

    local kind = "estimate"
    if source.kind ~= nil then
        local value, err = normalizeShort(source.kind, "kind", Estimates.MAX_SHORT)
        if value == false then return nil, err end
        if value then kind = value end
    end

    local classToken
    if source.class ~= nil then
        local value, err = normalizeShort(source.class, "class", Estimates.MAX_SHORT)
        if value == false then return nil, err end
        classToken = value
    end

    local spec
    if source.spec ~= nil then
        local value, err = normalizeShort(source.spec, "spec", Estimates.MAX_SHORT)
        if value == false then return nil, err end
        spec = value
    end

    local text = ""
    if source.text ~= nil then
        if type(source.text) ~= "string" then
            return nil, "A record text must be a string."
        end
        text = source.text
        if #text > Estimates.MAX_TEXT then
            return nil, "A record text is longer than " .. tostring(Estimates.MAX_TEXT) .. " characters."
        end
    end

    local unknowns = {}
    if source.unknowns ~= nil then
        if type(source.unknowns) == "string" then
            local value = trim(source.unknowns)
            if value ~= "" then unknowns[1] = value end
        elseif type(source.unknowns) == "table" then
            for index, item in ipairs(source.unknowns) do
                if type(item) ~= "string" then
                    return nil, "unknowns[" .. tostring(index) .. "] must be text."
                end
                local value = trim(item)
                if value ~= "" then
                    if #value > Estimates.MAX_NAME then
                        return nil, "unknowns[" .. tostring(index) .. "] is too long."
                    end
                    unknowns[#unknowns + 1] = value
                end
            end
        else
            return nil, "unknowns must be a string or a list of strings."
        end
        if #unknowns > Estimates.MAX_UNKNOWNS then
            return nil, "A record carries at most " .. tostring(Estimates.MAX_UNKNOWNS) .. " unknowns."
        end
    end

    local weights = {}
    if source.weights ~= nil then
        if type(source.weights) ~= "table" then
            return nil, "weights must be a table of stat keys to numbers."
        end
        local stats = {}
        for stat in pairs(source.weights) do
            if type(stat) ~= "string" or stat == "" then
                return nil, "Weight keys must be non-empty strings."
            end
            if #stat > Estimates.MAX_SHORT then
                return nil, "A weight key is longer than " .. tostring(Estimates.MAX_SHORT) .. " characters."
            end
            stats[#stats + 1] = stat
        end
        if #stats > Estimates.MAX_WEIGHTS then
            return nil, "A record carries at most " .. tostring(Estimates.MAX_WEIGHTS) .. " weights."
        end
        for _, stat in ipairs(stats) do
            local value = source.weights[stat]
            if isSecret(value) then
                return nil, "Weight \"" .. stat .. "\" is a restricted value."
            end
            if not isFiniteNumber(value) then
                return nil, "Weight \"" .. stat .. "\" is not a finite number."
            end
            weights[stat] = value
        end
    end

    return {
        id       = id,
        name     = name,
        kind     = kind,
        class    = classToken,
        spec     = spec,
        text     = text,
        unknowns = unknowns,
        weights  = weights,
    }
end

------------------------------------------------------------------------------
-- Registry
------------------------------------------------------------------------------

-- record = { id, name, kind, class, spec, text, unknowns, weights }
-- Re-adding an existing id replaces it in place, so a module that reloads its
-- own data does not fill the registry twice.
function Estimates:AddRecord(record)
    local stored, err = normalizeRecord(record)
    if not stored then
        return nil, err
    end

    local existing = self.byId[stored.id]
    if existing then
        for index = 1, #self.records do
            if self.records[index] == existing then
                self.records[index] = stored
                break
            end
        end
        self.byId[stored.id] = stored
        return copyRecord(stored)
    end

    if #self.records >= self.MAX_RECORDS then
        return nil, "The estimates registry is full (" .. tostring(self.MAX_RECORDS) .. " records)."
    end

    self.records[#self.records + 1] = stored
    self.byId[stored.id] = stored
    return copyRecord(stored)
end

function Estimates:GetRecord(id)
    if type(id) ~= "string" then return nil end
    local record = self.byId[id]
    if not record then return nil end
    return copyRecord(record)
end

function Estimates:GetRecords()
    local list = {}
    for index = 1, #self.records do
        list[index] = copyRecord(self.records[index])
    end
    return list
end

function Estimates:Count()
    return #self.records
end

function Estimates:GetProvenance()
    local provenance = self.provenance
    if type(provenance) ~= "table" then return nil end

    local refusals = {}
    for index = 1, #(provenance.refusals or {}) do
        local refusal = provenance.refusals[index]
        refusals[index] = { stat = refusal.stat, reason = refusal.reason }
    end

    return {
        schema   = provenance.schema,
        source   = provenance.source,
        applied  = provenance.applied,
        refused  = provenance.refused,
        refusals = refusals,
    }
end

------------------------------------------------------------------------------
-- Export and parse
------------------------------------------------------------------------------

function Estimates:ExportLines()
    local lines = { self.HEADER .. "\t" .. tostring(self.SCHEMA) }
    for index = 1, #self.records do
        lines[#lines + 1] = recordLine(self.records[index])
    end
    return lines
end

function Estimates:Export()
    return table.concat(self:ExportLines(), "\n")
end

-- Returns the records a pack describes, or nil and a reason. Nothing is added
-- to the registry here; Parse is the format's own reader, Import is the
-- caller's decision.
function Estimates:Parse(text)
    if type(text) ~= "string" then
        return nil, "An estimates pack must be text."
    end

    local normalized = text:gsub("\r\n", "\n")
    local lines = splitText(normalized, "\n")
    local records = {}
    local headerSeen = false

    for index = 1, #lines do
        local line = lines[index]
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local fields = splitText(line, "\t")

            if not headerSeen then
                if fields[1] ~= self.HEADER then
                    return nil, "This is not an estimates pack: the first line is not \""
                        .. self.HEADER .. "\"."
                end
                local schema = tonumber(fields[2])
                if schema ~= self.SCHEMA then
                    return nil, "This pack declares estimates schema " .. tostring(fields[2])
                        .. "; this build reads schema " .. tostring(self.SCHEMA) .. "."
                end
                headerSeen = true
            else
                if fields[1] ~= "R" then
                    return nil, "Line " .. tostring(index) .. " has unknown tag \""
                        .. tostring(fields[1]) .. "\"."
                end
                if #fields ~= 9 then
                    return nil, "Line " .. tostring(index) .. " has " .. tostring(#fields)
                        .. " fields; a record line has 9."
                end

                local weights, weightError = decodeWeights(fields[9])
                if not weights then
                    return nil, "Line " .. tostring(index) .. ": " .. tostring(weightError)
                end

                local record, recordError = normalizeRecord({
                    id       = decodeEscapes(fields[2]),
                    name     = decodeEscapes(fields[3]),
                    kind     = decodeEscapes(fields[4]),
                    class    = decodeEscapes(fields[5]),
                    spec     = decodeEscapes(fields[6]),
                    text     = decodeEscapes(fields[7]),
                    unknowns = decodeList(fields[8]),
                    weights  = weights,
                })
                if not record then
                    return nil, "Line " .. tostring(index) .. ": " .. tostring(recordError)
                end
                records[#records + 1] = record
            end
        end
    end

    if not headerSeen then
        return nil, "This is not an estimates pack: the header line is missing."
    end

    return records
end

------------------------------------------------------------------------------
-- The gate
--
-- Off by default. An explicit SetEnabled call wins for the session; otherwise a
-- host option of the same name is honoured if one exists (read, never written
-- here). With neither, values are not returned at all.
------------------------------------------------------------------------------

function Estimates:IsEnabled()
    if self.enabledExplicit then
        return self.estimatesEnabled == true
    end

    local Database = LT.Database
    if type(Database) == "table" and type(Database.GetOptions) == "function" then
        local ok, options = pcall(Database.GetOptions, Database)
        if ok and type(options) == "table" and options.estimatesEnabled ~= nil then
            return options.estimatesEnabled == true
        end
    end

    return self.estimatesEnabled == true
end

function Estimates:SetEnabled(value)
    self.estimatesEnabled = value and true or false
    self.enabledExplicit = true
    return self.estimatesEnabled
end

------------------------------------------------------------------------------
-- Pack
------------------------------------------------------------------------------

-- The stored weights of the active build's profile. A pack may only speak
-- about a stat the profile already scores; it never introduces one.
function Estimates:ProfileWeights()
    local Profiles = LT.Profiles
    if type(Profiles) ~= "table" or type(Profiles.ResolveForBuild) ~= "function" then
        return nil, "Profiles are not available, so a pack cannot be checked against one."
    end

    local index = 1
    local Builds = LT.Builds
    if type(Builds) == "table" and type(Builds.GetActiveIndex) == "function" then
        local ok, value = pcall(Builds.GetActiveIndex, Builds)
        if ok and tonumber(value) then
            index = tonumber(value)
        end
    end

    local ok, profile = pcall(Profiles.ResolveForBuild, Profiles, index)
    if not ok or type(profile) ~= "table" then
        return nil, "The active slot has no profile to check a pack against."
    end
    if type(profile.weights) ~= "table" then
        return nil, "The active profile has no weights to check a pack against."
    end
    return profile.weights
end

-- pack = { schema = 1, entries = { [stat] = { value, reason, confidence } } }
-- Everything is copied; the caller's tables are never retained. A refused
-- pack leaves the previously stored one untouched. ApplyPack only stores:
-- nothing here changes a weight or a score.
function Estimates:ApplyPack(pack)
    local result = {
        ok = false,
        schema = nil,
        applied = 0,
        refused = 0,
        refusals = {},
    }

    if type(pack) ~= "table" then
        result.reason = "An estimates pack must be a table."
        return result
    end

    local schema = pack.schema
    if isSecret(schema) then
        result.reason = "The pack schema is a restricted value."
        return result
    end
    schema = tonumber(schema)
    result.schema = schema
    if schema ~= self.SCHEMA then
        result.reason = "This pack declares schema " .. tostring(pack.schema)
            .. "; this build reads schema " .. tostring(self.SCHEMA) .. "."
        return result
    end

    if type(pack.entries) ~= "table" then
        result.reason = "A schema " .. tostring(self.SCHEMA) .. " pack needs an entries table."
        return result
    end

    local weights, profileError = self:ProfileWeights()
    if not weights then
        result.reason = profileError
        return result
    end

    local function refuse(stat, reason)
        result.refused = result.refused + 1
        if #result.refusals < self.MAX_REFUSALS then
            result.refusals[#result.refusals + 1] = { stat = stat, reason = reason }
        end
    end

    local accepted = {}
    local acceptedCount = 0

    for _, stat in ipairs(sortedKeys(pack.entries)) do
        local entry = pack.entries[stat]
        local reason = nil

        if isSecret(stat) then
            reason = "A pack entry key is a restricted value."
        elseif type(stat) ~= "string" or stat == "" then
            reason = "A pack entry key must be a non-empty stat key."
        elseif type(entry) ~= "table" then
            reason = "The entry for \"" .. stat .. "\" is not a table."
        elseif weights[stat] == nil then
            reason = "The active profile has no \"" .. stat .. "\" weight, so the estimate is refused."
        elseif isSecret(entry.value) then
            reason = "\"" .. stat .. "\" carries a restricted value."
        elseif not isFiniteNumber(entry.value) then
            reason = "\"" .. stat .. "\" has no finite numeric value."
        elseif entry.reason ~= nil and type(entry.reason) ~= "string" then
            reason = "\"" .. stat .. "\" has a reason that is not text."
        elseif entry.confidence ~= nil
            and (isSecret(entry.confidence) or not isFiniteNumber(entry.confidence)) then
            reason = "\"" .. stat .. "\" has a confidence that is not a finite number."
        elseif acceptedCount >= self.MAX_ENTRIES then
            reason = "The pack carries more than " .. tostring(self.MAX_ENTRIES) .. " usable entries."
        end

        if reason then
            refuse(stat, reason)
        else
            accepted[stat] = {
                value = entry.value,
                reason = entry.reason or "",
                confidence = entry.confidence,
            }
            acceptedCount = acceptedCount + 1
            result.applied = result.applied + 1
        end
    end

    self.pack = accepted

    -- Copied so a caller mutating the returned result cannot rewrite the
    -- provenance a later consumer reads.
    local provenanceRefusals = {}
    for index = 1, #result.refusals do
        provenanceRefusals[index] = {
            stat = result.refusals[index].stat,
            reason = result.refusals[index].reason,
        }
    end

    self.provenance = {
        schema = self.SCHEMA,
        source = "LT.EstimatesPack",
        applied = result.applied,
        refused = result.refused,
        refusals = provenanceRefusals,
    }

    result.ok = true
    return result
end

-- Picks up a pack the host (or another addon) left in LT.EstimatesPack. Safe to
-- call more than once; the same reason is only warned about once per session.
function Estimates:ReadRegisteredPack()
    local pack = LT.EstimatesPack
    if pack == nil then return nil end

    local result = self:ApplyPack(pack)
    if type(result) ~= "table" then return nil end

    if result.ok then
        self.packProblem = nil
        debug("estimates: stored " .. tostring(result.applied)
            .. " value(s) from LT.EstimatesPack")
    elseif self.packProblem ~= result.reason then
        self.packProblem = result.reason
        warn("LT.EstimatesPack was not accepted: " .. tostring(result.reason))
    end

    return result
end

-- The consumer read. Returns a fresh table, or nil when the gate is off, the
-- stat was never stored, or the entry is not usable.
function Estimates:Value(id)
    if type(id) ~= "string" or id == "" then return nil end
    if not self:IsEnabled() then return nil end

    local entry = self.pack[id]
    if type(entry) ~= "table" or not isFiniteNumber(entry.value) then return nil end

    return {
        value = entry.value,
        reason = entry.reason,
        confidence = entry.confidence,
        estimated = true,
    }
end

------------------------------------------------------------------------------
-- Slash command
------------------------------------------------------------------------------

function Estimates:PrintStored()
    local stats = sortedKeys(self.pack)
    if #stats == 0 then return end

    local shown = math.min(#stats, 20)
    out("  stored values:")
    for index = 1, shown do
        local stat = stats[index]
        local entry = self.pack[stat]
        local line = "    " .. tostring(stat) .. " = " .. tostring(entry.value)
        if entry.reason and entry.reason ~= "" then
            line = line .. " — " .. entry.reason
        end
        if entry.confidence then
            line = line .. " (confidence " .. tostring(entry.confidence) .. ")"
        end
        out(line)
    end
    if #stats > shown then
        out("    ... " .. tostring(#stats - shown) .. " more.")
    end
end

function Estimates:PrintList()
    local count = #self.records
    local stored = 0
    for _ in pairs(self.pack) do stored = stored + 1 end

    out("Estimates: " .. tostring(count) .. (count == 1 and " record" or " records")
        .. ", " .. tostring(stored) .. (stored == 1 and " stored value" or " stored values")
        .. ", gate " .. (self:IsEnabled() and "on" or "off") .. ".")

    if self.provenance then
        out("  pack: schema " .. tostring(self.provenance.schema)
            .. " from " .. tostring(self.provenance.source)
            .. ", " .. tostring(self.provenance.applied) .. " applied"
            .. ", " .. tostring(self.provenance.refused) .. " refused.")
    end

    local shown = math.min(count, 20)
    for index = 1, shown do
        local record = self.records[index]
        local weightCount = 0
        for _ in pairs(record.weights) do weightCount = weightCount + 1 end

        local scope = record.kind
        if record.class then scope = scope .. "/" .. record.class end
        if record.spec then scope = scope .. "/" .. record.spec end

        local line = "  " .. tostring(index) .. ". " .. record.id
            .. " — " .. record.name .. " [" .. scope .. "]"
            .. ", " .. tostring(weightCount) .. (weightCount == 1 and " weight" or " weights")
        if record.unknowns and #record.unknowns > 0 then
            line = line .. ", " .. tostring(#record.unknowns)
                .. (#record.unknowns == 1 and " unknown" or " unknowns")
        end
        out(line)
    end

    if count > shown then
        out("  ... " .. tostring(count - shown) .. " more.")
    end

    self:PrintStored()

    if not self:IsEnabled() then
        out("  The gate is off: Value(id) returns nil until a host enables estimates.")
    end
end

function Estimates:PrintExport()
    -- Printed without the addon's chat prefix: the output is the pack verbatim,
    -- so what a player copies is exactly what Parse reads back.
    local lines = self:ExportLines()
    for index = 1, #lines do
        print(lines[index])
    end
end

function Estimates:PrintClear()
    local records, stored = self:Clear()
    out("Cleared " .. tostring(records) .. (records == 1 and " record" or " records")
        .. " and " .. tostring(stored) .. (stored == 1 and " stored value" or " stored values")
        .. ". Modules add their records again after /reload.")
end

function Estimates:Clear()
    local records = #self.records
    local stored = 0
    for _ in pairs(self.pack) do stored = stored + 1 end

    for index = #self.records, 1, -1 do
        self.records[index] = nil
    end
    self.byId = {}
    self.pack = {}
    self.provenance = nil
    self.packProblem = nil

    return records, stored
end

function Estimates:PrintHelp()
    out("Estimates — records of what this build cannot measure:")
    out("  /lt estimates list   — counts, then the first 20 records")
    out("  /lt estimates export — the pack: schema header, then one record per line")
    out("  /lt estimates clear  — empty the registry and the stored values")
    out("  Records come from modules; values come from LT.EstimatesPack and are")
    out("  off until the host enables them.")
end

function Estimates:Command(words)
    local action = string.lower(tostring((words and words[2]) or ""))

    if action == "" or action == "help" or action == "?" then
        self:PrintHelp()
    elseif action == "list" then
        self:PrintList()
    elseif action == "export" then
        self:PrintExport()
    elseif action == "clear" then
        self:PrintClear()
    else
        warn("Unknown estimates subcommand \"" .. action
            .. "\". Use list, export or clear.")
    end
end

------------------------------------------------------------------------------
-- Login wiring
--
-- The slash command is registered at PLAYER_LOGIN, as the rest of the addon
-- does. The frame is created at load, never in combat. Both handlers are
-- idempotent, so a host that also lists this module in ModuleOrder does not
-- register twice or store the same pack twice.
------------------------------------------------------------------------------

function Estimates:RegisterCommand()
    if self.slashRegistered then return true end

    local Slash = LT.Slash
    if type(Slash) ~= "table" or type(Slash.RegisterCommand) ~= "function" then
        return false
    end

    local ok, accepted = pcall(Slash.RegisterCommand, Slash, "estimates",
        function(words) Estimates:Command(words) end,
        "/lt estimates list|export|clear — registry of unmeasured things and the stored pack")

    if ok and accepted then
        self.slashRegistered = true
        return true
    end
    return false
end

function Estimates:OnPlayerLogin()
    -- Also reached through Core's module stage; the frame hook must not run it
    -- twice.
    if self.loginHandled then return end
    self.loginHandled = true

    self:RegisterCommand()
    self:ReadRegisteredPack()
end

function Estimates:OnEnterWorld()
    -- A pack read at login can precede the profile it must be checked against;
    -- retry once something is known to exist, and never re-warn the same way.
    if self.provenance == nil then
        self:ReadRegisteredPack()
    end
end

local function wireEvents()
    -- The slash command is registered from the login handler, never at file
    -- load, as the rest of the addon does. If a client somehow has no frame
    -- system the module still loads: a host can call RegisterCommand itself,
    -- and nothing here invents a widget to fall back on.
    if type(CreateFrame) ~= "function" then return end

    local ok, frame = pcall(CreateFrame, "Frame")
    if not ok or not frame then return end

    Estimates.frame = frame
    local loginWatched = pcall(frame.RegisterEvent, frame, "PLAYER_LOGIN")
    pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")

    local scriptSet = pcall(frame.SetScript, frame, "OnEvent", function(_, event)
        if event == "PLAYER_LOGIN" then
            Estimates:OnPlayerLogin()
        elseif event == "PLAYER_ENTERING_WORLD" then
            Estimates:OnEnterWorld()
        end
    end)

    -- Say so rather than loading silently without a command.
    if not loginWatched or not scriptSet then
        warn("estimates: the login event could not be watched, so /lt estimates "
            .. "is not registered on this client.")
    end
end

wireEvents()
