local ADDON, ns = ...

local M = ns:NewModule("minimap", "Minimap", {
    size = 156,
    scale = 1,
    locked = true,
    point = { "TOPRIGHT", "TOPRIGHT", -20, -20 },
    borderSize = 2,
    borderColor = { 0, 0, 0, 1 },
    showZoneText = true,
    showCoords = true,
    showClock = true,
    showCalendar = true,
    mouseWheelZoom = true,
    rightClickTracking = true,
    zoom = 0,          -- 0 is as far out as the client goes
    lockZoom = true,   -- put it back when the game moves it
})

local db
local holder, border, coords

-- Round minimap furniture a square map has no use for.
local KILL = {
    "MinimapBorder",
    "MinimapBorderTop",
    "MinimapNorthTag",
    "MinimapZoomIn",
    "MinimapZoomOut",
    "MiniMapWorldMapButton",
    "MiniMapTracking",
    "MiniMapTrackingButton",
    "MiniMapTrackingBorder",
    "MiniMapMailBorder",
    "MiniMapBattlefieldBorder",
    "MiniMapVoiceChatFrame",
    "MinimapToggleButton",
    "MinimapZoneTextButton",
}

local function Kill(name)
    local f = _G[name]
    if not f then return end
    if f.UnregisterAllEvents then f:UnregisterAllEvents() end
    if f.SetTexture then f:SetTexture(nil) end
    f:Hide()
    if f.Show then f.Show = f.Hide end
end

--------------------------------------------------------------------------------
-- LibDBIcon and most hand rolled minimap buttons read this global to decide
-- where they sit. Returning SQUARE is what stops them orbiting in a circle.
--------------------------------------------------------------------------------

function _G.GetMinimapShape()
    return "SQUARE"
end

-- Declaring the shape is only half of it. LibDBIcon reads GetMinimapShape at the
-- moment it places an icon, and most icons are placed during their own addon's
-- ADDON_LOADED, which happens long before WoidzUI exists. Anything already sitting
-- on the old circle stays there until it is told to recalculate.
function ns.RefreshMinimapIcons()
    if not _G.LibStub then return 0 end

    local ok, lib = pcall(_G.LibStub, "LibDBIcon-1.0", true)
    if not ok or not lib or not lib.GetButtonList then return 0 end

    local names = lib:GetButtonList()
    if not names then return 0 end

    local refreshed = 0
    for _, name in ipairs(names) do
        -- Never refresh a button the tray has taken. LibDBIcon's Refresh
        -- re-reads that icon's saved settings, which is how a captured button
        -- gets its show-on-mouseover fade back and disappears inside the tray.
        local button = (lib.objects and lib.objects[name]) or _G["LibDBIcon10_" .. name]
        if not (button and button.wuiTaken) then
            if pcall(lib.Refresh, lib, name) then
                refreshed = refreshed + 1
            end
        end
    end
    return refreshed
end

--------------------------------------------------------------------------------

local function BuildHolder()
    holder = CreateFrame("Frame", "WoidzUIMinimapHolder", UIParent)
    holder:SetFrameStrata("LOW")
    holder:SetSize(db.size, db.size)
    ns.RestorePosition(holder, db, ns.defaults.minimap.point)
    holder:SetScale(db.scale)

    border = CreateFrame("Frame", "WoidzUIMinimapBorder", holder)
    border:SetFrameStrata("LOW")
    border:SetFrameLevel(holder:GetFrameLevel())
    border.edges = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local tex = border:CreateTexture(nil, "BORDER")
        tex:SetTexture(ns.SOLID)
        border.edges[side] = tex
    end

    ns.RegisterMover(holder, db, "Minimap")
end

local function LayoutBorder()
    local s, c = db.borderSize, db.borderColor
    local e = border.edges

    border:ClearAllPoints()
    border:SetPoint("TOPLEFT", holder, "TOPLEFT", -s, s)
    border:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", s, -s)

    e.TOP:ClearAllPoints()
    e.TOP:SetPoint("TOPLEFT", border, "TOPLEFT")
    e.TOP:SetPoint("TOPRIGHT", border, "TOPRIGHT")
    e.TOP:SetHeight(s)

    e.BOTTOM:ClearAllPoints()
    e.BOTTOM:SetPoint("BOTTOMLEFT", border, "BOTTOMLEFT")
    e.BOTTOM:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT")
    e.BOTTOM:SetHeight(s)

    e.LEFT:ClearAllPoints()
    e.LEFT:SetPoint("TOPLEFT", border, "TOPLEFT")
    e.LEFT:SetPoint("BOTTOMLEFT", border, "BOTTOMLEFT")
    e.LEFT:SetWidth(s)

    e.RIGHT:ClearAllPoints()
    e.RIGHT:SetPoint("TOPRIGHT", border, "TOPRIGHT")
    e.RIGHT:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT")
    e.RIGHT:SetWidth(s)

    for _, tex in pairs(e) do
        tex:SetVertexColor(c[1], c[2], c[3], c[4])
    end
