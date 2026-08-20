local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Profession guide tracker
--
-- An always on screen panel in the shape of the quest tracker: a header, then
-- indented rows under it, sitting on the HUD rather than in a window.
--
-- It is deliberately NOT closeable by anything but its own toggle, and that takes
-- two specific decisions:
--
--   It is never put in UISpecialFrames. That list is what Escape walks, so being
--   in it means any stray Escape wipes the panel out mid craft.
--
--   It is never registered as a UI panel (no ShowUIPanel, no UIPanelWindows
--   entry). The panel system is allowed to push its members off screen or shut
--   them outright to make room, which is why opening a character sheet can close
--   a window nobody asked it to touch.
--
-- Being a plain frame parented to UIParent also keeps CloseAllWindows and the
-- various addons that call it from reaching this at all.
--
-- Every row is two font strings, a label on the left and a value on the right,
-- rather than one string carrying both. One string meant the quantity sat
-- wherever the name happened to end, and a long recipe name pushed it out of the
-- panel entirely: at 250px wide "Enchant Cloak - Superior Defense" wrapped onto a
-- second row and drew straight over the line below it.
--------------------------------------------------------------------------------

local M = ns:NewModule("proftracker", "Profession guide", {
    enabled = true,
    locked = true,
    point = { "RIGHT", "RIGHT", -30, 60 },
    width = 280,
    profession = nil,   -- nil means pick the first one with a guide
    shown = false,
    collapsed = false,
    steps = 3,          -- how many upcoming steps to show under the current one
    showMats = true,
    showCost = true,
    background = true,
    fontSize = 11,
})

local db
local panel

local LABEL = "|cff9d9d9d"
local DIM = "|cff6e6e6e"
local VALUE = "|cffffffff"
local ACCENT = "|cffffa028"
local GOOD = "|cff59c94c"
local SHORT = "|cffd66b6b"
local STOP = "|r"

local PAD = 8       -- side padding
local INDENT = 10   -- how far a material sits in from a step
local GAP = 8       -- smallest space allowed between the two columns

-- Bag counts move constantly while looting, and the skill only moves on a craft.
-- One redraw a second after the last change covers both without redrawing the
-- panel several times over for a single loot.
local COALESCE = 1
local pending

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function Professions()
    local module = ns.modules and ns.modules.professions
    if not module or not module.Professions then return {} end

    local ok, list = pcall(module.Professions, module)
    if ok and type(list) == "table" then return list end
    return {}
end

-- Whichever profession the user picked, falling back to the first one that has a
-- guide at all. Picking nothing and showing an empty panel would just look broken.
local function Tracked()
    local list = Professions()
    if #list == 0 then return nil end

    if db and db.profession then
        for _, entry in ipairs(list) do
            if entry.name == db.profession then return entry end
        end
    end

    local guides = ns.ProfessionGuides or {}
    for _, entry in ipairs(list) do
        if guides[entry.name] then return entry end
    end

    return nil
end
M.Tracked = Tracked

-- Coloured, because a price on this panel is read at a glance and the coin
-- colours are what the eye already knows. Prices.lua is a separate file with
-- its own ways of failing, so a missing formatter still prints a number.
local function Money(copper)
    if not copper then return nil end
    if ns.Prices and ns.Prices.Format then
        local ok, text = pcall(ns.Prices.Format, copper, true)
        if ok and text then return text end
    end
    return tostring(math.floor(copper))
end

--------------------------------------------------------------------------------
-- Content
--
-- Kept apart from the drawing so the whole panel can be asserted on without a
-- frame anywhere in sight. Each row is { left, right, indent, kind }.
--------------------------------------------------------------------------------

