------------------------------------------------------------------------------
-- Lunchbox Toolkit — fishing bite alert
--
-- The moment a fish bites: "Check Lure Now" and a short screen flash. No
-- option, by request (2026-11-05).
--
-- How the bite is recognised, from the client probe on 2026-11-05:
--   * FISHING_BOBBER is NOT a valid event on Forever;
--   * FishingBobber / GetFishingBobber / C_Fishing do not exist;
--   * LOOT_READY IS valid, and UnitChannelInfo("player") reports "Fishing"
--     while the cast runs.
--
-- So: LOOT_READY fires when the bobber becomes lootable, which is the bite, and
-- the fishing context (channel name, or a recent Fishing cast) keeps corpse and
-- chest loot out of it. LOOT_OPENED disarms, so the loot window itself never
-- announces anything - it opens after the fish is already landed.
------------------------------------------------------------------------------

local LT = LunchboxToolkit
if type(LT) ~= "table" then return end

local Fishing = {}
LT.Fishing = Fishing
if type(LT.Modules) == "table" then LT.Modules.Fishing = Fishing end

local ARMED_SECONDS = 30
local armedUntil = 0

local function now()
    if type(GetTime) ~= "function" then return 0 end
    local ok, value = pcall(GetTime)
    if ok and tonumber(value) then return tonumber(value) end
    return 0
end

local function channelName()
    if type(UnitChannelInfo) ~= "function" then return nil end
    local ok, name = pcall(UnitChannelInfo, "player")
    if ok and type(name) == "string" then return name end
    return nil
end

local function isFishingContext()
    if channelName() == "Fishing" then return true end
    if type(IsFishingLoot) == "function" then
        local ok, fishing = pcall(IsFishingLoot)
        if ok and fishing == true then return true end
    end
    return now() < armedUntil
end

Fishing.IsBiteContext = isFishingContext

------------------------------------------------------------------------------
-- The flash and the line
------------------------------------------------------------------------------

local flashFrame
local floats = {}

local function ensureFlash()
    if flashFrame then return flashFrame end

    -- No name and no frame: a plain texture on UIParent, OVERLAY layer. A named
    -- frame on FULLSCREEN strata drew behind this client's own frames, and this
    -- is the smallest thing that cannot be hidden by them (report 2026-11-05).
    if type(UIParent) ~= "table" and type(UIParent) ~= "userdata" then return nil end
    if type(UIParent.CreateTexture) ~= "function" then return nil end

    local ok, texture = pcall(UIParent.CreateTexture, UIParent, nil, "OVERLAY")
    if not ok or not texture then return nil end
    if type(texture.SetAllPoints) ~= "function" then return nil end

    pcall(texture.SetAllPoints, texture, UIParent)
    pcall(texture.SetColorTexture, texture, 1.00, 0.95, 0.65, 0)
    pcall(texture.Hide, texture)

    flashFrame = { texture = texture, elapsed = 0 }
    return flashFrame
end

local driver

-- The wash is a texture; the animation needs a frame with OnUpdate, so one
-- unnamed driver frame does the counting for it.
local function flash()
    local holder = ensureFlash()
    if not holder then
        if type(LT.Diag) == "function" then
            pcall(LT.Diag, LT, "fishing: no texture could be created on UIParent")
        end
        return false
    end

    if not driver then
        local ok, frame = pcall(CreateFrame, "Frame", nil, UIParent)
        if ok and frame then
            driver = frame
            pcall(driver.EnableMouse, driver, false)
            -- OnUpdate does not run on a hidden frame: without this the alpha
            -- animation never fired and the wash stayed at zero (report
            -- 2026-11-05: "no flash, only the sct line").
            pcall(driver.Show, driver)
        end
    end

    local texture = holder.texture
    holder.elapsed = 0
    pcall(texture.Show, texture)
    pcall(texture.SetAlpha, texture, 0)

    if not driver then
        pcall(texture.SetAlpha, texture, 0.45)
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            pcall(C_Timer.After, 0.5, function() pcall(texture.SetAlpha, texture, 0) end)
        end
        return true
    end

    driver:SetScript("OnUpdate", function(_, delta)
        holder.elapsed = holder.elapsed + (delta or 0)

        local t = holder.elapsed
        local alpha
        if t < 0.15 then
            alpha = (t / 0.15) * 0.55
        elseif t < 0.40 then
            alpha = 0.55 * (1 - ((t - 0.15) / 0.25) * 0.6)
        elseif t < 0.55 then
            alpha = 0.22 + (t - 0.40) / 0.15 * 0.20
        elseif t < 0.80 then
            alpha = 0.42 * (1 - (t - 0.55) / 0.25)
        else
            alpha = 0
            pcall(texture.Hide, texture)
            driver:SetScript("OnUpdate", nil)
        end

        pcall(texture.SetAlpha, texture, alpha)
    end)
    return true
