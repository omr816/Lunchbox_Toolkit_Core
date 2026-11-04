--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — TalentsProbe

    This file exists to unblock two open items: T-05 (read the player's talent
    build) and T-22 (draw talent borders). Before any talent code can be
    written, the client's actual talent API shape has to be known rather than
    assumed: which namespace exists, what GetConfigInfo returns, and where the
    tree and node entry points live on this build.

    /lt talents therefore prints a bounded structural dump and stores the same
    text in LunchboxToolkitDB.talentDump so it survives a reload and can be
    copied out of the saved-variables file. /lt talents clear empties it.

    The only names ever *called* are in ROUTES below. Everything else in the
    report is a field read, so an unknown method is never invoked on a guess.
    This file does no scoring and creates no frame.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local TalentsProbe = {}
LT.TalentsProbe = TalentsProbe
LT.Modules = LT.Modules or {}
LT.Modules.TalentsProbe = TalentsProbe

TalentsProbe.MAX_DEPTH = 3
TalentsProbe.MAX_LINES = 40

-- Names this file is allowed to call. Add a route deliberately after reading
-- the API documentation; nothing is discovered and called by guessing. Args
-- name values captured from earlier routes.
local ROUTES = {
    { namespace = "C_ClassTalents", method = "GetActiveConfigID", args = {} },
    { namespace = "C_ClassTalents", method = "GetConfigIDs", args = {} },
    { namespace = "C_ClassTalents", method = "GetConfigInfo", args = { "configID" } },
    { namespace = "C_Traits", method = "GetTreeInfo", args = { "treeID" } },
    { namespace = "C_Traits", method = "GetTreeNodes", args = { "treeID" } },
}

local NAMESPACES = { "C_ClassTalents", "C_Traits" }

------------------------------------------------------------------------------
-- Small guarded helpers
--
-- Every client call sits behind a pcall. A missing global is a normal result,
-- not an error, so the report can always finish.
------------------------------------------------------------------------------

local function isSecret(value)
    local checker = rawget(_G, "issecretvalue")
    if type(checker) ~= "function" then return false end
    local ok, result = pcall(checker, value)
    return ok and result == true
end

local function safeGet(container, key)
    if container == nil then return nil end
    local ok, value = pcall(function() return container[key] end)
    if ok then return value end
    return nil
end

local function oneLine(text)
    return (tostring(text):gsub("[%c]", " "))
end

local function clipped(text, limit)
    local clean = oneLine(text)
    if #clean > limit then
        clean = clean:sub(1, limit - 3) .. "..."
    end
    return clean
end

local function currentTime()
    local ok, value = pcall(function() return time() end)
    if ok and type(value) == "number" then return value end
    return nil
end

local function formatTime(at)
    if type(at) ~= "number" then return "unknown time" end
    local ok, text = pcall(function() return date("%Y-%m-%d %H:%M:%S", at) end)
    if ok and type(text) == "string" then return text end
    local osTable = rawget(_G, "os")
    local formatter = type(osTable) == "table" and rawget(osTable, "date") or nil
    if type(formatter) == "function" then
        ok, text = pcall(formatter, "%Y-%m-%d %H:%M:%S", at)
        if ok and type(text) == "string" then return text end
    end
    return "timestamp " .. tostring(at)
end

local function buildText()
    local ok, major, _, _, toc = pcall(function() return GetBuildInfo() end)
    if ok and type(toc) == "string" then return toc end
    if ok and type(major) == "string" then return major end
    return "unknown"
end

local function say(text)
    if type(LT.Print) == "function" then
        LT:Print(text)
    else
        print(text)
    end
end

------------------------------------------------------------------------------
-- Value formatting
------------------------------------------------------------------------------

local function displayValue(value)
    if isSecret(value) then return "secret (not read)" end
    local kind = type(value)
    if kind == "string" then
        return "string \"" .. clipped(value, 80) .. "\""
    elseif kind == "number" then
        return "number " .. tostring(value)
    elseif kind == "boolean" then
        return "boolean " .. tostring(value)
    end
    return kind
end

local function keyText(key)
    local kind = type(key)
    if kind == "string" then
        if key:match("^[%a_][%w_]*$") then
            return "." .. key
        end
        return "[" .. string.format("%q", oneLine(key)) .. "]"
    end
    return "[" .. oneLine(tostring(key)) .. "]"
end

local function keyRank(key)
    local kind = type(key)
    if kind == "number" then return 1 end
    if kind == "string" then return 2 end
    if kind == "boolean" then return 3 end
    return 4
