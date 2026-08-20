-- Minimal WoW client mock, enough to load GearScout's Core/Locale/Skin/UI and
-- actually build widgets. Unknown method calls error instead of silently
-- passing, so a call this addon makes to something the real client does not
-- have shows up here rather than in game.

unpack = unpack or table.unpack
loadstring = loadstring or load

local function noop() end

-- ---------------------------------------------------------------------------
-- object model
-- ---------------------------------------------------------------------------
local KNOWN = {}

local function DefineType(name, methods)
    local set = {}
    for _, m in ipairs(methods) do set[m] = true end
    KNOWN[name] = set
end

local objMeta = {}
-- Real widget objects are plain tables, so reading a field the addon has not
-- set yields nil, exactly as it does in game. A method the real client has but
-- this mock does not model resolves to a no-op; a method that does not exist
-- at all resolves to nil, so calling it errors, which is the point.
objMeta.__index = function(t, k)
    local set = KNOWN[rawget(t, "__type")]
    if set and set[k] then return noop end
    return nil
end

local function New(objType, fields)
    local o = fields or {}
    o.__type = objType
    return setmetatable(o, objMeta)
end

-- ---------------------------------------------------------------------------
-- texture / fontstring
-- ---------------------------------------------------------------------------
DefineType("Texture", {
    "SetTexture", "SetTexCoord", "SetVertexColor", "SetColorTexture", "SetSize",
    "SetWidth", "SetHeight", "SetPoint", "SetAllPoints", "ClearAllPoints",
    "Show", "Hide", "SetShown", "SetGradientAlpha", "SetDrawLayer", "SetAlpha",
    "SetRotation", "SetBlendMode", "SetDesaturated", "SetTexelSnappingBias",
    "SetSnapToPixelGrid",
})

local function NewTexture()
    local t = New("Texture", { w = 0, h = 0 })
    -- Recorded so a test can assert what a widget actually painted.
    t.SetColorTexture = function(self, r, g, b, a)
        self.lastColor = { r, g, b, a }
    end
    t.SetVertexColor = function(self, r, g, b, a)
        self.lastVertex = { r, g, b, a }
    end
    t.SetGradient = function(self, orientation, c1, c2)
        -- Old client signature took seven numbers, so a colour object is an
        -- error here on purpose: that is exactly what the addon's pcall
        -- fallback is written for.
        if type(c1) ~= "number" then error("bad argument #2 to SetGradient", 2) end
    end
    t.SetWidth = function(self, w) self.w = w end
    t.SetHeight = function(self, h) self.h = h end
    t.SetSize = function(self, w, h) self.w, self.h = w, h end
    t.Show = function(self) self.shown = true end
    t.Hide = function(self) self.shown = false end
    t.SetShown = function(self, v) self.shown = v and true or false end
    t.GetWidth = function(self) return self.w end
    t.GetHeight = function(self) return self.h end
    return t
end

DefineType("FontString", {
    "SetFont", "SetTextColor", "SetJustifyH", "SetJustifyV", "SetText",
    "SetPoint", "SetAllPoints", "ClearAllPoints", "SetWidth", "SetHeight",
    "SetSize", "Show", "Hide", "SetShown", "SetSpacing", "SetWordWrap",
    "SetAlpha", "SetDrawLayer", "SetMaxLines", "SetShadowOffset", "SetShadowColor",
})

local function NewFontString()
    local fs = New("FontString", { text = "" })
    fs.SetText = function(self, s) self.text = tostring(s or "") end
    fs.GetText = function(self) return self.text end
    fs.SetFormattedText = function(self, fmt, ...) self.text = string.format(fmt, ...) end
    fs.GetFont = function(self) return [[Fonts\FRIZQT__.TTF]], 12, "" end
    fs.GetStringWidth = function(self) return #self.text * 6 end
    fs.GetStringHeight = function(self) return 12 end
    return fs
end

