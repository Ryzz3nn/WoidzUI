local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Party quests
--
-- Tells the user when a friend in the party has pulled ahead of them in a quest
-- line, so the two of them can get back onto the same step before one is running
-- escorts the other cannot see yet.
--
-- Two libraries do the reading. Modules/PartyQuests/Chain.lua turns a quest id
-- into a position in a quest line, out of Questie's local database.
-- Modules/PartyQuests/Roster.lua says who is in the group and which quests they
-- are broadcasting. Both are absent when Questie is not installed, which is why
-- everything here checks before it reaches.
--------------------------------------------------------------------------------

local M = ns:NewModule("partyquests", "Party quests", {
    enabled = true,
    threshold = 1,           -- how many quests ahead before it is worth saying
    cooldown = 300,          -- seconds before the same player and line speaks again
    alertAhead = false,      -- also say it when the user is the one in front
    scanInterval = 15,       -- seconds between comparisons while in a group
    onlySharedChains = true, -- ignore lines the user has never touched
    trackAll = true,         -- every party member, rather than a named list
    tracked = {},            -- [shortName] = true, used when trackAll is off
})

local db

-- Keyed player and chain root. Kept outside the module table so a wipe is one
-- assignment.
local lastAlert = {}
local pending

--------------------------------------------------------------------------------
-- Position
--------------------------------------------------------------------------------

-- Furthest point reached in one quest line. The local player's own completed
-- quests count towards it; for a party member only the active quest is ever
-- known, and that is enough, because a quest cannot be in a log until its
-- prequests are done. Both sides go through this one function so the two numbers
-- are always measured the same way and can honestly be subtracted.
-- How somebody came to be standing on a step. Position deliberately mixes the
-- active and the completed sets, because furthest reached is the only number the
-- two sides can both produce, but the wording downstream must not: a finished
-- quest is not in a quest log.
local ACTIVE, DONE, UNKNOWN = "active", "done", "unknown"

local function Position(chain, active, complete)
    local best = 0
    for i = 1, #chain.ids do
        local id = chain.ids[i]
        if (active and active[id]) or (complete and complete[id]) then
            best = i
        end
    end
    return best
end
M.Position = Position

local function InGroup()
    return ((GetNumGroupMembers and GetNumGroupMembers()) or 0) > 1
end

-- Whose progress the user actually wants to hear about. Tracking everyone is the
-- default because levelling with the same friends is the common case, but a
-- pickup group of strangers is pure noise, so a named list can take over. The
-- list is kept rather than cleared when someone leaves, so a friend who is
-- offline tonight has not lost their setting by tomorrow.
function M:Tracked(player)
    if not db then return false end
    if db.trackAll then return true end
    return (db.tracked and db.tracked[player] == true) or false
end

