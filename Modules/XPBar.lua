local ADDON, ns = ...

local M = ns:NewModule("xpbar", "XP bar", {
    width = 420,
    height = 16,
    locked = true,
    point = { "BOTTOM", "BOTTOM", 0, 140 },
    showRested = true,
    showRestedInText = false,
    showSegments = true,
    -- Twenty is the cut on Blizzard's own experience bar, so a tick lands on
    -- every boundary a default bar would have drawn.
    segments = 20,
    showFlash = true,
    textMode = "always", -- always | hover | never
    format = "cur-max-remaining", -- see FORMATS
    -- Bar text slots
    showLevel = true,
    -- Off by default now. A plate behind the level has no good colour: tint it
    -- from the fill and it reads as progress that is not there, make it darker
    -- and it becomes a third shade on a bar that only has two. The level text is
    -- outlined instead, which is what actually made the plate unnecessary.
    levelBlock = false,
    showPercent = true,
    -- Info rows above and below the bar
    showTopRow = true,
    showBottomRow = true,
    rowHeight = 14,
    rowBackground = true,
    showTimeThisLevel = true,
    showTimeThisSession = true,
    showLevelingIn = true,
    showCompleted = true,
    showRestedPct = true,
    showBars = true,
    refresh = 5, -- seconds between clock redraws
    completedMode = "xp", -- xp | levels
    repAtMax = true,
    hideAtMax = true,
    xpColor = { 0.29, 0.24, 0.68, 1 },
    restedColor = { 0.24, 0.44, 0.82, 0.55 },
    bgColor = { 0.08, 0.08, 0.09, 0.85 },
    borderColor = { 0, 0, 0, 1 },
    -- XP needed to leave each level, filled in from the live client as it is
    -- observed. Seeds below are only a starting point.
    learned = {},
})

local db
local bar

local MAX_LEVEL = 70

-- How hard the optional plate behind the level darkens what is under it. Kept
-- for anyone who wants the old look, but the outlined text means nothing depends
-- on it any more.
local BLOCK_SHADE = 0.45

--------------------------------------------------------------------------------
-- Preview
--
-- Drives the bar from made up numbers so every visual state can be looked at on
-- demand rather than waited for: empty, full, a fat rested pool, max level. Every
-- read the display makes goes through the four accessors below, which is what
-- lets this exist without a second rendering path to keep correct.
--
-- Session tracking and the learned experience table deliberately do NOT read
-- through them. A preview must never end up in the rate or in db.learned.
--------------------------------------------------------------------------------

local preview

-- No real requirement to borrow at max level, so previewing there needs a number
-- from somewhere. A round mid game level is close enough for looking at pixels.
local PREVIEW_FALLBACK_MAX = 50000

local function CurXP()
    if preview then return preview.cur end
    return UnitXP("player") or 0
end

local function MaxXP()
    if preview then return preview.max end
    local max = UnitXPMax("player") or 1
    if max <= 0 then max = 1 end
    return max
end

local function RestedXP()
    if preview then return preview.rested end
    return GetXPExhaustion() or 0
end

local function Level()
    if preview then return preview.level end
    return UnitLevel("player") or 1
end

-- Colours for the info rows. Labels sit back, values read first, and the two
-- numbers that describe the long game get the accent.
local LABEL = "|cff9d9d9d"
local VALUE = "|cffffffff"
local ACCENT = "|cffffa028"
local STOP = "|r"

-- Everything the bar knows beyond "how full am I" comes from watching this
-- play session. Nothing is persisted: a rate carried over from yesterday would
-- be worse than no rate at all.
-- start and levelStart stay nil until the session begins. GetTime is uptime,
-- not a wall clock, so a "> 0" test on a freshly launched client is a coin
-- flip: the timers have to be tested for existence, not for size.
local session = {
    start = nil,
    levelStart = nil,
    xp = 0,
    gains = 0,
    kills = 0,
    killXP = 0,
    lastXP = 0,
    lastMax = 0,
    samples = {},
}

-- How far back the experience rate looks. Long enough to ride out a quest
-- turn in, short enough to follow a change of pace.
local RATE_WINDOW = 900

--------------------------------------------------------------------------------
-- Experience table
--
-- The client only ever exposes the current level's requirement through
-- UnitXPMax, so overall progress towards max level needs a table. These are the
-- 1.12 values, and the client is treated as the authority: every level actually
-- played writes its real requirement into db.learned, which wins over the seed.
-- A wrong seed therefore corrects itself instead of quietly skewing forever.
--------------------------------------------------------------------------------

local SEED_XP = {
    [1] = 400, [2] = 900, [3] = 1400, [4] = 2100, [5] = 2800,
    [6] = 3600, [7] = 4500, [8] = 5400, [9] = 6500, [10] = 7600,
    [11] = 8800, [12] = 10100, [13] = 11400, [14] = 12900, [15] = 14400,
    [16] = 16000, [17] = 17700, [18] = 19400, [19] = 21300, [20] = 23200,
    [21] = 25200, [22] = 27300, [23] = 29400, [24] = 31700, [25] = 34000,
    [26] = 36400, [27] = 38900, [28] = 41400, [29] = 44300, [30] = 47400,
    [31] = 50800, [32] = 54500, [33] = 58600, [34] = 62800, [35] = 67100,
    [36] = 71600, [37] = 76100, [38] = 80800, [39] = 85700, [40] = 90700,
    [41] = 95800, [42] = 101000, [43] = 106300, [44] = 111800, [45] = 117500,
    [46] = 123200, [47] = 129100, [48] = 135100, [49] = 141200, [50] = 147500,
    [51] = 153900, [52] = 160400, [53] = 167100, [54] = 173900, [55] = 180800,
    [56] = 187900, [57] = 195000, [58] = 202300, [59] = 209800,
}

-- 60 to 70 costs 6,268,300 in total. The split between those ten levels is not
-- worth guessing at, so each one carries an even share until the character
-- actually reaches it and the real number is learned.
local OUTLAND_TOTAL = 6268300
local OUTLAND_SHARE = OUTLAND_TOTAL / 10

local totalCache

local function XPForLevel(level)
    if db and db.learned and db.learned[level] then return db.learned[level] end
    if SEED_XP[level] then return SEED_XP[level] end
    if level >= 60 and level <= 69 then return OUTLAND_SHARE end
    return nil
end

local function TotalXPTo(level)
    local sum = 0
    for i = 1, level - 1 do
        sum = sum + (XPForLevel(i) or 0)
    end
    return sum
end

local function TotalXPToMax()
    if not totalCache then
        totalCache = TotalXPTo(MAX_LEVEL)
    end
    return totalCache
end

local function Learn(level, max)
    if not db or not db.learned then return end
    if not level or not max or max <= 0 then return end
    if level >= MAX_LEVEL then return end
    if db.learned[level] ~= max then
        db.learned[level] = max
        totalCache = nil
    end
end

