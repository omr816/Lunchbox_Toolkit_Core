--[[--------------------------------------------------------------------------
    Lunchbox Toolkit — Minimap
    One small button on the minimap ring: left-click opens the window,
    right-click opens Settings, drag around the ring to move it.

    Why this file exists: the window and the gear check are easy to reach only
    if there is something on screen that is always there. The button is the
    add-on's own: the player's icon from Media\, the same art the window's header
    mark draws and the TOC declares as IconTexture, so the add-on list, the window
    and the minimap all show one piece of art, at the art's own colours. A client
    icon is the fallback for a client that refuses that file, and those are tinted
    with the brand colour so a stock icon still reads as part of the palette. No
    mask and no glyph of our own: both were reported failing on an earlier retest.

    Position is one of the eight compass points on the ring (45° steps), stored
    under character.window.minimapAngle. The stored value is snapped back to a
    compass point on read, so a hand-edited saved variable can never park the
    button off the ring. The compass direction is scaled into the minimap's
    current shape (circle unless the client reports a square), so the 20x20
    button stays on the rim at every angle, and a resize re-lays it out.

    The dot starts off: the client's addon compartment is the launcher now, fed
    by ## AddonCompartmentFunc in both TOCs. The dot is an opt-in extra.

    Nothing here builds or moves a frame while the player is in combat. The
    button is created on login when possible; if login happens in combat the
    work waits for PLAYER_REGEN_ENABLED.
--------------------------------------------------------------------------]]
local LT = LunchboxToolkit
if type(LT) ~= "table" then return end

local Minimap = {}
LT.Minimap = Minimap

if type(LT.Modules) == "table" then
    LT.Modules.Minimap = Minimap
end

local BUTTON_SIZE = 20
local DEFAULT_ANGLE = 225   -- bottom-left, the quiet corner beside the ring
local ANGLES = { 0, 45, 90, 135, 180, 225, 270, 315 }

-- The client can reshape the ring (round, square, a rounded corner). The layout
-- asks once per move and falls back to a circle, which fits every shape.
local function minimapShape()
    if type(GetMinimapShape) ~= "function" then return nil end
    local ok, shape = pcall(GetMinimapShape)
    if ok and type(shape) == "string" then return shape end
    return nil
end

-- WoW's Lua 5.1 exposes math.atan2; newer Lua folds the two-argument form into
-- math.atan. Both are kept working rather than assuming one client's runtime.
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local button
local shapesUnavailable = false   -- no icon texture could be made

------------------------------------------------------------------------------
-- Safe client surface
------------------------------------------------------------------------------

local function inCombat()
    if type(InCombatLockdown) ~= "function" then return false end

    local ok, value = pcall(InCombatLockdown)
    return ok and value and true or false
end

local function cursorPosition()
    if type(GetCursorPosition) ~= "function" then return nil, nil end

    local ok, x, y = pcall(GetCursorPosition)
    if not ok or type(x) ~= "number" or type(y) ~= "number" then return nil, nil end
    return x, y
end

-- Palette.lua loads before this file and owns every visible colour, so there is
-- no second set of numbers here to drift from it.
local function paletteRGB(key)
    local palette = LT.Palette
    if type(palette) == "table" and type(palette.RGB) == "function" then
        local ok, value = pcall(palette.RGB, palette, key)
        if ok and type(value) == "table" then return value end
    end

    return nil
end

------------------------------------------------------------------------------
-- Saved position and visibility
------------------------------------------------------------------------------

-- The same character window record UI.lua writes: the page and the window
-- place live there too, so this adds no new saved-variables table.
local function windowRecord()
    local database = LT.Database
    local character = database and database.character
    if type(character) ~= "table" then return nil end

    if type(character.window) ~= "table" then
        character.window = {}
    end

    return character.window
end

-- Nearest of the eight ring angles. The default is used for a missing or
-- unreadable value; a number that is not on a compass point is snapped to the
-- one it is closest to.
function Minimap:NormalizeAngle(angle)
    local value = tonumber(angle)
    if not value then return DEFAULT_ANGLE end

    value = value % 360

    local best = DEFAULT_ANGLE
    local bestDistance = math.huge

    for _, candidate in ipairs(ANGLES) do
        local difference = math.abs(((value - candidate + 180) % 360) - 180)
        if difference < bestDistance then
            bestDistance = difference
            best = candidate
        end
    end

    return best
