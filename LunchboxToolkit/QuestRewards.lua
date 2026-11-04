--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — QuestRewards
    Marks quest rewards for the active build by upgrade rank, and marks the
    reward worth the most to a merchant with the coin.

    Each choice / reward item is compared with the slot it would replace using
    exactly the same call the tooltip uses (Compare:ForBuild), so the outlined
    item and the score printed on its tooltip can never disagree: hover any
    reward for its own number, hold shift for the stat-level reason.

    Colours, in the order they are decided:
      green   usable later: the class can wear it eventually, but not at this level,
              so the reward is an upgrade the player cannot act on yet
      purple  the biggest upgrade the character can use now
      blue    the second biggest of those, only when there are two or more
      gold    the border for the most profitable reward when it has no colour above
              of its own -- money, the one answer a border colour alone can carry
              only with the coin glyph beside it

    Green is decided before the ranking, and that is deliberate: a deferred reward
    is kept out of the purple/blue race rather than being called second best, so
    the two best borders always mean "wear this now". A reward the player cannot
    equip until level 40 is a green icon, not a blue one (player's request,
    2026-10-27: a usable belt purple, untrained-mail gloves green).

    Gold also carries the coin glyph on its border. Purple, blue, green and gold
    answer different questions, so they can appear together in one reward window:
    the coin is what marks the gold one as money rather than as a verdict on the
    item. Gold does not wait for "nothing here is an upgrade": a reward that is
    usable but not an upgrade is otherwise left uncoloured, and the most profitable
    of those is a real answer at the reward window ("take it and sell it").

    The border hugs the item's icon inside the button, not the button itself: a
    reward button is a wide bar with the icon at one end and the item's name beside
    it, and a border around the bar says nothing about the item. See the Outline
    section for how the icon is found.

    The coin is a marker, not a colour (player's ruling, 2026-10-27). The single
    most profitable reward carries it whatever border that reward already has, so
    one icon can be purple *and* carry the coin: "wear this" and "this is the one
    worth the most to a vendor" are both true and do not compete. Gold is used for
    the border only when the most profitable reward has no verdict border at all.

    The coin is refused outright in the quest log: a button whose own name starts
    "QuestLog", or one found by walking the log's panes, is never asked for a price
    at all. The log is where a choice is re-read, not made, so money stays out of
    it while the verdict border and the tooltip are left exactly as they are.

    A verdict border for the active build can still mean something for the other
    build: when Compare:ForAllBuilds says the second build slot wins the reward but
    the active one does not, a small "2" is drawn in the icon's corner. That glyph
    takes an existing chrome colour from the palette (never a verdict hue) and
    disappears with the border it belongs to.

    A reward that ties, loses, or cannot be evaluated stays unranked.

    Each behaviour has its own switch in Settings (questRewardHighlight is the
    master switch, questRewardRanking and questVendorFallback refine it), so a
    player who only wants the single best border can turn the rest off.

    Everything here is optional: if the client's quest frames or quest item API
    are not where this expects, /lt quest reports that instead of raising an
    error, and no other part of the addon is affected.
--------------------------------------------------------------------------]]

local LT = LunchboxToolkit

local QuestRewards = {}
LT.QuestRewards = QuestRewards
LT.Modules.QuestRewards = QuestRewards

-- Colours carry the meaning instead of decorating it: green is the reward the
-- character cannot use yet, purple the best upgrade it can use now, blue the
-- second, and gold is the vendor fallback. Purple and blue are the client's own
-- quality hues, chosen because that ladder is the one a player already reads — see
-- the legend window — not because a border claims a quality the item does not have.
--
-- All four come from the palette, by identity, so the reward window, the tooltip
-- and the legend cannot drift apart. Gold also carries the coin glyph on the
-- border (see applyOutline): that glyph is what separates "money" from "a
-- verdict", since gold and the palette's yellow sit close together on a warm
-- monitor.
local OUTLINE_SIZE = 2

local COLOURS = {
    deferred      = LT.Palette.verdict.caution, -- green: usable later, not now
    upgradeBest   = LT.Palette.verdict.go,      -- purple: biggest upgrade usable now
    upgradeSecond = LT.Palette.verdict.good,    -- blue: second biggest of those
    vendor        = LT.Palette.verdict.money,   -- gold: money, for a border that has no verdict
}

-- Exposed for the self test, which checks these are the palette's own tables.
QuestRewards.colours = COLOURS

local watchedEvents = {
    "QUEST_DETAIL",
    "QUEST_PROGRESS",
    "QUEST_COMPLETE",
    "QUEST_ACCEPTED",
    "QUEST_FINISHED",
    "QUEST_LOG_UPDATE",
    "QUEST_UPDATE",
    "QUEST_ITEM_UPDATE",
    -- The client fetches item data lazily, so the reward buttons can exist before
    -- their links do. Waiting for the data and looking again is the difference
    -- between "no border" and a border a moment later.
    "GET_ITEM_INFO_RECEIVED",
    "ITEM_DATA_LOAD_RESULT",
}

local activeReward = nil      -- { button = frame, link = ..., difference = n }

-- Every button this module has bordered, held weakly so a recycled frame is
-- never kept alive by the bookkeeping. Refresh clears these as well as the
-- buttons it can see now, so a reward that has left the pane cannot keep a stale
-- border after the player changes a setting (C2/G2).
local highlighted = setmetatable({}, { __mode = "k" })

-----------------------------------------------------------------------------
-- Reading a reward button
--
-- Quest reward buttons differ between client builds. Nothing here assumes one
-- shape: each known way of asking a button for its item link is tried in turn,
-- and a button that answers none of them is simply not evaluated.
-----------------------------------------------------------------------------

-- The (type, index) pair a quest item button answers to. Classic builds keep both
-- on the button; a client that keeps only one is still read, because the button's
-- global name ends in its position ("...Reward3" is the third reward). The two
-- lists are "choice" (pick one of these) and "reward" (given as well), and a
-- button that carries no type cannot say which list it came from.
local function itemPosition(button)
    if type(button) ~= "table" then return nil, nil end

    local index = nil

    if type(button.index) == "number" and button.index > 0 then
        index = button.index
    end

    if not index and type(button.GetID) == "function" then
        local ok, id = pcall(button.GetID, button)
        if ok and type(id) == "number" and id > 0 then index = id end
    end

    if not index and type(button.GetName) == "function" then
        local ok, name = pcall(button.GetName, button)
        if ok and type(name) == "string" then
            index = tonumber(name:match("(%d+)$"))
        end
    end

    local kind = nil
    if type(button.type) == "string" and button.type ~= "" then
        kind = button.type
    end

    return kind, index
end

-- The quest log re-uses the same reward buttons as the quest giver's window, and
-- only the client's own view flag says which pane is being looked at. Its links
-- are kept apart from the giver's, so the read has to know where it is.
local function isQuestLogView()
    return type(QuestInfoFrame) == "table" and QuestInfoFrame.questLog and true or false
end

-- A button that lives in the quest log's own pane answers the log's call whatever
-- the view flag says, and asking the wrong pane's question would hand back the
-- log's selected quest while the pointer is on the giver's window. The name is
-- the only thing a button can be asked that says where it lives.
local function livesInQuestLog(button)
    if type(button) ~= "table" or type(button.GetName) ~= "function" then return false end

    local ok, name = pcall(button.GetName, button)
    return ok and type(name) == "string" and name:find("^QuestLog") ~= nil
end