-- Progress from level 1 to max level. Two honest ways to count it, and they
-- disagree wildly, so which one is in use is a setting rather than a guess:
--
--   xp      every point of experience the character will ever need, weighted by
--           what it actually costs. 60 to 70 is 6.3 million of the 10.4 million
--           total, so level 33 sits near 6% rather than near half.
--   levels  levels done out of levels to do, each one worth the same. Level 33
--           of 70 is a shade under half, whatever the last ten cost.
local function CompletedFraction(cur)
    local level = Level()
    local max = MaxXP()

    if db and db.completedMode == "levels" then
        if MAX_LEVEL <= 1 then return nil end
        return math.min(1, ((level - 1) + ((cur or 0) / max)) / (MAX_LEVEL - 1))
    end

    local total = TotalXPToMax()
    if total <= 0 then return nil end
    return math.min(1, (TotalXPTo(level) + (cur or 0)) / total)
end

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

local function Short(n)
    n = n or 0
    if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
    if n >= 10000 then return string.format("%.1fk", n / 1000) end
    return tostring(n)
end

-- 2570 reads as 2,570. This one number gets compared at a glance against quest
-- and mob rewards, and ungrouped digits make that comparison work.
local function Comma(n)
    local s = tostring(math.floor(n))
    local grouped = ""
    while #s > 3 do
        grouped = "," .. s:sub(-3) .. grouped
        s = s:sub(1, -4)
    end
    return s .. grouped
end

-- Whole when it divides, one decimal when it does not. A level's requirement is
-- always a round number in practice, but the estimated Outland levels are not,
-- and rounding those would be printing a figure the bar does not actually use.
local function Amount(n)
    local rounded = math.floor(n * 10 + 0.5) / 10
    local whole = math.floor(rounded)
    local text = Comma(whole)
    if rounded ~= whole then
        text = text .. string.format("%.1f", rounded - whole):sub(2)
    end
    return text
end

local function FormatTime(seconds)
    if not seconds or seconds <= 0 or seconds == math.huge or seconds ~= seconds then
        return nil
    end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    if m > 0 then return string.format("%dm", m) end
    return string.format("%ds", math.floor(seconds))
end

local function AtMaxLevel()
    return Level() >= MAX_LEVEL
end

--------------------------------------------------------------------------------
-- Bars
--
-- The default experience bar is cut into twenty by its nineteen divider
-- textures, so one bar is 5% of a level. This bar draws its own ticks and can be
-- set to any count, so "how many bars would be filled" is always answered
-- against the default texture's twenty, never against db.segments.
--
-- Everything here is measured off UnitXPMax, which is the live level's real
-- requirement. That matters: a bar is not some fixed amount of experience, it is
-- a twentieth of whatever this level costs, and that grows every level.
--------------------------------------------------------------------------------

local BARS_PER_LEVEL = 20

-- Whole bars filled, the exact position in bars, and the total. The exact figure
-- is the one worth showing: 13 of 20 hides the difference between only just past
-- thirteen and very nearly fourteen.
function M:Bars(cur, max)
    cur = cur or CurXP()
    max = max or MaxXP()
    if max <= 0 then return nil end

    local exact = (cur / max) * BARS_PER_LEVEL
    if exact > BARS_PER_LEVEL then exact = BARS_PER_LEVEL end
    return math.floor(exact), exact, BARS_PER_LEVEL
end

-- What one bar is worth at this level, exactly. Level 34 asks the client for
-- 51,400, so a bar there is 2,570 and nothing else. The figure changes at every
-- single level, which is the whole reason it is worth printing.
function M:XPPerBar(max)
    max = max or MaxXP()
    if max <= 0 then return nil end
    return max / BARS_PER_LEVEL
end

-- The rate expressed in bars rather than raw experience. A bar costs more every
-- level, so this is the figure that stays comparable across levels while
-- experience an hour keeps climbing.
function M:BarsPerHour()
    local rate = self:XPPerSecond()
    local worth = self:XPPerBar()
    if not rate or not worth or worth <= 0 then return nil end
    return (rate * 3600) / worth
end

--------------------------------------------------------------------------------
-- Time on this level
--
-- A session clock restarts at every login, which is why this read "20s" after
-- logging in on a level that was hours old. Persisting a wall clock would be
-- wrong the other way: sleeping for eight hours does not put eight hours into a
-- level. The number wanted is time played on this level, and the server has been
-- keeping exactly that all along, so it is asked for rather than accumulated
-- here. That also means it needs no SavedVariables and cannot drift.
--------------------------------------------------------------------------------

local played = {
    levelBase = nil, -- seconds on this level as of the last answer
    stamp = nil,     -- GetTime when that answer landed
}

local function TimeThisLevel()
    if played.levelBase and played.stamp then
        return played.levelBase + (GetTime() - played.stamp)
    end

    -- Only reached on a client with no played time API at all. It reads low
    -- after a relog, which is exactly the fault being fixed, so it is a last
    -- resort rather than a fallback worth reaching for.
    if not RequestTimePlayed and session.levelStart then
        return GetTime() - session.levelStart
    end

    return nil
end

-- Asking for the played time makes the chat frames announce it, which is right
-- when a player types /played and pure noise when an addon asks on every login.
-- The event is lifted off the chat frames for the length of the round trip and
-- put straight back, so a hand typed /played still prints normally.
local mutedFrames = {}

local function MuteTimePlayed()
    if not NUM_CHAT_WINDOWS then return end

    for i = 1, NUM_CHAT_WINDOWS do
        local frame = _G["ChatFrame" .. i]
        if frame and frame.IsEventRegistered and frame:IsEventRegistered("TIME_PLAYED_MSG") then
            frame:UnregisterEvent("TIME_PLAYED_MSG")
            mutedFrames[i] = true
        end
    end
end

local function UnmuteTimePlayed()
    for i in pairs(mutedFrames) do
        local frame = _G["ChatFrame" .. i]
        if frame and frame.RegisterEvent then
            frame:RegisterEvent("TIME_PLAYED_MSG")
        end
    end
    mutedFrames = {}
end

local function AskTimePlayed()
    if not RequestTimePlayed then return end

    MuteTimePlayed()
    RequestTimePlayed()

    -- If the answer never arrives the chat frames must not stay muted, or a
    -- /played typed by hand would be silent for the rest of the session.
    if C_Timer and C_Timer.After then
        C_Timer.After(5, UnmuteTimePlayed)
    end
end

--------------------------------------------------------------------------------
-- Kill detection
--
-- Both a kill and a quest turn in fire CHAT_MSG_COMBAT_XP_GAIN, so counting the
-- event is not enough. The kill variants are the ones that name the mob, which
-- means their format string carries a %s. Building the patterns from the
-- client's own globals keeps this working in any locale.
--------------------------------------------------------------------------------

local KILL_XP_GLOBALS = {
    "COMBATLOG_XPGAIN_FIRSTPERSON",
    "COMBATLOG_XPGAIN_EXHAUSTION1",
    "COMBATLOG_XPGAIN_EXHAUSTION2",
    "COMBATLOG_XPGAIN_EXHAUSTION4",
    "COMBATLOG_XPGAIN_EXHAUSTION5",
}

local killPatterns = {}