end

function Minimap:GetAngle()
    local record = windowRecord()
    return self:NormalizeAngle(record and record.minimapAngle)
end

-- Only an explicit true shows the button. The addon compartment in both TOCs is
-- the launcher now, so the dot starts off and a missing, nil or non-boolean key
-- stays off.
function Minimap:IsEnabled()
    local database = LT.Database
    local character = database and database.character
    local options = type(character) == "table" and character.options or nil
    local value
    if type(options) == "table" then value = options.minimapButton end

    return value == true
end

------------------------------------------------------------------------------
-- Ring geometry
------------------------------------------------------------------------------

-- x, y are offsets from the centre of the minimap in the minimap's own units.
-- The compass direction is a unit vector scaled to the largest point the shape
-- allows, so at 45 degrees the button stays on the rim instead of leaving a
-- round ring. A square shape scales into the box; every other shape (and a
-- client with no shape call) is treated as a circle of radius half its shorter
-- side, less half the button. The width/height arguments cover a resized ring
-- and fall back to one sane size when the client has not laid it out yet.
function Minimap:PositionFor(angle, minimapWidth, minimapHeight, size, shape)
    local width = tonumber(minimapWidth)
    if not width or width <= 0 then width = 140 end

    local height = tonumber(minimapHeight)
    if not height or height <= 0 then height = width end

    local box = tonumber(size)
    if not box or box <= 0 then box = BUTTON_SIZE end

    local halfWidth = width / 2
    local halfHeight = height / 2
    local inset = box / 2
    local maxX = math.max(0, halfWidth - inset)
    local maxY = math.max(0, halfHeight - inset)
    local radians = math.rad(self:NormalizeAngle(angle))

    local dirX = math.cos(radians)
    local dirY = math.sin(radians)
    local scale

    if shape == "SQUARE" then
        -- Scale the unit vector until it touches one of the two inset edges.
        local limitX = (math.abs(dirX) > 1e-6) and (maxX / math.abs(dirX)) or math.huge
        local limitY = (math.abs(dirY) > 1e-6) and (maxY / math.abs(dirY)) or math.huge
        scale = math.min(limitX, limitY)
        if scale == math.huge then scale = 0 end
    else
        -- A circle is defined by its shorter side, so an oval or a rounded
        -- corner stays inside the drawn shape as well.
        scale = math.min(maxX, maxY)
    end

    return dirX * scale, dirY * scale
end

local function applyPosition()
    if not button then return end
    if inCombat() then return end

    local minimap = _G.Minimap
    if not minimap then return end

    local width = minimap.GetWidth and minimap:GetWidth() or 0
    local height = minimap.GetHeight and minimap:GetHeight() or 0
    local x, y = Minimap:PositionFor(Minimap:GetAngle(), width, height, BUTTON_SIZE, minimapShape())

    button:ClearAllPoints()
    button:SetPoint("CENTER", minimap, "CENTER", x, y)
end

function Minimap:SetAngle(angle)
    -- Moving the dot is a UI change; it waits for the fight like every other
    -- structural step in this file.
    if inCombat() then return self:GetAngle() end

    local snapped = self:NormalizeAngle(angle)

    local record = windowRecord()
    if record then record.minimapAngle = snapped end

    applyPosition()
    return snapped
end

------------------------------------------------------------------------------
-- Tooltip text
------------------------------------------------------------------------------

-- Read at hover time, so changing the active slot is reflected without any
-- event wiring.
function Minimap:TooltipLines()
    local builds = LT.Builds
    local index = 1

    if type(builds) == "table" and type(builds.GetActiveIndex) == "function" then
        local ok, value = pcall(builds.GetActiveIndex, builds)
        if ok and tonumber(value) then index = tonumber(value) end
    end

    local name = "Build " .. tostring(index)

    if type(builds) == "table" and type(builds.GetActive) == "function" then
        local ok, build = pcall(builds.GetActive, builds)
        if ok and type(build) == "table" and build.name and build.name ~= "" then
            name = tostring(build.name)
        end
    end

    return LT.displayName or "Lunchbox Toolkit",
        "Slot " .. tostring(index) .. " · " .. name,
        "Left-click options, right-click settings"
end