-- A reward button may be named after the shared QuestInfoRewardsFrame while
-- sitting under QuestLogDetailScrollFrame (the log's own pane). Its name starts
-- with neither "QuestLog" nor "QuestInfoFrame", so the parent chain is the only
-- honest answer. The giver's window has the same QuestInfoRewardsFrame name, so
-- only a QuestLog ancestor counts.
local function underQuestLog(button)
    if type(button) ~= "table" or type(button.GetParent) ~= "function" then return false end

    local current = button
    for _ = 1, 8 do
        local ok, parent = pcall(current.GetParent, current)
        if not ok or type(parent) ~= "table" then return false end

        local okName, name = pcall(parent.GetName, parent)
        if okName and type(name) == "string" and name:find("^QuestLog") then
            return true
        end

        current = parent
    end

    return false
end

-- The coin is refused in the quest-log reward pane, where a choice is re-read
-- rather than made; the turn-in/giver window keeps it. A frame found by walking
-- the log's panes is in the log even when its own name does not start "QuestLog",
-- so the walked set is the reliable test, with the name prefix as a cheap first
-- pass for a pane the walk did not reach.
local function coinRefusal(button, walkedSet)
    local name = type(button) == "table" and button.GetName
        and (pcall(button.GetName, button) and button:GetName()) or nil

    if type(name) == "string" and name:find("^QuestLog") then return true end
    if type(walkedSet) == "table" and walkedSet[button] then return true end
    return nil
end

QuestRewards.CoinRefusal = coinRefusal

local function linkFromButton(button)
    if type(button) ~= "table" then return nil end

    local kind, index = itemPosition(button)

    -- 1. The classic quest item buttons store type + index and answer through the
    --    client: GetQuestLogItemLink in the quest log, GetQuestItemLink elsewhere.
    --    Both lists are asked, because a button with only an index cannot say
    --    which one it belongs to and an empty answer costs nothing. This is the
    --    read that has to work on Classic builds, where the button is neither an
    --    ItemButton nor carrying a link of its own, and the quest log route is
    --    the one a working Forever addon uses for its own reward pane.
    if index and (isQuestLogView() or livesInQuestLog(button))
        and type(GetQuestLogItemLink) == "function" then
        local questID = button.questID
        local ok, link = pcall(GetQuestLogItemLink, kind or "choice", index, questID)

        if ok and type(link) == "string" and link ~= "" and not LT:IsSecret(link) then
            return link
        end

        ok, link = pcall(GetQuestLogItemLink, kind or "choice", index)

        if ok and type(link) == "string" and link ~= "" and not LT:IsSecret(link) then
            return link
        end
    end

    if type(GetQuestItemLink) == "function" then
        if index then
            local kinds = {}

            if kind then
                table.insert(kinds, kind)
                table.insert(kinds, kind == "choice" and "reward" or "choice")
            else
                table.insert(kinds, "choice")
                table.insert(kinds, "reward")
            end

            for _, candidate in ipairs(kinds) do
                local ok, link = pcall(GetQuestItemLink, candidate, index)

                if ok and type(link) == "string" and link ~= "" and not LT:IsSecret(link) then
                    return link
                end
            end
        end
    end

    -- 2. Item-button style GetItem().
    if type(button.GetItem) == "function" then
        local ok, _, link = pcall(button.GetItem, button)
        if ok and type(link) == "string" and not LT:IsSecret(link) then
            return link
        end
    end

    -- 3. A link the button carries itself, whichever field name it used.
    for _, field in ipairs({ "link", "hyperlink", "itemLink", "lootLink" }) do
        local value = button[field]
        if type(value) == "string" and value ~= "" and not LT:IsSecret(value) then
            return value
        end
    end

    -- 4. A data table the button was populated from (retail shape).
    local info = button.info
    if type(info) == "table" then
        for _, field in ipairs({ "hyperlink", "itemLink", "link" }) do
            local value = info[field]
            if type(value) == "string" and value ~= "" and not LT:IsSecret(value) then
                return value
            end
        end

        if info.itemID then
            return "item:" .. tostring(info.itemID)
        end
    end

    -- 5. An item ID is enough for C_Item to answer; the client resolves it.
    local itemID = button.itemID or (type(button.id) == "number" and button.id) or nil
    if itemID then
        return "item:" .. tostring(itemID)
    end

    return nil
end

-- The tooltip module asks the same question when a pane fills a tooltip without
-- handing it a link: the button under the pointer is then the only source, and it
-- has to be asked the same way here and there.
QuestRewards.LinkFromButton = linkFromButton

-- "item:12345" is not a hyperlink the client's tooltip API accepts, so it is
-- resolved to a real one where the client can do it, and dropped where it
-- cannot. Nothing is invented from an ID alone.
local function resolveLink(raw)
    if type(raw) ~= "string" or raw == "" then return nil end
    if not raw:match("^item:") then return raw end

    local itemID = tonumber(raw:match("^item:(%d+)$"))
    if not itemID then return nil end

    -- Both the numeric and the "item:ID" string form are tried, because which
    -- one a client build accepts is not consistent.
    local attempts = { itemID, "item:" .. tostring(itemID) }

    for _, argument in ipairs(attempts) do
        if type(GetItemInfo) == "function" then
            local ok, _, link = pcall(GetItemInfo, argument)
            if ok and type(link) == "string" then return link end
        end

        if type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function" then
            local ok, _, link = pcall(C_Item.GetItemInfo, argument)
            if ok and type(link) == "string" then return link end
        end
    end

    return nil
end

QuestRewards.ResolveLink = resolveLink

-----------------------------------------------------------------------------
-- Outline
--
-- A plain overlay with four thin textures. Nothing on the button itself is
-- restyled, so the client's own quality colours, glow and disabled state are
-- untouched and removing the outline leaves the button exactly as it was.
--
-- The overlay hugs the item's icon, not the whole button. A reward button is a
-- wide bar -- the icon at one end, the item's name beside it -- and a border
-- around the bar is a border around a word, not around the item. The icon region
-- is found defensively, in this order, and a button whose icon cannot be found
-- keeps the old border around the whole button: an unfamiliar client still gets a
-- border, just a wider one.
-----------------------------------------------------------------------------

-- Field names a client may use for the icon texture it hangs on a reward button.
local ICON_FIELDS = { "Icon", "icon", "IconTexture", "iconTexture", "Texture",
    "texture", "ItemIcon" }

-- The same regions, reached through the button's global name, for a client that
-- names its texture in XML without putting it on the button table.
local ICON_SUFFIXES = { "Icon", "IconTexture", "ItemIcon", "Texture" }

-- Width and height of a region, or nil when it is not a region or has not been
-- laid out yet. Everything here is pcall'd: a region from an unfamiliar client
-- may be anything at all.
local function regionSize(region)
    if type(region) ~= "table" or type(region.GetWidth) ~= "function" then
        return nil
    end

    local okWidth, width = pcall(region.GetWidth, region)
    local okHeight, height = pcall(region.GetHeight, region)

    if not okWidth or not okHeight then return nil end
    if type(width) ~= "number" or type(height) ~= "number" then return nil end
    if width <= 0 or height <= 0 then return nil end

    return width, height
end

-- A region can only be anchored to once the client has given it points; an
-- unanchored texture has no rectangle for a border to hug.
local function isAnchored(region)
    if type(region) ~= "table" or type(region.GetPoint) ~= "function" then
        return false
    end

    local ok, point = pcall(region.GetPoint, region, 1)
    return ok and point ~= nil
end

-- An item icon is square, at least a few pixels across, and smaller than the
-- button that holds it. Anything else -- the button's own backdrop, a line of
-- text, a decoration -- must not be hugged, because a border around it would
-- point at the wrong thing.
local function looksLikeIcon(region, buttonWidth, buttonHeight)
    if not isAnchored(region) then return false end

    local width, height = regionSize(region)
    if not width then return false end
    if width < 8 or height < 8 then return false end

    local ratio = width / height
    if ratio < 0.75 or ratio > 1.34 then return false end

    if buttonWidth and buttonHeight
        and width >= buttonWidth * 0.9 and height >= buttonHeight * 0.9 then
        return false
    end

    return true
end

-- The largest square texture the button owns, when it exposes its regions at all.
local function biggestSquareRegion(button, buttonWidth, buttonHeight)
    if type(button.GetRegions) ~= "function" then return nil end

    -- GetRegions returns one value per region rather than a table, so the call is
    -- wrapped in a function that packs them.
    local ok, regions = pcall(function() return { button:GetRegions() } end)
    if not ok or type(regions) ~= "table" then return nil end

    local best, bestArea = nil, nil

    for _, region in ipairs(regions) do
        local isTexture = true

        if type(region) == "table" and type(region.GetObjectType) == "function" then
            local okType, kind = pcall(region.GetObjectType, region)
            isTexture = (okType and kind == "Texture") or false
        end

        if isTexture and looksLikeIcon(region, buttonWidth, buttonHeight) then
            local width, height = regionSize(region)
            local area = width * height

            if not bestArea or area > bestArea then
                best, bestArea = region, area
            end
        end
    end

    return best
end

-- The region the colour should hug: the item's icon when it can be found, the
-- button itself when it cannot. Exposed so /lt quest and the self test can ask
-- the same question the drawing code asks.
local function outlineAnchor(button)
    if type(button) ~= "table" then return nil end

    local buttonWidth, buttonHeight = regionSize(button)

    -- 1. A field the frame exposes by name.
    for _, field in ipairs(ICON_FIELDS) do
        local region = button[field]
        if looksLikeIcon(region, buttonWidth, buttonHeight) then return region end
    end

    -- 2. The same regions through the button's global name.
    local name = nil

    if type(button.GetName) == "function" then
        local ok, value = pcall(button.GetName, button)
        if ok and type(value) == "string" and value ~= "" then name = value end
    end

    if name then
        for _, suffix in ipairs(ICON_SUFFIXES) do
            local region = _G[name .. suffix]
            if looksLikeIcon(region, buttonWidth, buttonHeight) then return region end
        end
    end

    -- 3. The texture the client itself uses for the button's normal state: on a
    --    reward button that is the item's icon.
    if type(button.GetNormalTexture) == "function" then
        local ok, region = pcall(button.GetNormalTexture, button)
        if ok and looksLikeIcon(region, buttonWidth, buttonHeight) then return region end
    end

    -- 4. Anything square the button owns, biggest first.
    local region = biggestSquareRegion(button, buttonWidth, buttonHeight)
    if region then return region end

    -- 5. Nothing recognisable: the whole button, which is what earlier builds of
    --    this module always drew around.
    return button
end

QuestRewards.OutlineAnchor = outlineAnchor

-- Exposed so the self test can prove a position is taken from the fields the
-- client actually provides, and from the button's name when they are missing.
QuestRewards.ItemPosition = itemPosition

-- Every side of the overlay is pinned to the matching side of the region it
-- hugs, not just two corners: two corners leave the other sides to the client's
-- own rounding, and a region whose points move under the overlay then drags one
-- of the sized edges with it. Setting every side also turns a half-applied
-- anchor (one call succeeded, the next raised) into a reported failure instead of
-- a border that is only partly there.
local ANCHOR_POINTS = {
    { "TOPLEFT",     "TOPLEFT",     -OUTLINE_SIZE,  OUTLINE_SIZE },
    { "TOPRIGHT",    "TOPRIGHT",     OUTLINE_SIZE,  OUTLINE_SIZE },
    { "BOTTOMLEFT",  "BOTTOMLEFT",  -OUTLINE_SIZE, -OUTLINE_SIZE },
    { "BOTTOMRIGHT", "BOTTOMRIGHT",  OUTLINE_SIZE, -OUTLINE_SIZE },
}

local function setOverlayAnchor(overlay, anchor)
    pcall(overlay.ClearAllPoints, overlay)

    local all = true

    for _, point in ipairs(ANCHOR_POINTS) do
        local ok = pcall(overlay.SetPoint, overlay, point[1], anchor, point[2],
            point[3], point[4])

        if not ok then all = false end
    end

    return all
end

-- The four edges are two-point textures that span one side of the overlay, so
-- each is exactly as long as that side whatever size the overlay ended up with.
-- Their points are set again on every apply, not only when the overlay is built:
-- a recycled reward button can hand back a texture that kept only some of its
-- points, and a border with one side missing is worse than no border at all --
-- which is the "top and left only" the player reported (C2/G2).
local EDGE_GEOMETRY = {
    { "TOPLEFT",    "TOPRIGHT",    "HEIGHT" },  -- top
    { "BOTTOMLEFT", "BOTTOMRIGHT", "HEIGHT" },  -- bottom
    { "TOPLEFT",    "BOTTOMLEFT",  "WIDTH"  },  -- left
    { "TOPRIGHT",   "BOTTOMRIGHT", "WIDTH"  },  -- right
}

local function applyEdgeGeometry(overlay)
    local edges = overlay.__edges
    if type(edges) ~= "table" then return end

    for index = 1, #EDGE_GEOMETRY do
        local texture = edges[index]
        local geometry = EDGE_GEOMETRY[index]

        if type(texture) == "table" then
            pcall(texture.ClearAllPoints, texture)

            local ok = pcall(texture.SetPoint, texture, geometry[1], overlay,
                geometry[1], 0, 0)

            if ok then
                ok = pcall(texture.SetPoint, texture, geometry[2], overlay,
                    geometry[2], 0, 0)
            end

            -- Two points fix one dimension; the other is the border's own
            -- thickness, set explicitly so a recycled texture cannot keep an old
            -- one.
            if geometry[3] == "HEIGHT" then
                pcall(texture.SetHeight, texture, OUTLINE_SIZE)
            else
                pcall(texture.SetWidth, texture, OUTLINE_SIZE)
            end
        end
    end
end

-- A region's size is what the border is drawn against, so a resize matters as
-- much as a different region: recycled quest-log buttons reuse their overlay and
-- their icon, and the next reward can give that icon another rectangle.
local ANCHOR_EPSILON = 0.01

local function anchorResized(overlay, width, height)
    local cachedWidth, cachedHeight = overlay.__anchorWidth, overlay.__anchorHeight

    -- An unreadable size cannot be compared, so the only honest answer is to ask
    -- the client again; the calls are cheap and all pcall'd.
    if not cachedWidth or not cachedHeight or not width or not height then
        return true
    end

    return math.abs(width - cachedWidth) > ANCHOR_EPSILON
        or math.abs(height - cachedHeight) > ANCHOR_EPSILON
end

-- Anchors (or re-anchors) the overlay to whatever should be hugged. The icon can
-- appear a frame or two after the button on some clients, and a reward button is
-- recycled from quest to quest, so this is asked again on every refresh rather
-- than decided once: a different region, a different size and a region that
-- stopped reporting a size all mean "lay the border out again". A region that
-- reports no size is not hugged at all -- a zero-size anchor gives the overlay no
-- rectangle, which is how a border ends up with one or two sides drawn -- so the
-- button is used instead.
local function anchorOverlay(button, overlay)
    local anchor = outlineAnchor(button)
    if not anchor then return nil end

    local width, height = regionSize(anchor)

    if (not width or not height) and anchor ~= button then
        anchor = button
        width, height = regionSize(button)
    end

    local stale = overlay.__anchored ~= true
        or overlay.__anchor ~= anchor
        or anchorResized(overlay, width, height)

    if stale then
        local ok = setOverlayAnchor(overlay, anchor)

        -- A region the client will not accept as an anchor must not cost the
        -- border: falling back to the button keeps the behaviour that was there
        -- before icons were hugged.
        if not ok and anchor ~= button then
            anchor = button
            width, height = regionSize(button)
            ok = setOverlayAnchor(overlay, anchor)
        end

        if ok then
            overlay.__anchor = anchor
            overlay.__anchorWidth = width
            overlay.__anchorHeight = height
            overlay.__anchored = true

            -- The rectangle just moved or resized, so the sides are laid out
            -- again in the same breath rather than left to the next apply.
            applyEdgeGeometry(overlay)
        end
    end

    return overlay.__anchor or anchor
end

-- The coin is drawn inside the border, so its size follows the region the border
-- hugs: comfortable on a 36px icon, smaller on a small one, never larger than the
-- 14px it used to be drawn at.
local COIN_MIN, COIN_MAX, COIN_DEFAULT = 10, 16, 14

local function sizeCoin(overlay, anchor)
    local coin = overlay.__coin
    if not coin then return end

    local size = COIN_DEFAULT
    local width, height = regionSize(anchor)

    if width and height then
        size = math.floor(math.min(width, height) * 0.45 + 0.5)
        if size < COIN_MIN then size = COIN_MIN end
        if size > COIN_MAX then size = COIN_MAX end
    end

    pcall(coin.SetSize, coin, size, size)
end

-- The "2" that marks a reward the second build slot also wins. It is one
-- FontString on the same overlay as the border, so it cannot outlive the border,
-- and its colour is the palette's chrome build-2 tint -- a label, never a verdict.
local SECOND_MIN, SECOND_MAX, SECOND_DEFAULT = 9, 13, 12

-- A font this client is known to have. `STANDARD_TEXT_FONT` is the usual answer;
-- a font object is the fallback, and no font at all just leaves the glyph
-- unrendered rather than costing the border.
local function defaultFontPath()
    local standard = _G.STANDARD_TEXT_FONT
    if type(standard) == "string" and standard ~= "" then return standard end

    local fontObject = _G.GameFontNormal or _G.GameFontHighlight
    if type(fontObject) == "table" and type(fontObject.GetFont) == "function" then
        local ok, path = pcall(fontObject.GetFont, fontObject)
        if ok and type(path) == "string" and path ~= "" then return path end
    end

    return nil
end

local function sizeSecondBuild(overlay, anchor)
    local text = overlay.__secondBuild
    if not text or not overlay.__secondBuildFont then return end

    local size = SECOND_DEFAULT
    local width, height = regionSize(anchor)

    if width and height then
        size = math.floor(math.min(width, height) * 0.38 + 0.5)
        if size < SECOND_MIN then size = SECOND_MIN end
        if size > SECOND_MAX then size = SECOND_MAX end
    end

    pcall(text.SetFont, text, overlay.__secondBuildFont, size, "OUTLINE")
end

local function outlineFor(button)
    if type(button) ~= "table" or not button.CreateTexture then return nil end

    if button.__ltOutline then return button.__ltOutline end

    local ok, overlay = pcall(CreateFrame, "Frame", nil, button)
    if not ok or not overlay then return nil end

    -- The anchor is decided by anchorOverlay and re-decided on every refresh, so
    -- nothing is pinned to the button here.
    anchorOverlay(button, overlay)

    if button.GetFrameLevel and overlay.SetFrameLevel then
        local okLevel, level = pcall(button.GetFrameLevel, button)
        if okLevel and type(level) == "number" then
            pcall(overlay.SetFrameLevel, overlay, level + 5)
        end
    end

    -- The four edges are kept so one overlay can be re-coloured when the
    -- ranking changes (purple -> blue -> gold) instead of being rebuilt. A fixed
    -- index per side keeps this list and the geometry table in step even when
    -- the client refuses one texture.
    overlay.__edges = {}

    for index = 1, #EDGE_GEOMETRY do
        local okEdge, texture = pcall(overlay.CreateTexture, overlay, nil, "OVERLAY")
        overlay.__edges[index] = (okEdge and texture) or nil
    end

    applyEdgeGeometry(overlay)

    -- The colour is set by applyOutline, so the same overlay can change meaning
    -- without being recreated.

    -- The coin glyph: money is the one border that needs a second channel, so it
    -- cannot be confused with a verdict on the item. It is a child of the
    -- overlay, so it hides and shows with the border it belongs to.
    local coinOk, coin = pcall(overlay.CreateTexture, overlay, nil, "OVERLAY")
    if coinOk and coin then
        if coin.SetTexture then pcall(coin.SetTexture, coin, LT.Palette.coinTexture) end
        -- The size is set again by sizeCoin against the region the border hugs.
        pcall(coin.SetSize, coin, COIN_DEFAULT, COIN_DEFAULT)
        pcall(coin.SetPoint, coin, "BOTTOMRIGHT", overlay, "BOTTOMRIGHT", -1, 1)
        pcall(coin.Hide, coin)
        overlay.__coin = coin
    end

    -- The second-build glyph: one FontString, created with the border so a
    -- recycled reward button never carries a stale "2". Its text and size are set
    -- when the rule decides it, and it hides with the border.
    local secondaryOk, secondBuild = pcall(overlay.CreateFontString, overlay, nil, "OVERLAY")
    if secondaryOk and secondBuild then
        local fontPath = defaultFontPath()

        if fontPath then
            pcall(secondBuild.SetFont, secondBuild, fontPath, SECOND_DEFAULT, "OUTLINE")
            overlay.__secondBuildFont = fontPath
        elseif type(secondBuild.SetFontObject) == "function" then
            local fontObject = _G.GameFontNormalSmall or _G.GameFontNormal
            if fontObject then pcall(secondBuild.SetFontObject, secondBuild, fontObject) end
        end

        local colour = (LT.Palette.named and (LT.Palette.named.buildTwo
            or LT.Palette.named.text)) or nil

        if colour then
            pcall(secondBuild.SetTextColor, secondBuild, colour.r, colour.g, colour.b, 1)
        end

        pcall(secondBuild.SetJustifyH, secondBuild, "RIGHT")
        pcall(secondBuild.SetPoint, secondBuild, "TOPRIGHT", overlay, "TOPRIGHT", -1, -1)
        pcall(secondBuild.Hide, secondBuild)
        overlay.__secondBuild = secondBuild
    end

    pcall(overlay.Hide, overlay)
    button.__ltOutline = overlay
    return overlay
end

local function clearOutline(button)
    if type(button) ~= "table" or not button.__ltOutline then return end

    local overlay = button.__ltOutline

    -- The "2" and the coin belong to the border: clearing one clears all three.
    -- Every call is guarded because a recycled button can hand back an overlay
    -- whose regions the client no longer accepts, and one refusal must not stop
    -- the rest of a refresh from clearing.
    if overlay.__secondBuild then
        pcall(overlay.__secondBuild.Hide, overlay.__secondBuild)
    end

    if overlay.__coin then
        pcall(overlay.__coin.Hide, overlay.__coin)
    end

    pcall(overlay.Hide, overlay)
end

-- colour defaults to "biggest upgrade" so a caller that does not care about the
-- ranking still gets the behaviour this module was built for. `withCoin` marks
-- the border that also means money rather than a verdict only.
local function applyOutline(button, colour, withCoin)
    local overlay = outlineFor(button)
    if not overlay then return end

    -- The icon can arrive after the button, and a reward button is recycled from
    -- quest to quest, so the anchor is re-asked every time the colour is set.
    local anchor = anchorOverlay(button, overlay)
    if not anchor then return end

    sizeCoin(overlay, anchor)

    -- Every side is pointed and sized again on every apply: a recycled button
    -- must never keep a border from its last quest with a side missing.
    applyEdgeGeometry(overlay)

    colour = colour or COLOURS.upgradeBest
    local alpha = colour[4] or 1

    for index = 1, #EDGE_GEOMETRY do
        local texture = overlay.__edges and overlay.__edges[index]

        if type(texture) == "table" then
            pcall(texture.SetColorTexture, texture, colour[1], colour[2],
                colour[3], alpha)
        end
    end

    if overlay.__coin then
        if withCoin then pcall(overlay.__coin.Show, overlay.__coin)
        else pcall(overlay.__coin.Hide, overlay.__coin) end
    end

    -- A recycled overlay must not keep the other build's marker; the refresh
    -- re-applies it only to the verdict rows that earn it today.
    if overlay.__secondBuild then
        pcall(overlay.__secondBuild.Hide, overlay.__secondBuild)
    end

    pcall(overlay.Show, overlay)

    -- Remembered so Refresh can clear every border it ever drew, not only the
    -- ones the current walk still finds.
    highlighted[button] = true
end

-- The coin on a border that already has a verdict colour: the colour stays, only
-- the money marker is added, so "wear this" and "worth the most to a vendor" can
-- be read off one reward icon at the same time. Returns false when the button has
-- no border drawn yet, which is why the caller only uses it on a verdict row.
local function applyCoin(button)
    local overlay = type(button) == "table" and button.__ltOutline or nil
    if not overlay or not overlay.__coin then return false end

    local anchor = anchorOverlay(button, overlay)
    if not anchor then return false end

    sizeCoin(overlay, anchor)
    pcall(overlay.__coin.Show, overlay.__coin)
    pcall(overlay.Show, overlay)
    return true
end

-- The "2" on a verdict border that the second build slot also wins. Kept apart
-- from applyCoin because it is a different question ("also good for build 2",
-- not "worth money"), and both may be true of one icon. Returns false when the
-- button has no border drawn yet.
local function applySecondBuild(button)
    local overlay = type(button) == "table" and button.__ltOutline or nil
    if not overlay or not overlay.__secondBuild then return false end

    local anchor = anchorOverlay(button, overlay)
    if not anchor then return false end

    sizeSecondBuild(overlay, anchor)
    pcall(overlay.__secondBuild.SetText, overlay.__secondBuild, "2")
    pcall(overlay.__secondBuild.Show, overlay.__secondBuild)
    pcall(overlay.Show, overlay)
    return true
end

-----------------------------------------------------------------------------
-- Evaluating the reward buttons
-----------------------------------------------------------------------------

-- Reward buttons live in different globals depending on the client: the older
-- quest frame keeps its choice buttons in QuestInfoRewardsFrame, newer builds
-- expose them through the quest reward frame's item buttons. Each candidate
-- location is probed and anything that is not a table is skipped, so an
-- unfamiliar client means "no highlight", never an error.
local function addFrom(frame, prefix, add)
    if type(frame) ~= "table" then return end

    for index = 1, 8 do
        local button = frame[prefix .. tostring(index)]
        if type(button) ~= "table" then break end
        add(button)
    end
end

-- The position a frame's own name says it holds: "...Reward3" is the third. Used
-- by the walk below to recognise numbered slots without trusting a field the
-- frame may carry for another purpose.
local function trailingIndex(frame)
    if type(frame) ~= "table" or type(frame.GetName) ~= "function" then return nil end

    local ok, name = pcall(frame.GetName, frame)
    if not ok or type(name) ~= "string" then return nil end

    return tonumber(name:match("(%d+)$"))
end

-- The quest log draws the same rewards through frames whose names this build has
-- never been told. So its panes are walked rather than guessed at -- and only
-- those panes: the giver's window already answers by name, and its progress frame
-- carries numbered "required item" buttons that must never be scored as rewards.
--
-- The walk starts only at the frames that hold one quest's detail: the log's
-- detail pane, its scroll child and the popup. `QuestLogFrame` is deliberately
-- not a root (player report C5, 2026-10-28): the header and objective item
-- buttons under it are numbered frames that own a square icon too, so walking it
-- drew borders on frames attached to no reward.
--
-- A candidate then has to be a Button-like frame whose icon is a square between
-- 12 and 64 px, whose name is not one the client uses for objective, required,
-- progress or header rows, and from which a link can actually be read. Hidden
-- panes are not walked at all, and the visit count is capped, so an open log
-- costs a handful of reads and a closed one costs nothing.
local WALK_NAMES = {
    "QuestLogDetailFrame",
    "QuestLogDetailScrollFrame",
    "QuestLogDetailScrollChildFrame",
    "QuestLogDetailRewardFrame",
    "QuestLogRewardFrame",
    "QuestLogPopupDetailFrame",
    -- Forever (modern UI): the map's reward pane. The whole
    -- QuestMapFrame is deliberately not a root (same reason QuestLogFrame is
    -- excluded): walking it would reach objective/header rows and draw borders
    -- on frames attached to no reward.
    "MapQuestInfoRewardsFrame",
}

-- Bounds of a reward icon. A bar's backdrop, a decorative square or a piece of
-- header art falls outside them, and an icon at 70 px is not a reward icon.
local WALK_ICON_MIN, WALK_ICON_MAX = 12, 64

-- Words the client puts in the names of its own numbered rows. Matching is a
-- case-insensitive substring: such a row never belongs to a reward, wherever in
-- the name the word sits.
local WALK_EXCLUDED_NAMES = { "objective", "required", "progress", "header" }

local WALK_DEPTH = 5
local WALK_VISITS = 300
local WALK_MAX_BUTTONS = 40

-- A reward is a button. A plain frame or a texture whose name happens to end in a
-- digit is not asked any further questions. Older builds answer IsObjectType
-- instead; a frame that can answer neither is refused rather than guessed at.
local function buttonLike(frame)
    if type(frame) ~= "table" then return false end

    if type(frame.GetObjectType) == "function" then
        local ok, kind = pcall(frame.GetObjectType, frame)
        return ok and kind == "Button"
    end

    if type(frame.IsObjectType) == "function" then
        local ok, answer = pcall(frame.IsObjectType, frame, "Button")
        return ok and answer == true
    end

    return false
end

-- The name the client gave the frame, lowercased once, or nil when it has none.
local function lowerName(frame)
    if type(frame) ~= "table" or type(frame.GetName) ~= "function" then return nil end

    local ok, name = pcall(frame.GetName, frame)
    if not ok or type(name) ~= "string" or name == "" then return nil end

    return name:lower()
end

-- The exclusion word the frame's name contains, or nil. The word is returned
-- instead of a bare boolean so a refused row can say why it was refused.
local function excludedName(frame)
    local name = lowerName(frame)
    if not name then return nil end

    for _, word in ipairs(WALK_EXCLUDED_NAMES) do
        if name:find(word, 1, true) then return word end
    end

    return nil
end

-- The icon region and its size, when the region is a square inside the reward
-- bounds. outlineAnchor answers the button itself when no icon was recognisable,
-- and a button is never a reward icon.
local function squareIcon(frame)
    local anchor = outlineAnchor(frame)
    if not anchor or anchor == frame then return nil end

    local width, height = regionSize(anchor)
    if not width or not height then return nil end
    if width < WALK_ICON_MIN or width > WALK_ICON_MAX then return nil end
    if height < WALK_ICON_MIN or height > WALK_ICON_MAX then return nil end
    if math.abs(width - height) > 1 then return nil end

    return anchor, width, height
end

-- Why a frame the walk reached is not a reward button, and the link when it is
-- one. Cheapest question first; the link read is last because it is the only one
-- that calls the client.
local function walkRefusal(frame)
    if type(frame) ~= "table" then return "not a frame" end

    local excluded = excludedName(frame)
    if excluded then return "name contains " .. excluded end

    if not buttonLike(frame) then return "not a button" end
    if not trailingIndex(frame) then return "not a numbered slot" end

    if not squareIcon(frame) then
        return "no square icon between " .. WALK_ICON_MIN .. " and "
            .. WALK_ICON_MAX .. " px"
    end

    local link = linkFromButton(frame)
    if type(link) ~= "string" or link == "" then return "no item link" end

    return nil, link
end

-- Exposed so the self test and an offline harness can prove the walk's filters
-- without a client: the roots are data, and a refusal is a word.
QuestRewards.WalkRoots = WALK_NAMES
QuestRewards.WalkRefusal = walkRefusal

-- Children of a frame, walked the way the client exposes them. Retail/Forever
-- answer through GetNumChildren/GetChild; classic through GetChildren. A client
-- that implements only one still resolves its children.
local function childrenOf(frame)
    if type(frame) ~= "table" then return nil end

    if type(frame.GetNumChildren) == "function" and type(frame.GetChild) == "function" then
        local ok, count = pcall(frame.GetNumChildren, frame)
        if ok and type(count) == "number" then
            local list = {}
            for i = 1, count do
                local okChild, child = pcall(frame.GetChild, frame, i)
                if okChild and type(child) == "table" then
                    list[#list + 1] = child
                end
            end
            return list
        end
    end

    if type(frame.GetChildren) == "function" then
        -- GetChildren returns one value per child rather than a table, so the
        -- call is wrapped in a function that packs them.
        local ok, children = pcall(function() return { frame:GetChildren() } end)
        if ok and type(children) == "table" then return children end
    end

    return nil
end

local function walkItemButtons(root, found, seen, stats, depth)
    if type(root) ~= "table" or depth > WALK_DEPTH then return end
    if seen[root] then return end
    seen[root] = true

    if depth > 0 and type(root.IsShown) == "function" then
        local okShown, shown = pcall(root.IsShown, root)
        if okShown and shown == false then return end
    end

    -- A global that is not a frame, or a frame that answers nothing, simply ends
    -- this branch.
    local children = childrenOf(root)
    if not children then return end

    for _, child in ipairs(children) do
        if stats.visited >= WALK_VISITS or #found >= WALK_MAX_BUTTONS then return end

        if type(child) == "table" then
            stats.visited = stats.visited + 1

            -- A reward button is a numbered Button whose square icon is the size
            -- of an item icon and which answers with a link. Anything else -- the
            -- header, an objective line, a "required item" row -- is refused here
            -- rather than after a border has been drawn around it.
            local refusal, link = walkRefusal(child)

            if not refusal then
                table.insert(found, child)

                -- The link read is reused by Evaluate: asking twice could answer
                -- differently while the client is still loading item data.
                if stats.links then stats.links[child] = link end
            end

            walkItemButtons(child, found, seen, stats, depth + 1)
        end
    end
end

local function rewardButtons(stats)
    local buttons = {}
    local seen = {}

    local function add(frame)
        if type(frame) ~= "table" or seen[frame] then return end
        seen[frame] = true
        table.insert(buttons, frame)
    end

    addFrom(_G.QuestInfoRewardsFrame, "Reward", add)
    addFrom(_G.QuestInfoRewardsFrame, "ItemButton", add)

    if type(_G.QuestInfoRewardsFrame) == "table"
        and type(_G.QuestInfoRewardsFrame.RewardButtons) == "table" then
        for _, button in ipairs(_G.QuestInfoRewardsFrame.RewardButtons) do
            add(button)
        end
    end

    addFrom(_G.QuestInfoFrame, "ItemButton", add)
    addFrom(_G.QuestFrame, "ItemButton", add)
    addFrom(_G.QuestLogDetailFrame, "ItemButton", add)
    addFrom(_G.QuestLogPopupDetailFrame, "ItemButton", add)

    local named = #buttons

    -- The walk comes last, so a pane whose names this build already knows is
    -- never walked and the cost is only paid where the names failed.
    local found = {}
    local walkStats = { visited = 0, links = {} }
    local walkSeen = {}

    for _, name in ipairs(WALK_NAMES) do
        walkItemButtons(_G[name], found, walkSeen, walkStats, 0)
    end

    local walked = 0
    local walkedSet = {}

    for _, frame in ipairs(found) do
        if not seen[frame] then
            seen[frame] = true
            table.insert(buttons, frame)
            walkedSet[frame] = true
            walked = walked + 1
        end
    end

    if stats then
        stats.named = named
        stats.walked = walked
        stats.visited = walkStats.visited
        -- The coin refusal reads this: a frame found by walking the log's panes
        -- is in the quest log even when its own name does not start "QuestLog".
        stats.walkedSet = walkedSet
        stats.walkedLinks = walkStats.links
    end

    return buttons
end

-- Exposed so the self test and an offline harness can walk synthetic panes and
-- prove which frames the walk accepts, without a client.
QuestRewards.RewardButtons = rewardButtons

-- Diagnostic for /lt questwalk: every candidate under the quest-log roots, with
-- the reason it was accepted or refused. Used only when a border is missing.
function QuestRewards:WalkReport(limit)
    local out, seen, visited = {}, {}, 0
    local max = tonumber(limit) or 80

    local function walk(frame, depth)
        if type(frame) ~= "table" or depth > WALK_DEPTH or seen[frame] then return end
        seen[frame] = true

        if depth > 0 and type(frame.IsShown) == "function" then
            local ok, shown = pcall(frame.IsShown, frame)
            if ok and shown == false then return end
        end

        local children = childrenOf(frame)
        if not children then return end

        for _, child in ipairs(children) do
            if visited >= max then return end
            if type(child) == "table" then
                visited = visited + 1
                local name = lowerName(child) or "(unnamed)"
                local refusal, link = walkRefusal(child)
                out[#out + 1] = string.rep(" ", depth) .. name .. ": "
                    .. (refusal or ("REWARD " .. tostring(link)))
                walk(child, depth + 1)
            end
        end
    end

    for _, name in ipairs(WALK_NAMES) do
        local root = _G[name]
        if type(root) == "table" then
            local shown = "?"
            if type(root.IsShown) == "function" then
                local ok, value = pcall(root.IsShown, root)
                shown = ok and tostring(value) or "?"
            end
            out[#out + 1] = name .. " shown=" .. shown
            walk(root, 0)
        end
    end

    return out, visited
end

-- Every quest-reward behaviour has its own switch. The master switch and both
-- refinements default to on when a saved record predates the key, so an
-- existing character keeps the behaviour it had before the keys existed.
local function optionEnabled(key)
    local options = LT.Database and LT.Database:GetOptions()
    if not options then return false end
    if options[key] == nil then return true end
    return options[key] == true
end

function QuestRewards:IsEnabled()
    return optionEnabled("questRewardHighlight")
end

-- Purple plus blue. Off means "outline the single best upgrade in purple only".
function QuestRewards:RankingEnabled()
    return optionEnabled("questRewardRanking")
end

-- The coin, on the most profitable reward of the whole window (upgrades included).
function QuestRewards:VendorFallbackEnabled()
    return optionEnabled("questVendorFallback")
end

-----------------------------------------------------------------------------
-- Vendor value
--
-- The reward window is also a shopping decision: the reward worth the most to a
-- vendor is worth knowing about even when it is also the one you would wear, so
-- the coin is decided by price alone and rides on whatever border the winner has.
-- A price the client has not cached yet is simply "not ranked" -- it is never
-- treated as zero, because that would make an uncached item look cheap.
-----------------------------------------------------------------------------

-- The merchant pays what the client's own item tooltip says, so that is where
-- the price is read from. GetItemInfo's sellPrice return is not used as money
-- here: on Forever it can still carry the item's Classic-era price after the
-- server rebalanced the sell price, which is how a level-3 reward was read as
-- 13g 45s 83c (player report C6, 2026-10-28). An item whose tooltip shows no
-- Sell Price line has no known price: it is never treated as zero and never
-- read from another position, so an unreadable price prints nothing at all.

-- Calls one info function and records what came back, nil holes included. The
-- count comes from select("#", ...) and each slot from select(n, ...), because
-- packing the returns into a table would stop at the first nil and misreport the
-- count. Everything is pcall'd: a client without the function never gets here.
--
-- Only /lt itemdump uses this now. Every slot is kept so the whole reply can
-- be printed; no price is taken from it.
local function probeReply(infoFunction, link)
    local reply = { ok = false, count = 0 }

    local ok = pcall(function()
        local function sink(...)
            local count = select("#", ...)
            reply.count = count

            for index = 1, count do
                reply[index] = select(index, ...)
            end
        end

        sink(infoFunction(link))
    end)

    reply.ok = ok == true
    return reply
end

-- The tooltip's own Sell Price line, in copper, or nil. Enum names the line
-- type on modern clients; 11 is the position the Forever-era corpus addons use
-- when the enum is absent.
local SELL_PRICE_LINE_FALLBACK = 11

local function sellPriceLineType()
    local enum = type(Enum) == "table" and Enum.TooltipDataLineType or nil
    local value = type(enum) == "table" and enum.SellPrice or nil
    if type(value) == "number" then return value end
    return SELL_PRICE_LINE_FALLBACK
end

-- Prices do not change during a session, so a positive answer is kept. An item
-- still loading is deliberately not cached: the next scan asks again instead of
-- remembering "no price" for the rest of the session.
local priceCache, priceOrder = {}, {}
local PRICE_CACHE_LIMIT = 400

local function rememberPrice(link, copper)
    if priceCache[link] == nil then
        priceOrder[#priceOrder + 1] = link
    end

    priceCache[link] = copper

    while #priceOrder > PRICE_CACHE_LIMIT do
        priceCache[table.remove(priceOrder, 1)] = nil
    end
end

local function tooltipSellPrice(link)
    if type(link) ~= "string" or link == "" then return nil end
    if type(C_TooltipInfo) ~= "table"
        or type(C_TooltipInfo.GetHyperlink) ~= "function" then
        return nil
    end

    -- No fourth argument: hideVendorPrice=true would omit the very line this
    -- function reads.
    local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end

    -- A restricted line or number raises when it is compared or read; the whole
    -- scan is guarded so such a tooltip answers "no price" instead of an error.
    local scanned, copper = pcall(function()
        local wanted = sellPriceLineType()

        for _, line in ipairs(data.lines) do
            -- The first Sell Price line is the item's own; a later one would
            -- belong to a requirement or a comparison, not this item's money.
            if type(line) == "table" and line.type == wanted then
                local found = LT:Number(line.price)
                if found and found > 0 then return found end
                return nil
            end
        end

        return nil
    end)

    if not scanned then return nil end
    return copper
end

-- The merchant's price for one item, in copper, or nil when the client has not
-- shown one. Exposed for Vendor and DropHint so every printed price is the same
-- number the merchant will pay.
local function sellPrice(link)
    if type(link) ~= "string" or link == "" then return nil end

    local known = priceCache[link]
    if known then return known end

    local copper = tooltipSellPrice(link)
    if copper then rememberPrice(link, copper) end
    return copper
end

QuestRewards.SellPrice = sellPrice

-- /lt quest output only: copper counts are unreadable at a reward window.
local function moneyText(copper)
    copper = tonumber(copper)
    if not copper then return "unknown" end

    -- Kept defensive for any caller that hands over a negative: it stays
    -- visible instead of turning into "-1s -95c".
    if copper < 0 then return "-" .. moneyText(-copper) end

    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local remaining = copper % 100

    local parts = {}
    if gold > 0 then table.insert(parts, gold .. "g") end
    if silver > 0 then table.insert(parts, silver .. "s") end
    if remaining > 0 or #parts == 0 then table.insert(parts, remaining .. "c") end

    return table.concat(parts, " ")
end

-- Shared with DropHint so a copper total is formatted in one place. Re-exporting
-- the local leaves every existing caller untouched.
QuestRewards.moneyText = moneyText

-- /lt itemdump: the client's raw reply, one line per slot, so a layout this
-- build has never seen can be reported without guessing at a position. Values
-- are cut to 40 characters and a restricted value is named, never read.
local DUMP_VALUE_LIMIT = 40

local function dumpText(value, limit)
    local text = tostring(value)
    if #text > limit then return text:sub(1, limit) end
    return text
end

local function dumpType(value)
    if value == nil then return "nil" end
    return type(value)
end

local function dumpValue(value)
    if value == nil then return "nil" end

    -- A restricted value must never reach tostring: the type is safe to read,
    -- the contents are not.
    if type(LT.IsSecret) == "function" and LT:IsSecret(value) then
        return "<secret>"
    end

    local kind = type(value)

    if kind == "string" then
        if value == "" then return "\"\"" end
        return "\"" .. dumpText(value, DUMP_VALUE_LIMIT) .. "\""
    end

    if kind == "number" or kind == "boolean" then
        return tostring(value)
    end

    return "<" .. kind .. ">"
end

-- Pure: takes the table probeReply produced and returns the lines to print.
-- The loop stops at the client's own count, so a probe that holds extra slots
-- cannot invent returns the client did not give.
local function dumpReply(reply, source)
    local name = tostring(source or "the item query")
    local count = type(reply) == "table" and tonumber(reply.count) or 0

    if type(reply) ~= "table" or reply.ok ~= true then
        return { name .. " raised an error; there is no reply to dump." }
    end

    if count == 0 then
        return { name .. " returned 0 values (the item may not be cached yet)." }
    end

    local lines = { name .. " returned " .. tostring(count) .. " value(s):" }

    for index = 1, count do
        lines[#lines + 1] = "  #" .. tostring(index) .. " " .. dumpType(reply[index])
            .. " = " .. dumpValue(reply[index])
    end

    return lines
end

-- Exposed so SelfTest and an offline harness can prove the whole reply is
-- printed, capped at the client's own count, without a client.
QuestRewards.DumpReply = dumpReply

-- /lt itemdump <item link>. The argument is validated before any client call,
-- and the reply is dumped from whichever info function answers; nothing here is
-- read as copper. Strings out, so the command only prints them.
function QuestRewards:ItemDump(raw)
    if type(raw) ~= "string" or raw == "" then
        return { "Usage: /lt itemdump <item link> — shift-click an item into the chat box." }
    end

    local isHyperlink = raw:find("|Hitem:", 1, true) ~= nil
    local isItemID = raw:match("^item:%d+$") ~= nil

    if not isHyperlink and not isItemID then
        return { "\"" .. dumpText(raw, DUMP_VALUE_LIMIT) .. "\" is not an item link. "
            .. "Shift-click the item into the chat box and run /lt itemdump again." }
    end

    local link = resolveLink(raw)
    if not link then
        return { dumpText(raw, DUMP_VALUE_LIMIT)
            .. " could not be resolved to an item link on this client." }
    end

    local attempts = {}

    local function ask(name, infoFunction)
        if type(infoFunction) ~= "function" then return nil end

        local reply = probeReply(infoFunction, link)
        attempts[#attempts + 1] = { name = name, reply = reply }

        if reply.ok == true and reply.count > 0 then
            return dumpReply(reply, name)
        end

        return nil
    end

    local lines = ask("GetItemInfo", GetItemInfo)
    if lines then return lines end

    if type(C_Item) == "table" then
        lines = ask("C_Item.GetItemInfo", C_Item.GetItemInfo)
        if lines then return lines end
    end

    local last = attempts[#attempts]
    if last then return dumpReply(last.reply, last.name) end

    return { "This client has neither GetItemInfo nor C_Item.GetItemInfo." }
end

-- Usability's verdict for one reward, or nil when the module is missing or the
-- call fails. Nil means "say nothing": an unknown verdict must never paint a
-- reward green, because green is a promise about a later level.
local function usageVerdict(link, identity)
    local usability = LT.Usability
    if type(usability) ~= "table" or type(usability.GetVerdict) ~= "function" then
        return nil
    end

    local ok, verdict = pcall(usability.GetVerdict, usability, link,
        { identity = identity })

    if not ok or type(verdict) ~= "table" then return nil end

    return verdict
end

-- The decision step, deliberately pure: no buttons, no client API, no saved
-- data. It answers "which is green, which is purple, which is blue, and where
-- does the coin go?" so SelfTest can call it with synthetic rows.
function QuestRewards:Classify(rows)
    local rankable, deferred = {}, {}

    for _, row in ipairs(rows or {}) do
        -- Only a real upgrade with a numeric difference can carry a colour. An
        -- item that could not be evaluated must never out-rank one that could.
        if row.status == "upgrade" and type(row.difference) == "number" then
            -- A reward the character cannot use yet is green whatever it ranks:
            -- "you cannot equip this until 40" is the answer the player acts on
            -- first, so it stays out of the purple/blue race instead of being
            -- called second best. Ranking means "wear this now".
            if row.deferred then
                table.insert(deferred, row)
            else
                table.insert(rankable, row)
            end
        end
    end

    local function biggerFirst(a, b)
        return a.difference > b.difference
    end

    table.sort(rankable, biggerFirst)
    table.sort(deferred, biggerFirst)

    local result = {
        best = rankable[1],
        second = rankable[2],
        deferred = deferred,
        vendor = nil,
    }

    -- Money marks the single most profitable reward, decided by price alone and
    -- never by status (player's ruling, 2026-10-27: the single most profitable
    -- reward always carries the coin, whatever border colour it already has). An
    -- upgrade, a sidegrade and a reward that could not be scored all compete,
    -- because an item's price does not depend on whether the build wants it. A row
    -- with no known price never wins over one that has a price; a tie keeps the
    -- first one seen, so the marker cannot flicker between two equally rich ones.
    local highest = nil

    for _, row in ipairs(rows or {}) do
        local price = tonumber(row.sellPrice)
        if price and price > 0 and (not highest or price > highest.price) then
            highest = { row = row, price = price }
        end
    end

    result.vendor = highest and highest.row or nil
    return result
end

-- The rule behind the "2", deliberately pure so SelfTest and an offline harness
-- can answer it without a client. `borderedActive` says the reward carries a
-- verdict border for the build being looked at; `allBuilds` is the same reward
-- compared against every slot (Compare:ForAllBuilds), where the comparison's own
-- word for a win is status "upgrade".
--
-- The marker means "the second build slot wins this, the active one does not":
-- when both win it, the active border already answers the question and a second
-- marker would only repeat it. The marker names the second build slot, so when
-- that slot is the active one there is nothing left to flag.
function QuestRewards:SecondBuildGlyph(allBuilds, activeIndex, borderedActive)
    if borderedActive ~= true then return nil end

    activeIndex = tonumber(activeIndex) or 1
    if activeIndex == 2 then return nil end
    if type(allBuilds) ~= "table" then return nil end

    local function wins(index)
        local row = allBuilds[index]
        return type(row) == "table" and row.status == "upgrade"
    end

    if wins(activeIndex) then return nil end
    if wins(2) then return 2 end
    return nil
end

-- ForAllBuilds behind a pcall: a client whose Compare cannot answer must only
-- cost the glyph, never the borders that were already drawn.
local function allBuildRows(link)
    local compare = LT.Compare
    if type(compare) ~= "table" or type(compare.ForAllBuilds) ~= "function" then
        return nil
    end
    if type(link) ~= "string" or link == "" then return nil end

    local ok, rows = pcall(compare.ForAllBuilds, compare, link)
    if ok and type(rows) == "table" then return rows end
    return nil
end

-- Scores every reward against the build's own comparison, then classifies the
-- result. Returns the whole table so /lt quest can print what was decided.
function QuestRewards:Evaluate()
    local results = {
        buildIndex = LT.Builds:GetActiveIndex(),
        rows = {},
        best = nil,
        second = nil,
        deferred = {},
        vendor = nil,
        buttons = 0,
        unread = {},
        sources = { named = 0, walked = 0, visited = 0 },
    }

    local buttons = rewardButtons(results.sources)
    results.buttons = #buttons

    for _, button in ipairs(buttons) do
        -- A button the walk already read keeps that reading; asking the client
        -- again could answer differently while it is still loading item data.
        local walkedLink = results.sources.walkedLinks
            and results.sources.walkedLinks[button]
        local link = resolveLink(walkedLink or linkFromButton(button))
        local identity = link and LT.ItemStats:GetIdentity(link) or nil

        if identity then
            -- T-09: where the button lives decides the coin, before any price is
            -- asked for. The border and tooltip are unaffected by this refusal.
            local coinRefused = coinRefusal(button, results.sources.walkedSet)
            local comparison = LT.Compare:ForBuild(link, results.buildIndex)

            -- Usability answers the question a rank cannot: "can this character
            -- wear it at all, and if not, is that never or not yet?" A deferred
            -- answer is what turns the border green and keeps the reward out of
            -- the purple/blue ranking, so it is read once per reward here rather
            -- than inside the ranking.
            local usage = usageVerdict(link, identity)
            local deferred = false

            if usage and LT.Usability then
                deferred = usage.verdict == LT.Usability.DEFERRED
            end

            -- How many stat channels the client actually handed over for this
            -- item. One channel (item level) is what a client with no stat route
            -- returns, and "the client gave us nothing to weigh" is a different
            -- problem from "this reward is not an upgrade" -- /lt quest says which.
            local statCount = 0
            local itemStats = LT.ItemStats:Get(link)
            if type(itemStats) == "table" then
                for _ in pairs(itemStats) do statCount = statCount + 1 end
            end

            -- Refused rows never reach sellPrice: the price lookup is skipped
            -- outright, not hidden after it ran. A row the tooltip could not
            -- price keeps nil, so it is never ranked and never prints a number.
            local price = nil
            if not coinRefused then
                price = sellPrice(link)
            end

            local row = {
                button = button,
                link = link,
                comparison = comparison,
                name = comparison.itemName,
                status = comparison.status,
                difference = comparison.difference,
                sellPrice = price,
                coinRefused = coinRefused,
                verdict = usage and usage.verdict or nil,
                verdictReason = usage and usage.reason or nil,
                deferred = deferred,
                statCount = statCount,
            }

            table.insert(results.rows, row)
        else
            -- Kept so /lt quest can name the button and print the client's own
            -- answer, instead of only counting the failures.
            table.insert(results.unread, button)
        end
    end

    local ranking = self:Classify(results.rows)
    results.best = ranking.best
    results.second = ranking.second
    results.deferred = ranking.deferred
    results.vendor = ranking.vendor

    return results
end

-- Applies (or removes) the outlines according to the latest evaluation. Purple
-- and blue rank the upgrades the character can use now, green marks the ones it
-- cannot use yet, and the coin is decided separately, by price alone, riding on
-- whichever border the winning reward already has, so "wear this", "not yet" and
-- "worth the most to a vendor" can all be read off the reward icons.
--
-- This is the one entry point a settings checkbox calls, so it always starts by
-- clearing and then redraws from the options as they are now: a reward must never
-- be left with a border the current switches no longer mean (C2/G2, where turning
-- the tooltip switch off left reward borders cleared and they did not return).
function QuestRewards:Refresh()
    local buttons = rewardButtons()

    -- Clear every reward this module has ever bordered, not only the ones this
    -- walk can see: a closed log pane keeps its buttons, and an option change
    -- must not leave a border behind where the module no longer draws. The
    -- buttons found now are cleared too, because a freshly recycled one can carry
    -- an overlay from the quest before this one.
    local stale = {}
    for button in pairs(highlighted) do stale[#stale + 1] = button end

    for _, button in ipairs(stale) do
        clearOutline(button)
        highlighted[button] = nil
    end

    for _, button in ipairs(buttons) do
        clearOutline(button)
    end

    activeReward = nil

    if not self:IsEnabled() then return nil end
    if not LT.Builds or not LT.Compare then return nil end

    -- Called from an event and from a checkbox click alike, so a failure must not
    -- escape into either handler, and must be reported rather than leaving the
    -- borders cleared without a word.
    local ok, results = pcall(self.Evaluate, self)

    if not ok then
        LT:Debug("quest reward evaluation failed: " .. tostring(results))
        return nil
    end

    local active = nil

    -- Which buttons already carry a verdict colour, so the money marker knows
    -- whether it is adding a coin to a border or drawing the gold border itself.
    local bordered = {}
    -- The rows that earned a verdict border, in drawing order, for the glyph pass
    -- at the end. A gold/vendor border is not a verdict and is never in here.
    local verdictRows = {}

    if results.best then
        applyOutline(results.best.button, COLOURS.upgradeBest)
        bordered[results.best.button] = true
        table.insert(verdictRows, results.best)
        active = {
            button = results.best.button,
            link = results.best.link,
            difference = results.best.difference,
            kind = "upgrade-best",
        }

        -- One purple border, plus blue when the ranking switch is on and a
        -- second upgrade exists, so the two best choices never look alike.
        if results.second and self:RankingEnabled() then
            applyOutline(results.second.button, COLOURS.upgradeSecond)
            bordered[results.second.button] = true
            table.insert(verdictRows, results.second)
            active.second = {
                button = results.second.button,
                link = results.second.link,
                difference = results.second.difference,
            }
        end
    end

    -- Green: every reward that beats the saved gear but which the character cannot
    -- use yet. It is a verdict rather than a rank, so it is drawn whatever the
    -- ranking switch says, and it is drawn before the coin is decided -- the
    -- priciest reward can be one of these, and then the coin rides the green.
    local green = {}

    for _, row in ipairs(results.deferred or {}) do
        applyOutline(row.button, COLOURS.deferred)
        bordered[row.button] = true
        table.insert(verdictRows, row)

        table.insert(green, {
            button = row.button,
            link = row.link,
            difference = row.difference,
            reason = row.verdictReason,
        })
    end

    -- The coin: the single most profitable reward, decided by price alone. When
    -- that reward already has a purple, blue or green border the colour is kept
    -- and only the coin is added, so one icon can say "wear this" (or "not yet")
    -- and "this is the one worth the most to a vendor" at once; otherwise the
    -- reward gets the gold border, which is the only way a border can mean money.
    if results.vendor and self:VendorFallbackEnabled() then
        local sharesBorder = bordered[results.vendor.button] == true

        if sharesBorder then
            applyCoin(results.vendor.button)
        else
            applyOutline(results.vendor.button, COLOURS.vendor, true)
        end

        local vendor = {
            button = results.vendor.button,
            link = results.vendor.link,
            sellPrice = results.vendor.sellPrice,
            sharesBorder = sharesBorder,
        }

        if active then
            active.vendor = vendor
        else
            vendor.kind = "vendor"
            active = vendor
        end
    end

    -- The other build's marker: only a row that already carries a verdict colour
    -- can say "this is good for you too", and only when the second build slot is
    -- the one that wins it. Every call is guarded inside allBuildRows, so a failed
    -- comparison costs the "2", never the borders drawn above.
    if results.buildIndex ~= 2 and #verdictRows > 0 then
        for _, row in ipairs(verdictRows) do
            local glyph = self:SecondBuildGlyph(allBuildRows(row.link),
                results.buildIndex, bordered[row.button] == true)

            if glyph then
                applySecondBuild(row.button)
            end
        end
    end

    if #green > 0 then
        if active then
            active.deferred = green
        else
            active = {
                button = green[1].button,
                link = green[1].link,
                difference = green[1].difference,
                kind = "usable-later",
                deferred = green,
            }
        end
    end

    activeReward = active
    return results
end

function QuestRewards:GetActive()
    return activeReward
end

-----------------------------------------------------------------------------
-- Wiring
-----------------------------------------------------------------------------

local function refreshSafely()
    -- GetEffective fires EVENT_WEIGHTS on every call, so this module must never
    -- listen for that event: evaluating a quest reward would re-enter itself.
    -- The re-entrancy guard below is belt and braces for the same reason.
    if QuestRewards.refreshing then return end

    QuestRewards.refreshing = true
    local ok, err = pcall(QuestRewards.Refresh, QuestRewards)
    QuestRewards.refreshing = nil

    if not ok then
        LT:Debug("quest reward highlight failed: " .. tostring(err))
    end
end

function QuestRewards:Initialize()
    if self.frame then return end

    local frame = CreateFrame("Frame")
    self.frame = frame

    for _, event in ipairs(watchedEvents) do
        -- RegisterEvent raises on an event a client does not know, so each one
        -- is guarded: an unknown event must not stop the addon loading.
        pcall(frame.RegisterEvent, frame, event)
    end

    -- Item data arrives one item at a time, and during a login that is dozens of
    -- events in a row. They are folded into one refresh 0.2 s later instead of one
    -- evaluation each, which keeps a late link cheap to wait for.
    local pendingItemData = false

    local function refreshForItemData()
        if pendingItemData then return end

        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            pendingItemData = true

            C_Timer.After(0.2, function()
                pendingItemData = false
                refreshSafely()
            end)

            return
        end

        refreshSafely()
    end

    frame:SetScript("OnEvent", function(_, event)
        if event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
            refreshForItemData()
            return
        end

        refreshSafely()
    end)

    -- The quest log redraws its detail pane when the player clicks another entry,
    -- and that redraw is not one of the quest events above. The pane's own update
    -- functions are the signal that its buttons now hold different rewards.
    if type(hooksecurefunc) == "function" then
        for _, name in ipairs({ "QuestLog_Update", "QuestLog_UpdateQuestDetails" }) do
            if type(_G[name]) == "function" then
                pcall(hooksecurefunc, name, refreshSafely)
            end
        end
    end

    -- The quest frames spawn their reward buttons after the event fires on some
    -- builds, so the same refresh is also triggered by the events that change
    -- the answer: gear saved, profile edited, weights rebuilt.
    local function refreshSoon()
        refreshSafely()
    end

    if type(QuestLogFrame) == "table" and type(QuestLogFrame.HookScript) == "function" then
        pcall(QuestLogFrame.HookScript, QuestLogFrame, "OnShow", refreshSoon)
        pcall(QuestLogFrame.HookScript, QuestLogFrame, "OnHide", refreshSafely)
    end

    LT:On(LT.EVENT_GEARSET, refreshSoon)
    LT:On(LT.EVENT_PROFILE, refreshSoon)
end

function QuestRewards:OnPlayerLogin()
    refreshSafely()
end

function QuestRewards:OnEnterWorld()
    refreshSafely()
end

-- /lt quest is a diagnosis tool first. From the outside every unreadable reward
-- looks the same: no border. The reasons are not the same, though — this client
-- may keep the reward somewhere the module does not look, or it may know the
-- reward but not have the item link to hand. This prints which answer it gave,
-- so the next report says something a fix can act on.
function QuestRewards:ExplainButton(button)
    if type(button) ~= "table" then return "not a button" end

    local kind, index = itemPosition(button)
    local parts = {}

    table.insert(parts, "type " .. tostring(kind or "none")
        .. ", index " .. tostring(index or "none"))

    if type(GetQuestItemLink) ~= "function" then
        table.insert(parts, "this client has no GetQuestItemLink")
    else
        table.insert(parts, "GetQuestItemLink answered nothing")
    end

    if type(GetQuestItemInfo) == "function" and index then
        local kinds = kind and { kind } or { "choice", "reward" }
        local known = nil

        for _, candidate in ipairs(kinds) do
            -- name, texture, numItems, quality, isUsable is the classic order.
            local ok, itemName, _, _, quality = pcall(GetQuestItemInfo, candidate, index)

            if ok and type(itemName) == "string" and itemName ~= "" then
                known = "GetQuestItemInfo knows \"" .. itemName .. "\" (quality "
                    .. tostring(quality) .. ")"
                break
            end
        end

        table.insert(parts, known or "GetQuestItemInfo knows nothing at that position")
    end

    return table.concat(parts, "; ")
end

-- /lt quest: prints exactly what the highlight decided, which is the fastest
-- way to tell a client-shape problem from a scoring problem.
function QuestRewards:Describe()
    if not self:IsEnabled() then
        return { "Quest reward highlighting is turned off in Settings." }
    end

    local results = self:Evaluate()
    local lines = {}

    local rankingOn = self:RankingEnabled()
    local vendorOn = self:VendorFallbackEnabled()

    local refused = 0
    for _, row in ipairs(results.rows or {}) do
        if row.coinRefused then refused = refused + 1 end
    end

    table.insert(lines, "Quest reward highlight — active slot "
        .. tostring(results.buildIndex) .. ", " .. tostring(results.buttons)
        .. " reward button(s) found.")

    -- Which pane the buttons came from. A reward pane this build cannot name is
    -- found by walking the quest frames; when even that finds nothing, this line
    -- is what says whether the walk ran and how much it looked at.
    if results.sources then
        table.insert(lines, "  Found by name: " .. tostring(results.sources.named or 0)
            .. "; found by walking the quest panes: " .. tostring(results.sources.walked or 0)
            .. " (of " .. tostring(results.sources.visited or 0) .. " frames looked at).")
    end
    table.insert(lines, "  Purple = biggest upgrade usable now; blue = the second of "
        .. "those (" .. (rankingOn and "on" or "off") .. "); green = a bigger answer "
        .. "than the saved gear that cannot be used until later; the coin = the most "
        .. "profitable reward, on whatever border it already has ("
        .. (vendorOn and "on" or "off") .. ", never in the quest log).")

    -- Which stat route this client offers. Without one every item scores 0.0 and
    -- no reward can be ranked, so it is printed before any verdict is read.
    if LT.ItemStats and type(LT.ItemStats.DescribeSources) == "function" then
        table.insert(lines, "  " .. LT.ItemStats:DescribeSources())
    end

    if results.buttons == 0 then
        table.insert(lines, "No quest reward buttons are on screen, or this client "
            .. "keeps them somewhere this build does not look. Open a quest that "
            .. "offers items and run /lt quest again.")
        return lines
    end

    -- What the border is being drawn around. This is the one thing /lt quest can
    -- answer and the eye cannot: hug the item's icon, or fall back to the whole
    -- button because no icon region was recognisable on this client.
    if QuestRewards.OutlineAnchor then
        local icons, whole = 0, 0

        for _, row in ipairs(results.rows) do
            local anchor = QuestRewards.OutlineAnchor(row.button)
            if anchor and anchor ~= row.button then
                icons = icons + 1
            else
                whole = whole + 1
            end
        end

        if icons + whole > 0 then
            table.insert(lines, "  Border drawn around: " .. tostring(icons)
                .. " item icon(s), " .. tostring(whole)
                .. " whole button(s) where no icon region could be found.")
        end
    end

    for index, row in ipairs(results.rows) do
        local comparison = row.comparison
        local text = "  " .. tostring(index) .. ". " .. tostring(row.name or row.link)

        if row.difference then
            text = text .. ": " .. tostring(row.status) .. " "
                .. LT:FormatSigned(row.difference, 1)
        else
            text = text .. ": " .. tostring(row.status)
                .. " (" .. tostring(comparison.reason or "no reason given") .. ")"
        end

        if row.sellPrice then
            -- The merchant's own figure, plus the raw copper so a number that
            -- looks wrong can be checked against the counter without a second
            -- round trip.
            text = text .. ", vendor " .. moneyText(row.sellPrice)
                .. " (" .. tostring(row.sellPrice) .. "c)"
        elseif row.coinRefused then
            text = text .. ", coin refused: " .. tostring(row.coinRefused)
        end

        -- A reward that scores 0.0 in an empty slot is not "equal to nothing":
        -- on a client without a stat route there was nothing to weigh. From the
        -- outside that looks exactly like a reward that was graded and lost.
        if row.status == "even" and (row.statCount or 0) <= 1 then
            text = text .. ", no stats read from the client"
        end

        -- A row that already gets a verdict border keeps the colour; the coin is
        -- added on top of it, so /lt quest reports the two channels separately.
        local deferredRow = false

        for _, candidate in ipairs(results.deferred or {}) do
            if candidate == row then deferredRow = true end
        end

        local verdictBorder = (results.best == row)
            or (rankingOn and results.second == row) or deferredRow or false

        if results.best == row then
            text = text .. "   <- purple: biggest upgrade usable now"
        elseif rankingOn and results.second == row then
            text = text .. "   <- blue: second upgrade usable now"
        end

        if deferredRow then
            text = text .. "   <- green: usable later"
            if row.verdictReason then
                text = text .. " (" .. tostring(row.verdictReason) .. ")"
            end
        end

        if vendorOn and results.vendor == row then
            if verdictBorder then
                text = text .. "   <- coin: most profitable reward (added to the border)"
            else
                text = text .. "   <- gold + coin: most profitable reward"
            end
        end

        table.insert(lines, text)
    end

    if refused > 0 then
        table.insert(lines, "Coin refused: " .. tostring(refused)
            .. " quest-log button(s) were never asked for a price — money is not "
            .. "marked in the quest log, while their borders and tooltips are unchanged.")
    end

    if #results.rows < results.buttons then
        table.insert(lines, "  " .. tostring(results.buttons - #results.rows)
            .. " button(s) could not be read as items.")

        -- One line each, in the client's own words. A reward the client cannot
        -- describe cannot be scored, and a caption cannot be drawn over an icon
        -- the addon knows nothing about, so this is the line to read first.
        for index, button in ipairs(results.unread or {}) do
            local label = "button " .. tostring(index)

            if type(button.GetName) == "function" then
                local ok, name = pcall(button.GetName, button)
                if ok and type(name) == "string" and name ~= "" then label = name end
            end

            table.insert(lines, "    " .. label .. ": " .. self:ExplainButton(button))
        end
    end

    if #(results.deferred or {}) > 0 then
        local names = {}

        for _, row in ipairs(results.deferred) do
            table.insert(names, tostring(row.name or row.link))
        end

        table.insert(lines, "Green: " .. table.concat(names, ", ")
            .. ": bigger than the saved gear, but not usable yet, so it is drawn "
            .. "green instead of taking a purple or blue rank.")
    end

    if results.vendor and vendorOn then
        local vendorRow = results.vendor
        local name = tostring(vendorRow.name or vendorRow.link)
        local sell = " — sell this one (" .. moneyText(vendorRow.sellPrice)
            .. "), " .. tostring(vendorRow.sellPrice) .. "c"

        local hasBorder = (results.vendor == results.best)
            or (rankingOn and results.vendor == results.second)

        for _, candidate in ipairs(results.deferred or {}) do
            if candidate == results.vendor then hasBorder = true end
        end

        if hasBorder then
            table.insert(lines, "Coin: " .. name .. sell .. ": the most profitable "
                .. "reward, drawn on top of its own purple, blue or green border "
                .. "rather than replacing it. One icon answers both questions.")
        else
            table.insert(lines, "Gold + coin: " .. name .. sell .. ": the most "
                .. "profitable reward, and it earns no verdict border, so the border "
                .. "itself carries the money meaning.")
        end
    elseif results.vendor then
        table.insert(lines, "The coin is turned off in Settings, so the most profitable "
            .. "reward (" .. tostring(results.vendor.name or results.vendor.link)
            .. ") is not marked.")
    else
        -- No money answer at all: no reward's tooltip showed a price. The coin
        -- competes among every reward, so an upgrade no longer hides a price —
        -- only a missing tooltip line does, and an unknown price is not zero.
        local priced = 0
        for _, row in ipairs(results.rows or {}) do
            if row.sellPrice then priced = priced + 1 end
        end

        local text = "No coin: "
        if #results.rows == 0 then
            text = text .. "no reward button could be read as an item."
        elseif priced == 0 then
            if refused > 0 then
                text = text .. tostring(refused) .. " quest-log button(s) had the coin "
                    .. "refused by name before any price was asked, and no other reward "
                    .. "has a tooltip price; money cannot be compared there."
            else
                text = text .. "no reward's tooltip shows a sell price this client "
                    .. "has loaded yet, so money cannot be compared. That is not a "
                    .. "zero price, just an unknown one."
            end
        else
            text = text .. "no reward reported a price above zero ("
                .. tostring(priced) .. " of " .. tostring(#results.rows) .. " priced)."
        end

        table.insert(lines, text)
    end

    return lines
end