-- The lines this character has a stake in. These are the only ones worth asking a
-- peer about: a line neither of us has touched cannot put anyone behind anyone,
-- and asking about everything would mean shipping a whole quest history.
function M:MyChainRoots()
    local chainLib, rosterLib = ns.QuestChain, ns.QuestRoster
    if not chainLib or not rosterLib then return {} end
    if not chainLib.Available() then return {} end

    local me = rosterLib.Me()
    local roots, seen = {}, {}

    for questId in pairs(me.quests) do
        local chain = chainLib.Info(questId)
        if chain and chain.length > 1 and not seen[chain.root] then
            seen[chain.root] = true
            roots[#roots + 1] = chain.root
        end
    end

    table.sort(roots)
    return roots
end

--------------------------------------------------------------------------------
-- Comparison
--------------------------------------------------------------------------------

-- Pure. No printing, no state, no side effects, so the alerting and the report
-- are both built on exactly the same numbers and can never disagree.
function M:Compare()
    local findings = {}

    local chainLib, rosterLib = ns.QuestChain, ns.QuestRoster
    local syncLib = ns.QuestSync

    if not chainLib or not rosterLib then return findings end
    if not chainLib.Available() then return findings end

    -- Questie comms being down no longer means there is nothing to say, because a
    -- peer running WoidzUI reports directly.
    local haveSync = syncLib and syncLib.Available() and next(syncLib.Positions()) ~= nil
    if not rosterLib.Available() and not haveSync then return findings end

    local members = rosterLib.Members()
    local me = rosterLib.Me()

    for player, member in pairs(members) do
        -- A member who is not sharing tells us nothing, and one who stopped
        -- talking minutes ago tells us something out of date. The report names
        -- both cases; neither is ever a finding, because a guess presented as a
        -- gap is worse than no gap at all.
        local syncPositions = syncLib and syncLib.Positions(player) or nil

        -- Sharing means Questie is talking. A peer running WoidzUI is talking
        -- through this addon instead, and that is just as good a reason to
        -- compare, so either one is enough.
        local speaking = (member.sharing and not member.stale)
            or (syncPositions ~= nil and next(syncPositions) ~= nil)

        if self:Tracked(player) and speaking then
            local doneRoots = {}

            -- Every line either of us has a stake in. A line they finished before
            -- we grouped has no active quest to find it by, which is exactly the
            -- case Questie alone cannot see, so their reported lines are walked
            -- as well as their active ones.
            local candidates = {}
            for questId in pairs(member.quests) do candidates[questId] = true end
            if syncPositions then
                for root in pairs(syncPositions) do candidates[root] = true end
            end

            for questId in pairs(candidates) do
                local chain = chainLib.Info(questId)

                -- A quest line of one cannot put anybody behind anybody.
                if chain and chain.length > 1 and not doneRoots[chain.root] then
                    doneRoots[chain.root] = true

                    -- Questie can only place them by an active quest. A peer
                    -- running WoidzUI reports where they really are, completed
                    -- quests included, so that number wins wherever it exists.
                    local inferred = Position(chain, member.quests, nil)
                    local reported = syncPositions and syncPositions[chain.root]

                    local theirIndex = inferred
                    local exact = false
                    if reported and reported >= inferred then
                        theirIndex = reported
                        exact = true
                    end

                    local myIndex = Position(chain, me.quests, me.complete)
                    local gap = theirIndex - myIndex

                    -- Standing on a step and being past it are different facts,
                    -- and the sentence has to say which, or a user gets sent
                    -- looking through their log for a quest they handed in weeks
                    -- ago. Mine is known outright: anything in the position that
                    -- is not in the active log came out of the completed set.
                    local myState
                    if myIndex > 0 then
                        myState = me.quests[chain.ids[myIndex]] and ACTIVE or DONE
                    end

                    -- Theirs is worked out rather than told. A position Questie
                    -- inferred came from an active quest by definition. A
                    -- reported position past everything in their log is a quest
                    -- they have already handed in, since inferred is the highest
                    -- of their active ones. With no trustworthy active list to
                    -- measure against, it stays unknown rather than guessed.
                    local theirState
                    if theirIndex == 0 then
                        theirState = nil
                    elseif not exact or theirIndex == inferred then
                        theirState = ACTIVE
                    elseif member.sharing and not member.stale then
                        theirState = DONE
                    else
                        theirState = UNKNOWN
                    end

                    -- onlySharedChains keeps the user from hearing about every
                    -- line a friend has ever picked up in a zone they have not
                    -- been to. Off, those arrive with myIndex 0.
                    local skip = db and db.onlySharedChains and myIndex == 0

                    if gap ~= 0 and not skip then
                        findings[#findings + 1] = {
                            player = player,
                            chainRoot = chain.root,
                            chainName = chainLib.Name(chain.root),
                            theirIndex = theirIndex,
                            myIndex = myIndex,
                            gap = gap,
                            length = chain.length,
                            theirQuestId = chain.ids[theirIndex],
                            theirQuestName = chainLib.Name(chain.ids[theirIndex]),
                            exact = exact,
                            class = member.class,
                            theirState = theirState,
                            myState = myState,
                            myQuestId = (myIndex > 0) and chain.ids[myIndex] or nil,
                            myQuestName = (myIndex > 0) and chainLib.Name(chain.ids[myIndex]) or nil,
                        }
                    end
                end
            end
        end
    end

    table.sort(findings, function(a, b)
        if a.gap ~= b.gap then return a.gap > b.gap end
        -- Ties break on something fixed, so a report run twice with nothing
        -- changed comes out in the same order both times.
        if a.player ~= b.player then return a.player < b.player end
        return a.chainRoot < b.chainRoot
    end)

    return findings
end

--------------------------------------------------------------------------------
-- Wording
--------------------------------------------------------------------------------

local function Plural(count)
    return (count == 1) and "quest" or "quests"
end

local function Quoted(name)
    if type(name) ~= "string" or name == "" then return "an unnamed quest" end
    return '"' .. name .. '"'
end

--------------------------------------------------------------------------------
-- Colour
--
-- One sentence names four different things: who, which line, which quest, and
-- how far apart. In a single white they run together and the eye has to read the
-- whole thing to find any one of them. Each kind gets its own colour and the
-- prose between them sits back in grey, so the four land at a glance.
--
-- |r resets to the chat frame's own colour rather than restoring what was in
-- force before it, so a highlight ends by switching back to BODY explicitly and
-- only the end of a line ever uses STOP. Nesting it would leave the rest of the
-- sentence white, which is the exact thing being fixed.
--------------------------------------------------------------------------------

local BODY  = "|cff9d9d9d"   -- the prose, deliberately quiet
local LINE  = "|cffffffff"   -- the quest line the comparison is about
local QUEST = "|cffffd100"   -- a single quest, in the yellow the quest log uses
local COUNT = "|cffffa028"   -- the gap, the one number worth reading
local GOOD  = "|cff59c94c"   -- handed in, so not in a log at all
local NAME  = "|cff5b8dd9"   -- a player, until their class is known
local STOP  = "|r"

local function Paint(code, text)
    return code .. text .. BODY
end

-- A party member in their class colour, the way every other addon in the group
-- draws them, so the name is recognised before it is read. Questie's class token
-- is the only source, and it is absent for a peer reporting through sync alone.
local function ClassColour(class)
    if type(class) ~= "string" or class == "" then return NAME end

    local palette = (type(CUSTOM_CLASS_COLORS) == "table" and CUSTOM_CLASS_COLORS)
        or (type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS)
    local colour = palette and palette[class:upper()]
    if not colour then return NAME end

    if colour.colorStr then return "|c" .. colour.colorStr end
    if colour.r then
        return string.format("|cff%02x%02x%02x",
            math.floor(colour.r * 255), math.floor(colour.g * 255), math.floor(colour.b * 255))
    end

    return NAME
end

local function Who(name, class)
    return Paint(ClassColour(class), tostring(name))
end

-- The copy window is an EditBox, and an EditBox renders an escape sequence as the
-- literal characters it is made of, then puts them on the clipboard. Chat is the
-- only place the colours belong, so the report strips them on the way out rather
-- than the wording being written twice and drifting apart.
local function Plain(text)
    text = text:gsub("|c" .. ("%x"):rep(8), "")
    return (text:gsub("|r", ""))
end
M.Plain = Plain

-- Where somebody stands in a line, said honestly. "You are on X" was printed for
-- a completed quest as well as an active one, which reads as a quest log entry
-- that is not there. Subject is "you" or "they"; both take the same verb forms.
local function Standing(subject, questName, state)
    local quest = Paint(QUEST, Quoted(questName))

    if state == DONE then
        -- The one word that says the quest is not in a log. Worth its own colour,
        -- because it is the difference between go and go looking.
        return subject .. " have " .. Paint(GOOD, "finished") .. " " .. quest
    end

    -- Their furthest step with no active list to check it against. Reached is
    -- true either way, where on and finished would each be a coin flip.
    if state == UNKNOWN then
        return subject .. " have reached " .. quest
    end

    return subject .. " are on " .. quest
end

local function Capitalised(text)
    return text:sub(1, 1):upper() .. text:sub(2)
end

function M:Sentence(finding, behind)
    local count = math.abs(finding.gap)
    local plural = Plural(count)
    local line = Paint(LINE, Quoted(finding.chainName))

    -- Naming both quests is the whole point. "You are 2 behind" leaves the user
    -- opening Questie to find out behind what.
    local theirs = Standing("they", finding.theirQuestName, finding.theirState)
    local mine = finding.myQuestName
        and Standing("you", finding.myQuestName, finding.myState)
        or "you have not started it"

    if behind then
        return string.format("%s%s is %s %s ahead of you in %s. %s, %s.%s",
            BODY, Who(finding.player, finding.class), Paint(COUNT, count), plural,
            line, Capitalised(theirs), mine, STOP)
    end

    return string.format("%sYou are %s %s ahead of %s in %s. %s, %s.%s",
        BODY, Paint(COUNT, count), plural, Who(finding.player, finding.class),
        line, Capitalised(mine), theirs, STOP)
end

--------------------------------------------------------------------------------
-- Alerting
--------------------------------------------------------------------------------

-- Called by the sync file the moment a peer's real position arrives, because what
-- is on screen was computed without it.
function M:OnSyncUpdate()
    self:Alert()
end

function M:Alert()
    if not db then return end

    -- Ask before comparing. The answer lands a moment later and brings us back
    -- through OnSyncUpdate, so nothing waits on the round trip.
    local syncLib = ns.QuestSync
    if syncLib and syncLib.Available() then
        syncLib.Ask(self:MyChainRoots())
    end

    local now = (GetTime and GetTime()) or 0

    for _, finding in ipairs(self:Compare()) do
        local behind = finding.gap >= db.threshold
        local ahead = db.alertAhead and (-finding.gap) >= db.threshold

        if behind or ahead then
            local key = finding.player .. "\0" .. tostring(finding.chainRoot)
            local last = lastAlert[key]

            if not last or (now - last) >= db.cooldown then
                lastAlert[key] = now
                ns.Print(self:Sentence(finding, behind))
            end
        end
    end
end

-- QUEST_LOG_UPDATE arrives in bursts of a dozen or more for a single accepted
-- quest. Comparing on every one would walk the whole roster a dozen times for
-- one piece of news, which is what makes a naive version of this stutter on
-- every turn in. One comparison a second after the burst starts is plenty.
local function Schedule()
    if pending then return end

    if not (C_Timer and C_Timer.After) then
        M:Alert()
        return
    end

    pending = true
    C_Timer.After(1, function()
        pending = false
        M:Alert()
    end)
end

-- Wipes the debounce so every current gap is reported once more. Useful after
-- changing the threshold, when the interesting findings are all sitting inside a
-- cooldown from the old setting.
function M:ResetAlerts()
    lastAlert = {}
end

function M:StartTicker()
    if self.ticker then
        if self.ticker.Cancel then self.ticker:Cancel() end
        self.ticker = nil
    end

    -- Nothing to compare against while solo, so the ticker does not run at all
    -- rather than waking up every fifteen seconds to find an empty roster.
    if not db or db.enabled == false or not InGroup() then return end
    if not (C_Timer and C_Timer.NewTicker) then return end

    self.ticker = C_Timer.NewTicker(db.scanInterval, function() M:Alert() end)
end

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

-- Long enough that it belongs in the copyable window instead of shouting a wall
-- of text into chat.
local CHAT_LINES = 8

function M:Report()
    if db and db.enabled == false then
        ns.Print("party quest tracking is switched off in the settings.")
        return
    end

    local chainLib, rosterLib = ns.QuestChain, ns.QuestRoster

    -- Each of these is a different problem with a different fix, so each gets
    -- told apart rather than collapsing into one "no data" shrug.
    if not rosterLib or not chainLib then
        ns.Print("this needs Questie installed. Without it there is no way to read another player's quest log at all.")
        return
    end

    if not InGroup() then
        ns.Print("not in a group, so there is nobody to compare against.")
        return
    end

    local syncLib = ns.QuestSync
    local haveSync = syncLib and syncLib.Available() and next(syncLib.Positions()) ~= nil

    if rosterLib.Source() ~= "questie" and not haveSync then
        ns.Print("no quest data is arriving. Questie is not running, or its group comms are switched off in Questie's own options.")
        return
    end

    if not chainLib.Available() then
        ns.Print("Questie's quest database is still loading. Try again in a few seconds.")
        return
    end

    local members = rosterLib.Members()
    local names = {}
    for name in pairs(members) do names[#names + 1] = name end
    table.sort(names)

    if #names == 0 then
        ns.Print("nobody else in the group.")
        return
    end

    local lines = {}

    for _, name in ipairs(names) do
        local member = members[name]
        local who = Who(name, member.class)

        if not self:Tracked(name) then
            -- Named separately from "not sharing". One is a choice the user made
            -- and can undo in one click, the other is the other person's addon.
            lines[#lines + 1] = BODY .. who .. ": in the group, but not on your tracked list." .. STOP
        elseif not member.sharing then
            lines[#lines + 1] = BODY .. who .. ": not sharing. They need Questie running with its group comms on." .. STOP
        elseif member.stale then
            lines[#lines + 1] = string.format(
                "%s%s: %s %s known, but nothing new has arrived for a while, so this may be behind.%s",
                BODY, who, Paint(COUNT, member.count), Plural(member.count), STOP)
        else
            lines[#lines + 1] = string.format("%s%s: %s %s shared.%s",
                BODY, who, Paint(COUNT, member.count), Plural(member.count), STOP)
        end
    end

    local findings = self:Compare()

    lines[#lines + 1] = ""
    if #findings == 0 then
        lines[#lines + 1] = BODY .. "No quest line differences to report." .. STOP
    else
        for _, finding in ipairs(findings) do
            local line = self:Sentence(finding, finding.gap > 0)
            if not finding.exact then
                -- Worth flagging, because an inferred position is a floor rather
                -- than a measurement: they may be further on than this. The
                -- sentence has already closed its colour, so this opens its own.
                line = line .. BODY .. " (inferred from their active quest, so they may be further ahead)" .. STOP
            end
            lines[#lines + 1] = line
        end
    end

    if #lines > CHAT_LINES and ns.ShowText then
        ns.ShowText("WoidzUI party quests", Plain(table.concat(lines, "\n")))
        return
    end

    for _, line in ipairs(lines) do
        if line ~= "" then ns.Print(line) end
    end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Bound here as well as in OnEnable, because the settings page can ask who is
-- tracked while the module itself is switched off, and a nil db answered "nobody
-- is tracked" to a list the user had just filled in.
function M:OnInit(settings)
    db = settings
end

function M:OnSettingsChanged()
    self:StartTicker()
end

function M:OnEnable(settings)
    db = settings

    local events = CreateFrame("Frame")
    events:RegisterEvent("GROUP_ROSTER_UPDATE")
    events:RegisterEvent("QUEST_LOG_UPDATE")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")

    events:SetScript("OnEvent", function(_, event)
        if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
            -- Dropping the group clears the debounce. Otherwise regrouping with
            -- the same person inside the cooldown says nothing at all, which
            -- reads exactly like the feature being broken.
            if not InGroup() then
                lastAlert = {}
                -- Positions belong to a group. Carrying them into the next one
                -- would report on people who are no longer there.
                if ns.QuestSync then ns.QuestSync.Reset() end
            end
            M:StartTicker()
        end

        if InGroup() then
            if event == "QUEST_LOG_UPDATE" and ns.QuestSync then
                ns.QuestSync.Republish()
            end
            Schedule()
        end
    end)

    -- Two clients both running this addon tell each other where they really are,
    -- which is the only way to see a line somebody finished before you grouped.
    if ns.QuestSync then ns.QuestSync.Enable() end

    M.events = events
    self:StartTicker()
end