end

--------------------------------------------------------------------------------

local function ReparentMinimap()
    Minimap:SetParent(holder)
    Minimap:ClearAllPoints()
    Minimap:SetAllPoints(holder)
    Minimap:SetMaskTexture(ns.SOLID)
    Minimap:SetFrameStrata("LOW")

    -- MinimapBackdrop is where a lot of third party buttons anchor themselves.
    -- Keep it alive and glued to the map, so anything the tray does not collect
    -- still has a sane parent instead of floating off screen.
    if MinimapBackdrop then
        MinimapBackdrop:SetParent(holder)
        MinimapBackdrop:ClearAllPoints()
        MinimapBackdrop:SetAllPoints(Minimap)
    end

    -- The cluster becomes an empty 1x1 frame. Blizzard's layout code can keep
    -- shoving it around and nothing visible moves with it.
    if MinimapCluster then
        MinimapCluster:EnableMouse(false)
        MinimapCluster:ClearAllPoints()
        MinimapCluster:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
        MinimapCluster:SetSize(1, 1)
    end

    for _, name in ipairs(KILL) do
        Kill(name)
    end
end

--------------------------------------------------------------------------------
-- Zone text, coordinates, corner widgets
--------------------------------------------------------------------------------

local function BuildZoneText()
    if not db.showZoneText then return end
    local zone = holder:CreateFontString("WoidzUIZoneText", "OVERLAY", "GameFontNormalSmall")
    zone:SetPoint("BOTTOMLEFT", holder, "TOPLEFT", 0, 4)
    zone:SetPoint("BOTTOMRIGHT", holder, "TOPRIGHT", 0, 4)
    zone:SetJustifyH("CENTER")
    zone:SetWordWrap(false)
    holder.zone = zone
end

local function UpdateZoneText()
    if not holder or not holder.zone then return end
    holder.zone:SetText(GetMinimapZoneText() or "")

    local pvpType
    if C_PvP and C_PvP.GetZonePVPInfo then
        pvpType = C_PvP.GetZonePVPInfo()
    elseif GetZonePVPInfo then
        pvpType = GetZonePVPInfo()
    end

    if pvpType == "sanctuary" then
        holder.zone:SetTextColor(0.41, 0.8, 0.94)
    elseif pvpType == "arena" or pvpType == "hostile" then
        holder.zone:SetTextColor(1.0, 0.1, 0.1)
    elseif pvpType == "friendly" then
        holder.zone:SetTextColor(0.1, 1.0, 0.1)
    elseif pvpType == "contested" then
        holder.zone:SetTextColor(1.0, 0.7, 0.0)
    else
        holder.zone:SetTextColor(1.0, 1.0, 1.0)
    end
end

local function BuildCoords()
    if not db.showCoords then return end
    coords = holder:CreateFontString("WoidzUICoords", "OVERLAY", "GameFontHighlightSmall")
    coords:SetPoint("BOTTOM", holder, "BOTTOM", 0, 3)
    coords:SetText("")
end

local coordElapsed = 0
local function CoordsOnUpdate(_, elapsed)
    coordElapsed = coordElapsed + elapsed
    if coordElapsed < 0.2 then return end
    coordElapsed = 0

    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not mapID then coords:SetText("") return end

    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then coords:SetText("") return end

    local x, y = pos:GetXY()
    if not x or x == 0 then coords:SetText("") return end

    coords:SetFormattedText("%.1f, %.1f", x * 100, y * 100)
end

