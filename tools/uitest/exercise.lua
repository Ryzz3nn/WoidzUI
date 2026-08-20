-- Fires the bootstrap events, then opens and drives everything the settings
-- window builds.
local ns = _G.__NS
local out = {}
local function Try(name, fn)
    local ok, err = pcall(fn)
    out[#out + 1] = (ok and "PASS  " or "FAIL  ") .. name .. (ok and "" or ("  ->  " .. tostring(err)))
end

-- Every frame that registered for an event kept its OnEvent script, so the two
-- bootstrap events are delivered by hand.
local function Fire(event, arg1)
    for _, f in ipairs(_G.__FRAMES) do
        local scripts = rawget(f, "scripts")
        local fn = scripts and scripts.OnEvent
        if fn then
            local ok, err = pcall(fn, f, event, arg1)
            if not ok then error(event .. ": " .. tostring(err), 0) end
        end
    end
end

Try("ADDON_LOADED builds saved variables and inits every module", function()
    _G.WoidzUIDB = {}
    Fire("ADDON_LOADED", "WoidzUI")
    assert(ns.db, "no db")
    assert(#ns.moduleOrder > 0, "no modules registered")
end)

Try("PLAYER_LOGIN enables every module and builds the settings window", function()
    Fire("PLAYER_LOGIN")
    assert(_G.WoidzUIConfigFrame, "settings window was never built")
end)

Try("style kit exposes the palette and every widget", function()
    local S = ns.Style
    for _, k in ipairs({ "Panel", "Button", "Check", "Slider", "Tab", "Header",
                         "CloseButton", "TickBox", "ScrollBar", "EditBox",
                         "RowMeter", "SetRowMeter", "Gradient", "Track" }) do
        assert(type(S[k]) == "function", "Style." .. k .. " is missing")
    end
    assert(ns.C.accent[1] > ns.C.accent[2] and ns.C.accent[2] > ns.C.accent[3],
        "the accent is not a warm hue")
end)

Try("every settings page shows and refreshes", function()
    local win = _G.WoidzUIConfigFrame
    assert(#win.pages == 6, "expected six pages, got " .. tostring(#win.pages))
    for i = 1, #win.pages do
        ns.ShowConfigPage(i)
        local page = win.pages[i]
        local scripts = rawget(page, "scripts")
        if scripts and scripts.OnShow then scripts.OnShow(page) end
    end
end)

Try("the live tab is the only one wearing the sill", function()
    local win = _G.WoidzUIConfigFrame
    ns.ShowConfigPage(3)
    local lit = 0
    for i, tab in ipairs(win.tabs) do
        if tab.active then
            lit = lit + 1
            assert(i == 3, "the wrong tab is active")
        end
    end
    assert(lit == 1, "expected exactly one active tab, got " .. lit)
end)

Try("checkboxes toggle and repaint", function()
    local state = false
    local cb = ns.Style.Check(UIParent, "Enable this module", "tip",
        function() return state end,
        function(v) state = v end)
    cb.scripts.OnClick(cb)
    assert(state == true, "click did not set the value")
    cb.scripts.OnEnter(cb)
    cb.scripts.OnLeave(cb)
    cb:SetChecked(false)
    assert(state == false, "SetChecked did not write through")
    assert(cb:GetChecked() == false)
end)

Try("sliders paint their fill and write their value", function()
    local v = 250
    local s = ns.Style.Slider(UIParent, "Guide panel width", 180, 460, 10,
        function() return v end,
        function(nv) v = nv end)
    s.slider.scripts.OnValueChanged(s.slider, 300)
    assert(v == 300, "slider did not write, value is " .. tostring(v))
    s.wuiRefresh()
end)

Try("buttons carry all three variants", function()
    for _, variant in ipairs({ "ghost", "primary", "danger" }) do
        local b = ns.Style.Button(UIParent, "Reload UI", 130, 22, function() end, variant)
        b.scripts.OnEnter(b)
        b.scripts.OnLeave(b)
        b:SetText("Lock frames")
        assert(b:GetText() == "Lock frames")
    end
end)

Try("money is coloured per denomination", function()
    local P = ns.Prices
    assert(P and P.Format, "Prices.Format is missing")
    assert(P.Format(27002409) == "2700g 24s 9c", P.Format(27002409))
    local coloured = P.FormatColored(27002409)
    assert(coloured:find("|cffffd700", 1, true), "gold is not gold coloured")
    assert(coloured:find("|cffc7c7cf", 1, true), "silver is not silver coloured")
    assert(coloured:find("|cffeda55f", 1, true), "copper is not copper coloured")
    -- Every colour it opens, it closes.
    local _, opens = coloured:gsub("|c%x%x%x%x%x%x%x%x", "")
    local _, closes = coloured:gsub("|r", "")
    assert(opens == closes, "unbalanced colour codes: " .. opens .. " open, " .. closes .. " closed")
    assert(P.Format(0) == "0c", P.Format(0))
    assert(P.FormatColored(5):find("5c", 1, true), "a copper only amount lost its number")
end)

Try("the profession guide draws rows, meters and a coloured total", function()
    local M = ns.modules.proftracker
    local prof = ns.modules.professions
    assert(M and prof, "the profession modules are missing")

    -- Pick a profession the shipped guide data actually covers, then pretend
    -- the character has it. Everything below runs against the real guide.
    local guides = ns.ProfessionGuides or {}
    local name = next(guides)
    assert(name, "no profession guides shipped")

    prof.Professions = function() return { { name = name, skill = 58, max = 150 } } end
    ns.db.proftracker.shown = true
    ns.db.proftracker.collapsed = false
    ns.db.proftracker.profession = name
    ns.db.proftracker.showMats = true
    ns.db.proftracker.showCost = true

    local rows = M:Compose()
    assert(#rows > 0, "the guide composed nothing for " .. tostring(name))

    M:Refresh()
    local panel = M.panel
    assert(panel, "no panel")
    assert(#panel.rows > 0, "the panel drew no rows")

    -- The current step and every material row carry a meter, and at least one
    -- of them ended up wide enough to see.
    local drawn = 0
    for _, row in ipairs(panel.rows) do
        if row.meter and row.meter.shown and (row.meter.w or 0) > 1 then drawn = drawn + 1 end
    end
    assert(drawn > 0, "no row drew a meter bar")
end)

Try("slash command answers", function()
    local h = _G.SlashCmdList["WOIDZUI"]
    assert(h, "no slash handler")
    h("")
    h("unlock")
    h("lock")
end)

__RESULT = table.concat(out, "\n")
