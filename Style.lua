local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Style
--
-- The shared look for every WoidzUI frame: palette, materials, and a small
-- widget kit that replaces Blizzard's templates. UIPanelButtonTemplate,
-- UICheckButtonTemplate and OptionsSliderTemplate carry the 2004 parchment and
-- rivets look, and no amount of recolouring gets them out of it, so nothing
-- here uses a template.
--
-- Two rules the whole file is arranged around:
--
--   Orange is state, never surface. It marks the active tab, a value worth
--   reading, a checked box, the filled part of a slider and the one primary
--   action. It never fills a panel or a row.
--
--   A surface is raised or cut, never flat with only a border. Depth is one
--   1px lit edge and one 1px shade, the way a damage meter draws its rows.
--
-- Nothing here creates a frame on a refresh path; every widget builds its
-- textures once and only recolours them afterwards.
--------------------------------------------------------------------------------

local SOLID = "Interface\\Buttons\\WHITE8X8"

-- Hues. Same family as the rest of the suite: warm orange on charcoal.
ns.C = {
    bg          = { 0.055, 0.058, 0.067, 0.96 },
    panel       = { 0.071, 0.075, 0.086, 1 },
    raised      = { 0.106, 0.110, 0.125, 1 },
    hover       = { 0.145, 0.153, 0.169, 1 },
    text        = { 0.980, 0.960, 0.941, 1 },
    dim         = { 0.588, 0.596, 0.612, 1 },
    accent      = { 1.000, 0.561, 0.180, 1 },
    accentDark  = { 0.722, 0.361, 0.071, 1 },
    accentLight = { 1.000, 0.745, 0.502, 1 },
    good        = { 0.243, 0.769, 0.416, 1 },
    warn        = { 1.000, 0.851, 0.239, 1 },
    bad         = { 0.973, 0.443, 0.443, 1 },
}

-- Quiet surfaces are white at a low alpha over the dark canvas, whatever the
-- accent is. Keeping them out of the palette is what stops a recolour from
-- turning every hairline orange.
ns.W = {
    card     = { 1, 1, 1, 0.045 },
    inner    = { 1, 1, 1, 0.05 },
    hover    = { 1, 1, 1, 0.08 },
    hairline = { 1, 1, 1, 0.06 },
    border   = { 1, 1, 1, 0.10 },
    strong   = { 1, 1, 1, 0.30 },
    muted    = { 1, 1, 1, 0.50 },
    body     = { 1, 1, 1, 0.80 },
    track    = { 1, 1, 1, 0.12 },
    scrim    = { 0, 0, 0, 0.25 },
    well     = { 0, 0, 0, 0.34 },
}

local C, W = ns.C, ns.W
local S = {}
ns.Style = S

local FONT = GameFontNormal:GetFont()

--------------------------------------------------------------------------------
-- primitives
--------------------------------------------------------------------------------

function S.Tex(parent, layer, c)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetTexture(SOLID)
    if c then t:SetVertexColor(c[1], c[2], c[3], c[4] or 1) end
    return t
end

function S.SetColor(tex, c, alpha)
    tex:SetVertexColor(c[1], c[2], c[3], alpha or c[4] or 1)
end

-- Four hairlines rather than a backdrop: crisp at any UI scale, no template.
function S.Border(f, c)
    local b = {}
    for i = 1, 4 do b[i] = S.Tex(f, "BORDER", c or W.border) end
    b[1]:SetPoint("TOPLEFT");    b[1]:SetPoint("TOPRIGHT");    b[1]:SetHeight(1)
    b[2]:SetPoint("BOTTOMLEFT"); b[2]:SetPoint("BOTTOMRIGHT"); b[2]:SetHeight(1)
    b[3]:SetPoint("TOPLEFT");    b[3]:SetPoint("BOTTOMLEFT");  b[3]:SetWidth(1)
    b[4]:SetPoint("TOPRIGHT");   b[4]:SetPoint("BOTTOMRIGHT"); b[4]:SetWidth(1)
    f.borderTextures = b
    return b
end

function S.SetBorder(f, c, alpha)
    if not f.borderTextures then return end
    for i = 1, 4 do S.SetColor(f.borderTextures[i], c, alpha) end
end