-- ---------------------------------------------------------------------------
-- animations
-- ---------------------------------------------------------------------------
DefineType("Animation", {
    "SetFromAlpha", "SetToAlpha", "SetDuration", "SetSmoothing", "SetOrigin",
    "SetScaleTo", "SetOffset", "SetOrder", "SetStartDelay",
})
DefineType("AnimationGroup", { "Play", "Stop", "SetLooping", "SetScript" })

local function NewAnimGroup()
    local ag = New("AnimationGroup")
    ag.CreateAnimation = function(self, kind)
        local a = New("Animation")
        if kind == "Scale" then
            a.SetScaleFrom = function() end
        end
        return a
    end
    return ag
end

-- ---------------------------------------------------------------------------
-- frames
-- ---------------------------------------------------------------------------
DefineType("Frame", {
    "EnableMouse", "EnableMouseWheel", "SetFrameStrata", "SetToplevel",
    "SetMovable", "SetClampedToScreen", "SetResizable", "RegisterForDrag",
    "RegisterForClicks", "StartMoving", "StopMovingOrSizing", "SetAllPoints",
    "SetClipsChildren", "SetOrientation", "SetMinMaxValues", "SetValueStep",
    "SetObeyStepOnDrag", "SetThumbTexture", "SetValue", "Raise", "Lower",
    "SetAlpha", "SetScale", "SetHitRectInsets", "SetPropagateKeyboardInput",
    "RegisterEvent", "UnregisterEvent", "RegisterUnitEvent", "SetID",
    "SetBackdrop", "SetNormalTexture", "SetHighlightTexture", "Click",
    "SetFocus", "ClearFocus", "SetAutoFocus", "SetMultiLine", "SetMaxLetters",
    "HighlightText", "SetCursorPosition", "Disable", "Enable", "SetEnabled",
    "SetScrollChild", "UpdateScrollChildRect", "SetVerticalScroll",
})

local frameCount = 0

