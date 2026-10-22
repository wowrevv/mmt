-- MMT Quest Tracker: settings page (under MODULES in /mmt) with three
-- sub-tabs (Tracker, Automation, Fonts), and the debug report.

local _, mod = ...
local MMT = MMT
local M = mod.M
local UI = MMT.UI
local A = UI.ACCENT
local H = MMT.ConfigHelpers
local COL_W, COL2_X, PAGE_W = H.COL_W, H.COL2_X, H.PAGE_W
local StatusLine, ConfirmButton = H.StatusLine, H.ConfirmButton

local function Opt(key)
    return function() return M.db[key] end,
           function(v) M.db[key] = v end
end

local function FontChoices(current)
    local l = {}
    for _, f in ipairs(MMT.fonts) do l[#l + 1] = { value = f.name, text = f.name } end
    local known = false
    for _, c in ipairs(l) do if c.value == current then known = true end end
    if current and not known then l[#l + 1] = { value = current, text = "Custom" } end
    return l
end

-- small tab bar at the top of the page
local function SubTabs(page, names)
    local frames, buttons = {}, {}
    local function Select(i)
        for j, fr in ipairs(frames) do fr:SetShown(i == j) end
        for j, b in ipairs(buttons) do b.Update(i == j) end
        page.subTab = i
    end
    local x = 0
    for i, name in ipairs(names) do
        local b = CreateFrame("Button", nil, page)
        b:SetSize(110, 22)
        b:SetPoint("TOPLEFT", x, 0)
        x = x + 114
        local bg = UI.Fill(b, 1, 1, 1, 0.03)
        local bar = b:CreateTexture(nil, "ARTWORK")
        bar:SetColorTexture(A[1], A[2], A[3], 1)
        bar:SetPoint("BOTTOMLEFT"); bar:SetPoint("BOTTOMRIGHT")
        bar:SetHeight(2)
        local label = UI.Label(b, name, "GameFontNormal")
        label:SetPoint("CENTER", 0, 1)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.04)
        b.Update = function(on)
            bar:SetShown(on)
            bg:SetColorTexture(1, 1, 1, on and 0.07 or 0.03)
            if on then label:SetTextColor(1, 1, 1) else label:SetTextColor(0.6, 0.6, 0.6) end
        end
        b:SetScript("OnClick", function() Select(i) end)
        buttons[i] = b

        local fr = CreateFrame("Frame", nil, page)
        fr:SetPoint("TOPLEFT", 0, -32)
        fr:SetPoint("BOTTOMRIGHT")
        frames[i] = fr
    end
    Select(1)
    return frames
end

M.Page = function(_, page)
    local tabs = SubTabs(page, { "Tracker", "Automation", "Fonts" })
    local status

    -------------------------------------------------------------------------
    -- Tracker
    -------------------------------------------------------------------------
    local T = tabs[1]
    local L = UI.Column(T, 0, 0, COL_W)
    L:Header("Quest tracker")
    L:Check("Show quest tracker", Opt("show"))
    local ghb, shb = Opt("hideBlizzard")
    L:Check("Hide the Blizzard quest tracker", ghb, shb, "Comes back when you switch this off or disable the module (outside combat).")
    local glk, slk = Opt("locked")
    L:Check("Lock position", glk, slk, "Unlocked, Shift + drag moves the tracker.")
    local gct, sct = Opt("clickThrough")
    L:Check("Click-through", gct, sct, "Clicks go through the tracker to the game world. No collapsing, scrolling or tooltips then.")
    local gsh, ssh = Opt("showHeader")
    L:Check("Show header", gsh, ssh, "\"Quests 12/25\" at the top, with [-] / [+] on the right to collapse everything down to the zones or open everything.")

    L:Header("Content")
    local gw, sw = Opt("onlyWatched")
    L:Check("Only quests you track", gw, sw, "Only quests marked for tracking in your quest log.")
    local gtq, stq = Opt("teamQuests")
    L:Check("Include quests only teammates have", gtq, stq, "Quests your current character doesn't have, but someone in the team does.")
    local gm, sm = Opt("showMissing")
    L:Check("Show members not on the quest", gm, sm, "Adds \"not on quest\" for team members who don't have it.")
    local go, so = Opt("showOffline")
    L:Check("Include offline members", go, so, "Shows their last known progress.")
    L:Check("Class colours for names", Opt("classColors"))
    local glc, slc = Opt("levelColors")
    L:Check("Quest level in difficulty colour", glc, slc, "Colours the [level] by how hard the quest is for your character.")
    L:Space(6)
    L:Button("Request update from team", function()
        mod.RequestAll()
        status.Show_("Asked the online team for their quest logs.")
    end)
    status = StatusLine(T)
    status:SetWidth(COL_W)
    L:Add(status, 20)

    local R = UI.Column(T, COL2_X, 0, COL_W)
    R:Header("Look")
    local gbg, sbg = Opt("bg")
    R:Color("Background colour", gbg, sbg)
    local gba, sba = Opt("bgAlpha")
    R:Slider("Background opacity", 0, 1, 0.05, gba, sba, "%.2f")
    local gwi, swi = Opt("width")
    R:Slider("Width", 150, 500, 5, gwi, swi)
    local gmh, smh = Opt("maxHeight")
    R:Slider("Maximum height (scrolls beyond)", 100, 1000, 10, gmh, smh)
    local gin, sin = Opt("indent")
    R:Slider("Indent per level", 0, 30, 1, gin, sin)
    local gsc, ssc = Opt("scale")
    R:Slider("Scale", 0.5, 2, 0.05, gsc, ssc, "%.2f")
    local gal, sal = Opt("align")
    R:Cycle("Text alignment", {
        { value = "LEFT", text = "Left" },
        { value = "CENTER", text = "Center" },
        { value = "RIGHT", text = "Right" },
    }, gal, sal)
    local gol, sol = Opt("outline")
    R:Cycle("Outline", {
        { value = "NONE", text = "None" },
        { value = "OUTLINE", text = "Thin" },
        { value = "THICKOUTLINE", text = "Thick" },
        { value = "MONOCHROME,OUTLINE", text = "Mono" },
    }, gol, sol)
    R:Button("Expand all", function() mod.SetAllCollapsed(false) end)
    R:Note("In the tracker: Shift + drag moves it. Quest: click opens it in the quest log, Shift-click links it, Shift-right-click abandons it. Zone: Ctrl-click collapses its quests, Ctrl-right-click shows only that zone (again: all).")
    R:Button("Reset position", function() mod.ResetPosition() end)

    -------------------------------------------------------------------------
    -- Automation
    -------------------------------------------------------------------------
    local Au = tabs[2]
    local L2 = UI.Column(Au, 0, 0, COL_W)
    L2:Header("Quests")
    L2:Check("Accept quests from NPCs", Opt("acceptNPC"))
    L2:Check("Accept quests shared by group", Opt("acceptShared"))
    L2:Check("Turn in completed quests", Opt("turnIn"))
    local gt, st = Opt("skipTrivial")
    L2:Check("Skip grey (low level) quests", gt, st, "Grey quests are not picked up from NPC dialogs.")
    local gan, san = Opt("announce")
    L2:Check("Announce quest completion in party chat", gan, san,
        "Posts \"[Quest] is ready for turn-in.\" in party chat when one of your quests becomes ready to turn in.")
    local gst, sst = Opt("announceStarter")
    L2:Check("Announce looted items that start a quest", gst, sst,
        "Posts \"Looted [Item] - it starts a quest!\" in party chat when an item that starts a quest lands in your bags (not if that quest is already in your log). Not in a group: only shown to you.")
    L2:Note("Hold Shift while an NPC page opens to keep that page manual (Core > Automations).")

    local R2 = UI.Column(Au, COL2_X, 0, COL_W)
    R2:Header("Team")
    local gas, sas = Opt("autoShare")
    R2:Check("Share new quests automatically", gas, sas,
        "When you accept a quest, it is shared with your group. Quests you got shared by a group member, or that every team member already has, aren't shared again.")
    local gns, sns = Opt("announceNoShare")
    R2:Check("Announce in party chat if a quest can't be shared", gns, sns,
        "Posts \"[Quest] can't be shared.\" when you accept a quest that the game doesn't let you share.")
    local gab, sab = Opt("abortTeam")
    R2:Check("Abandon quests on the whole team", gab, sab,
        "When you abandon a quest, you are asked: \"Do you want to abort this quest on your entire team?\". Yes makes every online team member abandon it too. Must be on for the other characters as well.")
    R2:Note("Sharing and team abandon need MMT with this module on every client.")

    -------------------------------------------------------------------------
    -- Fonts: font, size and colour for each of the four levels
    -------------------------------------------------------------------------
    local Fo = tabs[3]
    local cols = { UI.Column(Fo, 0, 0, COL_W), UI.Column(Fo, COL2_X, 0, COL_W) }
    for i, level in ipairs(mod.LEVELS) do
        local C = cols[(i - 1) % 2 + 1]
        local function S() return M.db.fonts[level.key] end
        C:Header(level.title)
        C:Cycle("Font", function() return FontChoices(S().font) end,
            function() return S().font end, function(v) S().font = v end)
        C:Slider("Font size", 6, 24, 1, function() return S().size end, function(v) S().size = v end)
        C:Color("Font colour", function() return S().color end, function(v) S().color = v end)
        C:Space(8)
    end
    local note = UI.Label(Fo, "Zone > [Level] Quest > Objective > one row per team member. +/- at the start of a line collapses / expands it.")
    note:SetTextColor(0.6, 0.6, 0.6)
    note:SetWidth(PAGE_W)
    note:SetJustifyH("LEFT")
    note:SetPoint("TOPLEFT", 0, cols[1].y - 8)
end

function M.Report(_, add)
    add(("-- Quest Tracker  own hash=%s  own quests=%d  blizzard tracker parent=%s"):format(
        tostring(mod.OwnHash()), #(mod.ownOrder or {}),
        tostring(_G.ObjectiveTrackerFrame and _G.ObjectiveTrackerFrame:GetParent() and
            (_G.ObjectiveTrackerFrame:GetParent():GetName() or "hidden") or "n/a")))
    add(("automation: acceptNPC=%s acceptShared=%s turnIn=%s skipTrivial=%s announce=%s autoShare=%s announceNoShare=%s abortTeam=%s announceStarter=%s"):format(
        tostring(M.db.acceptNPC), tostring(M.db.acceptShared), tostring(M.db.turnIn), tostring(M.db.skipTrivial),
        tostring(M.db.announce), tostring(M.db.autoShare), tostring(M.db.announceNoShare), tostring(M.db.abortTeam), tostring(M.db.announceStarter)))
    local watchedN = 0
    for _ in pairs(mod.ownWatched or {}) do watchedN = watchedN + 1 end
    add(("tracker: onlyWatched=%s teamQuests=%s showMissing=%s focusZone=%s tracked=%d"):format(
        tostring(M.db.onlyWatched), tostring(M.db.teamQuests), tostring(M.db.showMissing),
        MMT.Repr(M.store.focusZone), watchedN))
    for _, id in ipairs(mod.ownOrder or {}) do
        local own = mod.AllData()[MMT.PlayerFull()]
        local q = own and own.quests and own.quests[id]
        add(("  own quest %s %s zone=%s tracked=%s"):format(tostring(id), MMT.Repr(q and q.title),
            MMT.Repr(q and q.zone), tostring(mod.ownWatched and mod.ownWatched[id] or false)))
    end
    for key, rec in pairs(mod.AllData()) do
        add(("quests %s: %d, hash %s, %s"):format(MMT.Repr(key), mod.QuestCount(rec), tostring(rec.hash), MMT.Ago(rec.time)))
    end
end
