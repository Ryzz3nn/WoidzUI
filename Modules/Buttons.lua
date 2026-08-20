local ADDON, ns = ...

local M = ns:NewModule("buttons", "Minimap button tray", {
    columns = 6,
    buttonSize = 32,
    spacing = 6,
    padding = 10,
    autoClose = true,
    stripBorders = true,
    collectBlizzard = false,
    anchorPoint = "BOTTOMRIGHT",
    togglePlacement = "below", -- below | corner
    trayGrowth = "DOWN", -- DOWN | UP | LEFT | RIGHT
    ignored = {},
})

local db
local tray, toggle
local collected = {}
local collectedByName = {}
local applying = false

--------------------------------------------------------------------------------
-- What never gets swallowed
--------------------------------------------------------------------------------

local BLIZZARD = {
    MinimapCluster = true, MinimapBackdrop = true, MinimapZoneTextButton = true,
    MinimapZoomIn = true, MinimapZoomOut = true, MinimapNorthTag = true,
    MinimapBorder = true, MinimapBorderTop = true, MinimapPing = true,
    MiniMapWorldMapButton = true, MiniMapTracking = true, MiniMapTrackingButton = true,
    MiniMapTrackingFrame = true, MiniMapMailFrame = true, MiniMapMailBorder = true,
    MiniMapBattlefieldFrame = true, MiniMapVoiceChatFrame = true,
    MiniMapInstanceDifficulty = true, MiniMapLFGFrame = true,
    QueueStatusMinimapButton = true, GameTimeFrame = true,
    TimeManagerClockButton = true, MinimapZoneText = true,
    WoidzUIMinimapButton = true, WoidzUIButtonTray = true,
    WoidzUIMinimapHolder = true, WoidzUIMinimapBorder = true,
}

-- Blizzard widgets the tray is allowed to swallow when the user asks for it.
-- The looking for group eye is the one people most often want moved, because
-- Blizzard anchors it and nothing on the default UI lets you pick it up.
local BLIZZARD_OPTIONAL = {
    MiniMapLFGFrame = true,
    LFGMinimapFrame = true,
    GameTimeFrame = true,
    MiniMapTracking = true,
    MiniMapBattlefieldFrame = true,
    MiniMapMailFrame = true,
}

local function PrettyName(name)
    local pretty = name:gsub("^LibDBIcon10_", "")
    pretty = pretty:gsub("^MinimapButton", "")
    pretty = pretty:gsub("MinimapButton$", "")
    pretty = pretty:gsub("MinimapIcon$", "")
    pretty = pretty:gsub("MinimapFrame$", "")
    return pretty ~= "" and pretty or name
end
M.PrettyName = PrettyName