local function NewFrame(kind, name, parent)
    frameCount = frameCount + 1
    local f = New("Frame", {
        kind = kind or "Frame", name = name, parent = parent,
        w = 200, h = 100, level = (parent and parent.level or 0) + 1,
        shown = true, scripts = {}, points = {},
    })

    f.CreateTexture = function(self, n, layer) return NewTexture() end
    f.CreateFontString = function(self, n, layer) return NewFontString() end
    f.CreateAnimationGroup = function(self) return NewAnimGroup() end
    f.CreateMaskTexture = function(self) return NewTexture() end

    f.SetSize = function(self, w, h) self.w, self.h = w, h end
    f.SetWidth = function(self, w) self.w = w end
    f.SetHeight = function(self, h) self.h = h end
    f.GetWidth = function(self) return self.w end
    f.GetHeight = function(self) return self.h end
    f.GetSize = function(self) return self.w, self.h end
    f.SetPoint = function(self, p, ...) self.points[#self.points + 1] = p end
    f.ClearAllPoints = function(self) self.points = {} end
    f.GetPoint = function(self) return "CENTER", nil, "CENTER", 0, 0 end
    f.GetCenter = function(self) return 0, 0 end
    f.SetFrameLevel = function(self, l) self.level = l end
    f.GetFrameLevel = function(self) return self.level end
    f.GetEffectiveScale = function(self) return 1 end
    f.GetObjectType = function(self) return self.kind end
    f.Show = function(self) self.shown = true end
    f.Hide = function(self) self.shown = false end
    f.IsShown = function(self) return self.shown end
    f.IsVisible = function(self) return self.shown end
    f.SetShown = function(self, v) self.shown = v and true or false end
    f.SetScript = function(self, e, fn) self.scripts[e] = fn end
    f.GetScript = function(self, e) return self.scripts[e] end
    f.HookScript = function(self, e, fn) self.scripts[e] = fn end
    f.GetThumbTexture = function(self)
        self.thumb = self.thumb or NewTexture()
        return self.thumb
    end
    f.GetName = function(self) return self.name end
    f.GetParent = function(self) return self.parent end

    f.SetTextColor = function(self, r, g, b2, a) self.textColor = { r, g, b2, a } end
    f.SetText = function(self, t) self.text = tostring(t or "") end
    f.GetText = function(self) return self.text or "" end
    f.SetFontObject = function() end
    f.GetRegions = function(self) return unpack(self.regions or {}) end
    f.GetValue = function(self) return self.value or 0 end
    f.SetValue = function(self, v) self.value = v end
    f.SetCheckedTexture = function(self) self.checkedTexture = NewTexture() end
    f.GetCheckedTexture = function(self) return self.checkedTexture end
    f.SetHighlightTexture = function(self) self.highlightTexture = NewTexture() end
    f.GetHighlightTexture = function(self) return self.highlightTexture end
    f.SetChecked = function(self, v) self.checked = v and true or false end
    f.GetChecked = function(self) return self.checked and true or false end

    -- Recorded so a harness can deliver an event to whoever registered for it.
    _G.__FRAMES = _G.__FRAMES or {}
    _G.__FRAMES[#_G.__FRAMES + 1] = f

    if name then _G[name] = f end
    return f
end

function CreateFrame(kind, name, parent, template)
    return NewFrame(kind, name, parent)
end

-- ---------------------------------------------------------------------------
-- globals the addon touches on load
-- ---------------------------------------------------------------------------
_G = _G or _ENV
UIParent = NewFrame("Frame", "UIParent")
Minimap = NewFrame("Frame", "Minimap")
GameTooltip = NewFrame("Frame", "GameTooltip")
GameTooltip.SetOwner = noop
GameTooltip.SetText = noop
GameTooltip.AddLine = noop
GameTooltip.AddDoubleLine = noop
GameTooltip.SetHyperlink = noop
GameTooltip.ClearLines = noop
GameTooltip.NumLines = function() return 0 end

GameFontNormal = { GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end }
UISpecialFrames = {}

format = string.format
strjoin = function(sep, ...) return table.concat({ ... }, sep) end
tinsert = table.insert
tremove = table.remove
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
strsplit = function(sep, s) return s end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
tostringall = function(...)
    local out = {}
    for i = 1, select("#", ...) do out[i] = tostring((select(i, ...))) end
    return unpack(out)
end

math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
cos = function(d) return math.cos(math.rad(d)) end
sin = function(d) return math.sin(math.rad(d)) end

PlaySound = noop
InCombatLockdown = function() return false end
GetTime = function() return 1000 end
GetRealmName = function() return "Test" end
UnitName = function() return "Tester" end
UnitFullName = function() return "Tester", nil end
UnitClass = function() return "Warrior", "WARRIOR" end
UnitGUID = function() return "Player-1-00000001" end
UnitLevel = function() return 70 end
UnitRace = function() return "Human", "Human" end
UnitFactionGroup = function() return "Alliance" end
GetItemInfo = function() return nil end
GetItemInfoInstant = function() return nil end
GetInventoryItemLink = function() return nil end
GetInventoryItemID = function() return nil end
GetInventoryItemTexture = function() return nil end
GetContainerNumSlots = function() return 0 end
GetContainerItemLink = function() return nil end
GetSpellInfo = function() return nil end
GetSpellBookItemInfo = function() return nil end
IsSpellKnown = function() return false end
GetNumTalentTabs = function() return 0 end
GetTalentTabInfo = function() return nil end
GetLocale = function() return "enUS" end
GetAddOnMetadata = function(_, key) return key == "Version" and "0.16.0" or nil end
C_Timer = { After = function(_, fn) end, NewTicker = function() return { Cancel = noop } end }
C_AddOns = nil
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a, __color = true } end
Enum = {}
SlashCmdList = {}
IsInGuild = function() return false end
IsInRaid = function() return false end
IsInGroup = function() return false end
GetNumGroupMembers = function() return 0 end
UnitIsGroupLeader = function() return false end
C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end, SendAddonMessage = noop }
SendAddonMessage = noop
GetChannelName = function() return 0 end
date = os.date
time = os.time
random = math.random
GetCursorPosition = function() return 0, 0 end
GetMinimapShape = nil
GetSpecialization = nil
CopyTable = function(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end
print = print

-- ---------------------------------------------------------------------------
-- second wave: globals the feature files touch at load time
-- ---------------------------------------------------------------------------
StaticPopupDialogs = {}
StaticPopup_Show = noop
StaticPopup_Hide = noop
SlashCmdList = SlashCmdList or {}
ChatFrame1 = GameTooltip
ChatFontNormal = { GetFont = function() return [[Fonts\FRIZQT__.TTF]], 12, "" end }
ReloadUI = noop

DEFAULT_CHAT_FRAME = { AddMessage = noop }
ItemRefTooltip = GameTooltip
GameTooltip_SetDefaultAnchor = noop
hooksecurefunc = function(a, b, c) end
securecall = function(fn, ...) return fn(...) end
issecure = function() return true end
GetNumSkillLines = function() return 0 end
GetSkillLineInfo = function() return nil end
GetProfessions = function() return nil end
GetSpellBookItemName = function() return nil end
HasPetUI = function() return false end
GetInventorySlotInfo = function(name) return 1, [[Interface\Icons\INV_Misc_QuestionMark]] end
GetItemQualityColor = function() return 1, 1, 1, "|cffffffff" end
GetItemStats = function() return {} end
GetItemSpell = function() return nil end
GetDetailedItemLevelInfo = function() return 100 end
GetAverageItemLevel = function() return 100, 100 end
GetQuestLogTitle = function() return nil end
GetNumQuestLogEntries = function() return 0, 0 end
GetQuestLogRewardInfo = function() return nil end
SelectQuestLogEntry = noop
GetQuestLogSelection = function() return 1 end
C_QuestLog = nil
GetCVar = function() return "0" end
GetCVarBool = function() return false end
UnitAffectingCombat = function() return false end
UnitInParty = function() return false end
UnitInRaid = function() return nil end
UnitIsPlayer = function() return true end
UnitExists = function() return false end
GetRaidRosterInfo = function() return nil end
GetNumGuildMembers = function() return 0 end
GetGuildRosterInfo = function() return nil end
GuildRoster = noop
C_GuildInfo = { GuildRoster = noop }
GetContainerItemInfo = function() return nil end
C_Container = nil
GetInventoryItemCount = function() return 0 end
GetItemCount = function() return 0 end
GetMoney = function() return 0 end
UnitBuff = function() return nil end
UnitAura = function() return nil end
GetWeaponEnchantInfo = function() return false end
CombatLogGetCurrentEventInfo = function() return 0 end
GetSpellCooldown = function() return 0, 0, 0 end
IsUsableSpell = function() return true end
GetTalentInfo = function() return nil end
GetActiveTalentGroup = function() return 1 end
UnitPowerType = function() return 0 end
UnitPower = function() return 100 end
UnitPowerMax = function() return 100 end
BackdropTemplateMixin = nil
Mixin = function(t, ...) return t end
CreateFromMixins = function() return {} end
EasyMenu = noop
UIDropDownMenu_Initialize = noop
ToggleDropDownMenu = noop
GetScreenWidth = function() return 1920 end
GetScreenHeight = function() return 1080 end
IsShiftKeyDown = function() return false end
IsControlKeyDown = function() return false end
IsAltKeyDown = function() return false end
IsModifiedClick = function() return false end
ChatEdit_GetActiveWindow = function() return nil end
ChatEdit_InsertLink = function() return false end
GetSpellLink = function() return nil end

return true