end

local function collectKeys(tbl)
    local ok, keys = pcall(function()
        local list = {}
        for key in pairs(tbl) do list[#list + 1] = key end
        return list
    end)
    if not ok then return nil end
    return keys
end

-- Deterministic order: numeric keys, then strings, then everything else.
-- A client table that refuses comparison simply stays in iteration order.
local function sortKeys(keys)
    return pcall(table.sort, keys, function(a, b)
        local rankA, rankB = keyRank(a), keyRank(b)
        if rankA ~= rankB then return rankA < rankB end
        if rankA == 1 or rankA == 2 then return a < b end
        return tostring(a) < tostring(b)
    end)
end

------------------------------------------------------------------------------
-- Bounded dump
--
-- One line per path: "path = type value". Depth is capped at MAX_DEPTH and
-- the whole report at MAX_LINES, with the final slot reserved for a visible
-- truncation marker rather than silent clipping. A table object seen twice on
-- the same route is reported as a cycle and never followed again.
------------------------------------------------------------------------------

local function newWriter(lines)
    return { lines = lines, seen = {}, truncated = false }
end

local function write(writer, text)
    if #writer.lines >= TalentsProbe.MAX_LINES - 1 then
        writer.truncated = true
        return false
    end
    writer.lines[#writer.lines + 1] = text
    return true
end

local function dumpValue(writer, path, value, depth)
    if isSecret(value) then
        write(writer, path .. " = secret (not read)")
        return
    end

    local kind = type(value)
    if kind ~= "table" then
        write(writer, path .. " = " .. displayValue(value))
        return
    end

    local previous = writer.seen[value]
    if previous then
        write(writer, path .. " = table (cycle: already seen at " .. previous .. ")")
        return
    end
    writer.seen[value] = path

    local keys = collectKeys(value)
    if not keys then
        write(writer, path .. " = table (keys unreadable)")
        return
    end

    write(writer, path .. " = table (" .. tostring(#keys) .. " keys)")
    if depth >= TalentsProbe.MAX_DEPTH then return end

    sortKeys(keys)
    for index = 1, #keys do
        if #writer.lines >= TalentsProbe.MAX_LINES - 1 then
            writer.truncated = true
            return
        end
        local key = keys[index]
        dumpValue(writer, path .. keyText(key), safeGet(value, key), depth + 1)
    end
end

------------------------------------------------------------------------------
-- Route execution
------------------------------------------------------------------------------

local function resolveArguments(route, context)
    local values = {}
    for index = 1, #route.args do
        local name = route.args[index]
        local value = context[name]
        if value == nil then return nil, name end
        values[#values + 1] = value
    end
    return values
end

local function routeLabel(route, values)
    local label = route.namespace .. "." .. route.method
    if #values == 0 then return label end
    local parts = {}
    for index = 1, #values do
        parts[index] = isSecret(values[index]) and "secret" or tostring(values[index])
    end
    return label .. "(" .. table.concat(parts, ",") .. ")"
end

local function invoke(route, values, env)
    local container = env[route.namespace]
    local lookupOk, fn = pcall(function() return container[route.method] end)
    if not lookupOk or type(fn) ~= "function" then
        return nil, "missing"
    end

    local callOk, result
    if #values == 0 then
        callOk, result = pcall(fn)
    elseif #values == 1 then
        callOk, result = pcall(fn, values[1])
    else
        callOk, result = pcall(fn, values[1], values[2])
    end

    if not callOk then
        return nil, "error: " .. clipped(result, 120)
    end
    return result, nil
end

-- Values later routes need, taken only from the results of routes already
-- listed above. Nothing is fetched by trying an unlisted method.
local function capture(route, result, context)
    if type(result) == "number" and not isSecret(result) then
        if route.method == "GetActiveConfigID" then
            context.activeConfigID = result
            context.configID = context.configID or result
        end
        return
    end

    if type(result) ~= "table" or isSecret(result) then return end

    if route.method == "GetConfigIDs" then
        local first = safeGet(result, 1)
        if type(first) == "number" and not isSecret(first) then
            context.configID = context.configID or first
        end
    elseif route.method == "GetConfigInfo" then
        local treeID = safeGet(result, "treeID")
        if type(treeID) == "number" and not isSecret(treeID) then
            context.treeID = context.treeID or treeID
        end
    end
end

------------------------------------------------------------------------------
-- Report
--
-- Pure: given an env table ({ at, build, C_ClassTalents, C_Traits }) it
-- returns the report lines and touches no other client state.
------------------------------------------------------------------------------

function TalentsProbe:BuildReport(env)
    if type(env) ~= "table" then env = {} end

    local lines = {}
    local writer = newWriter(lines)

    write(writer, "Lunchbox Toolkit talents probe — T-05 / T-22 — paste this into chat")
    write(writer, "at " .. formatTime(env.at)
        .. " · build " .. clipped(env.build or "unknown", 40)
        .. " · depth<=" .. tostring(self.MAX_DEPTH)
        .. " · " .. tostring(self.MAX_LINES) .. " lines max")

    for index = 1, #NAMESPACES do
        local name = NAMESPACES[index]
        local kind = type(env[name])
        if kind == "table" or kind == "userdata" then
            write(writer, name .. " = " .. kind)
        else
            write(writer, name .. " = missing")
        end
    end

    local context = {}
    for index = 1, #ROUTES do
        local route = ROUTES[index]
        local kind = type(env[route.namespace])
        if kind ~= "table" and kind ~= "userdata" then
            write(writer, route.namespace .. "." .. route.method
                .. " = missing (" .. route.namespace .. " absent)")
        else
            local values, missing = resolveArguments(route, context)
            if not values then
                write(writer, route.namespace .. "." .. route.method
                    .. " = skipped (no " .. tostring(missing) .. " yet)")
            else
                local label = routeLabel(route, values)
                local result, reason = invoke(route, values, env)
                if reason then
                    write(writer, label .. " = " .. reason)
                else
                    capture(route, result, context)
                    dumpValue(writer, label, result, 1)
                end
            end
        end
    end

    if writer.truncated then
        lines[#lines + 1] = "[truncated at " .. tostring(self.MAX_LINES) .. " lines]"
    end

    return lines
end

------------------------------------------------------------------------------
-- Storage
--
-- Account-wide on purpose: the dump is about the client build, not about one
-- character, and it has to survive a reload.
------------------------------------------------------------------------------

local function accountStore()
    local db = rawget(_G, "LunchboxToolkitDB")
    if type(db) == "table" then return db end
    if db == nil then
        db = {}
        _G.LunchboxToolkitDB = db
        return db
    end
    return nil
end

function TalentsProbe:Save(at, lines)
    local db = accountStore()
    if not db then
        return false, "LunchboxToolkitDB is not a table"
    end

    local copy = {}
    if type(lines) == "table" then
        for index = 1, #lines do copy[index] = lines[index] end
    end

    db.talentDump = { at = at, lines = copy }
    return true
end

function TalentsProbe:Clear()
    local db = rawget(_G, "LunchboxToolkitDB")
    if type(db) ~= "table" or db.talentDump == nil then
        return false
    end
    db.talentDump = nil
    return true
end

------------------------------------------------------------------------------
-- Command
------------------------------------------------------------------------------

local function handleCommand(words)
    local action = ""
    if type(words) == "table" and words[2] ~= nil then
        action = string.lower(tostring(words[2]))
    end

    if action == "clear" then
        if TalentsProbe:Clear() then
            say("talentDump cleared.")
        else
            say("talentDump was already empty.")
        end
        return
    end

    if action ~= "" and action ~= "dump" then
        say("Usage: /lt talents — probe the talent API; /lt talents clear — empty the saved dump.")
        return
    end

    TalentsProbe:Run()
end

function TalentsProbe:Run()
    local at = currentTime()
    local env = {
        at = at,
        build = buildText(),
        C_ClassTalents = rawget(_G, "C_ClassTalents"),
        C_Traits = rawget(_G, "C_Traits"),
    }

    local lines = self:BuildReport(env)
    local saved, reason = self:Save(at, lines)
    if not saved then
        say("The probe ran but the dump was not saved: " .. tostring(reason))
    end

    for index = 1, #lines do
        say(lines[index])
    end

    return lines
end

local function registerCommand()
    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then
        return false
    end

    local ok, result = pcall(slash.RegisterCommand, slash, "talents", handleCommand,
        "/lt talents — talent API probe for T-05/T-22; /lt talents clear — empty the saved dump")

    return ok and result == true
end

-- Called by Core's module stage at PLAYER_LOGIN. Core lists this module in
-- ModuleOrder; this file must not add itself at run time. Registration is
-- idempotent: the registry refuses a second "talents".
function TalentsProbe:OnPlayerLogin()
    return registerCommand()
end