local function BuildKillPatterns()
    for _, key in ipairs(KILL_XP_GLOBALS) do
        local fmt = _G[key]
        if type(fmt) == "string" and fmt:find("%%s") then
            -- Escape the pattern magic characters, then turn the format
            -- placeholders into captures. %d has to become a capture so the
            -- amount can be read back out.
            local pattern = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
            pattern = pattern:gsub("%%s", "\1")
            pattern = pattern:gsub("%%d", "\2")
            pattern = pattern:gsub("\1", "(.-)")
            pattern = pattern:gsub("\2", "(%%d+)")
            killPatterns[#killPatterns + 1] = pattern
        end
    end
end

local function ParseKillXP(msg)
    for _, pattern in ipairs(killPatterns) do
        local c1, c2, c3, c4 = msg:match(pattern)
        if c1 then
            for _, capture in ipairs({ c1, c2 or "", c3 or "", c4 or "" }) do
                if capture:match("^%d+$") then
                    return tonumber(capture)
                end
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Session rates
--------------------------------------------------------------------------------

function M:ResetSession()
    session.start = GetTime()
    session.levelStart = GetTime()
    session.xp = 0
    session.gains = 0
    session.kills = 0
    session.killXP = 0
    session.lastXP = UnitXP("player") or 0
    session.lastMax = UnitXPMax("player") or 1
    session.samples = {}
end

local function RecordXP()
    local cur = UnitXP("player") or 0
    local max = UnitXPMax("player") or 1
    local now = GetTime()

    local delta
    if max ~= session.lastMax then
        -- Levelled. What was left of the old bar plus whatever spilled over.
        delta = (session.lastMax - session.lastXP) + cur
        session.levelStart = now
    else
        delta = cur - session.lastXP
    end

    session.lastXP = cur
    session.lastMax = max

    if delta and delta > 0 then
        session.xp = session.xp + delta
        session.gains = session.gains + 1
        session.samples[#session.samples + 1] = { t = now, xp = delta }

        -- Anything past the window can never be counted again, so it goes.
        local cutoff = now - RATE_WINDOW
        local keep, first = {}, true
        for _, sample in ipairs(session.samples) do
            if sample.t >= cutoff or first then
                keep[#keep + 1] = sample
            end
            first = false
        end
        session.samples = keep
    end
    return delta
end

-- The rate is measured over a trailing window rather than over the whole
-- session, because a session average is dominated by whatever happened first.
-- One 3000 xp quest handed in two minutes after login reads as 90k an hour,
-- which is why the estimate used to leap the moment the first experience
-- landed and then sag for the next half hour. Two gains and two minutes is the
-- floor: below that there is nothing to average.
local MIN_ELAPSED = 120
local MIN_GAINS = 2

function M:XPPerSecond()
    if not session.start then return nil end

    local now = GetTime()
    local elapsed = now - session.start
    if elapsed < MIN_ELAPSED or session.gains < MIN_GAINS or session.xp <= 0 then
        return nil
    end

    local cutoff = now - RATE_WINDOW
    local windowed = 0
    for i = #session.samples, 1, -1 do
        local sample = session.samples[i]
        if sample.t < cutoff then break end
        windowed = windowed + sample.xp
    end

    if windowed > 0 then
        return windowed / math.min(RATE_WINDOW, elapsed)
    end

    -- Nothing gained in the whole window. The session average is the honest
    -- answer here: it keeps decaying while the character stands still, which is
    -- exactly what "at this rate" means.
    return session.xp / elapsed
end

function M:TimeToLevel(cur, max)
    local rate = self:XPPerSecond()
    if not rate or rate <= 0 then return nil end
    return (max - cur) / rate
end

function M:KillsToLevel(cur, max)
    if session.kills < 3 or session.killXP <= 0 then return nil end
    local average = session.killXP / session.kills
    return math.ceil((max - cur) / average), average
end

--------------------------------------------------------------------------------
-- Bar text
--------------------------------------------------------------------------------

M.FORMATS = { "cur-max-remaining", "cur-max-pct", "remaining", "percent", "bars", "time-to-level", "level-and-pct" }
M.FORMAT_LABEL = {
    ["cur-max-remaining"] = "current / max (remaining)",
    ["cur-max-pct"] = "current / max (percent)",
    ["remaining"] = "remaining to level",
    ["percent"] = "percent only",
    ["bars"] = "bars filled of 20",
    ["time-to-level"] = "time to level",
    ["level-and-pct"] = "level and percent",
}

local function BarText(cur, max)
    local pct = cur / max * 100
    local text

    if db.format == "cur-max-remaining" then
        -- Short everywhere. This slot used to print raw digits while every other
        -- number on the bar was abbreviated, which read as two different bars.
        text = string.format("%s / %s  (%s left)", Short(cur), Short(max), Short(max - cur))
    elseif db.format == "remaining" then
        text = string.format("%s to level", Short(max - cur))
    elseif db.format == "percent" then
        text = string.format("%.1f%%", pct)
    elseif db.format == "bars" then
        local _, exact, total = M:Bars(cur, max)
        text = string.format("%.1f / %d bars", exact or 0, total or 0)
    elseif db.format == "time-to-level" then
        local eta = FormatTime(M:TimeToLevel(cur, max))
        -- Before there is a rate, fall back rather than print a placeholder.
        text = eta and (eta .. " to level") or string.format("%s / %s", Short(cur), Short(max))
    elseif db.format == "level-and-pct" then
        text = string.format("Level %d  %.0f%%", Level(), pct)
    else
        text = string.format("%s / %s  (%.0f%%)", Short(cur), Short(max), pct)
    end

    -- The percent slot on the right already carries the rested share in
    -- brackets, so spelling it out in the middle as well was the same fact
    -- twice on one 280px strip. It only goes here when that slot is not there.
    local pctSlotSpeaks = db.showPercent and db.textMode ~= "never"
    if db.showRestedInText and not pctSlotSpeaks then
        local rested = RestedXP()
        if rested > 0 then
            text = text .. "  rested " .. Short(rested)
        end
    end

    return text
end

--------------------------------------------------------------------------------
-- Frame
--------------------------------------------------------------------------------

local function FlashUpdate(self, elapsed)
    bar.flashLeft = bar.flashLeft - elapsed
    if bar.flashLeft <= 0 then
        bar.flash:Hide()
        self:SetScript("OnUpdate", nil)
        return
    end
    bar.flash:SetAlpha(0.85 * (bar.flashLeft / 0.6))
end

-- A short bright strip over the slice that was just gained. Reads as "that
-- turn in was worth something" without adding anything permanent to the bar.
local function Flash(fromFraction, toFraction)
    if not db.showFlash or not bar then return end
    if toFraction <= fromFraction then return end

    local usable = bar:GetWidth() - 2
    local left = 1 + fromFraction * usable
    local width = math.max(1, (toFraction - fromFraction) * usable)

    bar.flash:ClearAllPoints()
    bar.flash:SetPoint("TOPLEFT", bar, "TOPLEFT", left, -1)
    bar.flash:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", left, 1)
    bar.flash:SetWidth(width)
    bar.flash:SetAlpha(0.85)
    bar.flash:Show()

    bar.flashLeft = 0.6
    bar:SetScript("OnUpdate", FlashUpdate)
end

-- One info row: a strip the width of the bar with a left and a right caption.
-- Rows are children of the bar so they inherit its position, its visibility and
-- its fate at max level without any extra bookkeeping.
local function BuildRow(edge)
    local row = CreateFrame("Frame", nil, bar)
    row:SetHeight(14)

    local rowBG = row:CreateTexture(nil, "BACKGROUND")
    rowBG:SetAllPoints(row)
    rowBG:SetTexture(ns.SOLID)
    row.bg = rowBG

    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.left:SetJustifyH("LEFT")

    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.right:SetJustifyH("RIGHT")

    row.edge = edge
    return row
end

local function Build()
    bar = CreateFrame("Frame", "WoidzUIXPBar", UIParent)
    bar:SetFrameStrata("MEDIUM")
    bar:SetSize(db.width, db.height)
    ns.RestorePosition(bar, db, ns.defaults.xpbar.point)

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetTexture(ns.SOLID)
    bar.bg = bg

    bar.edges = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local edge = bar:CreateTexture(nil, "BORDER")
        edge:SetTexture(ns.SOLID)
        bar.edges[side] = edge
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

    -- Rested sits behind and runs past the XP fill, so the bonus pool reads as
    -- "how far this rest will carry you".
    bar.rested = CreateFrame("StatusBar", nil, bar)
    bar.rested:SetPoint("TOPLEFT", 1, -1)
    bar.rested:SetPoint("BOTTOMRIGHT", -1, 1)
    bar.rested:SetStatusBarTexture(ns.BARTEX)
    bar.rested:SetMinMaxValues(0, 1)
    bar.rested:SetValue(0)

    bar.fill = CreateFrame("StatusBar", nil, bar)
    bar.fill:SetPoint("TOPLEFT", 1, -1)
    bar.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    bar.fill:SetStatusBarTexture(ns.BARTEX)
    bar.fill:SetMinMaxValues(0, 1)
    bar.fill:SetValue(0)
    bar.fill:SetFrameLevel(bar.rested:GetFrameLevel() + 1)

    -- The fill and rested bars are child frames, and a child frame draws above
    -- every region of its parent no matter which draw layer that region claims.
    -- Anything that has to sit on top of the fill therefore needs its own frame
    -- above it, not just a higher layer on the bar.
    bar.overlay = CreateFrame("Frame", nil, bar)
    bar.overlay:SetAllPoints(bar)
    bar.overlay:SetFrameLevel(bar.fill:GetFrameLevel() + 1)

    bar.flash = bar.overlay:CreateTexture(nil, "ARTWORK")
    bar.flash:SetTexture(ns.SOLID)
    bar.flash:SetVertexColor(1, 1, 1, 0.85)
    bar.flash:Hide()
    bar.flashLeft = 0

    bar.ticks = {}

    -- Three slots across the bar. The level sits on its own block at the left
    -- edge, the counts hold the middle, the percentages close the right.
    -- A shade over whatever is underneath, not a coloured plate. Tinting it from
    -- xpColor made it the same hue as the fill, so at 328 experience into a level
    -- the bar read as a fifth full when it was half a percent full: the block was
    -- the only purple on the strip and it looked exactly like progress. Darkening
    -- instead cannot lie about the fill, because the fill shows through it.
    bar.levelBlock = bar.overlay:CreateTexture(nil, "BACKGROUND")
    bar.levelBlock:SetTexture(ns.SOLID)
    bar.levelBlock:Hide()

    bar.levelText = bar.overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.levelText:SetPoint("LEFT", bar, "LEFT", 5, 0)

    bar.text = bar.overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER")

    bar.pctText = bar.overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.pctText:SetPoint("RIGHT", bar, "RIGHT", -5, 0)

    -- All three slots sit over whatever the bar is doing underneath them, so they
    -- carry an outline and need nothing drawn behind them to stay legible. Every
    -- later font change reads these flags back out of GetFont, so the outline
    -- survives the fitting passes.
    for _, fs in ipairs({ bar.levelText, bar.text, bar.pctText }) do
        local path, size = fs:GetFont()
        if path then fs:SetFont(path, size, "OUTLINE") end
    end

    bar.topRow = BuildRow("TOP")
    bar.bottomRow = BuildRow("BOTTOM")

    bar:SetScript("OnEnter", function(self)
        if db.textMode == "hover" then
            self.text:Show()
            self.levelText:SetShown(db.showLevel)
            self.pctText:SetShown(db.showPercent)
            self.levelBlock:SetShown(db.showLevel and db.levelBlock)
        end
        M:ShowTooltip()
    end)
    bar:SetScript("OnLeave", function(self)
        if db.textMode == "hover" then
            self.text:Hide()
            self.levelText:Hide()
            self.pctText:Hide()
            self.levelBlock:Hide()
        end
        GameTooltip:Hide()
    end)

    ns.RegisterMover(bar, db, "XP bar")
    M.bar = bar
end

local function LayoutTicks()
    for _, tick in ipairs(bar.ticks) do tick:Hide() end
    if not db.showSegments or (db.segments or 0) < 2 then return end

    for i = 1, db.segments - 1 do
        local tick = bar.ticks[i]
        if not tick then
            tick = bar.overlay:CreateTexture(nil, "BORDER")
            tick:SetTexture(ns.SOLID)
            bar.ticks[i] = tick
        end
        tick:SetVertexColor(0, 0, 0, 0.55)
        tick:SetSize(1, db.height - 2)
        tick:ClearAllPoints()
        -- The fill lives inside the 1px border, so the ticks have to be spread
        -- across that interior. Measuring against the whole frame drifted them
        -- right and left the last one sitting on the border itself.
        tick:SetPoint("LEFT", bar, "LEFT", 1 + ((db.width - 2) / db.segments) * i, 0)
        tick:Show()
    end
end

local function RowWanted(row)
    if row.edge == "TOP" then
        return db.showTopRow and (db.showTimeThisLevel or db.showTimeThisSession)
    end
    return db.showBottomRow and (db.showLevelingIn or db.showCompleted or db.showRestedPct)
end

local function LayoutRow(row)
    row:SetHeight(db.rowHeight)

    local c = db.bgColor
    row.bg:SetVertexColor(c[1], c[2], c[3], c[4])
    row.bg:SetShown(db.rowBackground)

    -- The size the row would like. FitRow may spend some of it to keep the two
    -- captions apart, and starts from this number again on every update.
    local size = math.max(8, math.min(16, math.floor(db.rowHeight * 0.72 + 0.5)))
    row.baseSize = size
    for _, fs in ipairs({ row.left, row.right }) do
        local fontPath, _, fontFlags = fs:GetFont()
        if fontPath then fs:SetFont(fontPath, size, fontFlags) end
    end

    row:SetShown(RowWanted(row))
end

-- Each row asks for a side of the bar, above or below. A bar parked against an
-- edge of the screen has no room on the side it asks for, and a row anchored
-- past the edge is not clipped, it is simply never drawn: that is what hid the
-- row above the bar for anyone who put the bar at the very top of the screen.
-- So the side is a preference. A row that will not fit flips to the other side
-- and stacks outside whatever is already sitting there.
local function PlaceRows()
    if not bar then return end

    local pad = db.rowHeight + 2
    local screenTop, screenBottom = UIParent:GetTop(), UIParent:GetBottom()
    local barTop, barBottom = bar:GetTop(), bar:GetBottom()

    -- Geometry reads nil until the frame has been laid out once. Calling that
    -- unlimited room keeps the first pass on the preferred sides.
    local room = {
        TOP = (screenTop and barTop) and (screenTop - barTop) or math.huge,
        BOTTOM = (screenBottom and barBottom) and (barBottom - screenBottom) or math.huge,
    }

    local rows = { bar.topRow, bar.bottomRow }
    local claimed = { TOP = 0, BOTTOM = 0 }
    local side, flipped = {}, {}

    for _, row in ipairs(rows) do
        if row:IsShown() then
            local want = row.edge
            local other = (want == "TOP") and "BOTTOM" or "TOP"
            -- Flip only when the wanted side cannot hold this row and the other
            -- side can hold it on top of what it already carries. Flipping into
            -- a second dead end would gain nothing.
            if room[want] < pad * (claimed[want] + 1)
                and room[other] >= pad * (claimed[other] + 1) then
                want = other
                flipped[row] = true
            end
            side[row] = want
            claimed[want] = claimed[want] + 1
        end
    end

    -- Rows that kept their side are placed first so they hold the slot against
    -- the bar, and a flipped row lands outside them rather than between.
    local order = { TOP = 0, BOTTOM = 0 }
    for pass = 1, 2 do
        for _, row in ipairs(rows) do
            local want = side[row]
            if want and ((pass == 1) ~= (flipped[row] == true)) then
                local offset = 1 + order[want] * (db.rowHeight + 1)
                order[want] = order[want] + 1
                row:ClearAllPoints()
                if want == "TOP" then
                    row:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 0, offset)
                    row:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", 0, offset)
                else
                    row:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -offset)
                    row:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -offset)
                end
            end
        end
    end
