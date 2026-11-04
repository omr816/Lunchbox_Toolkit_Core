--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — PluginAPI
    The documented interface plugins extend the core through.

    A plugin never edits the core. It registers itself, declares the
    adjustments it makes, and the core decides when they run.

    Ordering and combination rules (the part that stops the same benefit being
    counted twice):
      * every adjustment carries a `benefit` key naming the game effect it
        models (for example "windfury_extra_attack")
      * adjustments are applied in a fixed order: priority, then plugin id,
        then adjustment id — so two runs always produce the same weights
      * two adjustments that target the same stat with the same benefit key do
        NOT both apply: the second is skipped and reported, unless it sets
        allowStack = true and says why
      * every plugin call is pcall'd. A plugin that throws is skipped and
        named; the core still loads and still scores.

    API version: 1.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local PluginAPI = {}
LT.PluginAPI = PluginAPI
LT.Modules.PluginAPI = PluginAPI

PluginAPI.VERSION = 1
PluginAPI.plugins = {}
PluginAPI.adjustments = {}
PluginAPI.errors = {}
PluginAPI.registrationProblems = {}

------------------------------------------------------------------------------
-- Registration
------------------------------------------------------------------------------

-- meta = {
--   id            required, unique, stable
--   name          shown in the UI
--   version       plugin's own version
--   author
--   apiVersion    must be <= PluginAPI.VERSION
--   classes       optional list of class tokens this plugin is for
--   description
-- }
function PluginAPI:RegisterPlugin(meta)
    if type(meta) ~= "table" then
        return nil, "A plugin registration must be a table."
    end

    if type(meta.id) ~= "string" or meta.id == "" then
        return nil, "A plugin needs a stable string id."
    end

    if self.plugins[meta.id] then
        local reason = "Plugin id \"" .. meta.id .. "\" is already registered."
        table.insert(self.registrationProblems, reason)
        return nil, reason
    end

    local apiVersion = tonumber(meta.apiVersion) or 1
    if apiVersion > self.VERSION then
        -- Refused rather than half-loaded: a plugin written for a newer
        -- interface may rely on behaviour this core does not have.
        local reason = "Plugin \"" .. tostring(meta.name or meta.id)
            .. "\" targets plugin API " .. tostring(apiVersion)
            .. " but this build provides API " .. tostring(self.VERSION) .. "."
        table.insert(self.registrationProblems, reason)
        return nil, reason
    end

    local plugin = {
        id = meta.id,
        name = meta.name or meta.id,
        version = meta.version or "?",
        author = meta.author or "unknown",
        apiVersion = apiVersion,
        classes = meta.classes,
        description = meta.description or "",
        loadedAt = time and time() or 0,
    }

    self.plugins[meta.id] = plugin
    self.adjustments[meta.id] = self.adjustments[meta.id] or {}

    if LT.Profiles then LT.Profiles:Invalidate() end

    LT:Fire(LT.EVENT_PLUGINS, { reason = "registered", pluginId = meta.id })
    return plugin
end

function PluginAPI:UnregisterPlugin(pluginId)
    if not self.plugins[pluginId] then return false end

    self.plugins[pluginId] = nil
    self.adjustments[pluginId] = nil
    self.errors[pluginId] = nil

    LT:Fire(LT.EVENT_PLUGINS, { reason = "unregistered", pluginId = pluginId })
    return true
end

-- definition = {
--   id           required, unique within the plugin
--   title        shown in tooltips and the debug page
--   benefit      required — the game effect this models (dedupe key)
--   priority     lower runs first, default 100
--   mode         "additive" (default) adds to the weight,
--                "multiplier" multiplies the weight by (1 + value)
--   appliesTo    function(ctx) -> boolean, optional; default always true
--   contribution function(ctx) -> { stats = { [stat] = value }, notes = { ... } }
--   explain      function(ctx) -> string, optional
--   allowStack   true to deliberately apply alongside another adjustment that
--                models the same benefit (say why in `stackingReason`)
-- }
function PluginAPI:RegisterAdjustment(pluginId, definition)
    local plugin = self.plugins[pluginId]
    if not plugin then
        return nil, "RegisterAdjustment called for unknown plugin \"" .. tostring(pluginId) .. "\"."
    end

    if type(definition) ~= "table" then
        return nil, "An adjustment must be a table."
    end

    if type(definition.id) ~= "string" or definition.id == "" then
        return nil, "An adjustment needs an id."
    end

    if type(definition.benefit) ~= "string" or definition.benefit == "" then
        return nil, "Adjustment \"" .. definition.id
            .. "\" must declare the benefit it models, so the same effect cannot "
            .. "be applied twice by two different plugins."
    end

    if type(definition.contribution) ~= "function" then
        return nil, "Adjustment \"" .. definition.id .. "\" needs a contribution function."
    end

    local list = self.adjustments[pluginId] or {}
    self.adjustments[pluginId] = list

    for _, existing in ipairs(list) do
        if existing.id == definition.id then
            return nil, "Adjustment id \"" .. definition.id
                .. "\" is already registered by \"" .. pluginId .. "\"."
        end
    end

    local adjustment = {
        id = definition.id,
        pluginId = pluginId,
        title = definition.title or definition.id,
        benefit = definition.benefit,
        priority = tonumber(definition.priority) or 100,
        mode = definition.mode or "additive",
        appliesTo = definition.appliesTo,
        contribution = definition.contribution,
        explain = definition.explain,
        allowStack = definition.allowStack == true,
        stackingReason = definition.stackingReason,
    }

    table.insert(list, adjustment)

    -- Cached effective weights may have been built before this plugin loaded,
    -- so they are dropped rather than left stale.
    if LT.Profiles then LT.Profiles:Invalidate() end

    LT:Fire(LT.EVENT_PLUGINS, { reason = "adjustment_registered", pluginId = pluginId })
    return adjustment