local function PlaceCornerWidgets()
    local level = Minimap:GetFrameLevel() + 5

    if MiniMapMailFrame then
        MiniMapMailFrame:SetParent(holder)
        MiniMapMailFrame:ClearAllPoints()
        MiniMapMailFrame:SetPoint("TOPLEFT", holder, "TOPLEFT", 2, -2)
        MiniMapMailFrame:SetFrameLevel(level)
    end

    if MiniMapBattlefieldFrame then
        MiniMapBattlefieldFrame:SetParent(holder)
        MiniMapBattlefieldFrame:ClearAllPoints()
        MiniMapBattlefieldFrame:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
        MiniMapBattlefieldFrame:SetFrameLevel(level)
    end

    if MiniMapInstanceDifficulty then
        MiniMapInstanceDifficulty:SetParent(holder)
        MiniMapInstanceDifficulty:ClearAllPoints()
        MiniMapInstanceDifficulty:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 6, 6)
    end

    if GameTimeFrame then
        if db.showCalendar then
            GameTimeFrame:SetParent(holder)
            GameTimeFrame:ClearAllPoints()
            GameTimeFrame:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 2, 2)
            GameTimeFrame:SetScale(0.8)
            GameTimeFrame:SetFrameLevel(level)
        else
            GameTimeFrame:Hide()
        end
    end
end

--------------------------------------------------------------------------------
-- Looking for group eye
--
-- On 2.5.6 this is LFGMinimapFrame, not MiniMapLFGFrame, and it is a protected
-- frame, so every position change has to stay out of combat. Blizzard anchors it
-- and gives you no way to pick it up, so give it the same drag behaviour every
-- third party minimap button has. The position is stored as an offset from the
-- map's centre rather than a screen point, so it follows the minimap around.
--------------------------------------------------------------------------------

local function LFGEye()
    return _G.LFGMinimapFrame or _G.MiniMapLFGFrame
end

local function PlaceLFGEye()
    local eye = LFGEye()
    if not eye or not holder then return end

    local pos = db.lfgPos
    if not pos then
        pos = { db.size / 2 + 6, 0 }
        db.lfgPos = pos
    end

    eye:ClearAllPoints()
    eye:SetPoint("CENTER", holder, "CENTER", pos[1], pos[2])
end

local function SetupLFGEye()
    local eye = LFGEye()
    if not eye or eye.wuiTaken or eye.wuiEyeReady then return end
    if InCombatLockdown() then return end

    eye.wuiEyeReady = true

    eye:SetParent(holder)
    -- The map sits in LOW. Anything that wants clicks has to be above it, and
    -- MEDIUM is where every other minimap button already lives.
    eye:SetFrameStrata("MEDIUM")
    eye:SetFrameLevel(Minimap:GetFrameLevel() + 10)
    eye:EnableMouse(true)
    eye:SetMovable(true)
    eye:SetClampedToScreen(true)
    eye:RegisterForDrag("LeftButton")

    eye:SetScript("OnDragStart", function(self)
        if InCombatLockdown() then return end
        self:StartMoving()
    end)

    eye:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if InCombatLockdown() then return end

        local hx, hy = holder:GetCenter()
        local ex, ey = self:GetCenter()
        if hx and ex then
            db.lfgPos = { math.floor(ex - hx + 0.5), math.floor(ey - hy + 0.5) }
        end
        PlaceLFGEye()
    end)

    PlaceLFGEye()
end

