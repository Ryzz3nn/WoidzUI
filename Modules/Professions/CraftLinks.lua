local ADDON, ns = ...

--------------------------------------------------------------------------------
-- Craft links
--
-- Shift clicking a reagent to drop its name into the auction house search is
-- standard behaviour, and the trade skill window has it: its reagent buttons
-- carry an OnClick that routes through HandleModifiedItemClick. The Craft window
-- does not. On this client enchanting, and only enchanting, still runs on that
-- older frame, which is why the same click works in blacksmithing and does
-- nothing under enchanting.
--
-- This fills the gap rather than reimplementing the behaviour. A button the
-- client already routes is left strictly alone: hooking one that works would
-- fire HandleModifiedItemClick twice and put two copies of the link in chat. So
-- the test is "has this button no OnClick at all", which is true of the Craft
-- window's reagents and false of the trade skill window's.
--------------------------------------------------------------------------------

ns.CraftLinks = {}
local C = ns.CraftLinks

-- Both frames lay out a fixed eight reagent slots.
local MAX_REAGENTS = 8

local function Attach(button, getLink)
    if not button or button.wuiLinked then return false end
    if button.GetScript and button:GetScript("OnClick") then return false end

    if button.RegisterForClicks then
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    end

    button:SetScript("OnClick", function()
        local ok, link = pcall(getLink)
        if not ok or not link then return end

        -- Does nothing at all without a modifier held, which is what a plain
        -- click on a reagent should do.
        if HandleModifiedItemClick then HandleModifiedItemClick(link) end
    end)

    button.wuiLinked = true
    return true
end

--------------------------------------------------------------------------------
-- The two frames
--------------------------------------------------------------------------------

-- Enchanting, and anything else still on the Craft API.
function C.HookCraft()
    if type(GetCraftReagentItemLink) ~= "function" then return 0 end

    local count = 0
    for i = 1, MAX_REAGENTS do
        local index = i
        local attached = Attach(_G["CraftReagent" .. index], function()
            local selected = GetCraftSelectionIndex and GetCraftSelectionIndex() or 0
            if not selected or selected <= 0 then return nil end
            return GetCraftReagentItemLink(selected, index)
        end)
        if attached then count = count + 1 end
    end

    return count
end

-- Blacksmithing and the rest. Expected to be a no-op, and kept anyway: the same
-- gap has opened and closed across flavours, and a silent no-op costs nothing
-- while a missing case costs the behaviour.
function C.HookTradeSkill()
    if type(GetTradeSkillReagentItemLink) ~= "function" then return 0 end

    local count = 0
    for i = 1, MAX_REAGENTS do
        local index = i
        local attached = Attach(_G["TradeSkillReagent" .. index], function()
            local selected = GetTradeSkillSelectionIndex and GetTradeSkillSelectionIndex() or 0
            if not selected or selected <= 0 then return nil end
            return GetTradeSkillReagentItemLink(selected, index)
        end)
        if attached then count = count + 1 end
    end

    return count
end

function C.Hook()
    return C.HookCraft() + C.HookTradeSkill()
end

--------------------------------------------------------------------------------
-- Lifecycle
--
-- Both windows are load on demand, so the buttons do not exist at login. The
-- show events are the reliable moment: by then the frame is built, and running
-- again is free because a button already carrying our handler is skipped.
--------------------------------------------------------------------------------

function C.Enable()
    if C.frame then return C.frame end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ADDON_LOADED")
    frame:RegisterEvent("CRAFT_SHOW")
    frame:RegisterEvent("TRADE_SKILL_SHOW")

    frame:SetScript("OnEvent", function(_, event, arg1)
        if event == "ADDON_LOADED" then
            if arg1 == "Blizzard_CraftUI" then C.HookCraft() end
            if arg1 == "Blizzard_TradeSkillUI" then C.HookTradeSkill() end
            return
        end

        if event == "CRAFT_SHOW" then C.HookCraft() return end
        C.HookTradeSkill()
    end)

    -- A window already open when the addon loaded, which is what a reload in
    -- front of the enchanting frame looks like.
    C.Hook()

    C.frame = frame
    return frame
end