-- "raised" is lit from above, "cut" is sunk. Every surface is one or the other.
function S.Bevel(f, mode)
    local top    = (mode == "cut") and { 0, 0, 0, 0.55 } or { 1, 1, 1, 0.06 }
    local bottom = (mode == "cut") and { 1, 1, 1, 0.03 } or { 0, 0, 0, 0.40 }

    local t = S.Tex(f, "ARTWORK", top)
    t:SetPoint("TOPLEFT", 0, -1); t:SetPoint("TOPRIGHT", 0, -1); t:SetHeight(1)

    local b = S.Tex(f, "ARTWORK", bottom)
    b:SetPoint("BOTTOMLEFT", 0, 1); b:SetPoint("BOTTOMRIGHT", 0, 1); b:SetHeight(1)
    return f
end

function S.Font(parent, size, c, flags, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(FONT, size or 12, flags or "")
    c = c or C.text
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    if justify then fs:SetJustifyH(justify) end
    return fs
end

-- Letterspacing, faked with spaces because font strings have none. Per byte,
-- so anything outside ASCII is uppercased and left alone rather than cut
-- through the middle of a multi byte character.
function S.Track(text)
    if not text or text == "" then return text end
    text = text:upper()
    if text:find("[\128-\255]") then return text end
    return (text:gsub("(.)", "%1 "):gsub(" $", ""))
end

-- Old clients take seven numbers, newer ones take two colour objects. Both are
-- tried, and a client with neither still gets the solid end colour.
function S.Gradient(tex, orientation, c1, c2)
    tex:SetTexture(SOLID)
    tex:SetVertexColor(1, 1, 1, 1)
    local a1, a2 = c1[4] or 1, c2[4] or 1
    if tex.SetGradient and _G.CreateColor then
        local ok = pcall(tex.SetGradient, tex, orientation,
            _G.CreateColor(c1[1], c1[2], c1[3], a1),
            _G.CreateColor(c2[1], c2[2], c2[3], a2))
        if ok then return true end
    end
    if tex.SetGradientAlpha then
        local ok = pcall(tex.SetGradientAlpha, tex, orientation,
            c1[1], c1[2], c1[3], a1, c2[1], c2[2], c2[3], a2)
        if ok then return true end
    end
    tex:SetVertexColor(c2[1], c2[2], c2[3], a2)
    return false
end

--------------------------------------------------------------------------------
-- surfaces
--------------------------------------------------------------------------------

function S.Panel(parent, fill, border, mode)
    local f = CreateFrame("Frame", nil, parent)
    f:EnableMouse(true)
    f.bg = S.Tex(f, "BACKGROUND", fill or C.panel)
    f.bg:SetAllPoints()
    S.Border(f, border or W.border)
    S.Bevel(f, mode or "raised")
    return f
end

-- Label, then a hairline that fades as it runs to the edge. This replaces the
-- yellow GameFontNormal heading, which is the single loudest generic tell in a
-- settings window.
function S.Header(parent, text)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(14)
    f:SetWidth(300)

    f.label = S.Font(f, 10, C.accent, nil, "LEFT")
    f.label:SetPoint("LEFT")
    f.label:SetText(S.Track(text))

    f.line = S.Tex(f, "ARTWORK")
    f.line:SetHeight(1)
    f.line:SetPoint("LEFT", f.label, "RIGHT", 8, 0)
    f.line:SetPoint("RIGHT")
    S.Gradient(f.line, "HORIZONTAL", { 1, 1, 1, 0.12 }, { 1, 1, 1, 0.02 })

    function f:SetText(t) self.label:SetText(S.Track(t)) end
    return f
end

--------------------------------------------------------------------------------
-- button
--
-- Three variants, all a translucent fill behind a 1px border of the same hue.
-- Never a solid orange slab: a filled accent button is what turns the accent
-- into a surface.
--------------------------------------------------------------------------------
local VARIANT = {
    ghost   = function() return C.raised, W.border, C.text, C.hover, C.accent end,
    primary = function()
        local a = C.accent
        return { a[1], a[2], a[3], 0.14 }, { a[1], a[2], a[3], 0.45 }, a,
               { a[1], a[2], a[3], 0.24 }, C.accentLight
    end,
    danger  = function()
        local d = C.bad
        return { d[1], d[2], d[3], 0.12 }, { d[1], d[2], d[3], 0.40 }, d,
               { d[1], d[2], d[3], 0.22 }, d
    end,
}

function S.Button(parent, text, width, height, onClick, variant)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 130, height or 22)

    local fill, border, textColor, hoverFill, hoverText =
        (VARIANT[variant or "ghost"] or VARIANT.ghost)()
    b.restFill, b.hoverFill = fill, hoverFill
    b.restText, b.hoverText = textColor, hoverText

    b.bg = S.Tex(b, "BACKGROUND", fill)
    b.bg:SetAllPoints()
    S.Border(b, border)
    S.Bevel(b, "raised")

    b.label = S.Font(b, 12, textColor, nil, "CENTER")
    b.label:SetPoint("CENTER")
    b.label:SetText(text or "")

    b:SetScript("OnEnter", function(self)
        S.SetColor(self.bg, self.hoverFill)
        self.label:SetTextColor(unpack(self.hoverText))
        if self.tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self.tooltipText, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        S.SetColor(self.bg, self.restFill)
        self.label:SetTextColor(unpack(self.restText))
        GameTooltip:Hide()
    end)
    b:SetScript("OnMouseDown", function(self) self.label:SetPoint("CENTER", 0, -1) end)
    b:SetScript("OnMouseUp", function(self) self.label:SetPoint("CENTER", 0, 0) end)
    if onClick then b:SetScript("OnClick", onClick) end

    -- Kept so a caller can keep using SetText the way it did with the Blizzard
    -- template it replaced.
    function b:SetText(t) self.label:SetText(t or "") end
    function b:GetText() return self.label:GetText() end
    return b