end

local function float(text)
    local ok, frame = pcall(CreateFrame, "Frame", nil, UIParent)
    if not ok or not frame then return end

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    if not label then return end

    label:SetText(text)
    label:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    label:SetTextColor(1.00, 0.90, 0.40)
    label:SetShadowColor(0, 0, 0, 1)
    label:SetShadowOffset(1, -1)
    frame:SetFrameStrata("TOOLTIP")

    frame.elapsed = 0
    frame.label = label
    frame:SetScript("OnUpdate", function(self, delta)
        self.elapsed = self.elapsed + (delta or 0)
        local lift = 34 * math.min(1, self.elapsed / 1.2)
        local alpha = math.max(0, 1 - (self.elapsed / 2.0))
        self.label:SetPoint("CENTER", UIParent, "CENTER", 0, 150 + lift)
        self.label:SetAlpha(alpha)
        if self.elapsed >= 2.0 then
            self:Hide()
            self:SetScript("OnUpdate", nil)
        end
    end)

    table.insert(floats, frame)
    while #floats > 5 do
        local old = table.remove(floats, 1)
        if old then pcall(old.Hide, old) end
    end
end

function Fishing:Bite(verbose)
    local drewFlash = flash()
    float("Check Lure Now")
    if verbose and type(LT.Print) == "function" then
        pcall(LT.Print, LT, drewFlash
            and "Bite alert drawn: flash and text."
            or "Bite alert: text drawn, but no flash texture could be created.")
    end
    return drewFlash
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------

do
    local ok, listener = pcall(CreateFrame, "Frame", nil, UIParent)
    if ok and listener then
        for _, event in ipairs({ "LOOT_READY", "LOOT_OPENED",
            "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_CHANNEL_START",
            "PLAYER_ENTERING_WORLD" }) do
            pcall(listener.RegisterEvent, listener, event)
        end

        listener:SetScript("OnEvent", function(_, event, unit, spellName)
            if event == "PLAYER_ENTERING_WORLD" then
                armedUntil = 0
                return
            end

            if event == "UNIT_SPELLCAST_SUCCEEDED" then
                if tostring(unit) ~= "player" then return end
                if type(spellName) == "string" and spellName == "Fishing" then
                    armedUntil = now() + ARMED_SECONDS
                end
                return
            end

            if event == "UNIT_SPELLCAST_CHANNEL_START" then
                if tostring(unit) ~= "player" then return end
                if type(spellName) == "string" and spellName == "Fishing" then
                    armedUntil = now() + ARMED_SECONDS
                end
                return
            end

            if event == "LOOT_READY" then
                -- On this client LOOT_READY fires at the CLICK, not at the bite
                -- (player report 2026-11-05), so it must not announce. The
                -- fishing channel events are being traced to find the real one.
                return
            end

            if event == "LOOT_OPENED" then
                armedUntil = 0
            end
        end)
    end
end

-- /lt bitetest: draw the alert without a fish.
local function registerCommand()
    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then
        return false
    end
    local ok = pcall(slash.RegisterCommand, slash, "bitetest",
        function() Fishing:Bite(true) end,
        "/lt bitetest — draw the fishing bite alert (flash + Check Lure Now)")
    return ok
end

do
    if not registerCommand() then
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            pcall(C_Timer.After, 1, registerCommand)
        end
    end
end
