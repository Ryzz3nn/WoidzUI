local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Professions
--
-- Answers the only two questions a half levelled profession ever raises: what do
-- I make next, and what will the missing materials cost me.
--
-- The route itself comes from Modules/Professions/Data.lua, which is scraped
-- from Wowhead's TBC guides and shipped with the addon. It has to ship: the game
-- client cannot fetch anything from the internet, so a guide that is not in the
-- folder does not exist. That file may be missing or may cover only some
-- professions, so nothing here assumes a guide is there.
--
-- Prices come from Modules/Professions/Prices.lua, which is TSM or Auctionator
-- if either is installed and nothing at all otherwise. A plan with no prices on
-- it is still worth printing, so the two halves are kept independent.
--------------------------------------------------------------------------------

local M = ns:NewModule("professions", "Professions", {
    enabled = true,
    priceSource = "dbmarket",   -- TSM custom price string
    includeOwned = true,        -- subtract what is already in bags
    showCost = true,
})

local db

-- Long enough that it belongs in the copyable window instead of shouting a wall
-- of text into chat. Same cut as the party quest report.
local CHAT_LINES = 8

--------------------------------------------------------------------------------
-- What the player has
--
-- GetNumSkillLines walks everything in the skill window: weapon skills,
-- languages, defence, riding. Nothing in it says "this one is a profession", and
-- the header rows it is grouped under are localised, so the only reliable filter
-- on this flavour is a list of names. A guide keyed under a name counts too,
-- which means a profession added to the data file works without touching this.
--------------------------------------------------------------------------------

local PROFESSIONS = {
    ["Alchemy"] = true, ["Blacksmithing"] = true, ["Enchanting"] = true,
    ["Engineering"] = true, ["Herbalism"] = true, ["Jewelcrafting"] = true,
    ["Leatherworking"] = true, ["Mining"] = true, ["Skinning"] = true,
    ["Tailoring"] = true, ["Cooking"] = true, ["First Aid"] = true,
    ["Fishing"] = true,
}

local function Guides()
    if type(ns.ProfessionGuides) ~= "table" then return nil end
    return ns.ProfessionGuides
end

-- Case insensitive, because the name arrives from a slash command as often as
-- from the skill window. Returns the guide and the spelling the data file uses,
-- so everything printed afterwards is spelled one way.
local function FindGuide(professionName)
    local guides = Guides()
    if not guides or type(professionName) ~= "string" then return nil end

    local hit = guides[professionName]
    if hit then return hit, professionName end

    local wanted = professionName:lower()
    for name, guide in pairs(guides) do
        if name:lower() == wanted then return guide, name end
    end
    return nil
end

function M:Professions()
    local out = {}
    if type(GetNumSkillLines) ~= "function" or type(GetSkillLineInfo) ~= "function" then
        return out
    end

    local guides = Guides()

    for i = 1, (GetNumSkillLines() or 0) do
        local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
        if name and not isHeader then
            local known = PROFESSIONS[name] or (guides and FindGuide(name) ~= nil)
            if known then
                out[#out + 1] = {
                    name = name,
                    skill = rank or 0,
                    max = maxRank or 0,
                }
            end
        end
    end

    return out
end

-- Nil when the character has not learned it. That is deliberately different from
-- zero: a profession at skill 0 does not exist, and treating the two the same
-- would have the report offering to level something nobody has trained.
function M:Skill(professionName)
    if type(professionName) ~= "string" then return nil end
    local wanted = professionName:lower()

    for _, entry in ipairs(self:Professions()) do
        if entry.name:lower() == wanted then return entry.skill, entry.max end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Plan
--------------------------------------------------------------------------------

-- What is left of the route from the current skill upwards. A step already
-- passed is dropped entirely; a step the character is standing in the middle of
-- reports only the part still to make, because telling somebody at 145 to make
-- all 20 Runed Silver Rods for the 137 to 155 band is telling them to buy mats
-- they do not need.
--
-- The remainder is the share of the skill band still to cross. Crafts do not
-- come in halves and coming up short means going back to the auction house, so
-- it rounds up.
function M:Plan(professionName)
    local guide, canonical = FindGuide(professionName)
    if not guide then return nil end

    local skill = self:Skill(canonical) or 0
    local plan = {}

    for _, step in ipairs(guide.steps or {}) do
        local to = step.to or 0
        if to > skill then
            local from = step.from or 0
            local full = step.count or 1
            local left = full

            if skill > from then
                local span = to - from
                if span > 0 then
                    left = math.ceil(full * (to - skill) / span)
                end
                if left < 1 then left = 1 end
            end

            plan[#plan + 1] = {
                from = from,
                to = to,
                craft = step.craft,
                craftItemId = step.craftItemId,
                count = left,
                fullCount = full,
                partial = left < full,
                mats = step.mats or {},
                note = step.note,
            }
        end
    end

    return plan, canonical, guide