function M:Compose()
    local out = {}

    local entry = Tracked()
    if not entry then
        out[#out + 1] = { left = LABEL .. "No profession with a guide." .. STOP, kind = "empty" }
        return out, nil
    end

    local module = ns.modules and ns.modules.professions
    if not module then return out, entry end

    local plan = module:Plan(entry.name)
    if not plan then
        out[#out + 1] = { left = LABEL .. "No guide for " .. entry.name .. "." .. STOP, kind = "empty" }
        return out, entry
    end

    if #plan == 0 then
        out[#out + 1] = { left = GOOD .. "Finished. Nothing left to level." .. STOP, kind = "done" }
        return out, entry
    end

    local wanted = math.max(1, db.steps or 3)

    for i = 1, math.min(#plan, wanted) do
        local step = plan[i]
        local current = (i == 1)

        -- A hyphen rather than the word "to". On a 280px panel next to a recipe
        -- name that can run past thirty characters, six characters of range
        -- label is six characters the name does not get.
        local range = string.format("%d-%d", step.from, step.to)

        out[#out + 1] = {
            left = (current and ACCENT or DIM) .. range .. STOP .. "  " ..
                (current and VALUE or LABEL) .. (step.craft or "?") .. STOP,
            right = (current and ACCENT or DIM) .. "x" .. (step.count or 1) .. STOP,
            kind = "step",
            current = current,
            step = step,
        }

        -- Materials only for the step being worked on. Listing them for every
        -- upcoming step turns a tracker into a wall of text.
        if current and db.showMats then
            for _, mat in ipairs(step.mats or {}) do
                local need = (mat.each or 0) * (step.count or 1)
                local have = 0
                if GetItemCount and mat.id then
                    have = GetItemCount(mat.id, true) or 0
                end

                local enough = have >= need
                out[#out + 1] = {
                    left = LABEL .. (mat.name or "?") .. STOP,
                    right = (enough and GOOD or SHORT) .. have .. STOP ..
                        DIM .. " / " .. need .. STOP,
                    indent = INDENT,
                    kind = "mat",
                    mat = mat,
                    need = need,
                    have = have,
                    enough = enough,
                }
            end
        end

        if current and step.note then
            out[#out + 1] = {
                left = DIM .. step.note .. STOP,
                indent = INDENT,
                kind = "note",
            }
        end
    end

    if db.showCost and module.ShoppingList then
        local ok, rows, total, unknown = pcall(module.ShoppingList, module, entry.name)
        if ok and total then
            -- No accent wrapper around it: the coin colours are the colour
            -- here, and an outer code would be closed by the first inner one.
            local right = Money(total) or (ACCENT .. "?" .. STOP)
            if unknown and unknown > 0 then
                right = right .. DIM .. "  +" .. unknown .. STOP
            end
            out[#out + 1] = {
                left = LABEL .. "Still to buy" .. STOP,
                right = right,
                kind = "total",
                divider = true,
                total = total,
                unknown = unknown,
            }
        end
    end

    return out, entry
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function Row(index)
    local row = panel.rows[index]
    if row then return row end

    row = {}

    row.left = panel.body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.left:SetJustifyH("LEFT")

    row.right = panel.body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetJustifyH("RIGHT")

    -- Neither column may wrap. The row spacing assumes one line each, so a wrap
    -- puts the overflow straight on top of the row below.
    for _, fs in ipairs({ row.left, row.right }) do
        if fs.SetWordWrap then fs:SetWordWrap(false) end
        if fs.SetMaxLines then fs:SetMaxLines(1) end
    end

    -- The bar behind the row, the shape a damage meter uses: it fills from the
    -- left in proportion to the row's own progress, with the text on top of it.
    -- On a material that is how much of it you already have; on the step being
    -- worked it marks the live row.
    row.meter = panel.body:CreateTexture(nil, "BACKGROUND")
    row.meter:SetTexture(ns.SOLID)
    row.meter:Hide()

    row.divider = panel.body:CreateTexture(nil, "ARTWORK")
    row.divider:SetTexture(ns.SOLID)
    row.divider:SetVertexColor(1, 1, 1, 0.08)
    row.divider:Hide()

    panel.rows[index] = row
    return row
end

local function Build()
    panel = CreateFrame("Frame", "WoidzUIProfTracker", UIParent)
    panel:SetSize(db.width, 40)
    panel:SetFrameStrata("MEDIUM")
    panel:EnableMouse(true)
    ns.RestorePosition(panel, db, ns.defaults.proftracker.point)

    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(panel)
    bg:SetTexture(ns.SOLID)
    panel.bg = bg

    -- One hairline around the panel, drawn only when the background is on. A
    -- floating list of text needs an edge to sit inside; a transparent one has
    -- nothing to draw an edge around.
    if ns.Style then ns.Style.Border(panel, ns.W.border) end

    panel.header = CreateFrame("Button", nil, panel)
    panel.header:SetPoint("TOPLEFT", PAD, -6)
    panel.header:SetPoint("TOPRIGHT", -PAD, -6)
    panel.header:SetHeight(14)

    panel.title = panel.header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    panel.title:SetPoint("LEFT")
    panel.title:SetJustifyH("LEFT")

    panel.skill = panel.header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.skill:SetPoint("RIGHT", -12, 0)
    panel.skill:SetJustifyH("RIGHT")

    panel.toggle = panel.header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.toggle:SetPoint("RIGHT")

    -- A hairline under the header, which is most of what separates this from a
    -- pile of text stacked on a dark square.
    panel.rule = panel:CreateTexture(nil, "ARTWORK")
    panel.rule:SetTexture(ns.SOLID)
    panel.rule:SetVertexColor(1, 1, 1, 0.10)
    panel.rule:SetPoint("TOPLEFT", panel.header, "BOTTOMLEFT", 0, -3)
    panel.rule:SetPoint("TOPRIGHT", panel.header, "BOTTOMRIGHT", 0, -3)
    panel.rule:SetHeight(1)

    -- Collapsing is the only hiding this panel does on its own, and it is on the
    -- header rather than a close button on purpose: there is no way to dismiss
    -- the thing by accident while reaching for something else.
    panel.header:RegisterForClicks("LeftButtonUp")
    panel.header:SetScript("OnClick", function()
        db.collapsed = not db.collapsed
        M:Refresh()
    end)

    -- Dragging by the header works whether or not the frames are unlocked. The
    -- shared mover still covers this panel, but requiring /wui unlock to nudge a
    -- HUD element the user is actively reading is a step too many.
    panel.header:RegisterForDrag("LeftButton")
    panel.header:SetScript("OnDragStart", function()
        panel:StartMoving()
        panel.dragging = true
    end)
    panel.header:SetScript("OnDragStop", function()
        panel:StopMovingOrSizing()
        panel.dragging = false
        ns.SavePosition(panel, db)
    end)

    panel.body = CreateFrame("Frame", nil, panel)
    panel.body:SetPoint("TOPLEFT", panel.rule, "BOTTOMLEFT", 0, -5)
    panel.body:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
    panel.body:SetHeight(1)

    panel.rows = {}

    ns.RegisterMover(panel, db, "Profession guide")
    M.panel = panel
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

function M:Refresh()
    if not panel then return end

    if not db.enabled or not db.shown then
        panel:Hide()
        return
    end

    panel:Show()
    panel:SetWidth(db.width)
    panel.bg:SetVertexColor(ns.C.bg[1], ns.C.bg[2], ns.C.bg[3], 0.86)
    panel.bg:SetShown(db.background)
    if panel.borderTextures then
        for _, edge in ipairs(panel.borderTextures) do edge:SetShown(db.background) end
    end

    local entry = Tracked()
    if entry then
        panel.title:SetText(ACCENT .. entry.name .. STOP)
        panel.skill:SetFormattedText("%s%d%s%s / %d%s",
            VALUE, entry.skill or 0, STOP, DIM, entry.max or 375, STOP)
    else
        panel.title:SetText(ACCENT .. "Profession guide" .. STOP)
        panel.skill:SetText("")
    end
    panel.toggle:SetText(db.collapsed and "+" or "-")

    for _, row in ipairs(panel.rows) do
        row.left:Hide()
        row.right:Hide()
        row.divider:Hide()
        row.meter:Hide()
    end

    if db.collapsed then
        panel.rule:Hide()
        panel.body:SetHeight(1)
        panel:SetHeight(28)
        return
    end
    panel.rule:Show()

    local composed = self:Compose()
    local lineHeight = db.fontSize + 4
    local usable = db.width - (PAD * 2)
    local y = 0

    for i, item in ipairs(composed) do
        local row = Row(i)

        -- A divider costs a few pixels of its own, so the row below it starts
        -- lower rather than sitting on the line.
        if item.divider then
            y = y + 5
            row.divider:ClearAllPoints()
            row.divider:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, -(y - 3))
            row.divider:SetPoint("TOPRIGHT", panel.body, "TOPRIGHT", 0, -(y - 3))
            row.divider:SetHeight(1)
            row.divider:Show()
        end

        local indent = item.indent or 0

        -- Meter first, so the text below draws over it.
        local frac, colour
        if item.kind == "mat" and (item.need or 0) > 0 then
            frac = math.min(1, (item.have or 0) / item.need)
            colour = item.enough and ns.C.good or ns.C.accent
        elseif item.kind == "step" and item.current then
            frac = 1
            colour = ns.C.accent
        end

        if frac and frac > 0 and ns.Style then
            row.meter:ClearAllPoints()
            row.meter:SetPoint("TOPLEFT", panel.body, "TOPLEFT", 0, -(y - 1))
            row.meter:SetHeight(lineHeight - 1)
            row.meter:SetWidth(math.max(1, usable * frac))
            ns.Style.Gradient(row.meter, "HORIZONTAL",
                { colour[1], colour[2], colour[3], 0.22 },
                { colour[1], colour[2], colour[3], 0.03 })
            row.meter:Show()
        end

        for _, fs in ipairs({ row.left, row.right }) do
            local path, _, flags = fs:GetFont()
            if path then fs:SetFont(path, db.fontSize, flags) end
        end

        row.left:ClearAllPoints()
        row.left:SetPoint("TOPLEFT", panel.body, "TOPLEFT", indent, -y)
        row.left:SetText(item.left or "")
        row.left:Show()

        if item.right and item.right ~= "" then
            row.right:ClearAllPoints()
            row.right:SetPoint("TOPRIGHT", panel.body, "TOPRIGHT", 0, -y)
            row.right:SetText(item.right)
            row.right:Show()

            -- The left column stops where the right one starts. Without this the
            -- two overlap the moment a recipe name is long, which is the whole
            -- fault being fixed.
            local rightWidth = row.right:GetStringWidth() or 0
            local room = usable - indent - rightWidth - GAP
            if room > 10 then row.left:SetWidth(room) end
        else
            row.left:SetWidth(math.max(10, usable - indent))
        end

        y = y + lineHeight
    end

    panel.body:SetHeight(math.max(1, y))
    panel:SetHeight(y + 34)
end

--------------------------------------------------------------------------------
-- Toggling
--------------------------------------------------------------------------------

function M:Toggle(professionName)
    if professionName and professionName ~= "" then
        db.profession = professionName
        db.shown = true
    else
        db.shown = not db.shown
    end

    self:Refresh()
    return db.shown
end

function M:Track(professionName)
    db.profession = professionName
    db.shown = true
    self:Refresh()
end

function M:IsShown()
    return db.shown and true or false
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function Schedule()
    if pending then return end

    if not (C_Timer and C_Timer.After) then
        M:Refresh()
        return
    end

    pending = true
    C_Timer.After(COALESCE, function()
        pending = false
        M:Refresh()
    end)
end

function M:OnSettingsChanged()
    self:Refresh()
end

function M:OnInit(settings)
    db = settings
end

function M:OnEnable(settings)
    db = settings

    Build()
    self:Refresh()

    local events = CreateFrame("Frame")
    events:RegisterEvent("SKILL_LINES_CHANGED")
    events:RegisterEvent("CHAT_MSG_SKILL")
    events:RegisterEvent("TRADE_SKILL_UPDATE")
    events:RegisterEvent("BAG_UPDATE_DELAYED")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")

    events:SetScript("OnEvent", function()
        -- Prices are cached per scan, and a craft or a loot has just changed what
        -- the answer should be.
        if ns.Prices and ns.Prices.ClearCache then ns.Prices.ClearCache() end
        Schedule()
    end)

    M.events = events
end
