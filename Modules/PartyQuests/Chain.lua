local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Quest chains
--
-- Answering "how far along this quest line is that player" needs the shape of
-- the line, which means a static quest database. Questie already ships the whole
-- thing locally, chain links included, so this file only reads. Nothing here
-- goes near the network: the game client cannot make web requests at all, and
-- with Questie installed it has no reason to.
--------------------------------------------------------------------------------

ns.QuestChain = {}
local C = ns.QuestChain

-- Every walk is bounded. Questie's corrections data does contain the occasional
-- loop, and an unbounded follow of a bad link would hang the client rather than
-- misreport a number, which is much the worse failure.
local MAX_WALK = 64

local handle       -- QuestieDB, resolved lazily
local chains = {}  -- [rootId] = ordered ids
local byQuest = {} -- [questId] = { ids, index }, or false when unresolvable

--------------------------------------------------------------------------------
-- Database access
--------------------------------------------------------------------------------

-- QuestieDB gains QueryQuestSingle only once the database has finished
-- compiling, so a handle grabbed at load time is a table with nothing useful on
-- it. Re-import until the function is actually there instead of caching the
-- first thing Questie hands over.
local function DB()
    if handle and type(handle.QueryQuestSingle) == "function" then return handle end
    handle = nil

    if not QuestieLoader or type(QuestieLoader.ImportModule) ~= "function" then return nil end

    local ok, imported = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
    if not ok or type(imported) ~= "table" then return nil end
    if type(imported.QueryQuestSingle) ~= "function" then return nil end

    handle = imported
    return handle
end

function C.Available()
    return DB() ~= nil
end

-- QueryQuestSingle is a plain function rather than a method, and it is reading
-- compiled binary data, so a bad id can throw. pcall keeps a single odd quest
-- from taking the comparison down with it.
local function Field(questId, key)
    local db = DB()
    if not db then return nil end

    local ok, value = pcall(db.QueryQuestSingle, questId, key)
    if not ok then return nil end
    return value
end

function C.Name(questId)
    if type(questId) ~= "number" then return nil end

    local name = Field(questId, "name")
    if type(name) == "string" and name ~= "" then return name end
    return nil
end

--------------------------------------------------------------------------------
-- Walking the links
--------------------------------------------------------------------------------

-- One step back towards the start of the line. preQuestSingle means any one of
-- the listed quests opens this one, preQuestGroup means all of them are needed.
-- Either way the first entry is taken as the parent: real chains are
-- overwhelmingly linear, and where they do branch there is no ordering in the
-- data to rank the branches by, so a consistent choice beats a clever one.
local function Parent(questId)
    local single = Field(questId, "preQuestSingle")
    if type(single) == "table" and type(single[1]) == "number" then return single[1] end

    local group = Field(questId, "preQuestGroup")
    if type(group) == "table" and type(group[1]) == "number" then return group[1] end

    return nil
end

local function Next(questId)
    local nextId = Field(questId, "nextQuestInChain")
    if type(nextId) == "number" and nextId > 0 then return nextId end
    return nil
end

local function FindRoot(questId)
    local seen = { [questId] = true }
    local current = questId

    for _ = 1, MAX_WALK do
        local parent = Parent(current)
        -- A link back into something already walked is a loop in the data. Stop
        -- on the last quest that made sense rather than going round again.
        if not parent or seen[parent] then return current end
        seen[parent] = true
        current = parent
    end

    return current
end

local function Walk(rootId)
    local ids = { rootId }
    local seen = { [rootId] = true }
    local current = rootId

    for _ = 1, MAX_WALK - 1 do
        local nextId = Next(current)
        if not nextId or seen[nextId] then break end
        seen[nextId] = true
        ids[#ids + 1] = nextId
        current = nextId
    end

    return ids
end

--------------------------------------------------------------------------------
-- Lookup
--------------------------------------------------------------------------------

-- Callers get a fresh view rather than the memo itself. The ids table is shared
-- by every quest in the line, which is the point of memoising it, but the index
-- belongs to the quest that was asked about. Handing out one table with a
-- mutated index is the obvious way to get this wrong.
local function View(entry)
    return {
        ids = entry.ids,
        index = entry.index,
        length = #entry.ids,
        root = entry.ids[1],
    }
end

function C.Info(questId)
    if type(questId) ~= "number" then return nil end

    local cached = byQuest[questId]
    if cached ~= nil then
        if cached == false then return nil end
        return View(cached)
    end

    if not C.Available() then return nil end

    -- A quest the database has never heard of is not a chain of one, it is a
    -- question with no answer. Saying nil keeps the caller from reporting a
    -- position it has no basis for. Remembered as false so the walk is not
    -- retried on every scan.
    if not C.Name(questId) then
        byQuest[questId] = false
        return nil
    end

    local rootId = FindRoot(questId)
    local ids = chains[rootId]
    if not ids then
        ids = Walk(rootId)
        chains[rootId] = ids
    end

    -- Recording every member is what makes the next lookup free, and a party of
    -- five working the same chain hits this path once rather than five times.
    for i = 1, #ids do
        byQuest[ids[i]] = { ids = ids, index = i }
    end

    local entry = byQuest[questId]
    if not entry then
        -- The walk back found a root whose walk forward never came through this
        -- quest again, so the two directions disagree. Rather than report a
        -- position out of the wrong line, treat the quest as standing alone.
        entry = { ids = { questId }, index = 1 }
        byQuest[questId] = entry
    end

    return View(entry)
end

function C.Reset()
    handle = nil
    chains = {}
    byQuest = {}
end