-- Plenty of minimap buttons are created with a nil name. Fall back to the icon
-- texture, which is stable across sessions and good enough to key an ignore
-- entry on. A button with neither is not something we can track, so it is left
-- where it is.
local function DeriveName(f)
    local name = f.GetName and f:GetName()
    if name then return name end

    for _, region in ipairs({ f:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "Texture" then
            local tex = region:GetTexture()
            if type(tex) == "string" then
                local leaf = tex:match("([^\\/]+)$")
                if leaf and leaf ~= "" then return "Anon:" .. leaf end
            end
        end
    end
    return nil
end

-- Returns true, or false plus the reason, which /wui debug prints.
local function IsCandidate(f)
    if not f or type(f) ~= "table" or not f.GetObjectType then return false, "not a frame" end
    if f.IsForbidden and f:IsForbidden() then return false, "forbidden" end

    local objType = f:GetObjectType()
    if objType ~= "Button" and objType ~= "Frame" then return false, "object type " .. objType end
    if f.wuiTaken then return false, "already in the tray" end

    local realName = f.GetName and f:GetName()
    if realName then
        if BLIZZARD_OPTIONAL[realName] then
            if not db.collectBlizzard then
                return false, "blizzard widget, turn on Collect Blizzard buttons to move it"
            end
        elseif BLIZZARD[realName] then
            return false, "blizzard frame"
        elseif realName:find("^Mini[Mm]ap") then
            -- Anything Blizzard named is left alone unless it is allowed above.
            return false, "blizzard name prefix"
        end
    end

    -- Protected frames can taint if we start moving them around.
    if f.IsProtected and f:IsProtected() then return false, "protected" end

    local w = f:GetWidth() or 0
    if w < 15 then return false, string.format("too small (%.0f)", w) end
    if w > 60 then return false, string.format("too big (%.0f)", w) end

    if not DeriveName(f) then return false, "no name and no icon texture" end

    return true
end

--------------------------------------------------------------------------------
-- Taking a button over
--
-- Hooking SetPoint is not enough: some buttons re-anchor themselves every frame
-- and would fight the layout forever. Shadowing the widget methods with no-ops
-- ends the argument, and the real methods are kept for our own repositioning
-- and for handing the button back if it gets un-ignored.
--------------------------------------------------------------------------------

-- LibDBIcon icons registered with "show on mouseover" own a fadeOut animation
-- group that drives them to alpha 0 whenever the mouse is not over the minimap.
-- An animation group overrides SetAlpha for as long as it is playing, so a plain
-- SetAlpha(1) loses and the tray fills with invisible buttons. Stop the group and
-- clear the flag LibDBIcon's OnLeave reads before restarting it.
local function KillFade(btn)
    if btn.fadeOut and btn.fadeOut.Stop then
        btn.fadeOut:Stop()
    end

    if btn.GetAnimationGroups then
        for _, group in ipairs({ btn:GetAnimationGroups() }) do
            if group.IsPlaying and group:IsPlaying() then group:Stop() end
        end
    end

    -- Only the live field, never button.db. That table belongs to the other
    -- addon and writing to it would change the user's setting for good.
    btn.showOnMouseover = false
    btn:SetAlpha(1)
end

local function Neuter(btn)
    btn.wuiReal = {
        SetPoint = btn.SetPoint,
        ClearAllPoints = btn.ClearAllPoints,
        SetParent = btn.SetParent,
        SetSize = btn.SetSize,
        SetWidth = btn.SetWidth,
        SetHeight = btn.SetHeight,
    }
    local noop = function() end
    btn.SetPoint = noop
    btn.ClearAllPoints = noop
    btn.SetParent = noop
end

local function Restore(btn)
    local real = btn.wuiReal
    if not real then return end
    btn.SetPoint = nil
    btn.ClearAllPoints = nil
    btn.SetParent = nil
    btn.wuiReal = nil
    return real
end

--------------------------------------------------------------------------------
-- Minimap buttons wear a ring roughly 1.7x their own size, drawn in an overlay
-- layer. Packed into a grid those rings overlap and mask the icons underneath,
-- which reads as a sheet of grey blobs. Hide the ring and let the icon fill the
-- cell instead. Everything hidden is remembered so a button handed back to the
-- minimap looks exactly like it did before.
--------------------------------------------------------------------------------

local function LooksLikeRing(region, width)
    local tex = region.GetTexture and region:GetTexture()
    local path = type(tex) == "string" and tex:lower() or ""
    if path:find("border") or path:find("tracking") or path:find("ui%-minimap") then
        return true
    end
    local rw = region:GetWidth() or 0
    return rw > width * 1.25
end

local function LooksLikeIcon(region)
    local tex = region.GetTexture and region:GetTexture()
    local path = type(tex) == "string" and tex:lower() or ""
    return path:find("icons\\") or path:find("icons/") or region:GetDrawLayer() == "ARTWORK"
end

local function StripBorder(btn)
    if not db.stripBorders then return end

    local width = btn.wuiOrigSize[1]
    if not width or width <= 0 then width = 32 end

    btn.wuiHidden = {}
    local icon

    for _, region in ipairs({ btn:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "Texture" and region:IsShown() then
            if LooksLikeRing(region, width) then
                btn.wuiHidden[#btn.wuiHidden + 1] = region
                region:Hide()
            elseif not icon and LooksLikeIcon(region) then
                icon = region
            end
        end
    end

    if icon then
        btn.wuiIcon = icon
        btn.wuiIconPoints = {}
        for i = 1, icon:GetNumPoints() do
            btn.wuiIconPoints[i] = { icon:GetPoint(i) }
        end
        btn.wuiIconCoords = { icon:GetTexCoord() }
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:SetDrawLayer("ARTWORK")
    end
end

local function UnstripBorder(btn)
    for _, region in ipairs(btn.wuiHidden or {}) do
        region:Show()
    end
    btn.wuiHidden = nil

    local icon = btn.wuiIcon
    if icon then
        icon:ClearAllPoints()
        for _, p in ipairs(btn.wuiIconPoints or {}) do
            icon:SetPoint(unpack(p))
        end
        local c = btn.wuiIconCoords
        if c and #c >= 8 then
            icon:SetTexCoord(c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8])
        end
        btn.wuiIcon = nil
        btn.wuiIconPoints = nil
        btn.wuiIconCoords = nil
    end
end

--------------------------------------------------------------------------------
-- Dragging a button out of the tray and onto the minimap hands it back. The
-- addon that owns it takes over placement again, and because GetMinimapShape
-- now answers SQUARE it lands on the square edge instead of an invisible circle.
--------------------------------------------------------------------------------

local function Btn_OnDragStart(self)
    if not self.wuiTaken then return end
    applying = true
    self.wuiReal.SetParent(self, UIParent)
    applying = false
    self:SetFrameStrata("TOOLTIP")
    self:StartMoving()
    self.wuiDragging = true
end

local function Btn_OnDragStop(self)
    if not self.wuiDragging then return end
    self.wuiDragging = nil
    self:StopMovingOrSizing()

    local holder = ns.GetMinimapHolder() or Minimap
    if holder:IsMouseOver(36, -36, -36, 36) then
        M:SetIgnored(self.wuiName, true)
        ns.Print(M.PrettyName(self.wuiName) .. " left on the minimap.")
        return
    end

    applying = true
    self.wuiReal.SetParent(self, tray.content)
    applying = false
    self:SetFrameLevel(tray:GetFrameLevel() + 8)
    M:Layout()
end

local function Take(btn, name)
    btn.wuiTaken = true
    btn.wuiName = name
    btn.wuiOrigParent = btn:GetParent()
    btn.wuiOrigSize = { btn:GetWidth(), btn:GetHeight() }
    btn.wuiOrigPoints = {}
    for i = 1, btn:GetNumPoints() do
        btn.wuiOrigPoints[i] = { btn:GetPoint(i) }
    end
    btn.wuiOrigDragStart = btn:GetScript("OnDragStart")
    btn.wuiOrigDragStop = btn:GetScript("OnDragStop")

    StripBorder(btn)

    -- Their drag moved them around the minimap. Ours moves them out of the tray.
    if btn.SetScript then
        btn:SetMovable(true)
        btn:SetClampedToScreen(true)
        btn:RegisterForDrag("LeftButton")
        btn:SetScript("OnDragStart", Btn_OnDragStart)
        btn:SetScript("OnDragStop", Btn_OnDragStop)
    end

    Neuter(btn)

    applying = true
    btn.wuiReal.SetParent(btn, tray.content)
    btn.wuiReal.ClearAllPoints(btn)
    applying = false

    KillFade(btn)
    btn:SetFrameLevel(tray:GetFrameLevel() + 8)
    btn:Show()

    collected[#collected + 1] = btn
    collectedByName[name] = btn
end

local function Give(btn)
    UnstripBorder(btn)
    local real = Restore(btn)
    if real then
        real.SetParent(btn, btn.wuiOrigParent or Minimap)
        real.ClearAllPoints(btn)
        for _, p in ipairs(btn.wuiOrigPoints or {}) do
            real.SetPoint(btn, unpack(p))
        end
        if btn.wuiOrigSize then
            real.SetSize(btn, btn.wuiOrigSize[1], btn.wuiOrigSize[2])
        end
    end
    if btn.SetScript then
        btn:SetScript("OnDragStart", btn.wuiOrigDragStart)
        btn:SetScript("OnDragStop", btn.wuiOrigDragStop)
        btn:SetMovable(true)
    end
    btn:SetFrameStrata("MEDIUM")
    collectedByName[btn.wuiName or ""] = nil
    btn.wuiTaken = nil
end

--------------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------------

-- The holder is a scan root too: the minimap module reparents the Blizzard
-- widgets onto it, so without this the looking for group eye and the calendar
-- are invisible to the scanner.
local SCAN_ROOTS = { "Minimap", "MinimapBackdrop", "MinimapCluster", "WoidzUIMinimapHolder" }

function M:Scan()
    if not tray then return 0 end
    local found = 0

    for _, rootName in ipairs(SCAN_ROOTS) do
        local root = _G[rootName]
        if root and root.GetChildren then
            for _, child in ipairs({ root:GetChildren() }) do
                if IsCandidate(child) then
                    local name = DeriveName(child)
                    if name and not db.ignored[name] then
                        Take(child, name)
                        found = found + 1
                    end
                end
            end
        end
    end

    if found > 0 then
        table.sort(collected, function(a, b)
            return PrettyName(a.wuiName):lower() < PrettyName(b.wuiName):lower()
        end)
        self:Layout()
    end
    self:UpdateCount()
    return found
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

function M:Layout()
    if not tray then return end
    applying = true

    local size, spacing, pad = db.buttonSize, db.spacing, db.padding
    local cols = math.max(1, db.columns)
    local shown = 0

    -- Levels are re-stamped on every layout, not just on capture. The tray's own
    -- level can move underneath us, and a button that ends up below it is both
    -- dimmed by the backdrop and unclickable.
    local base = tray:GetFrameLevel()
    tray.content:SetFrameLevel(base + 1)

    for _, btn in ipairs(collected) do
        local col = shown % cols
        local row = math.floor(shown / cols)
        btn.wuiReal.ClearAllPoints(btn)
        btn.wuiReal.SetPoint(btn, "TOPLEFT", tray.content, "TOPLEFT",
            col * (size + spacing), -row * (size + spacing))
        btn.wuiReal.SetSize(btn, size, size)
        btn:SetFrameLevel(base + 8)
        btn:EnableMouse(true)
        KillFade(btn)
        shown = shown + 1
    end

    local count = math.max(shown, 1)
    local usedCols = math.min(count, cols)
    local rows = math.ceil(count / cols)

    tray.content:SetSize(
        usedCols * size + (usedCols - 1) * spacing,
        rows * size + (rows - 1) * spacing
    )
    tray:SetSize(
        tray.content:GetWidth() + pad * 2,
        tray.content:GetHeight() + pad * 2 + 16
    )

    applying = false
    self:Fit()
end

-- The tray hangs off the minimap, and the minimap usually lives in a corner, so
-- a wide grid runs straight off the screen. Re-apply the anchor, measure, and
-- slide it back inside.
function M:Fit()
    local base = tray and tray.baseAnchor
    if not base then return end

    tray:ClearAllPoints()
    tray:SetPoint(base[1], base[2], base[3], base[4], base[5])

    local pad = 6
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    local l, r, b, t = tray:GetLeft(), tray:GetRight(), tray:GetBottom(), tray:GetTop()
    local dx, dy = 0, 0

    if l and r then
        if l < pad then
            dx = pad - l
        elseif r > sw - pad then
            dx = (sw - pad) - r
        end
    end
    if b and t then
        if b < pad then
            dy = pad - b
        elseif t > sh - pad then
            dy = (sh - pad) - t
        end
    end

    if dx ~= 0 or dy ~= 0 then
        tray:ClearAllPoints()
        tray:SetPoint(base[1], base[2], base[3], base[4] + dx, base[5] + dy)
    end
end

function M:UpdateCount()
    if not toggle then return end
    local n = #collected
    toggle.count:SetText(n > 0 and tostring(n) or "")
    toggle.count:SetShown(n > 0)
end

--------------------------------------------------------------------------------
-- Tray frame
--------------------------------------------------------------------------------

local function BuildTray()
    local holder = ns.GetMinimapHolder() or Minimap

    tray = CreateFrame("Frame", "WoidzUIButtonTray", UIParent)

    -- Strata beats frame level, so a tray above the buttons' own MEDIUM strata
    -- could never lose an ordering argument, and every button that re-stamps
    -- itself back to MEDIUM would vanish behind the backdrop. Sit in the same
    -- strata at a deliberately low level instead: a button at its natural level
    -- 8 is then above this no matter how many times it re-applies itself.
    -- Also deliberately not SetToplevel, which would raise this frame's level
    -- on show and undo exactly that.
    tray:SetFrameStrata("MEDIUM")
    tray:SetFrameLevel(2)
    tray:SetClampedToScreen(true)
    tray:EnableMouse(true)
    tray:Hide()

    local bg = tray:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(tray)
    bg:SetTexture(ns.SOLID)
    bg:SetVertexColor(0.05, 0.05, 0.06, 0.92)

    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = tray:CreateTexture(nil, "BORDER")
        edge:SetTexture(ns.SOLID)
        edge:SetVertexColor(0, 0, 0, 1)
        if side == "TOP" then
            edge:SetPoint("TOPLEFT"); edge:SetPoint("TOPRIGHT"); edge:SetHeight(2)
        elseif side == "BOTTOM" then
            edge:SetPoint("BOTTOMLEFT"); edge:SetPoint("BOTTOMRIGHT"); edge:SetHeight(2)
        elseif side == "LEFT" then
            edge:SetPoint("TOPLEFT"); edge:SetPoint("BOTTOMLEFT"); edge:SetWidth(2)
        else
            edge:SetPoint("TOPRIGHT"); edge:SetPoint("BOTTOMRIGHT"); edge:SetWidth(2)
        end
    end

    local title = tray:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", tray, "TOPLEFT", db.padding, -6)
    title:SetText("Minimap buttons")
    tray.title = title

    tray.content = CreateFrame("Frame", nil, tray)
    tray.content:SetPoint("TOPLEFT", tray, "TOPLEFT", db.padding, -(db.padding + 12))

    -- Some buttons re-stamp their own strata, level or alpha after we place them,
    -- which drops them behind the tray backdrop: dimmed and unclickable. Layout
    -- alone cannot win that argument because it runs once. This runs only while
    -- the tray is open and only touches a button that has actually drifted.
    local restampAfter = 0
    tray:SetScript("OnUpdate", function(self, elapsed)
        restampAfter = restampAfter + elapsed
        if restampAfter < 0.25 then return end
        restampAfter = 0

        -- Alpha is the one thing a button can still take back from us, because
        -- an addon can restart its fade animation at any time. Level is only a
        -- floor now, and strata is left alone on purpose.
        local floor = self:GetFrameLevel() + 5
        for _, btn in ipairs(collected) do
            if btn:GetAlpha() < 1 then KillFade(btn) end
            if btn:GetFrameLevel() < floor then btn:SetFrameLevel(floor) end
        end
    end)

    tray:SetScript("OnLeave", function() M:MaybeAutoClose() end)
    tray:SetScript("OnHide", function() if toggle then toggle:SetChecked_(false) end end)

    tinsert(UISpecialFrames, "WoidzUIButtonTray")
    M.tray = tray
end

function M:Reanchor()
    if not tray then return end
    local holder = ns.GetMinimapHolder() or Minimap

    -- The strip under the map holds the clock and, when asked for, the menu
    -- button. The tray has to clear whichever of those is there.
    local below = db.togglePlacement == "below"
    local gap = below and 32 or 24

    local growth = db.trayGrowth
    if growth == "UP" then
        tray.baseAnchor = { "BOTTOM", holder, "TOP", 0, 24 }
    elseif growth == "LEFT" then
        tray.baseAnchor = { "RIGHT", holder, "LEFT", -6, 0 }
    elseif growth == "RIGHT" then
        tray.baseAnchor = { "LEFT", holder, "RIGHT", 6, 0 }
    else
        tray.baseAnchor = { "TOP", holder, "BOTTOM", 0, -gap }
    end

    tray:ClearAllPoints()
    tray:SetPoint(unpack(tray.baseAnchor))
    self:Fit()

    if toggle then
        toggle:ClearAllPoints()
        if below then
            -- Right hand end of the strip, so a centred clock still fits.
            toggle:SetPoint("TOPRIGHT", holder, "BOTTOMRIGHT", 0, -3)
        else
            local point = db.anchorPoint
            local xOff = point:find("RIGHT") and -3 or 3
            local yOff = point:find("BOTTOM") and 3 or -3
            toggle:SetPoint(point, holder, point, xOff, yOff)
        end
    end
end

--------------------------------------------------------------------------------
-- Toggle button on the map
--------------------------------------------------------------------------------

local function BuildToggle()
    local holder = ns.GetMinimapHolder() or Minimap

    toggle = CreateFrame("Button", "WoidzUIMinimapButton", holder)
    toggle:SetSize(24, 24)
    toggle:SetFrameStrata("MEDIUM")
    toggle:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    toggle:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local bg = toggle:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(toggle)
    bg:SetTexture(ns.SOLID)
    bg:SetVertexColor(0, 0, 0, 0.75)

    local icon = toggle:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Bag_08")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    toggle.icon = icon

    local highlight = toggle:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(toggle)
    highlight:SetTexture(ns.SOLID)
    highlight:SetVertexColor(1, 1, 1, 0.2)

    local count = toggle:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    count:SetPoint("BOTTOMRIGHT", toggle, "BOTTOMRIGHT", -1, 1)
    toggle.count = count

    toggle.SetChecked_ = function(self, checked)
        bg:SetVertexColor(checked and 0.16 or 0, checked and 0.35 or 0, checked and 0.55 or 0, 0.85)
    end

    toggle:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            ns.OpenConfig()
        else
            M:Toggle()
        end
    end)

    toggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("WoidzUI")
        GameTooltip:AddLine("Left click to open the button tray.", 1, 1, 1)
        GameTooltip:AddLine("Right click for settings.", 1, 1, 1)
        GameTooltip:Show()
    end)

    toggle:SetScript("OnLeave", function()
        GameTooltip:Hide()
        M:MaybeAutoClose()
    end)

    M.toggle = toggle
end

--------------------------------------------------------------------------------
-- Open, close, auto close
--------------------------------------------------------------------------------

function M:Toggle()
    if tray:IsShown() then
        tray:Hide()
    else
        self:Layout()
        tray:Show()
        toggle:SetChecked_(true)
    end
end

function M:MaybeAutoClose()
    if not db.autoClose or not tray or not tray:IsShown() then return end
    C_Timer.After(0.4, function()
        if not tray:IsShown() then return end
        if tray:IsMouseOver() then return end
        if toggle and toggle:IsMouseOver() then return end
        for _, btn in ipairs(collected) do
            if btn:IsMouseOver() then return end
        end
        tray:Hide()
    end)
end

--------------------------------------------------------------------------------
-- Ignore list, used by the config panel
--------------------------------------------------------------------------------

function M:GetCollected()
    return collected
end

-- /wui debug. Walks the same roots the scanner walks and says what happened to
-- every child, so a button that stayed on the minimap can be explained instead
-- of guessed at.
function M:Debug()
    local out = {}
    local function add(fmt, ...)
        out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    end

    add("WoidzUI %s buttons debug", ns.version)

    -- Strata, level and alpha are what decide whether a button is visible and
    -- clickable, so the tray's numbers and every button's numbers are the point
    -- of this report. A button below the tray is dimmed by its backdrop and gets
    -- no mouse events.
    if tray then
        add("tray      strata=%s level=%d shown=%s size=%.0fx%.0f mouse=%s",
            tray:GetFrameStrata(), tray:GetFrameLevel(), tostring(tray:IsShown()),
            tray:GetWidth(), tray:GetHeight(), tostring(tray:IsMouseEnabled()))
        add("content   level=%d size=%.0fx%.0f",
            tray.content:GetFrameLevel(), tray.content:GetWidth(), tray.content:GetHeight())
        add("expected  button level >= %d, alpha 1, strata left alone", tray:GetFrameLevel() + 5)
    else
        add("tray      not built")
    end

    add("")
    add("blizzard widgets")
    for _, name in ipairs({
        "LFGMinimapFrame", "MiniMapLFGFrame", "GameTimeFrame", "MiniMapTracking",
        "MiniMapMailFrame", "MiniMapBattlefieldFrame", "TimeManagerClockButton",
    }) do
        local f = _G[name]
        if not f then
            add("  %-26s missing", name)
        elseif not f.GetFrameStrata then
            add("  %-26s not a frame", name)
        else
            local parent = f:GetParent()
            add("  %-26s parent=%-24s strata=%-8s level=%-4d shown=%-6s mouse=%-6s protected=%s",
                name,
                parent and (parent:GetName() or "(anonymous)") or "none",
                f:GetFrameStrata(), f:GetFrameLevel(),
                tostring(f:IsShown()), tostring(f:IsMouseEnabled()),
                tostring(f.IsProtected and f:IsProtected() or false))
        end
    end

    add("")
    add("scan roots")
    for _, rootName in ipairs(SCAN_ROOTS) do
        local root = _G[rootName]
        if not root or not root.GetChildren then
            add("  %s: missing", rootName)
        else
            local children = { root:GetChildren() }
            add("  %s: %d child frame(s)", rootName, #children)

            -- Questie alone parks several hundred sub-13px quest pins on the
            -- minimap. Listing them individually buries everything that matters.
            local tiny = 0

            for _, child in ipairs(children) do
                local name = DeriveName(child) or (child.GetName and child:GetName()) or "(anonymous)"
                local verdict
                if child.wuiTaken then
                    verdict = "in the tray"
                elseif db.ignored[name] then
                    verdict = "ignored, left on the map"
                else
                    local ok, reason = IsCandidate(child)
                    verdict = ok and "eligible, not taken yet" or ("skipped: " .. tostring(reason))
                end
                if verdict:find("too small", 1, true) then
                    tiny = tiny + 1
                else
                    add("    %-38s %-7s w=%-5.0f shown=%-6s %s",
                        name,
                        child.GetObjectType and child:GetObjectType() or "?",
                        child.GetWidth and child:GetWidth() or 0,
                        tostring(child.IsShown and child:IsShown()),
                        verdict)
                end
            end

            if tiny > 0 then
                add("    (%d more skipped as too small, map pins and similar)", tiny)
            end
        end
    end

    add("")
    add("in the tray (%d)", #collected)
    for i, btn in ipairs(collected) do
        add("  %2d %-36s strata=%-18s level=%-5d alpha=%.2f shown=%-6s mouse=%-6s size=%.0f",
            i, tostring(btn.wuiName),
            btn:GetFrameStrata(), btn:GetFrameLevel(), btn:GetAlpha(),
            tostring(btn:IsShown()), tostring(btn:IsMouseEnabled()), btn:GetWidth())
    end

    local ignoredNames = {}
    for name in pairs(db.ignored) do ignoredNames[#ignoredNames + 1] = name end
    table.sort(ignoredNames)

    add("")
    add("left on the map (%d)", #ignoredNames)
    for _, name in ipairs(ignoredNames) do
        add("  %s", name)
    end

    ns.ShowText("WoidzUI buttons debug", table.concat(out, "\n"))
end

function M:SetIgnored(name, ignored)
    db.ignored[name] = ignored or nil
    if ignored then
        local btn = collectedByName[name]
        if btn then
            for i, b in ipairs(collected) do
                if b == btn then table.remove(collected, i) break end
            end
            Give(btn)
        end
    else
        self:Scan()
    end
    self:Layout()
    self:UpdateCount()
end

--------------------------------------------------------------------------------

function M:OnSettingsChanged()
    if not tray then return end
    self:Reanchor()
    self:Layout()
end

function M:OnEnable(settings)
    db = settings

    BuildTray()
    BuildToggle()
    self:Reanchor()
    self:Scan()

    -- Buttons show up late and keep showing up. Sweep on a decaying schedule,
    -- plus once more whenever any addon finishes loading.
    for _, delay in ipairs({ 1, 3, 6, 12, 25 }) do
        C_Timer.After(delay, function() M:Scan() end)
    end

    local events = CreateFrame("Frame")
    events:RegisterEvent("ADDON_LOADED")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    local pending = false
    events:SetScript("OnEvent", function()
        if pending then return end
        pending = true
        C_Timer.After(1, function()
            pending = false
            M:Scan()
        end)
    end)
end