end

--------------------------------------------------------------------------------
-- checkbox
--------------------------------------------------------------------------------
function S.Check(parent, label, tooltip, get, set)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(20)

    local box = CreateFrame("Frame", nil, b)
    box:SetSize(15, 15)
    box:SetPoint("LEFT")
    box.bg = S.Tex(box, "BACKGROUND", W.scrim)
    box.bg:SetAllPoints()
    S.Border(box, W.strong)
    S.Bevel(box, "cut")

    local tick = S.Tex(box, "OVERLAY", C.accent)
    tick:SetPoint("TOPLEFT", 4, -4)
    tick:SetPoint("BOTTOMRIGHT", -4, 4)

    b.text = S.Font(b, 12, C.text, nil, "LEFT")
    b.text:SetPoint("LEFT", box, "RIGHT", 8, 0)
    b.text:SetText(label or "")
    b:SetWidth(b.text:GetStringWidth() + 28)

    b.tooltipText = tooltip

    function b:Refresh()
        local on = get() and true or false
        tick:SetShown(on)
        if on then
            S.SetColor(box.bg, C.accent, 0.12)
            S.SetBorder(box, C.accent, 0.55)
        else
            S.SetColor(box.bg, W.scrim)
            S.SetBorder(box, W.strong)
        end
    end
    -- The config window refreshes a whole page through this hook.
    b.wuiRefresh = function() b:Refresh() end

    -- Kept for call sites that speak the Blizzard CheckButton API.
    function b:SetChecked(v) set(v and true or false) self:Refresh() end
    function b:GetChecked() return get() and true or false end
    function b:SetLabel(t)
        self.text:SetText(t or "")
        self:SetWidth(self.text:GetStringWidth() + 28)
    end

    b:SetScript("OnClick", function(self)
        set(not get())
        self:Refresh()
        PlaySound(856)
    end)
    b:SetScript("OnEnter", function(self)
        self.text:SetTextColor(unpack(C.accent))
        if self.tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.tooltipText, 1, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.text:SetTextColor(unpack(C.text))
        GameTooltip:Hide()
    end)

    b:Refresh()
    return b
end

