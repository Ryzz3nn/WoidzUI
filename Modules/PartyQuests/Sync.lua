local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Party quest sync
--
-- Questie broadcasts a player's ACTIVE quests and nothing else. That is enough to
-- place someone who is working a quest line right now, because prequests gate a
-- chain, but it says nothing at all about a line they finished before you grouped
-- up: no active quest, no signal, no comparison. Joining a friend who is four
-- quests further on therefore looked identical to joining one who is level with
-- you, which is the case that matters most.
--
-- Nothing can fix that from Questie's data, so this fills the gap directly: two
-- clients both running WoidzUI tell each other where they actually are. Whoever
-- is missing it still gets the Questie inference, so the feature degrades rather
-- than breaking.
--
-- The exchange is deliberately scoped. Rather than shipping a whole completed
-- quest history, which is thousands of ids, a client asks only about the handful
-- of chains it is personally working on, and gets back one number per chain.
--------------------------------------------------------------------------------

ns.QuestSync = {}
local S = ns.QuestSync

local PREFIX = "WoidzUIPQ"

-- An addon message body is capped at 255 characters. Staying well under it leaves
-- room for the ids to be longer than expected without silently truncating.
local MAX_BODY = 220

-- No point asking about more lines than a quest log can hold, and a cap is what
-- stops a malformed or hostile message turning into unbounded work.
local MAX_ROOTS = 40

-- Two asks inside this window is the same ask. Group roster churn and quest log
-- churn both fire in bursts, and each burst must cost one message, not twenty.
local ASK_THROTTLE = 10

local positions = {}   -- [player] = { [chainRoot] = index }
local lastHeard = {}   -- [player] = GetTime of their last answer
local answerSet = {}   -- chain roots anyone has asked us about
local lastAsk = 0
local frame

--------------------------------------------------------------------------------
-- Plumbing
--------------------------------------------------------------------------------

local function Now()
    return (GetTime and GetTime()) or 0
end

-- Coerced to a real boolean. A bare `C_ChatInfo and ...` chain yields nil when
-- the table is missing, and a caller testing for false would not catch it.
local function CanSend()
    if not C_ChatInfo then return false end
    if type(C_ChatInfo.SendAddonMessage) ~= "function" then return false end
    if type(C_ChatInfo.RegisterAddonMessagePrefix) ~= "function" then return false end
    return true
end

function S.Available()
    return CanSend() and frame ~= nil
end

-- Party unless the group is actually a raid, because sending to PARTY in a raid
-- reaches nobody.
local function Channel()
    if ((GetNumGroupMembers and GetNumGroupMembers()) or 0) <= 1 then return nil end
    if IsInRaid and IsInRaid() then return "RAID" end
    return "PARTY"
end

local function Send(body)
    local channel = Channel()
    if not channel or not CanSend() then return false end

    pcall(C_ChatInfo.SendAddonMessage, PREFIX, body, channel)
    return true
end

