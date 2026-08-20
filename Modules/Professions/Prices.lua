local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Prices
--
-- What a material costs at the auction house. The game client has no price API
-- at all, so this is entirely other people's addons: TradeSkillMaster where it
-- is installed, Auctionator otherwise. Neither is a dependency, and a shopping
-- list with no prices on it is still a useful shopping list, so every reach into
-- them is guarded and "no price source" is a first class answer rather than an
-- error.
--
-- TSM is preferred because its custom price strings let the user pick what
-- "price" even means. dbmarket is a fortnight of observed sales, dbminbuyout is
-- what is on the auction house right now, and those two disagree by a lot on a
-- thin server.
--------------------------------------------------------------------------------

ns.Prices = {}
local P = ns.Prices

-- Auctionator hands out prices per caller so it can tell who asked. Any stable
-- string does, and it shows up in Auctionator's own diagnostics as this.
local CALLER = "WoidzUI"

local DEFAULT_SOURCE = "dbmarket"

-- One scan's worth of answers. A shopping list walks the same mat once per step
-- it appears in, and TSM's evaluator is not free, so the second and later reads
-- of Strange Dust in one pass come from here.
local cache = {}

-- The invalid price string warning is worth saying once and unbearable a hundred
-- times, which is exactly what a full scan would do without this.
local warnedInvalid = false

--------------------------------------------------------------------------------
-- Sources
--------------------------------------------------------------------------------

-- Both addons appear in _G long before they are ready to answer, so presence of
-- the table is not enough: the functions actually called are what gets tested.
local function TSM()
    if type(TSM_API) ~= "table" then return nil end
    if type(TSM_API.GetCustomPriceValue) ~= "function" then return nil end
    if type(TSM_API.ToItemString) ~= "function" then return nil end
    return TSM_API
end

local function Auc()
    if type(Auctionator) ~= "table" then return nil end
    local api = Auctionator.API and Auctionator.API.v1
    if type(api) ~= "table" then return nil end
    if type(api.GetAuctionPriceByItemID) ~= "function" then return nil end
    return api
end

function P.Source()
    if TSM() then return "tsm" end
    if Auc() then return "auctionator" end
    return "none"
end

function P.Available()
    return P.Source() ~= "none"
end

--------------------------------------------------------------------------------
-- Lookup
--------------------------------------------------------------------------------

local function Configured()
    local settings = ns.db and ns.db.professions
    local str = settings and settings.priceSource
    if type(str) ~= "string" or str == "" then return DEFAULT_SOURCE end
    return str
end

-- TSM throws on a price string it cannot parse rather than returning nil, and
-- the string comes from a setting the user can put anything into, so validating
-- first is the difference between a bad setting costing one warning and it
-- taking down every scan.
local function PriceString(api)
    local str = Configured()
    if type(api.IsCustomPriceValid) ~= "function" then return str end

    local ok, valid = pcall(api.IsCustomPriceValid, str)
    if ok and valid then return str end

    if not warnedInvalid then
        warnedInvalid = true
        ns.Print('the TSM price source "' .. tostring(str) ..
            '" is not something TSM understands, so ' .. DEFAULT_SOURCE ..
            " is being used instead. Pick another one on the Professions page.")
    end
    return DEFAULT_SOURCE
end

local function FromTSM(api, itemId)
    -- Every one of these is a pcall on purpose. TSM raises rather than returns
    -- on anything it dislikes, including an item string it cannot build, and one
    -- unpriceable mat must never end a shopping list halfway through.
    local ok, itemString = pcall(api.ToItemString, "item:" .. itemId)
    if not ok or not itemString then return nil end

    local priced, value = pcall(api.GetCustomPriceValue, PriceString(api), itemString)
    if not priced then return nil end
    return value
end

local function FromAuctionator(api, itemId)
    local ok, value = pcall(api.GetAuctionPriceByItemID, CALLER, itemId)
    if not ok then return nil end
    return value
end

-- Copper, or nil when nothing knows. Zero is treated as nothing knows: both
-- addons return 0 for an item they have never seen on the auction house, and a
-- free Fel Iron Bar is a worse answer than an honest unknown.
function P.Get(itemId)
    itemId = tonumber(itemId)
    if not itemId then return nil end

    local hit = cache[itemId]
    if hit ~= nil then
        if hit == false then return nil end
        return hit
    end

    local value
    local tsm = TSM()
    if tsm then
        value = FromTSM(tsm, itemId)
    else
        local auc = Auc()
        if auc then value = FromAuctionator(auc, itemId) end
    end

    if type(value) ~= "number" or value <= 0 then value = nil end

    -- false rather than nil, so a known miss is remembered for the rest of the
    -- scan instead of being asked for again on every step that uses the mat.
    cache[itemId] = value or false
    return value
end

function P.ClearCache()
    cache = {}
    warnedInvalid = false
end

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

-- Coin colours, the three the game itself paints a money amount with: gold
-- yellow, silver grey, copper brown. Each denomination carries its own colour
-- and closes it again, so a price reads as coins at a glance instead of as a
-- string of numbers and letters.
local COIN = {
    g = "|cffffd700",
    s = "|cffc7c7cf",
    c = "|cffeda55f",
}
local STOP = "|r"

-- Empty denominations are dropped, because "12g 0s 0c" is three numbers where
-- one was said. Zero still has to render as something, so it renders as 0c.
--
-- colored adds the coin colours. It is off by default because the plain form
-- is what a copyable report and any width measurement wants; the on screen
-- guide and the chat report ask for the coloured one.
function P.Format(copper, colored)
    copper = tonumber(copper)
    if not copper then return "unknown" end
    if copper < 0 then copper = 0 end

    copper = math.floor(copper + 0.5)

    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local rest = copper % 100

    local function Part(value, suffix)
        if not colored then return value .. suffix end
        return COIN[suffix] .. value .. suffix .. STOP
    end

    local parts = {}
    if gold > 0 then parts[#parts + 1] = Part(gold, "g") end
    if silver > 0 then parts[#parts + 1] = Part(silver, "s") end
    if rest > 0 or #parts == 0 then parts[#parts + 1] = Part(rest, "c") end

    return table.concat(parts, " ")
end

-- Convenience wrapper, so a call site reads as what it wants rather than as a
-- true flag with no name on it.
function P.FormatColored(copper)
    return P.Format(copper, true)
end