end

------------------------------------------------------------------------------
-- Eligibility
------------------------------------------------------------------------------

function PluginAPI:IsPluginEnabledForBuild(pluginId, buildIndex)
    if LT.Builds and LT.Builds.IsPluginEnabled then
        return LT.Builds:IsPluginEnabled(buildIndex, pluginId)
    end
    return true
end

function PluginAPI:PluginAppliesToClass(plugin, classToken)
    if not plugin.classes then return true end

    for _, class in ipairs(plugin.classes) do
        if class == classToken then return true end
    end

    return false
end

------------------------------------------------------------------------------
-- Running the adjustments
------------------------------------------------------------------------------

local function contributionStats(result)
    if type(result) ~= "table" then return nil end

    if type(result.stats) == "table" then
        return result.stats, result.notes
    end

    -- A bare stat map is accepted too, with any non-numeric entry ignored.
    local stats = {}
    for key, value in pairs(result) do
        if type(value) == "number" then
            stats[key] = value
        end
    end

    return stats, nil
end

-- Deterministic order: priority, then plugin id, then adjustment id.
function PluginAPI:GetOrderedAdjustments(ctx)
    local rows = {}

    for pluginId, list in pairs(self.adjustments) do
        local plugin = self.plugins[pluginId]

        if plugin
            and self:PluginAppliesToClass(plugin, ctx.build and ctx.build.class)
            and self:IsPluginEnabledForBuild(pluginId, ctx.buildIndex) then
            for _, adjustment in ipairs(list) do
                table.insert(rows, adjustment)
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if a.pluginId ~= b.pluginId then return a.pluginId < b.pluginId end
        return a.id < b.id
    end)

    return rows
end