local function hideTooltip()
    if not GameTooltip then return end

    local owner
    if type(GameTooltip.GetOwner) == "function" then
        local ok, value = pcall(GameTooltip.GetOwner, GameTooltip)
        if ok then owner = value end
    end

    if not owner or owner == button then
        pcall(GameTooltip.Hide, GameTooltip)
    end
end

function Minimap:ShowTooltip(owner)
    if not GameTooltip or not (owner or button) then return end

    local title, buildLine, hint = self:TooltipLines()
    local brand = paletteRGB("brand")
    local text = paletteRGB("text")
    local muted = paletteRGB("muted")
    if not brand or not text or not muted then return end

    pcall(GameTooltip.SetOwner, GameTooltip, owner or button, "ANCHOR_LEFT")
    pcall(GameTooltip.SetText, GameTooltip, title, brand.r, brand.g, brand.b)
    pcall(GameTooltip.AddLine, GameTooltip, buildLine, text.r, text.g, text.b)
    pcall(GameTooltip.AddLine, GameTooltip, hint, muted.r, muted.g, muted.b)
    pcall(GameTooltip.Show, GameTooltip)
end

------------------------------------------------------------------------------
-- Clicking
------------------------------------------------------------------------------

local function toggleWindow()
    local ui = LT.UI
    if type(ui) ~= "table" or type(ui.Toggle) ~= "function" then
        LT:Error("The main window module is not loaded.")
        return
    end

    local ok, err = pcall(ui.Toggle, ui)
    if not ok then LT:Error("Opening the window failed: " .. tostring(err)) end
end

local function openSettings()
    local ui = LT.UI
    if type(ui) ~= "table" or type(ui.Show) ~= "function" then
        LT:Error("The main window module is not loaded.")
        return
    end

    -- ShowPage keeps the chosen page in the character record, so the window
    -- opens on Settings now and after the next /reload.
    if type(ui.ShowPage) == "function" then
        local ok, err = pcall(ui.ShowPage, ui, "settings")
        if not ok then
            LT:Error("Opening Settings failed: " .. tostring(err))
            return
        end
    end

    local ok, err = pcall(ui.Show, ui)
    if not ok then LT:Error("Opening the window failed: " .. tostring(err)) end
end

local function openWindow()
    local ui = LT.UI
    if type(ui) ~= "table" or type(ui.Show) ~= "function" then
        LT:Error("The main window module is not loaded.")
        return
    end

    local ok, err = pcall(ui.Show, ui)
    if not ok then LT:Error("Opening the window failed: " .. tostring(err)) end
end