end

--------------------------------------------------------------------------------
-- Shopping list
--------------------------------------------------------------------------------

local function MatName(mat)
    if type(mat.name) == "string" and mat.name ~= "" then return mat.name end
    if type(GetItemInfo) == "function" then
        local name = GetItemInfo(mat.id)
        if name then return name end
    end
    -- Better than an empty cell. An id is still something to paste into a search.
    return "item " .. tostring(mat.id)
end

local function Owned(itemId)
    if not (db and db.includeOwned) then return 0 end
    if type(GetItemCount) ~= "function" then return 0 end
    -- true includes the bank. Mats sitting in the bank are mats already bought,
    -- and buying them twice is the mistake this whole list exists to avoid.
    return GetItemCount(itemId, true) or 0
end

-- Every mat across the remaining plan, one row each, dearest first. Returns the
-- rows, the total in copper, and how many rows nothing could price: that count
-- has to travel with the total, because a total that silently skipped three
-- unpriced mats reads as the whole answer when it is not.
function M:ShoppingList(professionName)
    local plan = self:Plan(professionName)
    if not plan then return nil end

    -- A fresh scan asks for fresh prices. The cache exists so one list does not
    -- hit TSM once per step for the same dust, not so yesterday's numbers stay.
    if ns.Prices and ns.Prices.ClearCache then ns.Prices.ClearCache() end

    local rows, byId = {}, {}

    for _, step in ipairs(plan) do
        for _, mat in ipairs(step.mats or {}) do
            if mat.id then
                local row = byId[mat.id]
                if not row then
                    row = { id = mat.id, name = MatName(mat), need = 0, have = 0, buy = 0 }
                    byId[mat.id] = row
                    rows[#rows + 1] = row
                end
                row.need = row.need + (mat.each or 1) * step.count
            end
        end
    end

    local total, unknown = 0, 0

    for _, row in ipairs(rows) do
        row.have = Owned(row.id)
        row.buy = math.max(0, row.need - row.have)

        local unit = ns.Prices and ns.Prices.Get(row.id) or nil
        if unit then
            row.unit = unit
            row.cost = row.buy * unit
            total = total + row.cost
        else
            unknown = unknown + 1
        end
    end

    table.sort(rows, function(a, b)
        -- Unpriced rows sink rather than sort as free, because "costs nothing"
        -- and "nobody knows" are not the same row and must not read the same.
        local ac, bc = a.cost, b.cost
        if ac and bc then
            if ac ~= bc then return ac > bc end
        elseif ac or bc then
            return ac ~= nil
        end
        -- Ties break on something fixed, so the same list twice comes out in the
        -- same order both times.
        if a.need ~= b.need then return a.need > b.need end
        return a.id < b.id
    end)

    return rows, total, unknown
end

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

local function Plural(count, word)
    if count == 1 then return word end
    return word .. "s"
end

-- Prices.lua is a separate file and a separate agent's worth of things that can
-- go wrong, so the report never assumes it loaded.
local function Money(copper)
    if ns.Prices and ns.Prices.Format then return ns.Prices.Format(copper, true) end
    return tostring(math.floor((copper or 0) + 0.5)) .. "c"
end

local function SourceLine()
    local prices = ns.Prices
    if not prices or not prices.Available() then
        return "No price source. Install TradeSkillMaster or Auctionator and run one auction house scan, then this list carries costs."
    end
    if prices.Source() == "tsm" then
        return "Prices from TSM (" .. ((db and db.priceSource) or "dbmarket") .. ")."
    end
    return "Prices from Auctionator."
end

-- One profession's worth of lines, appended to whatever is already there, so the
-- all professions case and the single profession case build the same text.
function M:Lines(professionName, out)
    out = out or {}

    local plan, canonical, guide = self:Plan(professionName)
    if not plan then
        out[#out + 1] = "No levelling guide for " .. tostring(professionName)
            .. " is installed. The guides ship in Modules\\Professions\\Data.lua."
        return out
    end

    local skill, max = self:Skill(canonical)
    local cap = guide.skillMax or max or 375

    if not skill then
        out[#out + 1] = canonical .. ": not learned on this character."
        return out
    end

    if #plan == 0 then
        out[#out + 1] = string.format("%s: %d of %d. Nothing left in the guide.", canonical, skill, cap)
        return out
    end

    out[#out + 1] = string.format("%s: %d of %d, %d to go.", canonical, skill, cap, cap - skill)

    for _, step in ipairs(plan) do
        local line = string.format("  %d to %d: make %d x %s",
            step.from, step.to, step.count, tostring(step.craft or "something"))
        if step.partial then
            line = line .. string.format(" (%d of %d left)", step.count, step.fullCount)
        end
        if step.note then
            line = line .. " - " .. step.note
        end
        out[#out + 1] = line
    end

    local rows, total, unknown = self:ShoppingList(canonical)
    if not rows or #rows == 0 then return out end

    local showCost = not db or db.showCost ~= false

    out[#out + 1] = ""
    out[#out + 1] = "Materials still to buy:"

    for _, row in ipairs(rows) do
        local line
        if row.buy > 0 then
            line = string.format("  %s x%d", row.name, row.buy)
        else
            line = string.format("  %s: none, you already have %d", row.name, row.need)
        end

        if db and db.includeOwned and row.have > 0 and row.buy > 0 then
            line = line .. string.format(" (need %d, have %d)", row.need, row.have)
        end

        if showCost and row.buy > 0 then
            if row.cost then
                line = line .. "  " .. Money(row.cost)
            else
                line = line .. "  price unknown"
            end
        end

        out[#out + 1] = line
    end

    if showCost then
        local line = "Total: " .. Money(total)
        if unknown > 0 then
            line = line .. string.format(", plus %d %s nothing could price",
                unknown, Plural(unknown, "material"))
        end
        out[#out + 1] = line
    end

    if guide.source then
        out[#out + 1] = "Guide: " .. guide.source
    end

    return out
end

function M:Report(professionName)
    if db and db.enabled == false then
        ns.Print("the professions module is switched off in the settings.")
        return
    end

    if not Guides() then
        ns.Print("no profession guides are loaded. Modules\\Professions\\Data.lua is missing from the addon folder, and the client cannot fetch it: it has to ship with the addon.")
        return
    end

    local out = {}
    local showCost = not db or db.showCost ~= false
    if showCost then out[#out + 1] = SourceLine() end

    if professionName and professionName ~= "" then
        self:Lines(professionName, out)
    else
        local mine = self:Professions()
        local covered = 0

        for _, entry in ipairs(mine) do
            if FindGuide(entry.name) then
                covered = covered + 1
                if covered > 1 then out[#out + 1] = "" end
                self:Lines(entry.name, out)
            end
        end

        if covered == 0 then
            if #mine == 0 then
                ns.Print("no professions learned on this character yet.")
            else
                -- Naming them matters. "No guides" alone reads as the feature
                -- being broken when it is simply a guide nobody has scraped yet.
                local names = {}
                for _, entry in ipairs(mine) do names[#names + 1] = entry.name end
                ns.Print("no guide is installed for " .. table.concat(names, ", ") .. ".")
            end
            return
        end
    end

    if #out > CHAT_LINES and ns.ShowText then
        ns.ShowText("WoidzUI professions", table.concat(out, "\n"))
        return
    end

    for _, line in ipairs(out) do
        if line ~= "" then ns.Print(line) end
    end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Bound here as well as in OnEnable, because the settings page asks this module
-- for the character's professions while it is switched off, and a nil db there
-- is how the party quest page once answered "nobody is tracked" to a list the
-- user had just filled in.
function M:OnInit(settings)
    db = settings
end

function M:OnEnable(settings)
    db = settings
end

-- Changing the price source changes what every cached number meant, so the
-- cache goes rather than being trusted into the next scan.
function M:OnSettingsChanged(settings)
    if settings then db = settings end
    if ns.Prices and ns.Prices.ClearCache then ns.Prices.ClearCache() end
end
