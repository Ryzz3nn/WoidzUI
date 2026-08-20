local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Party quest roster
--
-- No WoW API reads another player's quest log. None. The only way that data
-- exists on this client is if their client chose to send it, which is why this
-- reads Questie's received comms rather than asking the game: Questie already
-- broadcasts its active quest log to the party, and the people this feature is
-- for are already running it. Inventing a second protocol would mean nobody to
-- talk to.
--
-- The consequence is worth stating plainly, because the consumer has to report
-- it: a party member without Questie is not "level with you", they are unknown,
-- and those two have to look different on screen.
--------------------------------------------------------------------------------

ns.QuestRoster = {}
local R = ns.QuestRoster

-- Two minutes. Questie broadcasts when a quest changes rather than on a clock,
-- so a quiet stretch of killing things is perfectly normal and a tight window
-- would flag a healthy client as gone. Long enough to ride that out, short
-- enough to notice someone whose addon has actually stopped talking.
local STALE_AFTER = 120

--------------------------------------------------------------------------------
-- Questie access
--------------------------------------------------------------------------------

local function ImportModule(name)
    if not QuestieLoader or type(QuestieLoader.ImportModule) ~= "function" then return nil end

    local ok, imported = pcall(QuestieLoader.ImportModule, QuestieLoader, name)
    if ok and type(imported) == "table" then return imported end
    return nil
end

-- Comms counts as reachable only once the table the data lands in exists. The
-- module itself appears well before that.
local function Comms()
    local comms = ImportModule("QuestieComms")
    if comms and type(comms.remoteQuestLogs) == "table" then return comms end
    return nil
end

function R.Available()
    return Comms() ~= nil
end

function R.Source()
    return Comms() and "questie" or "none"
end

--------------------------------------------------------------------------------
-- Names
--
-- Comms names carry a realm on them once the group is cross realm, unit names do
-- not. Every comparison goes through here so the two sides can actually meet,
-- and so one player never shows up twice under two spellings.
--------------------------------------------------------------------------------

local function ShortName(name)
    if type(name) ~= "string" or name == "" then return nil end

    local short = name:match("^([^%-]+)")
    if not short or short == "" then return nil end

    -- Case folded to the one shape WoW itself uses for character names. The realm
    -- strip alone was not enough: a name typed into the tracked list is
    -- capitalised, and a name arriving over comms is whatever the sender's client
    -- put in the packet, so without this the two could disagree and a tracked
    -- friend would silently never match.
    return short:sub(1, 1):upper() .. short:sub(2):lower()
end

-- Exported because the sync file has to fold sender names the exact same way, and
-- two nearly identical helpers would eventually drift apart.
R.ShortName = ShortName

--------------------------------------------------------------------------------
-- The group
--------------------------------------------------------------------------------

-- The real roster is the authority, never Questie's cache. Questie holds a
-- player's rows for a while after they leave, and telling the user they are
-- behind someone who walked off ten minutes ago is worse than saying nothing.
local function GroupUnits()
    local units = {}

    local total = (GetNumGroupMembers and GetNumGroupMembers()) or 0
    if total <= 1 then return units end

    if IsInRaid and IsInRaid() then
        for i = 1, total do units[#units + 1] = "raid" .. i end
    else
        -- GetNumGroupMembers counts the player in a party, so the party units run
        -- one short of it. In a raid the player is one of the raid units instead,
        -- and gets filtered out by unit identity below.
        for i = 1, total - 1 do units[#units + 1] = "party" .. i end
    end

    return units
end

function R.Members()
    local members = {}
    local me = ShortName(UnitName and UnitName("player"))

    for _, unit in ipairs(GroupUnits()) do
        local isMe = UnitIsUnit and UnitIsUnit(unit, "player")
        if not isMe then
            local name = ShortName(UnitName and UnitName(unit))
            if name and name ~= me and not members[name] then
                -- Present but silent until proven otherwise. A member who never
                -- gains a quest stays sharing = false, which is exactly the state
                -- the consumer needs to report differently from "no gap".
                members[name] = {
                    quests = {},
                    count = 0,
                    class = nil,
                    lastSeen = nil,
                    stale = false,
                    sharing = false,
                }
            end
        end
    end

    local comms = Comms()
    if not comms then return members end

    -- remoteQuestLogs is keyed quest first and player second, which is the wrong
    -- way round for asking what one player holds. One pass inverts it, and one
    -- pass is enough: a party is at most four other people.
    for questId, players in pairs(comms.remoteQuestLogs) do
        if type(questId) == "number" and type(players) == "table" then
            for rawName in pairs(players) do
                local member = members[ShortName(rawName) or ""]
                if member and not member.quests[questId] then
                    member.quests[questId] = true
                    member.count = member.count + 1
                    member.sharing = true
                end
            end
        end
    end

    if type(comms.remotePlayerTimes) == "table" then
        for rawName, stamp in pairs(comms.remotePlayerTimes) do
            local member = members[ShortName(rawName) or ""]
            if member and type(stamp) == "number" then
                -- Cross realm and same realm spellings of one player can both
                -- carry a stamp. The newer one is the one that matters.
                if not member.lastSeen or stamp > member.lastSeen then
                    member.lastSeen = stamp
                end
            end
        end
    end

    if type(comms.remotePlayerClasses) == "table" then
        for rawName, class in pairs(comms.remotePlayerClasses) do
            local member = members[ShortName(rawName) or ""]
            if member then member.class = class end
        end
    end

    local now = (GetTime and GetTime()) or 0
    for _, member in pairs(members) do
        member.stale = (member.lastSeen ~= nil) and ((now - member.lastSeen) > STALE_AFTER) or false
    end

    return members
end

--------------------------------------------------------------------------------
-- The local player
--------------------------------------------------------------------------------

-- Fallback for a client with no Questie. Which of these exist differs between
-- Classic flavours, so every one is tested before it is called rather than
-- assumed from the interface number.
local function LocalQuestIds()
    local quests = {}

    local count = (GetNumQuestLogEntries and GetNumQuestLogEntries()) or 0
    for i = 1, count do
        local title, _, _, isHeader, _, _, _, questID
        if GetQuestLogTitle then
            title, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(i)
        end

        -- Zone headers share the index space with real quests and have no id.
        if title and not isHeader then
            local id = (type(questID) == "number" and questID > 0) and questID or nil

            if not id and C_QuestLog and C_QuestLog.GetQuestIDForLogIndex then
                id = C_QuestLog.GetQuestIDForLogIndex(i)
            end

            if not id and GetQuestLink then
                local link = GetQuestLink(i)
                if link then id = tonumber(link:match("quest:(%d+)")) end
            end

            if type(id) == "number" and id > 0 then quests[id] = true end
        end
    end

    return quests
end

function R.Me()
    local active, complete = {}, {}

    local player = ImportModule("QuestiePlayer")
    if player and type(player.currentQuestlog) == "table" then
        for questId in pairs(player.currentQuestlog) do
            if type(questId) == "number" then active[questId] = true end
        end
    else
        active = LocalQuestIds()
    end

    -- Questie is the only cheap source of "quests already handed in". The client
    -- will answer for one quest at a time through the server, which is no use for
    -- walking a chain, so without Questie this stays empty rather than guessed.
    -- The consumer can still place the player from their active quest.
    if Questie and Questie.db and Questie.db.char and type(Questie.db.char.complete) == "table" then
        for questId in pairs(Questie.db.char.complete) do
            if type(questId) == "number" then complete[questId] = true end
        end
    end

    return { quests = active, complete = complete }
end