-- One list, split so no single message runs past the cap.
local function SendChunked(tag, pieces)
    if #pieces == 0 then return end

    local batch = {}
    local length = 0

    local function flush()
        if #batch == 0 then return end
        Send(tag .. "|" .. table.concat(batch, ","))
        batch, length = {}, 0
    end

    for _, piece in ipairs(pieces) do
        -- The two accounts for the separator and the tag, so the estimate errs on
        -- the side of sending one message too many rather than one too long.
        if length + #piece + 2 > MAX_BODY then flush() end
        batch[#batch + 1] = piece
        length = length + #piece + 1
    end

    flush()
end

--------------------------------------------------------------------------------
-- Answering
--------------------------------------------------------------------------------

-- Where this character actually is in a line, counting its own completed quests.
-- This is the number a party member cannot work out for themselves, and the whole
-- reason this file exists.
local function MyIndex(root)
    local chainLib, rosterLib = ns.QuestChain, ns.QuestRoster
    if not chainLib or not rosterLib then return nil end

    local chain = chainLib.Info(root)
    if not chain then return nil end

    local me = rosterLib.Me()
    local best = 0

    for i = 1, #chain.ids do
        local id = chain.ids[i]
        if me.quests[id] or me.complete[id] then best = i end
    end

    if best == 0 then return nil end
    return best
end

local function Answer(roots)
    local pieces = {}

    for _, root in ipairs(roots) do
        local index = MyIndex(root)
        -- A line this character has never touched is left out rather than sent as
        -- a zero. Silence and "not started" are the same thing to the asker, and
        -- leaving it out keeps the message shorter.
        if index then
            pieces[#pieces + 1] = root .. ":" .. index
        end
    end

    SendChunked("a", pieces)
end

--------------------------------------------------------------------------------
-- Asking
--------------------------------------------------------------------------------

-- roots is whatever the caller cares about, which in practice is the lines this
-- character is working on. Anything a peer has finished in one of those is the
-- gap worth knowing about.
function S.Ask(roots, force)
    if not S.Available() then return false end
    if type(roots) ~= "table" or #roots == 0 then return false end

    local now = Now()
    if not force and (now - lastAsk) < ASK_THROTTLE then return false end
    lastAsk = now

    local pieces = {}
    for i = 1, math.min(#roots, MAX_ROOTS) do
        pieces[#pieces + 1] = tostring(roots[i])
    end

    SendChunked("q", pieces)
    return true
end

-- Our own answer changes the moment we hand a quest in, so anyone who has already
-- asked gets the correction without having to ask again.
function S.Republish()
    local roots = {}
    for root in pairs(answerSet) do roots[#roots + 1] = root end
    if #roots == 0 then return false end

    Answer(roots)
    return true
end

--------------------------------------------------------------------------------
-- Receiving
--
-- Everything below is parsing text sent by another player's client, so it is
-- treated as hostile: numbers only, hard caps on how much is accepted, and
-- anything that does not parse is dropped rather than guessed at.
--------------------------------------------------------------------------------

local function ParseQuery(body)
    local roots, count = {}, 0

    for token in body:gmatch("[^,]+") do
        local root = tonumber(token)
        if root and root > 0 and root == math.floor(root) then
            count = count + 1
            if count > MAX_ROOTS then break end
            roots[#roots + 1] = root
        end
    end

    return roots
end

local function ParseAnswer(body)
    local out, count = {}, 0

    for token in body:gmatch("[^,]+") do
        local root, index = token:match("^(%d+):(%d+)$")
        root, index = tonumber(root), tonumber(index)
        if root and index and root > 0 and index > 0 then
            count = count + 1
            if count > MAX_ROOTS then break end
            out[root] = index
        end
    end

    return out
end

local function OnMessage(prefix, message, channel, sender)
    if prefix ~= PREFIX then return end
    if channel ~= "PARTY" and channel ~= "RAID" then return end
    if type(message) ~= "string" then return end

    local rosterLib = ns.QuestRoster
    local name = rosterLib and rosterLib.ShortName and rosterLib.ShortName(sender)
    if not name then return end

    -- Our own broadcast comes straight back to us.
    local me = rosterLib.ShortName(UnitName and UnitName("player"))
    if name == me then return end

    local tag, body = message:match("^(%a)|(.+)$")
    if not tag then return end

    if tag == "q" then
        local roots = ParseQuery(body)
        if #roots == 0 then return end

        -- Remembered so a later quest turn in can correct what was said here.
        for _, root in ipairs(roots) do answerSet[root] = true end

        Answer(roots)
        return
    end

    if tag == "a" then
        local answers = ParseAnswer(body)

        positions[name] = positions[name] or {}
        for root, index in pairs(answers) do
            positions[name][root] = index
        end
        lastHeard[name] = Now()

        -- A better number just arrived, so whatever is on screen is now stale.
        local module = ns.modules and ns.modules.partyquests
        if module and module.OnSyncUpdate then module:OnSyncUpdate(name) end
    end
end

--------------------------------------------------------------------------------
-- Public state
--------------------------------------------------------------------------------

-- Exact positions reported by a peer, or nil when that peer has told us nothing.
function S.Positions(player)
    if player then return positions[player] end
    return positions
end

function S.HeardFrom(player)
    return lastHeard[player]
end

function S.Forget(player)
    positions[player] = nil
    lastHeard[player] = nil
end

function S.Reset()
    positions = {}
    lastHeard = {}
    answerSet = {}
    lastAsk = 0
end

function S.Enable()
    if frame then return true end
    if not CanSend() then return false end

    pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)

    frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, event, prefix, message, channel, sender)
        if event ~= "CHAT_MSG_ADDON" then return end
        -- One bad message from one peer must not take the handler down for
        -- everyone else in the group.
        pcall(OnMessage, prefix, message, channel, sender)
    end)

    S.frame = frame
    return true
end