--------------------------------------------------------------------------------
-- slider
--
-- Caption and live value on one line above a 4px track, with the minimum and
-- maximum under its ends. The filled part of the track is the accent, so the
-- position is readable without reading the number.
--------------------------------------------------------------------------------
function S.Slider(parent, label, minV, maxV, step, get, set)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(210, 40)

    local caption = S.Font(f, 11, C.dim, nil, "LEFT")
    caption:SetPoint("TOPLEFT", 0, 0)
    caption:SetText(label)

    local value = S.Font(f, 11, C.accent, nil, "RIGHT")
    value:SetPoint("TOPRIGHT", 0, 0)

    local slider = CreateFrame("Slider", nil, f)
    slider:SetOrientation("HORIZONTAL")
    slider:SetHeight(12)
    slider:SetPoint("TOPLEFT", 0, -16)
    slider:SetPoint("TOPRIGHT", 0, -16)
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(step)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end

    local track = S.Tex(slider, "BACKGROUND", W.track)
    track:SetPoint("LEFT")
    track:SetPoint("RIGHT")
    track:SetHeight(4)

    local fill = S.Tex(slider, "BORDER")
    fill:SetPoint("LEFT", track, "LEFT")
    fill:SetHeight(4)
    fill:SetWidth(1)
    S.Gradient(fill, "HORIZONTAL", C.accentDark, C.accent)

    -- A thumb wide enough to grab, drawn as a plain bar rather than as the
    -- template's metal knob.
    slider:SetThumbTexture(SOLID)
    local thumb = slider:GetThumbTexture()
    thumb:SetSize(6, 12)
    thumb:SetVertexColor(C.accentLight[1], C.accentLight[2], C.accentLight[3], 1)

    local low = S.Font(f, 9, W.muted, nil, "LEFT")
    low:SetPoint("BOTTOMLEFT", 0, 0)
    low:SetText(tostring(minV))

    local high = S.Font(f, 9, W.muted, nil, "RIGHT")
    high:SetPoint("BOTTOMRIGHT", 0, 0)
    high:SetText(tostring(maxV))

    local function Paint(v)
        value:SetText(tostring(v))
        local w = track:GetWidth() or 0
        local span = (maxV - minV)
        local frac = span > 0 and ((v - minV) / span) or 0
        fill:SetWidth(math.max(1, w * math.max(0, math.min(1, frac))))
    end

    slider:SetScript("OnValueChanged", function(_, v)
        v = math.floor(v / step + 0.5) * step
        Paint(v)
        set(v)
    end)
    slider:SetScript("OnSizeChanged", function() Paint(get()) end)

    slider:SetValue(get())
    Paint(get())

    f.slider = slider
    f.wuiRefresh = function()
        slider:SetValue(get())
        Paint(get())
    end
    function f:SetValue(v) slider:SetValue(v) end
    function f:GetValue() return slider:GetValue() end
    return f
end

--------------------------------------------------------------------------------
-- tab
--
-- A tab is a label with a 2px sill under it when it is the live one. No slab,
-- no second border: the page below is what the tab belongs to.
--------------------------------------------------------------------------------
function S.Tab(parent, text, onClick)
    local t = CreateFrame("Button", nil, parent)
    t:SetHeight(24)

    t.bg = S.Tex(t, "BACKGROUND", { 1, 1, 1, 0 })
    t.bg:SetAllPoints()

    t.label = S.Font(t, 12, C.dim, nil, "CENTER")
    t.label:SetPoint("CENTER")
    t.label:SetText(text or "")

    t.sill = S.Tex(t, "OVERLAY")
    t.sill:SetPoint("BOTTOMLEFT", 4, 0)
    t.sill:SetPoint("BOTTOMRIGHT", -4, 0)
    t.sill:SetHeight(2)
    S.Gradient(t.sill, "HORIZONTAL", C.accentDark, C.accent)
    t.sill:Hide()

    function t:SetActive(on)
        self.active = on and true or false
        self.sill:SetShown(self.active)
        self.label:SetTextColor(unpack(self.active and C.text or C.dim))
        S.SetColor(self.bg, W.hover, self.active and 0.05 or 0)
    end

    function t:SetText(s) self.label:SetText(s or "") end

    t:SetScript("OnEnter", function(self)
        if not self.active then
            self.label:SetTextColor(unpack(C.text))
            S.SetColor(self.bg, W.hover, 0.06)
        end
    end)
    t:SetScript("OnLeave", function(self)
        if not self.active then
            self.label:SetTextColor(unpack(C.dim))
            S.SetColor(self.bg, W.hover, 0)
        end
    end)
    if onClick then t:SetScript("OnClick", onClick) end

    t:SetActive(false)
    return t
end

