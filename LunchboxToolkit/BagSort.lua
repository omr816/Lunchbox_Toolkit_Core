--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — BagSort

    One job: ask the client to sort a container set, and say plainly what it did.

    It calls the client's own sort — `C_Container.SortBags` for the bags, then
    `C_Container.SortBank(Enum.BankType.Character)` or the legacy `SortBankBags`
    for the bank. Nothing here moves an item itself: no PickupContainerItem, no
    slot juggling, no swap loop. FirstStrike, a shipped Forever addon, sorts with
    `C_Container.SortBags` alone, which is why that route comes first; every other
    route is a fallback and a client with none of them is told so instead of
    being guessed at.

    Why the option exists: sorting rearranges the player's bags, so it starts OFF
    and refuses until it is switched on in Settings. The switch and the command
    read the same stored key.

    Commands
      /lt sort bags    sort the backpack and the equipped bags
      /lt sort bank    sort the bank (the bank must be open for the client to move)
      /lt sort all     bags first, then the bank
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local BagSort = {}
LT.BagSort = BagSort
LT.Modules.BagSort = BagSort

BagSort.SCOPES = { bags = true, bank = true, all = true }

local function combatLocked()
    if type(InCombatLockdown) ~= "function" then return false end
    local ok, locked = pcall(InCombatLockdown)
    return ok and locked == true
end

-- Off by default, so the first `/lt sort` in a fresh install is a message, not a
-- rearranged bag.
local function allowed()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return false
    end

    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then return false end
    return options.bagSortEnabled == true
end

-- Which frames the bag marks belong on (L-17 / T-137). One table owns the
-- default (Database.defaultOptions); this file reads the live value and never
-- keeps a second copy. Anything but the two known words reads as "client", so
-- an older record keeps today's behaviour.
function BagSort:BagFrames()
    local database = LT.Database
    if type(database) ~= "table" or type(database.GetOptions) ~= "function" then
        return "client"
    end

    local ok, options = pcall(database.GetOptions, database)
    if not ok or type(options) ~= "table" then return "client" end
    if options.bagFrames == "replacement" then return "replacement" end
    return "client"
end

-- True when a replacement addon draws the bags and this one must leave them be.
function BagSort:UsesReplacementBags()
    return self:BagFrames() == "replacement"
end

-- Bagnon / Baganator take the bag frames over. The addon still works, but its
-- bag marks cannot land on frames nobody sees, so the player is told once which
-- addon owns them and that the switch exists. Same guarded lookup as Core.lua's
-- PLAYER_LOGIN diagnostic (which stays: this is the player-facing line, that one
-- is the developer diagnostic).
local replacementNoticed = false

local function loadedBagReplacement()
    local lookup
    if type(C_AddOns) == "table" and type(C_AddOns.IsAddOnLoaded) == "function" then
        lookup = C_AddOns.IsAddOnLoaded
    elseif type(IsAddOnLoaded) == "function" then
        lookup = IsAddOnLoaded
    end
    if lookup == nil then return nil end

    for _, name in ipairs({ "Bagnon", "Baganator" }) do
        local ok, loaded = pcall(lookup, name)
        if ok and loaded == true then return name end
    end
    return nil
end

local function noteBagReplacement()
    if replacementNoticed then return end

    local replacement = loadedBagReplacement()
    if not replacement then return end

    replacementNoticed = true
    if type(LT.Print) == "function" then
        pcall(LT.Print, LT, replacement .. " draws the bags — the \"Bag frames\" "
            .. "setting (client | replacement) says whether this addon annotates "
            .. "the client's own bags or leaves them to it.")
    end
end

-- At load the addon is already in the list, but a replacement may load after
-- this file; PLAYER_LOGIN asks again and the flag keeps it to one line.
noteBagReplacement()

function BagSort:OnPlayerLogin()
    noteBagReplacement()
end

-- The client call for one container set, or nil and the reason it is missing.
local function sorter(scope)
    if scope == "bags" then
        if type(C_Container) == "table" and type(C_Container.SortBags) == "function" then
            return function() return C_Container.SortBags() end
        end
        if type(SortBags) == "function" then
            return function() return SortBags() end
        end
        return nil, "this client has no bag sort function"
    end

    if type(C_Container) == "table" and type(C_Container.SortBank) == "function" then
        local bankType = type(Enum) == "table" and type(Enum.BankType) == "table"
            and Enum.BankType.Character or nil
        if bankType then
            return function() return C_Container.SortBank(bankType) end
        end
    end

    if type(SortBankBags) == "function" then
        return function() return SortBankBags() end
    end

    return nil, "this client has no bank sort function"