end
M.PlaceRows = PlaceRows

function M:ApplyLook()
    if not bar then return end
    bar:SetSize(db.width, db.height)

    local c = db.bgColor
    bar.bg:SetVertexColor(c[1], c[2], c[3], c[4])

    c = db.borderColor
    for _, edge in pairs(bar.edges) do
        edge:SetVertexColor(c[1], c[2], c[3], c[4])
    end

    c = db.xpColor
    bar.fill:SetStatusBarColor(c[1], c[2], c[3], c[4])
    -- Deliberately not derived from xpColor. This is a darkening pass that keeps
    -- the level readable over both the fill and the empty track, and its whole
    -- job is to be visibly not the fill.
    bar.levelBlock:SetVertexColor(0, 0, 0, BLOCK_SHADE)

    c = db.restedColor
    bar.rested:SetStatusBarColor(c[1], c[2], c[3], c[4])

    -- Track the bar height so a 40px bar does not wear 10px text. Clamped at
    -- both ends: below 8 it stops being readable, above 22 it outgrows any
    -- sensible bar.
    local size = math.max(8, math.min(22, math.floor(db.height * 0.65 + 0.5)))
    for _, fs in ipairs({ bar.text, bar.levelText, bar.pctText }) do
        local fontPath, _, fontFlags = fs:GetFont()
        if fontPath then fs:SetFont(fontPath, size, fontFlags) end
    end

    bar:EnableMouse(db.textMode == "hover")

    local visible = db.textMode == "always"
    bar.text:SetShown(visible)
    bar.levelText:SetShown(visible and db.showLevel)
    bar.pctText:SetShown(visible and db.showPercent)
    bar.levelBlock:SetShown(visible and db.showLevel and db.levelBlock)

    LayoutTicks()
    LayoutRow(bar.topRow)
    LayoutRow(bar.bottomRow)
    PlaceRows()
