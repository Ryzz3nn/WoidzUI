local ADDON, ns = ...

local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata

ns.name = ADDON
ns.version = GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version") or "0.0.0"
ns.PREFIX = "|cff5b8dd9WoidzUI|r: "

-- Shared media. Both paths ship with every client, so no files to package.
ns.SOLID = "Interface\\Buttons\\WHITE8X8"
ns.BARTEX = "Interface\\TargetingFrame\\UI-StatusBar"

ns.defaults = {}
ns.modules = {}
ns.moduleOrder = {}

--------------------------------------------------------------------------------
-- Module registry
--
-- A module is one file under Modules/. It declares its own defaults, so adding
-- a new one never means touching Core. Lifecycle:
--   OnInit(settings)    once SavedVariables exist, before the world is up
--   OnEnable(settings)  at PLAYER_LOGIN, skipped when settings.enabled is false
--   OnSettingsChanged() whenever config writes to it, if the module wants it
--------------------------------------------------------------------------------

function ns:NewModule(key, title, defaults)
    local m = {
        key = key,
        title = title or key,
    }
    defaults = defaults or {}
    if defaults.enabled == nil then defaults.enabled = true end

    self.defaults[key] = defaults
    self.modules[key] = m
    self.moduleOrder[#self.moduleOrder + 1] = m
    return m
end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(ns.PREFIX .. tostring(msg))
end

function ns.Refresh(key)
    local m = ns.modules[key]
    if m and m.OnSettingsChanged then
        m:OnSettingsChanged(ns.db[key])
    end
end

--------------------------------------------------------------------------------
-- SavedVariables
--------------------------------------------------------------------------------

local function CopyDefaults(src, dst)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = CopyDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end
ns.CopyDefaults = CopyDefaults

--------------------------------------------------------------------------------
-- Position helpers
--------------------------------------------------------------------------------

function ns.SavePosition(frame, store)
    local point, _, relPoint, x, y = frame:GetPoint(1)
    if not point then return end
    store.point = { point, relPoint, math.floor(x + 0.5), math.floor(y + 0.5) }
end

function ns.RestorePosition(frame, store, fallback)
    local p = store.point or fallback
    frame:ClearAllPoints()
    frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

--------------------------------------------------------------------------------
-- Movers
--
-- Every positionable frame in the suite registers here, so one unlock toggle
-- covers the whole UI and a locked frame cannot be nudged by a stray drag.
--------------------------------------------------------------------------------

ns.movers = {}

local function Mover_OnDragStart(frame)
    if frame.suMover.store.locked then return end
    frame:StartMoving()
end

local function Mover_OnDragStop(frame)
    frame:StopMovingOrSizing()
    ns.SavePosition(frame, frame.suMover.store)
    -- A frame that hangs captions outside its own edges has to be told the move
    -- is over, because where it landed decides where those can go.
    if frame.suMover.onStop then frame.suMover.onStop(frame) end
end

function ns.RegisterMover(frame, store, label)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", Mover_OnDragStart)
    frame:SetScript("OnDragStop", Mover_OnDragStop)

    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    overlay:SetFrameStrata("TOOLTIP")
    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetScript("OnDragStart", function() Mover_OnDragStart(frame) end)
    overlay:SetScript("OnDragStop", function() Mover_OnDragStop(frame) end)
    overlay:Hide()

    local bg = overlay:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(overlay)
    bg:SetTexture(ns.SOLID)
    bg:SetVertexColor(0.16, 0.55, 0.28, 0.55)

    local text = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("CENTER")
    text:SetText(label)

    frame.suMover = { store = store, overlay = overlay, label = label }
    ns.movers[#ns.movers + 1] = frame
    return frame.suMover
end

function ns.SetUnlocked(unlocked)
    ns.unlocked = unlocked and true or false
    for _, frame in ipairs(ns.movers) do
        local mover = frame.suMover
        mover.store.locked = not ns.unlocked
        if ns.unlocked then mover.overlay:Show() else mover.overlay:Hide() end
    end
    if ns.unlocked then
        ns.Print("Frames unlocked. Drag them where you want, then /wui lock.")
    else
        ns.Print("Frames locked.")
    end
end

--------------------------------------------------------------------------------
-- Copyable text window. Chat output cannot be selected, so anything meant to be
-- pasted somewhere goes here instead.
--------------------------------------------------------------------------------

function ns.ShowText(title, text)
    local f = ns.textWindow

    if not f then
        f = CreateFrame("Frame", "WoidzUITextWindow", UIParent)
        f:SetSize(680, 480)
        f:SetPoint("CENTER")
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:EnableMouse(true)
        f:SetMovable(true)
        f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)

        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(f)
        bg:SetTexture(ns.SOLID)
        bg:SetVertexColor(0.04, 0.04, 0.05, 0.95)

        for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
            local edge = f:CreateTexture(nil, "BORDER")
            edge:SetTexture(ns.SOLID)
            edge:SetVertexColor(0.25, 0.25, 0.28, 1)
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

        f.titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.titleText:SetPoint("TOPLEFT", 12, -11)

        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)

        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("BOTTOMLEFT", 12, 11)
        hint:SetText("Everything is selected. Press Ctrl+C to copy, Escape to close.")

        local scroll = CreateFrame("ScrollFrame", "WoidzUITextWindowScroll", f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -34)
        scroll:SetPoint("BOTTOMRIGHT", -34, 30)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:SetFontObject(ChatFontNormal)
        edit:SetWidth(620)
        edit:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(edit)
        f.edit = edit

        tinsert(UISpecialFrames, "WoidzUITextWindow")
        ns.textWindow = f
    end

    f.titleText:SetText(title or "WoidzUI")
    f.edit:SetText(text or "")
    f:Show()
    f.edit:SetFocus()
    f.edit:HighlightText()
end

--------------------------------------------------------------------------------
-- Bootstrap
--------------------------------------------------------------------------------

local core = CreateFrame("Frame")
core:RegisterEvent("ADDON_LOADED")
core:RegisterEvent("PLAYER_LOGIN")

core:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        WoidzUIDB = CopyDefaults(ns.defaults, WoidzUIDB)
        ns.db = WoidzUIDB
        for _, m in ipairs(ns.moduleOrder) do
            if m.OnInit then m:OnInit(ns.db[m.key]) end
        end
    elseif event == "PLAYER_LOGIN" then
        for _, m in ipairs(ns.moduleOrder) do
            local settings = ns.db[m.key]
            if m.OnEnable and settings.enabled ~= false then
                local ok, err = pcall(m.OnEnable, m, settings)
                if not ok then
                    ns.Print("module " .. m.key .. " failed to start: " .. tostring(err))
                end
            end
        end
        -- Locks always start engaged, whatever state the last session ended in.
        for _, frame in ipairs(ns.movers) do
            frame.suMover.store.locked = true
            frame.suMover.overlay:Hide()
        end
        ns.unlocked = false
    end
end)

ns.core = core