--------------------------------------------------------------------------------
-- close button
--------------------------------------------------------------------------------
function S.CloseButton(parent, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(24, 24)
    b.label = S.Font(b, 13, C.dim, nil, "CENTER")
    b.label:SetPoint("CENTER")
    b.label:SetText("X")
    b:SetScript("OnEnter", function(self) self.label:SetTextColor(unpack(C.bad)) end)
    b:SetScript("OnLeave", function(self) self.label:SetTextColor(unpack(C.dim)) end)
    b:SetScript("OnClick", onClick)
    return b
end

--------------------------------------------------------------------------------
-- meter row
--
-- The damage meter shape: a bar behind a row filling from the left in
-- proportion to its value, with the text on top. Used by the profession guide
-- for material progress.
--------------------------------------------------------------------------------
function S.RowMeter(row)
    local t = S.Tex(row, "BACKGROUND")
    t:SetPoint("TOPLEFT")
    t:SetPoint("BOTTOMLEFT")
    t:SetWidth(1)
    t:Hide()
    return t
end

function S.SetRowMeter(tex, row, frac, c)
    local w = row:GetWidth() or 0
    frac = math.max(0, math.min(1, frac or 0))
    if w <= 0 or frac <= 0 then
        tex:Hide()
        return
    end
    tex:SetWidth(math.max(1, w * frac))
    S.Gradient(tex, "HORIZONTAL", { c[1], c[2], c[3], 0.24 }, { c[1], c[2], c[3], 0.04 })
    tex:Show()
end

--------------------------------------------------------------------------------
-- tick box
--
-- A real CheckButton, so call sites keep using SetChecked and GetChecked, but
-- with our own textures instead of the template's yellow tick on a stone
-- square. Used by the list rows that are checkable.
--------------------------------------------------------------------------------
function S.TickBox(parent, size)
    local cb = CreateFrame("CheckButton", nil, parent)
    size = size or 16
    cb:SetSize(size, size)

    cb.bg = S.Tex(cb, "BACKGROUND", W.scrim)
    cb.bg:SetAllPoints()
    S.Border(cb, W.strong)

    -- Set by path, then re-anchored, because a checked texture given as a path
    -- fills the whole button and the mark wants an inset.
    cb:SetCheckedTexture(SOLID)
    local check = cb:GetCheckedTexture()
    if check then
        check:ClearAllPoints()
        check:SetPoint("TOPLEFT", 4, -4)
        check:SetPoint("BOTTOMRIGHT", -4, 4)
        check:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 1)
    end

    cb:SetHighlightTexture(SOLID)
    local hl = cb:GetHighlightTexture()
    if hl then
        hl:SetAllPoints()
        hl:SetVertexColor(1, 1, 1, 0.08)
    end

    return cb
end

--------------------------------------------------------------------------------
-- restyling Blizzard frames we still want the behaviour of
--
-- A ScrollFrame and an EditBox are worth keeping: their scrolling and their
-- text input are not worth rewriting. Their art is not worth keeping, so it is
-- stripped and replaced.
--------------------------------------------------------------------------------
function S.StripTextures(frame)
    if not frame or not frame.GetRegions then return end
    for _, region in ipairs({ frame:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "Texture" then
            region:SetTexture(nil)
        end
    end
end

function S.ScrollBar(scroll)
    local name = scroll.GetName and scroll:GetName()
    local bar = name and _G[name .. "ScrollBar"]
    if not bar then return end

    -- The arrows go: a 5px bar with a thumb is the whole control, and the
    -- wheel plus a draggable thumb covers everything the arrows did.
    local up = _G[bar:GetName() and (bar:GetName() .. "ScrollUpButton")]
        or _G[name .. "ScrollBarScrollUpButton"]
    local down = _G[bar:GetName() and (bar:GetName() .. "ScrollDownButton")]
        or _G[name .. "ScrollBarScrollDownButton"]
    if up then up:Hide(); up:SetWidth(1) end
    if down then down:Hide(); down:SetWidth(1) end

    S.StripTextures(bar)
    bar:SetWidth(5)

    local track = S.Tex(bar, "BACKGROUND", { 0, 0, 0, 0.35 })
    track:SetPoint("TOPLEFT", 0, -2)
    track:SetPoint("BOTTOMRIGHT", 0, 2)

    bar:SetThumbTexture(SOLID)
    local thumb = bar:GetThumbTexture()
    if thumb then
        thumb:SetSize(5, 40)
        thumb:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.55)
    end
    return bar
end

function S.EditBox(box)
    S.StripTextures(box)
    box.bg = S.Tex(box, "BACKGROUND", W.scrim)
    box.bg:SetAllPoints()
    S.Border(box, W.border)
    S.Bevel(box, "cut")
    box:SetTextColor(C.text[1], C.text[2], C.text[3], 1)
    box:SetScript("OnEditFocusGained", function(self) S.SetBorder(self, C.accent, 0.45) end)
    box:SetScript("OnEditFocusLost", function(self) S.SetBorder(self, W.border) end)
    return box
end