end

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

-- Three slots share one strip: the level on the left, the counts in the middle,
-- the percentages on the right. Declared ahead of the fitter because the block
-- behind the level is sized from the level text, and the fitter is what decides
-- how big that text ends up.
local UpdateLevelBlock

-- The smallest share of the bar the middle is allowed to be left with. Slot
-- fonts follow the bar height, so a tall narrow bar asks for text that cannot
-- fit three slots across: at 37px high and 280 wide the level and the percent
-- wanted 242 of the 280 between them and left the middle 29 to work in.
local MIDDLE_SHARE = 0.34

local function FitBarText()
    local fontPath, _, fontFlags = bar.text:GetFont()
    if not fontPath then return end

    local size = math.max(8, math.min(22, math.floor(db.height * 0.65 + 0.5)))

    -- Every slot starts from the height derived size on every pass. Measuring
    -- from whatever last pass shrank them to would ratchet the text smaller and
    -- smaller and never let it grow back.
    local slots = { bar.text, bar.levelText, bar.pctText }
    for _, fs in ipairs(slots) do
        local fp, _, ff = fs:GetFont()
        if fp then fs:SetFont(fp, size, ff) end
    end

    -- Where the two neighbours actually end. The block behind the level is wider
    -- than the level text sitting on it, so measuring the text alone let the
    -- middle string slide under the block.
    local function edges()
        local left = 5
        if bar.levelText:IsShown() then
            left = bar.levelText:GetStringWidth() + (db.levelBlock and 10 or 5)
        end
        local right = db.width - 5
        if bar.pctText:IsShown() then
            right = db.width - bar.pctText:GetStringWidth() - 10
        end
        return left, right
    end

    -- Step the two side slots down together until the middle has its share. They
    -- move as a pair because a level in one size beside a percent in another
    -- reads as a mistake.
    local sideSize = size
    local leftEdge, rightEdge = edges()
    while sideSize > 8 and (rightEdge - leftEdge) < db.width * MIDDLE_SHARE do
        sideSize = sideSize - 1
        for _, fs in ipairs({ bar.levelText, bar.pctText }) do
            local fp, _, ff = fs:GetFont()
            if fp then fs:SetFont(fp, sideSize, ff) end
        end
        leftEdge, rightEdge = edges()
    end

    -- The block is only correct once the level text has stopped moving.
    UpdateLevelBlock()

    -- Centre the middle string in the gap between its neighbours, not in the
    -- bar. Staying centred on the bar means reserving the wider neighbour's
    -- width on BOTH sides, and a tall bar wears a big level block: at 37px high
    -- that reservation left the middle about a fifth of the bar and shrank a
    -- short string down to nothing for no reason at all.
    local gap = rightEdge - leftEdge
    if gap <= 0 then return end

    bar.text:ClearAllPoints()
    bar.text:SetPoint("CENTER", bar, "LEFT", leftEdge + gap / 2, 0)

    local allowed = gap - 6
    while size > 8 and bar.text:GetStringWidth() > allowed do
        size = size - 1
        bar.text:SetFont(fontPath, size, fontFlags)
    end
end

function UpdateLevelBlock()
    if not (db.showLevel and db.levelBlock) or not bar.levelText:IsShown() then
        bar.levelBlock:Hide()
        return
    end
    local width = bar.levelText:GetStringWidth()
    if not width or width <= 0 then
        bar.levelBlock:Hide()
        return
    end
    bar.levelBlock:ClearAllPoints()
    bar.levelBlock:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
    bar.levelBlock:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 1, 1)
    bar.levelBlock:SetWidth(width + 9)
    bar.levelBlock:Show()
end

-- Two captions sharing one strip will collide the moment the numbers grow, and
-- a 420px bar is narrow enough that they do. So each caption is written as a
-- list of forms, longest first, and the pair steps down together until the two
-- measured widths fit side by side. Only when the shortest pair still overruns
-- does the font give way, one point at a time, down to 8.
local GAP = 14
local INSET = 8 -- the 4px each caption is held off its end of the row