end

-- Returns ok, a sentence for the player, and whether the bank was involved.
function BagSort:Run(scope)
    local wanted = tostring(scope or "bags"):lower()

    if not self.SCOPES[wanted] then
        return false, "usage: /lt sort bags|bank|all"
    end

    if combatLocked() then
        return false, "not while you are in combat: the client will not move items mid-fight"
    end

    if not allowed() then
        return false, "bag sorting is off. Settings → Window → \"Allow /lt sort to move bag items\""
    end

    -- Order mode: our own comparator and swap loop (BagOrder), which reproduces
    -- the BankStack ordering. Default is still the client's own sort.
    local order = LT.BagOrder
    if type(order) == "table" and type(order.Plan) == "function"
        and type(order.Mode) == "function" and order:Mode() == "order" then
        local plan, why = order:Plan(wanted)
        if not plan then return false, tostring(why) end
        local ok, message = order:Apply(plan)
        return ok, tostring(message)
    end

    local queue = { wanted }
    if wanted == "all" then queue = { "bags", "bank" } end

    local done, refused = {}, {}
    for _, part in ipairs(queue) do
        local run, why = sorter(part)
        if not run then
            refused[#refused + 1] = why
        else
            local ok, result = pcall(run)
            if ok and result ~= false then
                done[#done + 1] = part
            else
                refused[#refused + 1] = part .. ": the client refused the sort"
            end
        end
    end

    if #done == 0 and #refused > 0 then
        return false, table.concat(refused, "; ")
    end

    local sentence = "Sorted the " .. table.concat(done, " and ") .. "."
    if #refused > 0 then
        sentence = sentence .. " " .. table.concat(refused, "; ")
        if refused[1] and refused[1]:find("bank", 1, true) then
            sentence = sentence .. " The bank sorting needs the bank open."
        end
    end

    return #done > 0, sentence
end

function BagSort:Preview(scope)
    local order = LT.BagOrder
    if type(order) ~= "table" or type(order.Plan) ~= "function" then
        return false, "the bag order module is not loaded"
    end

    local plan, why = order:Plan(tostring(scope or "bags"):lower())
    if not plan then return false, tostring(why) end

    for _, line in ipairs(order:Describe(plan)) do
        if type(LT.Print) == "function" then pcall(LT.Print, LT, line) end
    end
    return true, ""
end

function BagSort:Command(words)
    local action = words and words[2]
    local extra = words and words[3]

    if action == "preview" then
        local ok, sentence = self:Preview(extra or "bags")
        if not ok and type(LT.Print) == "function" then
            pcall(LT.Warn or LT.Print, LT, sentence)
        end
        return ok
    end

    if action == "mode" then
        local order = LT.BagOrder
        local mode = tostring(extra or ""):lower()
        if type(order) ~= "table" or (mode ~= "client" and mode ~= "order") then
            if type(LT.Print) == "function" then
                pcall(LT.Warn or LT.Print, LT, "usage: /lt sort mode client|order")
            end
            return false
        end
        order:SetMode(mode)
        if type(LT.Print) == "function" then
            pcall(LT.Print, LT, "Bag sort order: " .. mode
                .. (mode == "order" and " (BankStack-style, our own code)" or ""))
        end
        return true
    end

    if action == "reverse" then
        local order = LT.BagOrder
        if type(order) ~= "table" then return false end
        local value = tostring(extra or ""):lower()
        local on
        if value == "on" then on = true
        elseif value == "off" then on = false
        else on = not order:Reverse() end
        order:SetReverse(on)
        if type(LT.Print) == "function" then
            pcall(LT.Print, LT, "Reverse order: " .. (on and "on" or "off"))
        end
        return true
    end

    local scope = action
    if scope == nil then
        -- No word: bags, which is what "sort" means to a player with a full bag.
        scope = "bags"
    end

    local ok, sentence = self:Run(scope)
    if type(LT.Print) == "function" then
        if ok then
            pcall(LT.Print, LT, sentence)
        else
            pcall(LT.Warn or LT.Print, LT, sentence)
        end
    end
    return ok
end

-- Registered here rather than in Slash.lua's own table, and this file loads after
-- Slash.lua in both TOCs, so the word exists by the time the player types it.
do
    local slash = LT.Slash
    if type(slash) == "table" and type(slash.RegisterCommand) == "function" then
        pcall(slash.RegisterCommand, slash, "sort",
            function(words) BagSort:Command(words) end,
            "/lt sort [bags|bank|all] | preview | mode client|order | reverse on|off — sort, preview the order, choose the client's sort or the BankStack-style order, or flip it (Settings switch first)")
    end
end
