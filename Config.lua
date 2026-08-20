local ADDON, ns = ...

local uid = 0
local function NextName(prefix)
    uid = uid + 1
    return "WoidzUI" .. prefix .. uid
end

--------------------------------------------------------------------------------
-- Widget helpers
--------------------------------------------------------------------------------

-- Every widget here comes from Style.lua rather than from a Blizzard
-- template. The templates carry the old parchment and rivets look in their
-- art, not in their colours, so restyling them was never going to work; these
-- are drawn from flat textures and hairlines instead.
local S = ns.Style

local function MakeCheck(parent, label, tooltip, get, set)
    return S.Check(parent, label, tooltip, get, set)
end

local function MakeSlider(parent, label, minV, maxV, step, get, set)
    return S.Slider(parent, label, minV, maxV, step, get, set)
end

local function MakeButton(parent, label, width, onClick, variant)
    return S.Button(parent, label, width or 130, 22, onClick, variant)
end

-- A button that steps through a list of values and relabels itself.
local function MakeCycle(parent, label, width, values, labels, get, set)
    local b = MakeButton(parent, "", width)
    local function paint()
        local value = get()
        b:SetText(label .. ": " .. (labels[value] or tostring(value)))
    end
    b:SetScript("OnClick", function()
        local current = get()
        local index = 1
        for i, value in ipairs(values) do
            if value == current then index = i break end
        end
        set(values[(index % #values) + 1])
        paint()
    end)
    paint()
    b.wuiRefresh = paint
    return b
end

-- A section rule: tracked label, then a hairline to the edge. The stacker
-- anchors by TOPLEFT and the rule needs a width, so it carries its own.
local function MakeHeader(parent, text)
    local h = S.Header(parent, text)
    h:SetWidth(300)
    return h
end

-- Vertical stacker. Each call anchors below the previous widget in that column.
local function Stacker(panel, startX, startY)
    local anchor
    return function(widget, gapX, gapY)
        if not anchor then
            widget:SetPoint("TOPLEFT", panel, "TOPLEFT", startX + (gapX or 0), startY + (gapY or 0))
        else
            widget:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", gapX or 0, gapY or -10)
        end
        anchor = widget
        return widget
    end
end

local function ModuleToggle(panel, key)
    return MakeCheck(panel, "Enable this module", "Takes effect after a UI reload.",
        function() return ns.db[key].enabled end,
        function(v)
            ns.db[key].enabled = v
            ns.Print("module change applies after a UI reload.")
        end)
end

--------------------------------------------------------------------------------
-- Settings window
--
-- Blizzard's options plumbing is inconsistent across clients: this one carries
-- the old InterfaceOptions category list and parts of the newer Settings API at
-- the same time, and opening a category reliably through either is more work
-- than owning a frame. Owning it means right click always opens something.
--------------------------------------------------------------------------------

local window

local function BuildWindow()
    window = CreateFrame("Frame", "WoidzUIConfigFrame", UIParent)
    -- Wide enough for five tabs plus a third column, which 760 was not, and tall
    -- enough to carry the preview strip under the XP bar settings.
    window:SetSize(940, 600)
    window:SetPoint("CENTER")
    -- HIGH sits below DIALOG and everything above it, so any addon parking a
    -- frame up there drew straight over this window and made an opaque panel look
    -- see through. A settings window is the thing in front while it is open.
    window:SetFrameStrata("FULLSCREEN_DIALOG")
    window:SetFrameLevel(100)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:SetClampedToScreen(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:Hide()

    local bg = window:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(window)
    bg:SetTexture(ns.SOLID)
    bg:SetVertexColor(unpack(ns.C.bg))

    -- A 1px hairline, not a 2px grey frame. The old edge read as a border drawn
    -- around a box; this reads as the edge of the surface itself.
    ns.Style.Border(window, ns.W.border)
    ns.Style.Bevel(window, "raised")

    -- Header: tracked kicker over the window name, the same recipe the rest of
    -- the suite uses, with the version kept quiet beside it.
    local kicker = ns.Style.Font(window, 9, ns.C.accent, nil, "LEFT")
    kicker:SetPoint("TOPLEFT", 14, -9)
    kicker:SetText(ns.Style.Track("WOIDZ UI"))

    local heading = ns.Style.Font(window, 13, ns.C.text, nil, "LEFT")
    heading:SetPoint("TOPLEFT", 14, -20)
    heading:SetText("Settings")

    local version = ns.Style.Font(window, 11, ns.C.dim, nil, "LEFT")
    version:SetPoint("LEFT", heading, "RIGHT", 8, 0)
    version:SetText(ns.version)

    local headRule = ns.Style.Tex(window, "ARTWORK", ns.W.hairline)
    headRule:SetPoint("TOPLEFT", 0, -40)
    headRule:SetPoint("TOPRIGHT", 0, -40)
    headRule:SetHeight(1)

    local close = ns.Style.CloseButton(window, function() window:Hide() end)
    close:SetPoint("TOPRIGHT", -6, -6)

    local footRule = ns.Style.Tex(window, "ARTWORK", ns.W.hairline)
    footRule:SetPoint("BOTTOMLEFT", 0, 40)
    footRule:SetPoint("BOTTOMRIGHT", 0, 40)
    footRule:SetHeight(1)

    -- One action row for the whole window, so it is reachable from any tab.
    local unlock = MakeButton(window, "Unlock frames", 130, function(self)
        ns.SetUnlocked(not ns.unlocked)
        self:SetText(ns.unlocked and "Lock frames" or "Unlock frames")
    end)
    unlock:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 14, 12)

    local rescan = MakeButton(window, "Rescan buttons", 130, function()
        local found = ns.modules.buttons and ns.modules.buttons:Scan() or 0
        local placed = ns.RefreshMinimapIcons and ns.RefreshMinimapIcons() or 0
        ns.Print("scan picked up " .. found .. " new button(s), re-placed " .. placed .. " library icon(s).")
    end)
    rescan:SetPoint("LEFT", unlock, "RIGHT", 8, 0)

    local dump = MakeButton(window, "Copy debug report", 150, function()
        if ns.modules.buttons and ns.modules.buttons.Debug then
            ns.modules.buttons:Debug()
        end
    end)
    dump:SetPoint("LEFT", rescan, "RIGHT", 8, 0)

    local reload = MakeButton(window, "Reload UI", 130, function() ReloadUI() end, "primary")
    reload:SetPoint("LEFT", dump, "RIGHT", 8, 0)

    window.pages = {}
    window.tabs = {}

    tinsert(UISpecialFrames, "WoidzUIConfigFrame")
    return window
end

local TAB_HEIGHT = 24
local TAB_GAP = 4
-- Header strip: kicker, title and the hairline under them. The tab row starts
-- below it, and the pages below the tabs, all from this one number.
local HEADER_H = 48
local TAB_MIN = 104   -- below this a label starts getting cut, so wrap instead

-- Tabs divide up whatever width the window has rather than each claiming a fixed
-- 150. Five fixed tabs already overflowed a 760 window and clipped the last
-- label; a sixth page would have pushed one off the edge entirely. Wrapping to a
-- second row keeps that from ever happening again, and the pages are re-anchored
-- underneath so a wrapped row pushes content down instead of sitting on it.
local function LayoutTabs()
    local count = #window.tabs
    if count == 0 then return end

    local avail = window:GetWidth() - 28

    local perRow = count
    while perRow > 1 and ((avail - (perRow - 1) * TAB_GAP) / perRow) < TAB_MIN do
        perRow = perRow - 1
    end

    local width = math.floor((avail - (perRow - 1) * TAB_GAP) / perRow)
    local rows = math.ceil(count / perRow)

    for i, tab in ipairs(window.tabs) do
        local row = math.floor((i - 1) / perRow)
        local col = (i - 1) % perRow
        tab:SetSize(width, TAB_HEIGHT)
        tab:ClearAllPoints()
        tab:SetPoint("TOPLEFT", window, "TOPLEFT",
            14 + col * (width + TAB_GAP),
            -HEADER_H - row * (TAB_HEIGHT + 4))
    end

    local top = HEADER_H + rows * (TAB_HEIGHT + 4) + 6
    for _, page in ipairs(window.pages) do
        page:ClearAllPoints()
        page:SetPoint("TOPLEFT", window, "TOPLEFT", 0, -top)
        page:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 44)
    end
end

local function AddPage(label, builder)
    local index = #window.pages + 1

    local page = CreateFrame("Frame", nil, window)
    page:SetPoint("TOPLEFT", window, "TOPLEFT", 0, -64)
    page:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, 44)
    page:Hide()

    local refreshers = {}
    page.track = function(widget)
        if widget.wuiRefresh then refreshers[#refreshers + 1] = widget.wuiRefresh end
        return widget
    end

    builder(page)

    page.refresh = page.refresh or function()
        for _, fn in ipairs(refreshers) do fn() end
    end
    page:SetScript("OnShow", page.refresh)
    window.pages[index] = page

    local tab = S.Tab(window, label, function() ns.ShowConfigPage(index) end)
    tab:SetSize(150, TAB_HEIGHT)
    window.tabs[index] = tab

    LayoutTabs()

    return page
end

function ns.ShowConfigPage(index)
    if not window then return end
    window.activeIndex = index
    for i, page in ipairs(window.pages) do
        if i == index then page:Show() else page:Hide() end
    end
    for i, tab in ipairs(window.tabs) do
        tab:SetActive(i == index)
    end
    local page = window.pages[index]
    if page and page.refresh then page.refresh() end
end

function ns.OpenConfig()
    if not window then
        ns.Print("settings window is not built yet.")
        return
    end
    if window:IsShown() then
        window:Hide()
        return
    end
    window:Show()
    ns.ShowConfigPage(window.activeIndex or 1)
end

--------------------------------------------------------------------------------
-- Minimap page
--------------------------------------------------------------------------------

local function BuildMinimapPage(panel)
    local track = panel.track
    local left = Stacker(panel, 16, -12)
    local right = Stacker(panel, 350, -12)

    left(MakeHeader(panel, "Minimap"))
    left(track(ModuleToggle(panel, "minimap")), -6, -8)

    left(track(MakeSlider(panel, "Size", 100, 300, 2,
        function() return ns.db.minimap.size end,
        function(v) ns.db.minimap.size = v ns.Refresh("minimap") end)), 10, -20)

    left(track(MakeSlider(panel, "Border thickness", 0, 8, 1,
        function() return ns.db.minimap.borderSize end,
        function(v) ns.db.minimap.borderSize = v ns.Refresh("minimap") end)), 0, -24)

    right(MakeHeader(panel, "Show"))

    right(track(MakeCheck(panel, "Zone text", nil,
        function() return ns.db.minimap.showZoneText end,
        function(v) ns.db.minimap.showZoneText = v ns.Print("zone text change applies after a UI reload.") end)), -6, -8)

    right(track(MakeCheck(panel, "Coordinates", nil,
        function() return ns.db.minimap.showCoords end,
        function(v) ns.db.minimap.showCoords = v ns.Print("coordinate change applies after a UI reload.") end)), 0, -4)

    right(track(MakeCheck(panel, "Clock", nil,
        function() return ns.db.minimap.showClock end,
        function(v) ns.db.minimap.showClock = v ns.Refresh("minimap") end)), 0, -4)

    right(track(MakeCheck(panel, "Calendar button", nil,
        function() return ns.db.minimap.showCalendar end,
        function(v) ns.db.minimap.showCalendar = v ns.Refresh("minimap") end)), 0, -4)

    right(track(MakeCheck(panel, "Mouse wheel zoom", nil,
        function() return ns.db.minimap.mouseWheelZoom end,
        function(v) ns.db.minimap.mouseWheelZoom = v end)), 0, -4)

    right(track(MakeCheck(panel, "Right click opens tracking", nil,
        function() return ns.db.minimap.rightClickTracking end,
        function(v) ns.db.minimap.rightClickTracking = v end)), 0, -4)
end

--------------------------------------------------------------------------------
-- Button tray page
--------------------------------------------------------------------------------

local function BuildTrayPage(panel)
    local track = panel.track
    local left = Stacker(panel, 16, -12)
    local right = Stacker(panel, 350, -12)

    left(MakeHeader(panel, "Button tray"))
    left(track(ModuleToggle(panel, "buttons")), -6, -8)

    left(track(MakeSlider(panel, "Columns", 1, 12, 1,
        function() return ns.db.buttons.columns end,
        function(v) ns.db.buttons.columns = v ns.Refresh("buttons") end)), 10, -20)

    left(track(MakeSlider(panel, "Icon size", 16, 48, 1,
        function() return ns.db.buttons.buttonSize end,
        function(v) ns.db.buttons.buttonSize = v ns.Refresh("buttons") end)), 0, -24)

    left(track(MakeSlider(panel, "Spacing", 0, 16, 1,
        function() return ns.db.buttons.spacing end,
        function(v) ns.db.buttons.spacing = v ns.Refresh("buttons") end)), 0, -24)

    right(MakeHeader(panel, "Behaviour"))

    right(track(MakeCheck(panel, "Close when the mouse leaves", nil,
        function() return ns.db.buttons.autoClose end,
        function(v) ns.db.buttons.autoClose = v end)), -6, -8)

    right(track(MakeCheck(panel, "Strip the round button borders",
        "Minimap buttons wear a ring far wider than themselves. In a grid those rings overlap and hide the icons.",
        function() return ns.db.buttons.stripBorders end,
        function(v) ns.db.buttons.stripBorders = v ns.Print("border change applies after a UI reload.") end)), 0, -4)

    right(track(MakeCheck(panel, "Collect Blizzard buttons",
        "Lets the tray take the looking for group eye, the calendar, tracking, mail and the battleground icon.",
        function() return ns.db.buttons.collectBlizzard end,
        function(v)
            ns.db.buttons.collectBlizzard = v
            if v then
                ns.modules.buttons:Scan()
            else
                ns.Print("Blizzard buttons go back to the map after a UI reload.")
            end
        end)), 0, -4)

    right(track(MakeCycle(panel, "Tray grows", 220,
        { "DOWN", "UP", "LEFT", "RIGHT" },
        { DOWN = "down", UP = "up", LEFT = "left", RIGHT = "right" },
        function() return ns.db.buttons.trayGrowth end,
        function(v) ns.db.buttons.trayGrowth = v ns.Refresh("buttons") end)), 6, -10)

    right(track(MakeCycle(panel, "Menu button", 220,
        { "below", "corner" },
        { below = "under the minimap", corner = "on the map corner" },
        function() return ns.db.buttons.togglePlacement end,
        function(v) ns.db.buttons.togglePlacement = v ns.Refresh("buttons") end)), 0, -6)
end

--------------------------------------------------------------------------------
-- XP bar preview strip
--
-- Parked along the bottom of the XP bar page and spanning it, because these are
-- the controls you reach for while looking at the bar itself rather than at this
-- window. Burying them in a column would mean hunting for them every time.
--------------------------------------------------------------------------------

local function ButtonRow(parent, anchorTo, yOffset, width, entries)
    local gap = 6
    local each = math.floor((width - (#entries - 1) * gap) / #entries)
    local first

    for i, entry in ipairs(entries) do
        local button = MakeButton(parent, entry[1], each, entry[2])
        button:SetPoint("TOPLEFT", anchorTo, "TOPLEFT", (i - 1) * (each + gap), yOffset)
        first = first or button
    end

    return first
end

local function BuildPreviewStrip(panel)
    local strip = CreateFrame("Frame", nil, panel)
    strip:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 10)
    strip:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -16, 10)
    strip:SetHeight(78)

    local bg = strip:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(strip)
    bg:SetTexture(ns.SOLID)
    bg:SetVertexColor(0.10, 0.10, 0.12, 0.85)

    local top = strip:CreateTexture(nil, "BORDER")
    top:SetTexture(ns.SOLID)
    top:SetVertexColor(0.22, 0.22, 0.26, 1)
    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(1)

    local title = strip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -7)
    title:SetText("Preview the bar")

    local status = strip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("LEFT", title, "RIGHT", 10, 0)

    local note = strip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPRIGHT", -8, -7)
    note:SetText("Fake numbers for looking at the bar. Nothing is saved and no session data is touched.")

    local function xp()
        return ns.modules.xpbar
    end

    local function Paint()
        local module = xp()
        if not module or not module.IsPreviewing then
            status:SetText("")
            return
        end
        if module:IsPreviewing() then
            status:SetFormattedText("|cffffa028previewing %.0f%% full|r", module:PreviewFraction() * 100)
        else
            status:SetText("|cff7f7f7fshowing live experience|r")
        end
    end
    strip.wuiRefresh = Paint

    -- Every button repaints the status, so the strip never claims to be live
    -- while the bar is still showing made up numbers.
    local function Act(fn)
        return function()
            local module = xp()
            if module then fn(module) end
            Paint()
        end
    end

    local width = 940 - 32 - 16

    ButtonRow(strip, strip, -26, width, {
        { "Empty",  Act(function(m) m:Preview(0, 0) end) },
        { "10%",    Act(function(m) m:Preview(0.10, 0) end) },
        { "25%",    Act(function(m) m:Preview(0.25, 0) end) },
        { "50%",    Act(function(m) m:Preview(0.50, 0) end) },
        { "75%",    Act(function(m) m:Preview(0.75, 0) end) },
        { "Full",   Act(function(m) m:Preview(1, 0) end) },
    })

    ButtonRow(strip, strip, -52, width, {
        { "Half rested",  Act(function(m) m:Preview(0.35, 0.5) end) },
        { "Rested capped", Act(function(m) m:Preview(0.60, 1.5) end) },
        { "Max level",    Act(function(m) m:Preview(1, 0, m:MaxLevel()) end) },
        { "Sweep",        Act(function(m) m:Sweep(4) end) },
        { "Back to live", Act(function(m) m:PreviewOff() end) },
        { "One bar",      Act(function(m) m:Preview(0.05, 0) end) },
    })

    Paint()
    return strip
end

--------------------------------------------------------------------------------
-- XP bar page
--------------------------------------------------------------------------------

local function BuildXPPage(panel)
    local track = panel.track
    local left = Stacker(panel, 16, -12)
    local mid = Stacker(panel, 250, -12)
    local right = Stacker(panel, 520, -12)

    left(MakeHeader(panel, "XP bar"))
    left(track(ModuleToggle(panel, "xpbar")), -6, -8)

    left(track(MakeSlider(panel, "Width", 100, 900, 10,
        function() return ns.db.xpbar.width end,
        function(v) ns.db.xpbar.width = v ns.Refresh("xpbar") end)), 10, -20)

    left(track(MakeSlider(panel, "Height", 6, 40, 1,
        function() return ns.db.xpbar.height end,
        function(v) ns.db.xpbar.height = v ns.Refresh("xpbar") end)), 0, -24)

    left(track(MakeSlider(panel, "Row height", 8, 24, 1,
        function() return ns.db.xpbar.rowHeight end,
        function(v) ns.db.xpbar.rowHeight = v ns.Refresh("xpbar") end)), 0, -24)

    left(track(MakeSlider(panel, "Segments", 0, 20, 1,
        function() return ns.db.xpbar.segments end,
        function(v)
            ns.db.xpbar.segments = v
            ns.db.xpbar.showSegments = v > 1
            ns.Refresh("xpbar")
        end)), 0, -24)

    left(MakeButton(panel, "Match the default bar", 180, function()
        ns.db.xpbar.segments = 20
        ns.db.xpbar.showSegments = true
        ns.Refresh("xpbar")
        if panel.refresh then panel.refresh() end
        ns.Print("segments set to 20, the same cut as the default experience bar.")
    end), 0, -14)

    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetWidth(200)
    hint:SetJustifyH("LEFT")
    hint:SetText("Twenty is the cut on the default experience bar, so a tick lands on every bar boundary. Hover the bar for session experience, rate per hour, bars filled, what one bar is worth, time to level and kills to level.")
    left(hint, 0, -18)

    BuildPreviewStrip(panel)

    mid(MakeHeader(panel, "On the bar"))

    local xp = ns.modules.xpbar
    mid(track(MakeCycle(panel, "Middle shows", 240,
        xp.FORMATS, xp.FORMAT_LABEL,
        function() return ns.db.xpbar.format end,
        function(v) ns.db.xpbar.format = v ns.Refresh("xpbar") end)), 0, -10)

    mid(track(MakeCycle(panel, "Bar text", 240,
        { "always", "hover", "never" },
        { always = "always visible", hover = "on hover", never = "hidden" },
        function() return ns.db.xpbar.textMode end,
        function(v) ns.db.xpbar.textMode = v ns.Refresh("xpbar") end)), 0, -6)

    mid(track(MakeCheck(panel, "Level on the left", nil,
        function() return ns.db.xpbar.showLevel end,
        function(v) ns.db.xpbar.showLevel = v ns.Refresh("xpbar") end)), -6, -10)

    mid(track(MakeCheck(panel, "Block behind the level",
        "A darker slab under the level text so it stays readable over the fill.",
        function() return ns.db.xpbar.levelBlock end,
        function(v) ns.db.xpbar.levelBlock = v ns.Refresh("xpbar") end)), 0, -4)

    mid(track(MakeCheck(panel, "Percent on the right",
        "Percent of the level, and the percent the rested pool would reach, in brackets.",
        function() return ns.db.xpbar.showPercent end,
        function(v) ns.db.xpbar.showPercent = v ns.Refresh("xpbar") end)), 0, -4)

    mid(track(MakeCheck(panel, "Show the rested pool", nil,
        function() return ns.db.xpbar.showRested end,
        function(v) ns.db.xpbar.showRested = v ns.Refresh("xpbar") end)), 0, -4)

    mid(track(MakeCheck(panel, "Put rested in the bar text", nil,
        function() return ns.db.xpbar.showRestedInText end,
        function(v) ns.db.xpbar.showRestedInText = v ns.Refresh("xpbar") end)), 0, -4)

    mid(track(MakeCheck(panel, "Flash experience as it lands", nil,
        function() return ns.db.xpbar.showFlash end,
        function(v) ns.db.xpbar.showFlash = v end)), 0, -4)

    right(MakeHeader(panel, "Info rows"))

    right(track(MakeCheck(panel, "Row above the bar", nil,
        function() return ns.db.xpbar.showTopRow end,
        function(v) ns.db.xpbar.showTopRow = v ns.Refresh("xpbar") end)), -6, -8)

    right(track(MakeCheck(panel, "Time this level", nil,
        function() return ns.db.xpbar.showTimeThisLevel end,
        function(v) ns.db.xpbar.showTimeThisLevel = v ns.Refresh("xpbar") end)), 12, -4)

    right(track(MakeCheck(panel, "Time this session", nil,
        function() return ns.db.xpbar.showTimeThisSession end,
        function(v) ns.db.xpbar.showTimeThisSession = v ns.Refresh("xpbar") end)), 0, -4)

    right(track(MakeCheck(panel, "Row below the bar", nil,
        function() return ns.db.xpbar.showBottomRow end,
        function(v) ns.db.xpbar.showBottomRow = v ns.Refresh("xpbar") end)), -12, -10)

    right(track(MakeCheck(panel, "Leveling in, and rate per hour", nil,
        function() return ns.db.xpbar.showLevelingIn end,
        function(v) ns.db.xpbar.showLevelingIn = v ns.Refresh("xpbar") end)), 12, -4)

    right(track(MakeCheck(panel, "Completed towards max level",
        "Progress from level 1 to max, counted in experience rather than levels.",
        function() return ns.db.xpbar.showCompleted end,
        function(v) ns.db.xpbar.showCompleted = v ns.Refresh("xpbar") end)), 0, -4)

    right(track(MakeCheck(panel, "Rested percent",
        "Only appears once there is a rested pool to report.",
        function() return ns.db.xpbar.showRestedPct end,
        function(v) ns.db.xpbar.showRestedPct = v ns.Refresh("xpbar") end)), 0, -4)

    right(track(MakeCheck(panel, "Bars filled",
        "How many of the twenty bars on the default experience bar this level would have filled. Hover the bar for what one is worth at this level.",
        function() return ns.db.xpbar.showBars end,
        function(v) ns.db.xpbar.showBars = v ns.Refresh("xpbar") end)), 0, -4)

    right(track(MakeCheck(panel, "Row backgrounds", nil,
        function() return ns.db.xpbar.rowBackground end,
        function(v) ns.db.xpbar.rowBackground = v ns.Refresh("xpbar") end)), -12, -10)

    right(track(MakeCycle(panel, "Completed counts", 220,
        { "xp", "levels" },
        { xp = "experience", levels = "levels" },
        function() return ns.db.xpbar.completedMode end,
        function(v) ns.db.xpbar.completedMode = v ns.Refresh("xpbar") end)), 6, -10)

    right(track(MakeCycle(panel, "Clocks redraw every", 220,
        { 1, 5, 10, 30 },
        { [1] = "1s", [5] = "5s", [10] = "10s", [30] = "30s" },
        function() return ns.db.xpbar.refresh end,
        function(v) ns.db.xpbar.refresh = v ns.Refresh("xpbar") end)), 0, -6)

    right(track(MakeCheck(panel, "Watched reputation at max level", nil,
        function() return ns.db.xpbar.repAtMax end,
        function(v) ns.db.xpbar.repAtMax = v ns.Refresh("xpbar") end)), 0, -10)

    right(track(MakeCheck(panel, "Hide the bar at max level", nil,
        function() return ns.db.xpbar.hideAtMax end,
        function(v) ns.db.xpbar.hideAtMax = v ns.Refresh("xpbar") end)), 0, -4)

    right(MakeButton(panel, "Reset session stats", 180, function()
        if ns.modules.xpbar and ns.modules.xpbar.ResetSession then
            ns.modules.xpbar:ResetSession()
            ns.modules.xpbar:Update()
            ns.Print("session stats reset.")
        end
    end), 6, -10)
end

--------------------------------------------------------------------------------
-- Party quests page
--------------------------------------------------------------------------------

-- Typed names arrive however the user typed them. Unit names never carry a realm
-- and are capitalised on the first letter only, so both sides get pushed into
-- that shape or a hand entered name would never match a real party member.
local function NormaliseName(text)
    text = tostring(text or "")
    text = text:match("^%s*(.-)%s*$") or text
    text = text:match("^([^%-]+)") or text
    if text == "" then return nil end
    return text:sub(1, 1):upper() .. text:sub(2):lower()
end

-- The list is the union of who is in the group right now and who is already
-- saved. The group so ticking a friend is one click, the saved names so somebody
-- offline tonight does not fall off the list and quietly lose their setting.
local function NameCandidates()
    local names, seen, inParty = {}, {}, {}

    if ns.QuestRoster and ns.QuestRoster.Members then
        local ok, members = pcall(ns.QuestRoster.Members)
        if ok and type(members) == "table" then
            for name in pairs(members) do
                inParty[name] = true
                if not seen[name] then
                    seen[name] = true
                    names[#names + 1] = name
                end
            end
        end
    end

    local saved = (ns.db.partyquests and ns.db.partyquests.tracked) or {}
    for name in pairs(saved) do
        if not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end

    table.sort(names)
    return names, inParty
end

local ROW_HEIGHT = 22

-- A scrolling list of names with a checkbox each. Rows are built once and reused
-- on every refresh, because a raid can hand this thirty nine names and a frame in
-- WoW can be hidden but never destroyed: building fresh rows each time would leak
-- widgets for the rest of the session.
local function MakeNameList(parent, width, height)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(width, height)

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetTexture(ns.SOLID)
    bg:SetVertexColor(0.10, 0.10, 0.12, 0.9)

    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = frame:CreateTexture(nil, "BORDER")
        edge:SetTexture(ns.SOLID)
        edge:SetVertexColor(0.22, 0.22, 0.26, 1)
        if side == "TOP" then
            edge:SetPoint("TOPLEFT"); edge:SetPoint("TOPRIGHT"); edge:SetHeight(1)
        elseif side == "BOTTOM" then
            edge:SetPoint("BOTTOMLEFT"); edge:SetPoint("BOTTOMRIGHT"); edge:SetHeight(1)
        elseif side == "LEFT" then
            edge:SetPoint("TOPLEFT"); edge:SetPoint("BOTTOMLEFT"); edge:SetWidth(1)
        else
            edge:SetPoint("TOPRIGHT"); edge:SetPoint("BOTTOMRIGHT"); edge:SetWidth(1)
        end
    end

    local scroll = CreateFrame("ScrollFrame", NextName("Scroll"), frame, "UIPanelScrollFrameTemplate")
    S.ScrollBar(scroll)
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -26, 4)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(width - 34, height)
    scroll:SetScrollChild(content)

    frame.rows = {}

    frame.empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.empty:SetPoint("TOPLEFT", 4, -6)
    frame.empty:SetWidth(width - 44)
    frame.empty:SetJustifyH("LEFT")

    local function Row(index)
        local row = frame.rows[index]
        if row then return row end

        row = S.TickBox(content, 16)
        row:SetPoint("TOPLEFT", 2, -((index - 1) * ROW_HEIGHT) - 2)

        row.label = ns.Style.Font(row, 11, ns.C.text, nil, "LEFT")
        row.label:SetPoint("LEFT", row, "RIGHT", 8, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWidth(width - 64)

        row:SetScript("OnClick", function(self)
            if not self.playerName then return end
            local set = ns.db.partyquests.tracked
            -- nil rather than false, so unticking a saved name drops it off the
            -- list instead of leaving a dead entry sitting there forever.
            set[self.playerName] = self:GetChecked() and true or nil
            ns.Refresh("partyquests")
            frame:Refresh()
        end)

        frame.rows[index] = row
        return row
    end
    frame.Row = function(_, index) return Row(index) end

    function frame:Refresh()
        for _, row in ipairs(self.rows) do row:Hide() end

        local names, inParty = NameCandidates()

        if #names == 0 then
            self.empty:SetText("Nobody to list yet. Join a party, or type a name below to track someone before you ever group up with them.")
            self.empty:Show()
            content:SetHeight(height)
            return
        end
        self.empty:Hide()

        local tracked = ns.db.partyquests.tracked or {}
        for i, name in ipairs(names) do
            local row = Row(i)
            row.playerName = name
            row:SetChecked(tracked[name] and true or false)
            row.label:SetText(inParty[name] and (name .. " |cff7f7f7f(in your party)|r") or name)
            row:Show()
        end

        content:SetHeight(math.max(height, #names * ROW_HEIGHT + 8))
    end

    frame.wuiRefresh = function() frame:Refresh() end
    return frame
end

local function MakeEditBox(parent, width, onAccept)
    local box = CreateFrame("EditBox", NextName("Edit"), parent, "InputBoxTemplate")
    S.EditBox(box)
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(24)

    local function accept(self)
        local name = NormaliseName(self:GetText())
        self:SetText("")
        self:ClearFocus()
        if name then onAccept(name) end
    end

    box.wuiAccept = accept
    box:SetScript("OnEnterPressed", accept)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
    end)
    return box
end

local function BuildPartyQuestsPage(panel)
    local track = panel.track
    local left = Stacker(panel, 16, -12)
    local mid = Stacker(panel, 330, -12)
    local right = Stacker(panel, 646, -12)

    left(MakeHeader(panel, "Warnings"))
    left(track(ModuleToggle(panel, "partyquests")), -6, -8)

    left(track(MakeSlider(panel, "Quests ahead before warning", 1, 5, 1,
        function() return ns.db.partyquests.threshold end,
        function(v) ns.db.partyquests.threshold = v ns.Refresh("partyquests") end)), 10, -20)

    left(track(MakeCycle(panel, "Repeat warning after", 240,
        { 60, 300, 600, 1800 },
        { [60] = "1m", [300] = "5m", [600] = "10m", [1800] = "30m" },
        function() return ns.db.partyquests.cooldown end,
        function(v) ns.db.partyquests.cooldown = v ns.Refresh("partyquests") end)), 0, -26)

    left(track(MakeCheck(panel, "Also warn when I am ahead", nil,
        function() return ns.db.partyquests.alertAhead end,
        function(v) ns.db.partyquests.alertAhead = v ns.Refresh("partyquests") end)), -6, -14)

    left(track(MakeCheck(panel, "Ignore lines I have not started",
        "Off, a friend picking up a quest line in a zone you have never visited counts as you being behind.",
        function() return ns.db.partyquests.onlySharedChains end,
        function(v) ns.db.partyquests.onlySharedChains = v ns.Refresh("partyquests") end)), 0, -4)

    left(MakeButton(panel, "Check now", 200, function()
        local pq = ns.modules.partyquests
        if pq and pq.Report then pq:Report() end
    end), 6, -16)

    left(MakeButton(panel, "Reset warning timers", 200, function()
        local pq = ns.modules.partyquests
        if pq and pq.ResetAlerts then
            pq:ResetAlerts()
            ns.Print("warning timers cleared, so every current gap gets reported again.")
        end
    end), 0, -6)

    mid(MakeHeader(panel, "Who to track"))

    mid(track(MakeCheck(panel, "Everyone in my party", nil,
        function() return ns.db.partyquests.trackAll end,
        function(v)
            ns.db.partyquests.trackAll = v
            ns.Refresh("partyquests")
            if panel.refresh then panel.refresh() end
        end)), -6, -8)

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetWidth(290)
    note:SetJustifyH("LEFT")
    note:SetText("With that off, only the ticked names below are watched.")
    mid(note, 12, -4)

    local list = MakeNameList(panel, 290, 168)
    mid(track(list), 0, -8)

    local box
    box = MakeEditBox(panel, 200, function(name)
        ns.db.partyquests.tracked[name] = true
        ns.Refresh("partyquests")
        list:Refresh()
        ns.Print(name .. " added to the tracked list.")
    end)
    mid(box, 8, -14)

    local add = MakeButton(panel, "Add", 70, function()
        if box.wuiAccept then box.wuiAccept(box) end
    end)
    add:SetPoint("LEFT", box, "RIGHT", 8, 0)

    right(MakeHeader(panel, "How this works"))

    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetWidth(276)
    hint:SetJustifyH("LEFT")
    hint:SetText("No addon can read another player's quest log. The game does not expose it. "
        .. "What this reads instead is what Questie broadcasts to the party, so everyone you "
        .. "want tracked has to be running Questie with its group comms enabled."
        .. "|n|n"
        .. "A party member without it shows as not sharing rather than as level with you, "
        .. "because those are very different things."
        .. "|n|n"
        .. "Quest line order comes from Questie's own quest database, which ships with it. "
        .. "Nothing here is fetched from the internet."
        .. "|n|n"
        .. "A name you type is kept even while that person is offline, so a levelling partner "
        .. "can be set up once and left alone.")
    right(hint, 0, -12)
end

--------------------------------------------------------------------------------
-- Collected buttons page
--------------------------------------------------------------------------------

local function BuildCollectedPage(panel)
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", 16, -12)
    title:SetText("Collected buttons")

    local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    sub:SetText("Ticked buttons live in the tray. Untick one to leave it on the minimap.")

    local scroll = CreateFrame("ScrollFrame", "WoidzUICollectedScroll", panel, "UIPanelScrollFrameTemplate")
    S.ScrollBar(scroll)
    scroll:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -12)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -40, 12)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(600, 10)
    scroll:SetScrollChild(content)

    local rows = {}

    panel.refresh = function()
        local mod = ns.modules.buttons
        if not mod or not mod.GetCollected then return end

        local names = {}
        for _, btn in ipairs(mod:GetCollected()) do
            names[#names + 1] = btn.wuiName
        end
        for name in pairs(ns.db.buttons.ignored) do
            names[#names + 1] = name
        end
        table.sort(names)

        for _, row in ipairs(rows) do row:Hide() end

        for i, name in ipairs(names) do
            local row = rows[i]
            if not row then
                -- The label used to come from the template, which named it
                -- <button>Text and parented it for us. Ours is built here.
                row = S.TickBox(content, 16)
                row:SetPoint("TOPLEFT", 4, -((i - 1) * 24) - 4)
                row.label = ns.Style.Font(row, 11, ns.C.text, nil, "LEFT")
                row.label:SetPoint("LEFT", row, "RIGHT", 8, 0)
                row.label:SetWidth(200)
                rows[i] = row
            end
            row.wuiButtonName = name
            if row.label then row.label:SetText(mod.PrettyName(name)) end
            row:SetChecked(not ns.db.buttons.ignored[name])
            row:SetScript("OnClick", function(self)
                mod:SetIgnored(self.wuiButtonName, not self:GetChecked())
            end)
            row:Show()
        end

        content:SetHeight(math.max(#names * 24 + 8, 10))
    end
end

--------------------------------------------------------------------------------
-- Professions page
--------------------------------------------------------------------------------

-- A fixed pool of report buttons. Two primaries and three secondaries is the
-- most this client can hand out, and a frame in WoW can be hidden but never
-- destroyed, so the rows are built once and relabelled rather than rebuilt every
-- time the page is shown.
local PROFESSION_ROWS = 6

local function BuildProfessionsPage(panel)
    local track = panel.track
    local left = Stacker(panel, 16, -12)
    local mid = Stacker(panel, 330, -12)
    local right = Stacker(panel, 646, -12)

    left(MakeHeader(panel, "Shopping list"))
    left(track(ModuleToggle(panel, "professions")), -6, -8)

    left(track(MakeCycle(panel, "TSM price source", 260,
        { "dbmarket", "dbminbuyout", "dbhistorical", "crafting" },
        {
            ["dbmarket"] = "market value",
            ["dbminbuyout"] = "lowest buyout",
            ["dbhistorical"] = "historical",
            ["crafting"] = "crafting cost",
        },
        function() return ns.db.professions.priceSource end,
        function(v) ns.db.professions.priceSource = v ns.Refresh("professions") end)), 6, -18)

    -- Label and setting say the same thing in the same direction. This tick used
    -- to be the negation of the value behind it, which is the kind of thing that
    -- reads fine today and gets inverted by accident six months from now.
    left(MakeHeader(panel, "On screen guide"), 0, -18)

    left(MakeButton(panel, "Show or hide the guide", 200, function()
        local t = ns.modules.proftracker
        if not t or not t.Toggle then return end
        local shown = t:Toggle()
        ns.Print(shown and "guide shown. Drag it by its title bar. Escape and other windows cannot close it."
            or "guide hidden. Bring it back from here or with /wui guide.")
    end), 6, -8)

    left(track(MakeSlider(panel, "Guide panel width", 180, 460, 10,
        function() return ns.db.proftracker.width end,
        function(v) ns.db.proftracker.width = v ns.Refresh("proftracker") end)), 10, -18)

    left(track(MakeSlider(panel, "Upcoming steps to list", 1, 8, 1,
        function() return ns.db.proftracker.steps end,
        function(v) ns.db.proftracker.steps = v ns.Refresh("proftracker") end)), 10, -18)

    left(track(MakeCheck(panel, "Materials for the current step", nil,
        function() return ns.db.proftracker.showMats end,
        function(v) ns.db.proftracker.showMats = v ns.Refresh("proftracker") end)), -6, -22)

    left(track(MakeCheck(panel, "Running total to buy", nil,
        function() return ns.db.proftracker.showCost end,
        function(v) ns.db.proftracker.showCost = v ns.Refresh("proftracker") end)), 0, -4)

    left(track(MakeCheck(panel, "Panel background", nil,
        function() return ns.db.proftracker.background end,
        function(v) ns.db.proftracker.background = v ns.Refresh("proftracker") end)), 0, -4)

    left(track(MakeCheck(panel, "Subtract what I already have in bags",
        "On, mats already in your bags or bank come off the list first. Off, the whole route is priced.",
        function() return ns.db.professions.includeOwned end,
        function(v) ns.db.professions.includeOwned = v ns.Refresh("professions") end)), -6, -16)

    left(track(MakeCheck(panel, "Show costs", nil,
        function() return ns.db.professions.showCost end,
        function(v) ns.db.professions.showCost = v ns.Refresh("professions") end)), 0, -4)

    mid(MakeHeader(panel, "Your professions"))

    local none = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    none:SetWidth(290)
    none:SetJustifyH("LEFT")
    none:SetText("No professions learned on this character yet.")
    mid(none, 12, -8)

    local rows = {}
    for i = 1, PROFESSION_ROWS do
        local button = MakeButton(panel, "", 260, function(self, mouseButton)
            if not self.wuiProfession then return end

            -- Right click keeps the old behaviour, because a full costed report is
            -- worth reaching for and there is nowhere better to put it.
            if mouseButton == "RightButton" then
                local prof = ns.modules.professions
                if prof and prof.Report then prof:Report(self.wuiProfession) end
                return
            end

            local tracker = ns.modules.proftracker
            if tracker and tracker.Track then
                tracker:Track(self.wuiProfession)
                ns.Print("guide now showing " .. self.wuiProfession .. ".")
            end

            if panel.refresh then panel.refresh() end
        end)
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        mid(button, 0, (i == 1) and -8 or -6)
        button:Hide()
        rows[i] = button
    end

    -- Skill lines are not readable until the character is in the world, and they
    -- change the moment a profession is trained or dropped, so the labels are
    -- painted on every page show rather than once at login.
    rows[1].wuiRefresh = function()
        local prof = ns.modules.professions
        local list = (prof and prof.Professions) and prof:Professions() or {}

        for i, button in ipairs(rows) do
            local entry = list[i]
            if entry then
                local tracker = ns.modules.proftracker
                local shown = tracker and tracker.Tracked and tracker.Tracked()
                local active = shown and shown.name == entry.name
                    and ns.db.proftracker and ns.db.proftracker.shown

                button.wuiProfession = entry.name
                button:SetText(string.format("%s%s  %d / %d%s",
                    active and "|cffffa028" or "",
                    entry.name, entry.skill, entry.max,
                    active and "  (on screen)|r" or ""))
                button:Show()
            else
                button.wuiProfession = nil
                button:Hide()
            end
        end

        none:SetShown(#list == 0)
    end
    track(rows[1])

    local pick = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    pick:SetWidth(290)
    pick:SetJustifyH("LEFT")
    pick:SetText("Click one to point the on screen guide at it. Right click for the full costed report instead.")
    mid(pick, 12, -10)

    right(MakeHeader(panel, "How this works"))

    local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetWidth(276)
    hint:SetJustifyH("LEFT")
    hint:SetText("The levelling routes are scraped from Wowhead's TBC guides and ship inside the "
        .. "addon, in Modules\\Professions\\Data.lua. They have to: the game client cannot fetch "
        .. "anything from the internet, so nothing here is ever downloaded or up to date with "
        .. "today's Wowhead."
        .. "|n|n"
        .. "A profession with no guide in that file says so rather than guessing at a route."
        .. "|n|n"
        .. "Prices come from TradeSkillMaster if you run it, Auctionator otherwise, and from "
        .. "neither if you run neither. Both only know what their own auction house scans have "
        .. "seen, so a material nobody has listed shows as no price rather than as free."
        .. "|n|n"
        .. "The report goes to chat, or to a copyable window once it outgrows a few lines.")
    right(hint, 0, -12)
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

SLASH_WOIDZUI1 = "/wui"
SLASH_WOIDZUI2 = "/woidz"
SLASH_WOIDZUI3 = "/woidzui"

SlashCmdList["WOIDZUI"] = function(msg)
    local cmd = (msg or ""):lower():match("^%s*(%S*)")

    if cmd == "unlock" then
        ns.SetUnlocked(true)
    elseif cmd == "lock" then
        ns.SetUnlocked(false)
    elseif cmd == "scan" then
        local found = ns.modules.buttons and ns.modules.buttons:Scan() or 0
        local placed = ns.RefreshMinimapIcons and ns.RefreshMinimapIcons() or 0
        ns.Print("scan picked up " .. found .. " new button(s), re-placed " .. placed .. " library icon(s).")
    elseif cmd == "square" then
        local placed = ns.RefreshMinimapIcons and ns.RefreshMinimapIcons() or 0
        ns.Print("re-placed " .. placed .. " library icon(s) against the square edge.")
    elseif cmd == "quests" then
        local pq = ns.modules.partyquests
        if pq and pq.Report then
            pq:Report()
        else
            ns.Print("party quest tracking is not loaded.")
        end
    elseif cmd == "guide" then
        local tracker = ns.modules.proftracker
        local wanted = (msg or ""):match("^%s*%S+%s+(.+)$")
        if wanted then wanted = wanted:gsub("%s+$", "") end

        if not (tracker and tracker.Toggle) then
            ns.Print("the guide tracker is not loaded.")
        elseif tracker:Toggle(wanted) then
            ns.Print("guide shown. Drag it by its title bar. Nothing but this command or its own header closes it.")
        else
            ns.Print("guide hidden.")
        end
    elseif cmd == "prof" or cmd == "professions" then
        local prof = ns.modules.professions
        if prof and prof.Report then
            -- Everything after the command, spaces and all, so "first aid"
            -- arrives whole. Read off the raw message rather than the lowered
            -- copy, because the guides are keyed by the client's own spelling.
            local arg = (msg or ""):match("^%s*%S+%s+(.-)%s*$")
            prof:Report((arg ~= "" and arg) or nil)
        else
            ns.Print("the professions module is not loaded.")
        end
    elseif cmd == "xp" then
        local xp = ns.modules.xpbar
        local arg = (msg or ""):lower():match("^%s*%S+%s+(%S+)")

        if not (xp and xp.Preview) then
            ns.Print("the XP bar module is not loaded.")
        elseif arg == nil or arg == "" then
            ns.Print("usage: /wui xp empty | full | <0-100> | rested | maxlevel | sweep | off")
        elseif arg == "off" or arg == "live" then
            if xp:PreviewOff() then
                ns.Print("XP bar back to live experience.")
            else
                ns.Print("the XP bar was already showing live experience.")
            end
        elseif arg == "empty" then
            xp:Preview(0, 0)
            ns.Print("XP bar previewing empty. /wui xp off to return.")
        elseif arg == "full" then
            xp:Preview(1, 0)
            ns.Print("XP bar previewing full. /wui xp off to return.")
        elseif arg == "rested" then
            xp:Preview(0.35, 0.5)
            ns.Print("XP bar previewing a rested pool. /wui xp off to return.")
        elseif arg == "maxlevel" or arg == "max" then
            xp:Preview(1, 0, xp:MaxLevel())
            ns.Print("XP bar previewing max level. /wui xp off to return.")
        elseif arg == "sweep" then
            xp:Sweep(4)
            ns.Print("sweeping the fill from empty to full. /wui xp off to return.")
        elseif tonumber(arg) then
            local pct = tonumber(arg)
            xp:Preview(pct / 100, 0)
            ns.Print(string.format("XP bar previewing %.0f%% full. /wui xp off to return.", pct))
        else
            ns.Print("usage: /wui xp empty | full | <0-100> | rested | maxlevel | sweep | off")
        end
    elseif cmd == "bars" then
        local xp = ns.modules.xpbar
        if xp and xp.Bars then
            local filled, exact, total = xp:Bars()
            if filled then
                local worth = xp:XPPerBar()
                local bph = xp.BarsPerHour and xp:BarsPerHour()

                local worthText = "unknown"
                if worth then
                    if worth == math.floor(worth) then
                        worthText = tostring(math.floor(worth))
                    else
                        worthText = string.format("%.1f", worth)
                    end
                end

                ns.Print(string.format("%d of %d bars filled (%.2f exact, %.2f to go)", filled, total, exact, total - exact))
                ns.Print(string.format("one bar at level %d is %s xp%s",
                    UnitLevel("player") or 0, worthText,
                    bph and string.format(", currently %.1f bars an hour", bph) or ""))
            else
                ns.Print("no experience bar to measure right now.")
            end
        end
    elseif cmd == "debug" then
        if ns.modules.buttons and ns.modules.buttons.Debug then
            ns.modules.buttons:Debug()
        end
    elseif cmd == "reset" then
        WoidzUIDB = nil
        ns.Print("settings wiped, reloading.")
        ReloadUI()
    elseif cmd == "config" or cmd == "" then
        ns.OpenConfig()
    else
        ns.Print("commands: config, unlock, lock, scan, square, bars, quests, prof [profession], guide [profession], xp, debug, reset")
    end
end

--------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    BuildWindow()
    AddPage("Minimap", BuildMinimapPage)
    AddPage("Button tray", BuildTrayPage)
    AddPage("XP bar", BuildXPPage)
    AddPage("Party quests", BuildPartyQuestsPage)
    AddPage("Collected", BuildCollectedPage)
    AddPage("Professions", BuildProfessionsPage)
    ns.ShowConfigPage(1)
    window:Hide()
end)