local function PlaceClock()
    if not TimeManagerClockButton then return end
    if not db.showClock then
        TimeManagerClockButton:Hide()
        return
    end
    TimeManagerClockButton:SetParent(holder)
    TimeManagerClockButton:ClearAllPoints()
    TimeManagerClockButton:SetPoint("TOP", holder, "BOTTOM", 0, -2)
    TimeManagerClockButton:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    -- Drop the round ticket border it wears by default.
    for _, region in ipairs({ TimeManagerClockButton:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "Texture" then
            region:SetTexture(nil)
        end
    end
end

--------------------------------------------------------------------------------
-- Zoom
--
-- The client offers a fixed ladder of zoom levels and 0 is the bottom rung.
-- Nothing widens the map past it: the ground each level covers is baked into the
-- client rather than handed to addons, and a bigger frame spends more pixels on
-- the same ground rather than showing more of it.
--
-- What can be fixed is the drift. The game moves the zoom on its own, walking
-- indoors and back out and again at login, so a map left fully out does not stay
-- fully out. Pinning it is the part the user actually feels.
--------------------------------------------------------------------------------

local function MaxZoom()
    local levels = Minimap.GetZoomLevels and Minimap:GetZoomLevels()
    if type(levels) ~= "number" or levels < 1 then levels = 6 end
    return levels - 1
end
M.MaxZoom = MaxZoom

local function ApplyZoom()
    if not db then return end

    local wanted = math.max(0, math.min(db.zoom or 0, MaxZoom()))

    -- Setting the zoom fires MINIMAP_UPDATE_ZOOM, which lands back in here.
    -- Leaving early when it already matches is what stops that being a loop, so
    -- this test is load bearing rather than an optimisation.
    if Minimap:GetZoom() == wanted then return end

    Minimap:SetZoom(wanted)
end
M.ApplyZoom = ApplyZoom

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

local function HookInput()
    if db.mouseWheelZoom then
        Minimap:EnableMouseWheel(true)
        Minimap:SetScript("OnMouseWheel", function(self, delta)
            local zoom = self:GetZoom()
            local wanted = (delta > 0) and math.min(zoom + 1, MaxZoom())
                or math.max(zoom - 1, 0)

            if wanted == zoom then return end

            -- Written down before the zoom moves, so the lock reads the wheel as
            -- the new intent instead of dragging it straight back.
            db.zoom = wanted
            self:SetZoom(wanted)
        end)
    end

    Minimap:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" and db.rightClickTracking and MiniMapTrackingDropDown then
            ToggleDropDownMenu(1, nil, MiniMapTrackingDropDown, self, 0, 0)
        elseif Minimap_OnClick then
            Minimap_OnClick(self, button)
        end
    end)
end

--------------------------------------------------------------------------------

function M:ApplySize()
    holder:SetSize(db.size, db.size)
    holder:SetScale(db.scale)
    Minimap:SetSize(db.size, db.size)
    LayoutBorder()
end

function M:OnSettingsChanged()
    if not holder then return end
    self:ApplySize()
    ApplyZoom()
    PlaceCornerWidgets()
    PlaceClock()
    SetupLFGEye()
    PlaceLFGEye()
    UpdateZoneText()
    if ns.modules.buttons and ns.modules.buttons.Reanchor then
        ns.modules.buttons:Reanchor()
    end
end

function M:OnEnable(settings)
    db = settings

    BuildHolder()
    ReparentMinimap()
    LayoutBorder()
    BuildZoneText()
    BuildCoords()
    PlaceCornerWidgets()
    PlaceClock()
    SetupLFGEye()
    HookInput()
    self:ApplySize()
    ApplyZoom()
    UpdateZoneText()

    if coords then
        holder:SetScript("OnUpdate", CoordsOnUpdate)
    end

    -- Icons register at their own pace, so sweep on a decaying schedule rather
    -- than assuming everything that will ever exist exists at login.
    ns.RefreshMinimapIcons()
    for _, delay in ipairs({ 1, 3, 6, 12, 25 }) do
        C_Timer.After(delay, function()
            ns.RefreshMinimapIcons()
            SetupLFGEye()
        end)
    end

    local events = CreateFrame("Frame")
    events:RegisterEvent("ZONE_CHANGED")
    events:RegisterEvent("ZONE_CHANGED_INDOORS")
    events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("ADDON_LOADED")
    events:RegisterEvent("MINIMAP_UPDATE_ZOOM")
    -- The eye is protected, so a login that lands in combat cannot touch it.
    -- Try again the moment combat drops.
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:SetScript("OnEvent", function(_, event, arg1)
        if event == "ADDON_LOADED" then
            if arg1 == "Blizzard_TimeManager" then PlaceClock() end
            SetupLFGEye()
            return
        end
        if event == "PLAYER_REGEN_ENABLED" then
            SetupLFGEye()
            return
        end
        if event == "MINIMAP_UPDATE_ZOOM" then
            -- The game moved the zoom, which is what it does on the way indoors
            -- and back out again.
            if db.lockZoom then ApplyZoom() end
            return
        end
        UpdateZoneText()
        if db.lockZoom then ApplyZoom() end
        if event == "PLAYER_ENTERING_WORLD" then
            -- Other addons like to re-round the mask on load. Take it back.
            Minimap:SetMaskTexture(ns.SOLID)
            ns.RefreshMinimapIcons()
            SetupLFGEye()
        end
    end)

    ns.minimapHolder = holder
end

function ns.GetMinimapHolder()
    return holder
end