-- ctx = { build, buildIndex, profile, level, weights }
-- Returns adjusted weights plus a full trace of what was applied and skipped.
function PluginAPI:CollectAdjustments(ctx)
    ctx = ctx or {}

    local weights = LT:Copy(ctx.weights or {})
    local trace, limitations, applied, skipped = {}, {}, {}, {}
    local claimed = {}

    if not next(self.plugins) then
        return {
            weights = weights,
            trace = trace,
            limitations = limitations,
            applied = applied,
            skipped = skipped,
            pluginCount = 0,
        }
    end

    for _, adjustment in ipairs(self:GetOrderedAdjustments(ctx)) do
        local plugin = self.plugins[adjustment.pluginId]
        local label = tostring(plugin.name) .. " / " .. tostring(adjustment.title)

        local eligible = true
        if type(adjustment.appliesTo) == "function" then
            local ok, allowed = pcall(adjustment.appliesTo, ctx)
            if not ok then
                eligible = false
                self:RecordError(adjustment.pluginId, label .. ": appliesTo failed — " .. tostring(allowed))
                table.insert(limitations, label .. " could not run (appliesTo failed).")
                table.insert(skipped, { adjustment = adjustment, reason = "appliesTo failed" })
            else
                eligible = allowed == true
            end
        end

        if eligible then
            local ok, contribution = pcall(adjustment.contribution, ctx)

            if not ok then
                self:RecordError(adjustment.pluginId, label .. ": " .. tostring(contribution))
                table.insert(limitations,
                    label .. " failed and was skipped: " .. tostring(contribution))
                table.insert(skipped, { adjustment = adjustment, reason = tostring(contribution) })
            else
                local stats, notes = contributionStats(contribution)

                if not stats or not next(stats) then
                    -- No contribution is a valid answer: the condition simply
                    -- was not met this time.
                    table.insert(skipped, { adjustment = adjustment, reason = "no contribution" })
                else
                    local appliedHere = false

                    for stat, rawValue in pairs(stats) do
                        local value = tonumber(rawValue)
                        if value and value ~= 0 then
                            local claimKey = tostring(stat) .. "|" .. tostring(adjustment.benefit)
                            local already = claimed[claimKey]

                            if already and not adjustment.allowStack then
                                local reason = label .. " models the same benefit as "
                                    .. tostring(already.label) .. " (" .. tostring(adjustment.benefit)
                                    .. ") for " .. LT:Label(stat)
                                    .. ", so it was skipped to avoid counting it twice."
                                table.insert(limitations, reason)
                                table.insert(skipped, { adjustment = adjustment, reason = reason })
                            else
                                claimed[claimKey] = { label = label, adjustment = adjustment }

                                local before = tonumber(weights[stat]) or 0
                                local after

                                if adjustment.mode == "multiplier" then
                                    after = before * (1 + value)
                                else
                                    after = before + value
                                end

                                weights[stat] = after
                                appliedHere = true

                                table.insert(trace, {
                                    stage = "plugin",
                                    stat = stat,
                                    from = before,
                                    value = after,
                                    note = label .. " (" .. adjustment.mode
                                        .. ", benefit " .. tostring(adjustment.benefit) .. ")",
                                    pluginId = adjustment.pluginId,
                                    adjustmentId = adjustment.id,
                                })
                            end
                        end
                    end

                    if appliedHere then
                        local explanation
                        if type(adjustment.explain) == "function" then
                            local okExplain, text = pcall(adjustment.explain, ctx)
                            if okExplain then explanation = text end
                        end

                        table.insert(applied, {
                            pluginId = adjustment.pluginId,
                            adjustmentId = adjustment.id,
                            title = adjustment.title,
                            label = label,
                            benefit = adjustment.benefit,
                            explanation = explanation,
                            notes = notes,
                        })
                    end
                end
            end
        else
            table.insert(skipped, { adjustment = adjustment, reason = "not applicable" })
        end
    end

    return {
        weights = weights,
        trace = trace,
        limitations = limitations,
        applied = applied,
        skipped = skipped,
        pluginCount = (function()
            local count = 0
            for _ in pairs(self.plugins) do count = count + 1 end
            return count
        end)(),
    }
end

function PluginAPI:RecordError(pluginId, message)
    self.errors[pluginId] = self.errors[pluginId] or {}
    table.insert(self.errors[pluginId], tostring(message))
end

function PluginAPI:GetErrors()
    return self.errors
end

function PluginAPI:HasErrors()
    return next(self.errors) ~= nil
end

------------------------------------------------------------------------------
-- What a plugin is allowed to read
--
-- Plugins go through these accessors instead of reaching into core internals,
-- so the core can change its storage without breaking them.
------------------------------------------------------------------------------

function PluginAPI:GetBuildSummary(buildIndex)
    local build = LT.Builds and LT.Builds:Get(buildIndex)
    if not build then return nil end

    return {
        index = build.index,
        name = build.name,
        class = build.class,
        spec = build.spec,
        role = build.role,
        context = build.context,
        weaponSetup = build.weaponSetup,
        profileKey = build.profileKey,
    }
end

function PluginAPI:GetEffectiveWeights(buildIndex)
    local effective = LT.Profiles and LT.Profiles:GetEffective(buildIndex)
    return effective and effective.weights or {}
end

function PluginAPI:RequestItemScore(itemLink, buildIndex)
    if not LT.Score then return nil end
    return LT.Score:ScoreItem(itemLink, buildIndex)
end

function PluginAPI:GetScoringLevel()
    return LT.Levels and LT.Levels:GetScoringLevel() or 1
end

function PluginAPI:GetClassOptions(buildIndex)
    local effective = LT.Profiles and LT.Profiles:GetEffective(buildIndex)
    local profile = effective and effective.profile
    return profile and profile.classOptions or {}
end

-- Plugins report anything they cannot model; the core surfaces it on tooltips
-- and in the plugin page rather than letting it disappear.
function PluginAPI:ReportUnsupported(pluginId, message)
    self:RecordError(pluginId, "unsupported: " .. tostring(message))
end

-- Change notifications. Events fired by the core:
--   BUILDS_CHANGED, PROFILE_CHANGED, EFFECTIVE_WEIGHTS_REBUILT,
--   GEARSET_CHANGED, LEVEL_CHANGED, PLUGINS_CHANGED, TALENTS_CHANGED
function PluginAPI:On(eventName, fn, pluginId)
    return LT:On(eventName, fn, pluginId or "plugin")
end