-- The addon compartment (## AddonCompartmentFunc* in both TOCs) is the client's
-- own launcher, so its click opens the window rather than toggling it like the
-- minimap dot. Enter and leave draw and clear a one-line tooltip.
function LunchboxToolkit_OnAddonCompartmentClick()
    openWindow()
end

function LunchboxToolkit_OnAddonCompartmentEnter(_, buttonName)
    if not GameTooltip then return end

    local owner = buttonName
    if type(owner) ~= "table" and type(owner) ~= "userdata" then owner = UIParent end
    if not owner then return end

    -- The compartment sits at the right of the screen, so the tip opens left.
    pcall(GameTooltip.SetOwner, GameTooltip, owner, "ANCHOR_LEFT")
    pcall(GameTooltip.SetText, GameTooltip, LT.displayName or "Lunchbox Toolkit")
    if type(GameTooltip.AddLine) == "function" then
        pcall(GameTooltip.AddLine, GameTooltip, "Click to open the window")
    end
    pcall(GameTooltip.Show, GameTooltip)
end

function LunchboxToolkit_OnAddonCompartmentLeave(_, buttonName)
    if not GameTooltip then return end

    local owner
    if type(GameTooltip.GetOwner) == "function" then
        local ok, value = pcall(GameTooltip.GetOwner, GameTooltip)
        if ok then owner = value end
    end

    if not owner or not buttonName or owner == buttonName then
        pcall(GameTooltip.Hide, GameTooltip)
    end
end

local dragged = false
local pressX, pressY

local function cursorMoved()
    if not pressX or not pressY then return false end

    local x, y = cursorPosition()
    if not x or not y then return false end

    local scale = 1
    if button and button.GetEffectiveScale then
        local ok, value = pcall(button.GetEffectiveScale, button)
        if ok and tonumber(value) and tonumber(value) > 0 then scale = tonumber(value) end
    end

    local dx = (x - pressX) / scale
    local dy = (y - pressY) / scale
    return (dx * dx + dy * dy) > 64   -- an 8-pixel drag is not a click
end

local function angleFromCursor()
    local x, y = cursorPosition()
    if not x or not y then return nil end

    local minimap = _G.Minimap
    if not minimap then return nil end

    local scale = 1
    if minimap.GetEffectiveScale then
        local ok, value = pcall(minimap.GetEffectiveScale, minimap)
        if ok and tonumber(value) and tonumber(value) > 0 then scale = tonumber(value) end
    end

    local centerX, centerY
    if minimap.GetCenter then
        local ok, mx, my = pcall(minimap.GetCenter, minimap)
        if ok and tonumber(mx) and tonumber(my) then
            centerX, centerY = tonumber(mx), tonumber(my)
        end
    end

    if not centerX or not centerY then return nil end

    return math.deg(atan2(y / scale - centerY, x / scale - centerX))
end

------------------------------------------------------------------------------
-- Building the button
------------------------------------------------------------------------------

-- The player's own art comes first: the TGA in Media\, the same file the window's
-- header mark draws and the TOC declares as IconTexture. It is drawn untinted —
-- the tint below exists to make a stock client icon read as part of the palette,
-- and multiplying the player's own colours by the brand colour would only dirty
-- them. The rest are the client icons that were already in the build, in the order
-- they were trusted: the chest plate, the engineering toolbox, the engineering
-- gizmo, then a plain gear. The last two ship with every client, so the dot still
-- draws where the earlier files cannot be read. No mask or glyph is used: both were
-- reported failing on the 1.5.3 retest and left an empty blue rectangle, so the
-- accepted texture itself has to be the visible dot.
local DOT_ICONS = {
    { file = "Interface\\AddOns\\LunchboxToolkit\\Media\\Inv_treasurechest_felfirecitadel_64",
      untinted = true },
    { file = "Interface\\Icons\\INV_Chest_Plate03" },
    { file = "Interface\\Icons\\Trade_Engineering" },
    { file = "Interface\\Icons\\INV_Misc_EngGizmos_12" },
    { file = "Interface\\Icons\\INV_Misc_Gear_01" },
}

-- A stock icon is multiplied by the brand colour the caller hands in; the player's
-- art is multiplied by white, which leaves it exactly as drawn.
local UNTINTED = { r = 1, g = 1, b = 1 }

-- One icon texture in the brand colour. The first icon file the client accepts
-- is the one drawn; a client that refuses a file moves on to the next. nil
-- means no icon could be shown, and the caller hides the button rather than
-- leaving an empty rectangle on the minimap.
local function iconDot(parent, layer, colour, alpha)
    if type(parent.CreateTexture) ~= "function" then return nil end

    local ok, texture = pcall(parent.CreateTexture, parent, nil, layer)
    if not ok or (type(texture) ~= "table" and type(texture) ~= "userdata") then
        return nil
    end
    if type(texture.SetTexture) ~= "function" then return nil end
    if type(texture.SetVertexColor) ~= "function" then return nil end

    local chosen
    for _, entry in ipairs(DOT_ICONS) do
        local file = entry.file or entry
        -- An accepted file answers nothing on older clients, so only an
        -- explicit false counts as "this client will not take the icon".
        local okFile, accepted = pcall(texture.SetTexture, texture, file)
        if okFile and accepted ~= false then
            chosen = entry
            break
        end
    end

    if not chosen then
        pcall(texture.Hide, texture)
        return nil
    end

    -- The player's own art keeps the colours it was drawn in; a stock icon takes
    -- the tint the caller asked for. Nothing here can tell whether a file exists on
    -- disk — a refused call is the only signal the API gives.
    local tint = colour
    if type(chosen) == "table" and chosen.untinted then tint = UNTINTED end
    if type(tint) ~= "table" then tint = UNTINTED end

    pcall(texture.SetSize, texture, BUTTON_SIZE, BUTTON_SIZE)
    pcall(texture.SetPoint, texture, "CENTER", parent, "CENTER", 0, 0)
    pcall(texture.SetVertexColor, texture, tint.r, tint.g, tint.b, alpha or 1)

    return texture
end

function Minimap:Create()
    if button then return button end
    if shapesUnavailable then return nil end
    if inCombat() then return nil end   -- never build a frame during combat

    local minimap = _G.Minimap
    if not minimap then return nil end

    local brand = paletteRGB("brand")
    if not brand then return nil end

    local ok, created = pcall(CreateFrame, "Button", nil, minimap)
    if not ok or not created then return nil end

    button = created
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    if button.SetFrameLevel and minimap.GetFrameLevel then
        local okLevel, level = pcall(minimap.GetFrameLevel, minimap)
        if okLevel and tonumber(level) then
            pcall(button.SetFrameLevel, button, tonumber(level) + 8)
        end
    end
    button:EnableMouse(true)
    button:RegisterForDrag("LeftButton")
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- The dot is the player's own art at the art's own colours; a client that
    -- refuses that file falls back to a stock icon tinted with the brand colour.
    -- There is no mask and no glyph, and no flat colour texture, so the button
    -- cannot come back as an empty rectangle.
    local dot = iconDot(button, "ARTWORK", brand, 1)

    if not dot then
        -- No icon at all: hide and forget the button rather than leave an
        -- invisible, clickable square on the minimap, and stop retrying.
        button:Hide()
        button = nil
        shapesUnavailable = true
        return nil
    end

    -- The hover glow is the same icon, one layer up, at 0.3 alpha.
    local highlight = iconDot(button, "OVERLAY", brand, 0.30)

    if highlight then
        highlight:Hide()
    end

    button:SetScript("OnEnter", function(self)
        if highlight then highlight:Show() end
        Minimap:ShowTooltip(self)
    end)

    button:SetScript("OnLeave", function()
        if highlight then highlight:Hide() end
        hideTooltip()
    end)

    button:SetScript("OnMouseDown", function(_, mouseButton)
        if mouseButton ~= "LeftButton" then
            pressX, pressY = nil, nil
            dragged = false
            return
        end

        pressX, pressY = cursorPosition()
        dragged = false
    end)

    button:SetScript("OnDragStart", function()
        if inCombat() then return end

        dragged = true
        hideTooltip()
    end)

    button:SetScript("OnDragStop", function()
        if inCombat() then
            dragged = false
            return
        end

        local angle = angleFromCursor()
        if angle then Minimap:SetAngle(angle) end
    end)

    button:SetScript("OnClick", function(_, mouseButton)
        -- A drag ends with a click on the same button; that click must not also
        -- open or close the window.
        if dragged or cursorMoved() then
            dragged = false
            pressX, pressY = nil, nil
            return
        end

        pressX, pressY = nil, nil

        if mouseButton == "RightButton" then
            openSettings()
        else
            toggleWindow()
        end
    end)

    -- The ring can be resized by the client (resolution or UI scale). Move with
    -- it, but never mid-fight.
    if type(minimap.HookScript) == "function" then
        pcall(minimap.HookScript, minimap, "OnSizeChanged", function()
            if inCombat() then
                Minimap.pending = true
            else
                applyPosition()
            end
        end)
    end

    return button
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

function Minimap:Refresh()
    if inCombat() then
        self.pending = true
        return
    end

    self.pending = false

    if not self:IsEnabled() then
        if button then
            hideTooltip()
            button:Hide()
        end
        return
    end

    if not button and not self:Create() then return end

    applyPosition()
    button:Show()
end

local function onEvent(_, event)
    if event == "PLAYER_LOGIN" then
        Minimap:Refresh()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if Minimap.pending then
            Minimap:Refresh()
        end
    end
end

-- The option lives in the same character record as the rest of Settings, so a
-- save that flips it applies without waiting for the next login. Refresh is a
-- no-op mid-fight, exactly like every other visibility change here.
if type(LT.On) == "function" then
    pcall(LT.On, LT, LT.EVENT_PROFILE, function() Minimap:Refresh() end, Minimap)
end

-- Ride the core's event frame instead of creating one of our own: at file load
-- the client may already be in combat, and this module must not create a frame
-- there. The hook runs after Core's own handler, so the database and the class
-- records are ready by the time PLAYER_LOGIN reaches us.
local coreFrame = LT.frame
if coreFrame then
    if type(coreFrame.RegisterEvent) == "function" then
        pcall(coreFrame.RegisterEvent, coreFrame, "PLAYER_REGEN_ENABLED")
    end

    if type(coreFrame.HookScript) == "function" then
        pcall(coreFrame.HookScript, coreFrame, "OnEvent", onEvent)
    end
end
