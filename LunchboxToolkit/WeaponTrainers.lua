------------------------------------------------------------------------------
-- Lunchbox Toolkit — weapon trainer hint
--
-- Entering a city that has a weapon master who can teach a type this character
-- has never trained raises one toast, once per city per session:
--
--     Weapon training here: Staves, Fist Weapons
--
-- Data only from what the addon already owns: Usability.TRAINERS names the
-- trainer and the city, Usability.WEAPON_SUBCLASS maps the item type, and the
-- client answers whether the character knows the skill (KnowsProficiency). No
-- trainer list is duplicated here, so a corrected zone moves the hint with it.
--
-- Nothing is shown for a type the class can never use, for a type already
-- trained, or for a city with nothing to teach this character.
------------------------------------------------------------------------------

local LT = LunchboxToolkit
if type(LT) ~= "table" then return end

local WeaponTrainers = {}
LT.WeaponTrainers = WeaponTrainers
if type(LT.Modules) == "table" then LT.Modules.WeaponTrainers = WeaponTrainers end

local shownThisSession = {}

local function optionOn()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then return false end
    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then return false end
    return options.weaponTrainerHint ~= false
end

-- key -> subclass id, derived from the same table the verdict engine reads.
local function subclassKeys()
    local out = {}
    local table_ = LT.Usability and LT.Usability.WEAPON_SUBCLASS
    if type(table_) ~= "table" then return out end
    for sub, key in pairs(table_) do
        if type(key) == "string" then out[key] = sub end
    end
    return out
end