local function FitRow(row, lefts, rights)
    local usable = db.width - INSET - GAP
    local steps = math.max(#lefts, #rights)

    local function measure(i)
        row.left:SetText(lefts[math.min(i, #lefts)] or "")
        row.right:SetText(rights[math.min(i, #rights)] or "")
        return row.left:GetStringWidth() + row.right:GetStringWidth()
    end

    local fontPath, _, fontFlags = row.left:GetFont()
    local size = row.baseSize or 10
    if fontPath then
        row.left:SetFont(fontPath, size, fontFlags)
        row.right:SetFont(fontPath, size, fontFlags)
    end

    for i = 1, steps do
        if measure(i) <= usable then return end
    end

    if not fontPath then return end
    while size > 8 do
        size = size - 1
        row.left:SetFont(fontPath, size, fontFlags)
        row.right:SetFont(fontPath, size, fontFlags)
        if measure(steps) <= usable then return end
    end
end

-- Rates read better rounded than exact: 7558 an hour is 7.6k an hour, and the
-- extra two digits are two more characters fighting for the same strip.
local function Rate(perSecond)
    local hourly = math.floor(perSecond * 3600)
    if hourly >= 1000 then return Short(hourly) end
    return tostring(hourly)
end

-- How the right hand caption gives way as the bar narrows, longest rung first.
-- A label of "" keeps the value and drops its word; false drops the value. The
-- tooltip carries all three in full whatever the row ends up showing.
local RUNGS = {
    { done = "Completed: ", bars = "Bars: ", rested = "Rested: " },
    { done = "Done: ",      bars = "Bars: ", rested = "Rest: " },
    { done = "Done: ",      bars = "",       rested = "Rest: " },
    { done = "Done: ",      bars = "",       rested = false },
    { done = "Done: ",      bars = false,    rested = false },
    { done = "",            bars = false,    rested = false },
}

function M:UpdateRows()
    if not bar or bar.mode ~= "xp" then
        if bar then
            bar.topRow:Hide()
            bar.bottomRow:Hide()
        end
        return
    end

    bar.topRow:SetShown(RowWanted(bar.topRow))
    bar.bottomRow:SetShown(RowWanted(bar.bottomRow))
    PlaceRows()

    if bar.topRow:IsShown() then
        local lefts, rights = { "" }, { "" }

        -- Nothing is drawn until the server has answered. A second of no caption
        -- at login beats a confident wrong number, which is what was there.
        local levelSeconds = TimeThisLevel()
        if db.showTimeThisLevel and levelSeconds then
            local t = FormatTime(levelSeconds) or "0s"
            lefts = {
                LABEL .. "Time this level: " .. STOP .. VALUE .. t .. STOP,
                LABEL .. "Level: " .. STOP .. VALUE .. t .. STOP,
                VALUE .. t .. STOP,
            }
        end

        if db.showTimeThisSession and session.start then
            local t = FormatTime(GetTime() - session.start) or "0s"
            rights = {
                LABEL .. "Time this session: " .. STOP .. VALUE .. t .. STOP,
                LABEL .. "Session: " .. STOP .. VALUE .. t .. STOP,
                VALUE .. t .. STOP,
            }
        end

        FitRow(bar.topRow, lefts, rights)
    end

    if not bar.bottomRow:IsShown() then return end

    local cur, max = CurXP(), MaxXP()

    local lefts, rights = { "" }, { "" }

    -- When the middle of the bar is set to the estimate, the row below it was
    -- printing the same minutes a second time. The rate is the half the bar
    -- never shows, so that is all the row keeps in that case.
    local etaOnBar = db.format == "time-to-level" and db.textMode ~= "never"

    if db.showLevelingIn then
        local eta = FormatTime(self:TimeToLevel(cur, max))
        local rate = self:XPPerSecond()
        if eta and rate then
            local hourly = Rate(rate)
            if etaOnBar then
                lefts = {
                    LABEL .. "Rate: " .. STOP .. VALUE .. hourly .. STOP ..
                        LABEL .. " xp/h" .. STOP,
                    LABEL .. "Rate: " .. STOP .. VALUE .. hourly .. STOP ..
                        LABEL .. "/h" .. STOP,
                    VALUE .. hourly .. STOP .. LABEL .. "/h" .. STOP,
                }
            else
                lefts = {
                    LABEL .. "Leveling in: " .. STOP .. VALUE .. eta .. STOP ..
                        LABEL .. string.format(" (%s xp/h)", hourly) .. STOP,
                    LABEL .. "Leveling in: " .. STOP .. VALUE .. eta .. STOP ..
                        LABEL .. string.format(" (%s/h)", hourly) .. STOP,
                    LABEL .. "Leveling in: " .. STOP .. VALUE .. eta .. STOP,
                    VALUE .. eta .. STOP,
                }
            end
        else
            -- No rate yet. "measuring" says why the number is missing, where the
            -- ellipsis this used to print said nothing at all.
            lefts = {
                LABEL .. "Leveling in: " .. STOP .. VALUE .. "measuring" .. STOP,
                LABEL .. "Rate: " .. STOP .. VALUE .. "measuring" .. STOP,
                VALUE .. "measuring" .. STOP,
            }
        end
    end

    local done = db.showCompleted and CompletedFraction(cur) or nil

    -- Zero rested is not information, and neither is a pool so small it prints as
    -- zero: hiding only the exactly zero case still left "Rest: 0%" sitting there
    -- after a level up. The test is the string that would actually be drawn,
    -- because any cutoff picked by eye is wrong on one side of it. %.0f rounds
    -- half down, so 0.5% renders as "0%" and a >= 0.5 threshold let it through.
    local pool = RestedXP()
    local restedText = string.format("%.0f%%", (pool > 0) and (pool / max * 100) or 0)
    local rested = (db.showRestedPct and restedText ~= "0%") and restedText or nil

    -- Same rule as the estimate: whichever slot already carries the bars, the
    -- other one drops them.
    local barsOnBar = db.format == "bars" and db.textMode ~= "never"
    local _, exact, total = self:Bars(cur, max)
    local bars = (db.showBars and exact and not barsOnBar) and exact or nil

    if done or rested or bars then
        rights = {}
        for _, rung in ipairs(RUNGS) do
            local parts = {}
            if done and rung.done then
                parts[#parts + 1] = LABEL .. rung.done .. STOP ..
                    ACCENT .. string.format("%.1f%%", done * 100) .. STOP
            end
            if bars and rung.bars then
                parts[#parts + 1] = LABEL .. rung.bars .. STOP ..
                    ACCENT .. string.format("%.1f/%d", bars, total) .. STOP
            end
            if rested and rung.rested then
                parts[#parts + 1] = LABEL .. rung.rested .. STOP .. ACCENT .. rested .. STOP
            end
            if #parts > 0 then
                local text = table.concat(parts, LABEL .. " - " .. STOP)
                -- A rung whose only change was a value that is absent anyway
                -- renders identically to the one above it, and a duplicate rung
                -- is a step the ladder spends for nothing.
                if text ~= rights[#rights] then rights[#rights + 1] = text end
            end
        end
        if #rights == 0 then rights = { "" } end
    end

    FitRow(bar.bottomRow, lefts, rights)
end

function M:Tick()
    if not bar or bar.mode ~= "xp" then
        self:UpdateRows()
        return
    end

    if db.format == "time-to-level" then
        local cur, max = CurXP(), MaxXP()
        bar.text:SetText(BarText(cur, max))
        FitBarText()
    end

    self:UpdateRows()
end

-- The watched reputation, whichever way this client spells it.
--
-- GetWatchedFactionInfo does not exist on the Anniversary client: reputation
-- moved to C_Reputation.GetWatchedFactionData, which hands back one table
-- instead of five returns. Calling the old global here was a live error, logged
-- by BugSack every time the bar tried to draw a reputation.
--
-- Both are tested rather than the interface number, because the same addon
-- folder is expected to run on whatever client it is dropped into, and a
-- version check would have to be revised every time Blizzard moves the line.
local function WatchedFaction()
    local modern = C_Reputation and C_Reputation.GetWatchedFactionData
    if modern then
        local data = modern()
        if not data then return nil end
        return data.name, data.standingID, data.currentReactionThreshold,
            data.nextReactionThreshold, data.currentStandingValue
    end

    if GetWatchedFactionInfo then
        return GetWatchedFactionInfo()
    end

    return nil
end
M.WatchedFaction = WatchedFaction

function M:Update(gained)
    if not bar then return end

    local xpOff = IsXPUserDisabled and IsXPUserDisabled()

    if AtMaxLevel() or xpOff then
        if db.repAtMax then
            local name, standing, minv, maxv, value = WatchedFaction()
            if name and name ~= "" then
                local span = (maxv or 0) - (minv or 0)
                local cur = (value or 0) - (minv or 0)

                bar:Show()
                bar.rested:SetValue(0)
                bar.fill:SetMinMaxValues(0, span > 0 and span or 1)
                bar.fill:SetValue(cur)

                local col = FACTION_BAR_COLORS and FACTION_BAR_COLORS[standing]
                if col then bar.fill:SetStatusBarColor(col.r, col.g, col.b, 1) end

                bar.levelText:SetText("")
                bar.levelBlock:Hide()
                bar.pctText:SetText("")
                bar.text:SetFormattedText("%s  %s / %s", name, Short(cur), Short(span))
                bar.mode = "rep"
                self:UpdateRows()
                return
            end
        end

        bar:SetShown(not db.hideAtMax)
        bar.mode = "none"
        self:UpdateRows()
        return
    end

    bar:Show()
    bar.mode = "xp"

    local cur, max = CurXP(), MaxXP()
    local rested = db.showRested and RestedXP() or 0

    -- Never learn from made up numbers. A preview borrows the real requirement,
    -- but it can preview a different level, and filing this level's cost under
    -- that level would quietly poison the table for good.
    if not preview then
        Learn(Level(), max)
    end

    local fraction = cur / max
    if gained and bar.lastFraction and fraction > bar.lastFraction then
        Flash(bar.lastFraction, fraction)
    end
    bar.lastFraction = fraction

    bar.fill:SetMinMaxValues(0, max)
    bar.fill:SetValue(cur)

    local c = db.xpColor
    bar.fill:SetStatusBarColor(c[1], c[2], c[3], c[4])

    bar.rested:SetMinMaxValues(0, max)
    bar.rested:SetValue(math.min(cur + rested, max))

    bar.text:SetText(BarText(cur, max))

    if db.showLevel then
        bar.levelText:SetFormattedText("Level %d", Level())
    else
        bar.levelText:SetText("")
    end

    if db.showPercent then
        local pct = cur / max * 100
        local restedPool = RestedXP()
        if restedPool > 0 then
            bar.pctText:SetFormattedText("%.1f%% (%.1f%%)", pct,
                math.min(100, (cur + restedPool) / max * 100))
        else
            bar.pctText:SetFormattedText("%.1f%%", pct)
        end
    else
        bar.pctText:SetText("")
    end

    FitBarText()
    self:UpdateRows()
end

--------------------------------------------------------------------------------
-- Preview controls
--------------------------------------------------------------------------------

-- fraction and restedFraction are both shares of one level, so 1 and 0.5 is a
-- full bar with half a level banked. level is optional and only matters for
-- looking at the max level states.
function M:Preview(fraction, restedFraction, level)
    fraction = tonumber(fraction) or 0
    if fraction < 0 then fraction = 0 end
    if fraction > 1 then fraction = 1 end

    local restedShare = tonumber(restedFraction) or 0
    if restedShare < 0 then restedShare = 0 end

    -- The real requirement where there is one, so the numbers on screen are the
    -- ones this character would actually see.
    local realMax = UnitXPMax("player") or 0
    local max = (realMax > 0) and realMax or PREVIEW_FALLBACK_MAX

    preview = {
        max = max,
        cur = math.floor(max * fraction + 0.5),
        rested = math.floor(max * restedShare + 0.5),
        level = tonumber(level) or UnitLevel("player") or 1,
    }

    self:Update()
    return preview
end

function M:PreviewOff()
    self:StopSweep()
    if not preview then return false end
    preview = nil
    self:Update()
    return true
end

function M:IsPreviewing()
    return preview ~= nil
end

function M:MaxLevel()
    return MAX_LEVEL
end

-- What the bar is currently showing as a share of a level, previewed or not. The
-- settings page reads this so its slider follows the bar instead of fighting it.
function M:PreviewFraction()
    local max = MaxXP()
    if max <= 0 then return 0 end
    return CurXP() / max
end

function M:StopSweep()
    if self.sweep then
        if self.sweep.Cancel then self.sweep:Cancel() end
        self.sweep = nil
    end
end

-- Walks the fill from empty to full. A moving fill is the only way to catch a
-- rendering fault that only shows at some widths, which is exactly the class of
-- problem this whole preview exists for.
function M:Sweep(seconds)
    if not (C_Timer and C_Timer.NewTicker) then return false end

    self:StopSweep()

    seconds = tonumber(seconds) or 4
    if seconds <= 0 then seconds = 4 end

    local step = 0.05
    local elapsed = 0

    self.sweep = C_Timer.NewTicker(step, function()
        elapsed = elapsed + step
        if elapsed >= seconds then
            M:Preview(1, 0)
            M:StopSweep()
            return
        end
        M:Preview(elapsed / seconds, 0)
    end)

    return true
end

--------------------------------------------------------------------------------
-- Tooltip. This is where the density lives, so the bar itself can stay quiet.
--------------------------------------------------------------------------------

function M:ShowTooltip()
    if not bar or bar.mode == "none" then return end
    GameTooltip:SetOwner(bar, "ANCHOR_TOP")

    if bar.mode == "rep" then
        local name, standing, minv, maxv, value = WatchedFaction()
        GameTooltip:AddLine(name or "")
        GameTooltip:AddLine(_G["FACTION_STANDING_LABEL" .. (standing or 4)] or "", 1, 1, 1)
        GameTooltip:AddDoubleLine("Progress",
            string.format("%d / %d", (value or 0) - (minv or 0), (maxv or 0) - (minv or 0)),
            1, 1, 1, 1, 1, 1)
        GameTooltip:Show()
        return
    end

    local cur, max = CurXP(), MaxXP()
    local remaining = max - cur
    local rested = RestedXP()

    GameTooltip:AddLine(string.format("Level %d", Level()))
    if preview then
        -- Impossible to mistake a previewed bar for a real one, which matters the
        -- moment someone forgets they left it on.
        GameTooltip:AddLine("Preview mode. /wui xp off returns to live data.", 1, 0.5, 0.3)
    end
    GameTooltip:AddDoubleLine("Experience", string.format("%d / %d", cur, max), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Remaining", string.format("%d  (%.1f%%)", remaining, cur / max * 100), 1, 1, 1, 1, 1, 1)

    local filled, exact, total = self:Bars(cur, max)
    if filled then
        GameTooltip:AddDoubleLine("Bars",
            string.format("%d of %d  (%.1f to go)", filled, total, total - exact),
            1, 1, 1, 1, 1, 1)

        -- The exact worth of one bar at this level. Every level moves it, so a
        -- remembered number from ten levels ago is no use.
        local worth = self:XPPerBar(max)
        if worth then
            GameTooltip:AddDoubleLine("One bar", Amount(worth) .. " xp", 1, 1, 1, 1, 1, 1)
        end
    end

    local done = CompletedFraction(cur)
    if done then
        GameTooltip:AddDoubleLine("Completed",
            string.format("%.1f%% of level %d", done * 100, MAX_LEVEL), 1, 1, 1, 1, 0.63, 0.16)
    end

    if rested > 0 then
        -- One decimal here where the row rounds. The row is choosing what is
        -- worth the space, the tooltip is the place that does not round away a
        -- pool the user can see in the bracket beside the percent.
        GameTooltip:AddDoubleLine("Rested",
            string.format("%d  (%.1f%% of a level)", rested, rested / max * 100), 1, 1, 1, 0.6, 0.8, 1)
    end

    local levelSeconds = TimeThisLevel()
    if levelSeconds then
        GameTooltip:AddDoubleLine("Time this level",
            FormatTime(levelSeconds) or "0s", 1, 1, 1, 1, 1, 1)
    end

    if session.xp > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("This session", 1, 0.82, 0)

        local elapsed = GetTime() - session.start
        GameTooltip:AddDoubleLine("Played", FormatTime(elapsed) or "0s", 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Gained", Short(session.xp), 1, 1, 1, 1, 1, 1)

        local rate = self:XPPerSecond()
        if rate then
            GameTooltip:AddDoubleLine("Per hour", Short(math.floor(rate * 3600)), 1, 1, 1, 1, 1, 1)

            local bph = self:BarsPerHour()
            if bph then
                GameTooltip:AddDoubleLine("Bars per hour",
                    string.format("%.1f", bph), 1, 1, 1, 1, 1, 1)
            end

            local eta = FormatTime(self:TimeToLevel(cur, max))
            if eta then
                GameTooltip:AddDoubleLine("Time to level", eta, 1, 1, 1, 0.6, 1, 0.6)
            end
        else
            GameTooltip:AddDoubleLine("Per hour", "measuring", 1, 1, 1, 0.6, 0.6, 0.6)
        end

        local kills, average = self:KillsToLevel(cur, max)
        if kills then
            GameTooltip:AddDoubleLine("Kills to level",
                string.format("%d  (%d xp each)", kills, math.floor(average + 0.5)), 1, 1, 1, 1, 1, 1)
        end
    end

    GameTooltip:Show()
end

--------------------------------------------------------------------------------

-- The clocks are the only thing here with no event behind them, so they get
-- their own hand rather than an OnUpdate that would run every frame for two
-- strings. Below a minute the captions are counting seconds and want the fast
-- tick; past that they read in minutes and a slow one is indistinguishable.
function M:StartTicker()
    if not (C_Timer and C_Timer.NewTicker) then return end

    local interval = db.refresh or 5
    if self.ticker then
        if self.tickerInterval == interval then return end
        if self.ticker.Cancel then self.ticker:Cancel() end
    end

    self.tickerInterval = interval
    self.ticker = C_Timer.NewTicker(interval, function() M:Tick() end)
end

function M:OnSettingsChanged()
    self:ApplyLook()
    self:StartTicker()
    self:Update()
end

function M:OnInit(settings)
    db = settings

    -- One time only. The plate behind the level was a third shade on a bar that
    -- has two, and at low experience it was the only coloured thing on the strip,
    -- so the bar read as a fifth full when it was half a percent full. An
    -- existing profile gets it switched off once; schema then stops this ever
    -- running again, so turning it back on afterwards sticks.
    if not db.schema then
        db.schema = 1
        if db.levelBlock then
            db.levelBlock = false
            ns.Print("the plate behind the level on the XP bar is now off: it was reading as fill. The level text is outlined instead. Re-enable it on the XP bar page if you liked it.")
        end
    end
end

function M:OnEnable(settings)
    db = settings
    db.learned = db.learned or {}
    totalCache = nil

    if GetMaxPlayerLevel then
        MAX_LEVEL = GetMaxPlayerLevel() or MAX_LEVEL
    elseif MAX_PLAYER_LEVEL then
        MAX_LEVEL = MAX_PLAYER_LEVEL
    end

    BuildKillPatterns()
    Build()

    -- Where the bar sits decides where its rows can go, so the placer has to run
    -- again once a drag has finished.
    if bar.suMover then bar.suMover.onStop = PlaceRows end

    self:ApplyLook()
    self:ResetSession()
    self:Update()

    -- The default XP bar is redundant once this exists.
    if MainMenuExpBar then
        MainMenuExpBar:UnregisterAllEvents()
        MainMenuExpBar:Hide()
    end

    self:StartTicker()

    local events = CreateFrame("Frame")
    events:RegisterEvent("PLAYER_XP_UPDATE")
    events:RegisterEvent("PLAYER_LEVEL_UP")
    events:RegisterEvent("UPDATE_EXHAUSTION")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("DISPLAY_SIZE_CHANGED")
    events:RegisterEvent("UI_SCALE_CHANGED")
    events:RegisterEvent("UPDATE_FACTION")
    events:RegisterEvent("ENABLE_XP_GAIN")
    events:RegisterEvent("DISABLE_XP_GAIN")
    events:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
    events:RegisterEvent("TIME_PLAYED_MSG")

    events:SetScript("OnEvent", function(_, event, arg1, arg2)
        if event == "CHAT_MSG_COMBAT_XP_GAIN" then
            local killXP = ParseKillXP(arg1 or "")
            if killXP then
                session.kills = session.kills + 1
                session.killXP = session.killXP + killXP
            end
            return
        end

        if event == "TIME_PLAYED_MSG" then
            -- arg1 is the total, arg2 is the one that matters here.
            UnmuteTimePlayed()
            if type(arg2) == "number" and arg2 >= 0 then
                played.levelBase = arg2
                played.stamp = GetTime()
                M:UpdateRows()
            end
            return
        end

        if event == "PLAYER_LEVEL_UP" then
            -- The level up event carries the new level before the unit does,
            -- and RecordXP catches the roll over, but the clock has to start
            -- here either way.
            session.levelStart = GetTime()

            -- The server zeroes time on level the instant the level lands, so
            -- the display is zeroed here rather than sitting on the old number
            -- for the length of a round trip. The request that follows only
            -- confirms it.
            played.levelBase = 0
            played.stamp = GetTime()
            if C_Timer and C_Timer.After then
                C_Timer.After(3, AskTimePlayed)
            end
        end

        if event == "PLAYER_XP_UPDATE" or event == "PLAYER_LEVEL_UP" then
            RecordXP()
            M:Update(true)
            return
        end

        M:Update()
    end)

    M.events = events

    -- A moment after login rather than during it, so the request is not competing
    -- with everything else the client is doing as the world loads.
    if C_Timer and C_Timer.After then
        C_Timer.After(2, AskTimePlayed)
    else
        AskTimePlayed()
    end
end