local function currentZones()
    local zones = {}
    for _, name in ipairs({ "GetZoneText", "GetRealZoneText", "GetSubZoneText" }) do
        local fn = _G[name]
        if type(fn) == "function" then
            local ok, text = pcall(fn)
            if ok and type(text) == "string" and text ~= "" then
                zones[#zones + 1] = text
            end
        end
    end
    return zones
end

local function cityOf(zone)
    if type(zone) ~= "string" then return "" end
    local city = zone:match("([^,]+)$") or zone
    return (city:gsub("^%s+", ""))
end

-- The weapon types this character can use but has not trained, at this city.
local function untrainedHere(city)
    local usability = LT.Usability
    local faction = LT.player and LT.player.faction
    local classToken = LT.player and LT.player.class
    local level = LT.player and LT.player.level
    if type(usability) ~= "table" or type(faction) ~= "string" then return nil end

    local byFaction = usability.TRAINERS and usability.TRAINERS[faction] or nil
    if type(byFaction) ~= "table" then return nil end

    local wanted = city:lower()
    local names = {}

    for key, sub in pairs(subclassKeys()) do
        local verdict = usability:Classify({
            classID = usability.ITEM_CLASS_WEAPON,
            subClassID = sub,
        }, classToken, level)

        -- Only a type the pack says the class can use; "never" and unknown are
        -- both silent here, because neither is something training fixes today.
        if type(verdict) == "table" and verdict.verdict == usability.USABLE
            and usability:KnowsProficiency(key) == false then
            local entries = byFaction[key]
            if type(entries) == "table" then
                for _, entry in ipairs(entries) do
                    if cityOf(entry.zone):lower() == wanted then
                        names[#names + 1] = usability:GetLabel(key)
                        break
                    end
                end
            end
        end
    end

    return names
end

-- Professions the city teaches and this character has not learned. The spellbook
-- holds a learned profession as a passive, so KnowsSpellName answers "learned"
-- without a profession API.
local PROFESSIONS = { "Skinning", "Mining" }

local function untrainedProfessionsHere(city)
    local usability = LT.Usability
    local faction = LT.player and LT.player.faction
    if type(usability) ~= "table" or type(usability.GetProfessionTraining) ~= "function" then
        return nil
    end

    local names = {}
    for _, profession in ipairs(PROFESSIONS) do
        local known = type(usability.KnowsSpellName) == "function"
            and usability:KnowsSpellName(profession) or nil
        if known ~= true then
            local entries = usability:GetProfessionTraining(profession, faction)
            for _, entry in ipairs(entries or {}) do
                if cityOf(entry.zone):lower() == city:lower() then
                    names[#names + 1] = profession
                    break
                end
            end
        end
    end

    return names
end

function WeaponTrainers:Check()
    if not optionOn() then return false end

    local toasts = LT.Toasts
    if type(toasts) ~= "table" or type(toasts.Show) ~= "function" then return false end

    for _, zone in ipairs(currentZones()) do
        if not shownThisSession[zone] then
            local names = untrainedHere(zone) or {}
            for _, profession in ipairs(untrainedProfessionsHere(zone) or {}) do
                names[#names + 1] = profession
            end

            if #names > 0 then
                local shown = names
                if #names > 3 then
                    shown = {}
                    for index = 1, 3 do shown[index] = names[index] end
                end

                local text = table.concat(shown, ", ")
                if #names > 3 then text = text .. " and " .. tostring(#names - 3) .. " more" end

                shownThisSession[zone] = true
                pcall(toasts.Show, toasts, "trainer", "Training here: " .. text)
                return true
            end
        end
    end

    return false
end

function WeaponTrainers:Report()
    if type(LT.Print) ~= "function" then return end

    local usability = LT.Usability
    local faction = LT.player and LT.player.faction

    LT:Print("Weapon trainer check — option " .. (optionOn() and "on" or "off")
        .. ", faction " .. tostring(faction or "?"))

    for _, zone in ipairs(currentZones()) do
        LT:Print("  zone: " .. zone)
    end

    local byFaction = usability and usability.TRAINERS and usability.TRAINERS[faction] or nil
    if type(byFaction) ~= "table" then
        LT:Print("  no trainer table for this faction")
        return
    end

    for key, sub in pairs(subclassKeys()) do
        local verdict = usability:Classify({
            classID = usability.ITEM_CLASS_WEAPON,
            subClassID = sub,
        }, LT.player and LT.player.class, LT.player and LT.player.level)

        local known = usability:KnowsProficiency(key)
        local cities = {}
        for _, entry in ipairs(byFaction[key] or {}) do
            cities[#cities + 1] = cityOf(entry.zone)
        end

        if (type(verdict) == "table" and verdict.verdict == usability.USABLE) or known ~= nil then
            LT:Print("  " .. usability:GetLabel(key)
                .. ": verdict=" .. tostring(verdict and verdict.verdict)
                .. " known=" .. tostring(known)
                .. " trainers=" .. (#cities > 0 and table.concat(cities, ", ") or "none"))
        end
    end

    if self:Check() then
        LT:Print("  a hint was shown just now")
    else
        LT:Print("  no hint shown for this zone")
    end
end

-- /lt trainhere: the same check, with its reasoning printed. Registered late
-- because Slash.lua loads after this file.
local function registerCommand()
    local slash = LT.Slash
    if type(slash) ~= "table" or type(slash.RegisterCommand) ~= "function" then return false end
    local ok = pcall(slash.RegisterCommand, slash, "trainhere",
        function() WeaponTrainers:Report() end,
        "/lt trainhere — explain the weapon trainer hint for the current zone")
    return ok
end

do
    if not registerCommand() then
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            pcall(C_Timer.After, 1, registerCommand)
        end
    end
end

do
    local ok, listener = pcall(CreateFrame, "Frame", nil, UIParent)
    if ok and listener then
        for _, event in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA",
            "ZONE_CHANGED_INDOORS", "PLAYER_ENTERING_WORLD" }) do
            pcall(listener.RegisterEvent, listener, event)
        end

        listener:SetScript("OnEvent", function()
            -- A zone change fires three events at once; one check, a moment later,
            -- when the client has settled on the new zone name.
            if WeaponTrainers.pending then return end
            WeaponTrainers.pending = true

            local function run()
                WeaponTrainers.pending = false
                WeaponTrainers:Check()
            end

            if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
                pcall(C_Timer.After, 1.5, run)
            else
                run()
            end
        end)
    end
end
