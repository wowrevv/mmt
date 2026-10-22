-- MMT Quest Tracker: the tracker window.
--
--   ZONE
--     [Level] Quest
--       Objective
--         Member   3/8        (one row per team member)
--
-- Mouse:
--   +/- at the start of a line     collapse / expand that line (state in M.store.collapsed)
--   [-] / [+] on the header        everything down to the zones / everything open
--   Shift + drag                   move the window (unless locked)
--   quest: click                   open it in the quest log
--   quest: Shift-click             link it in chat
--   quest: Shift-right-click       abandon it (asks first)
--   zone:  Ctrl-click              collapse / expand all quests of that zone
--   zone:  Ctrl-right-click        focus the zone (only its quests), again = all zones
--   right-click elsewhere          settings
-- The mouse wheel scrolls when the list is taller than the maximum height.
-- The Blizzard quest tracker is moved into a hidden frame (re-parenting out of
-- combat; nothing of Blizzard's code is replaced).

local _, mod = ...
local MMT = MMT
local M = mod.M

local PAD = 6
local MARKER_W = 12

local f = CreateFrame("Frame", "MMTQuestTrackerFrame", UIParent)
f:SetFrameStrata("LOW")
f:SetClampedToScreen(true)
f:SetMovable(true)
f:EnableMouseWheel(true)
f:RegisterForDrag("LeftButton")
f:Hide()
f.bg = f:CreateTexture(nil, "BACKGROUND")
f.bg:SetAllPoints()
f.rows = {}
f.offset = 0

local function SavePosition(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    M.db.point = { point, relPoint, math.floor(x + 0.5), math.floor(y + 0.5) }
end
local dragging, dragEnd = false, 0
f:SetScript("OnDragStart", function(self)
    if M.db.locked or not IsShiftKeyDown() then return end -- moving needs Shift
    dragging = true
    self:StartMoving()
end)
f:SetScript("OnDragStop", function(self)
    if not dragging then return end
    dragging, dragEnd = false, GetTime()
    SavePosition(self)
end)
-- a click that ends a drag is not a click
local function JustDragged() return dragging or GetTime() - dragEnd < 0.2 end
f:SetScript("OnMouseUp", function(_, button) if button == "RightButton" then MMT.ToggleConfig("QuestTracker") end end)
f:SetScript("OnMouseWheel", function(self, delta)
    self.offset = math.max(0, self.offset - delta)
    mod.Redraw()
end)

---------------------------------------------------------------------------
-- Collapse state
---------------------------------------------------------------------------
local function Collapsed()
    M.store.collapsed = M.store.collapsed or {}
    return M.store.collapsed
end

function mod.Toggle(key)
    local c = Collapsed()
    c[key] = not c[key] or nil
    mod.Redraw()
end

function mod.SetAllCollapsed(on, zones)
    local c = Collapsed()
    wipe(c)
    if on then for _, z in ipairs(zones or {}) do c["z:" .. z] = true end end
    f.offset = 0
    mod.Redraw()
end

-- Ctrl-click on a zone: all its quests collapsed (only the quest names), or all open again
function mod.ToggleZoneQuests(zone, questIDs)
    local c = Collapsed()
    local allClosed = #questIDs > 0
    for _, id in ipairs(questIDs) do if not c["q:" .. id] then allClosed = false end end
    c["z:" .. zone] = nil
    for _, id in ipairs(questIDs) do c["q:" .. id] = (not allClosed) or nil end
    mod.Redraw()
end

-- Ctrl-right-click on a zone: only that zone's quests; again = all zones.
-- Kept in the tracker only (the quest log's tracked quests stay as they are).
function mod.FocusZone(zone)
    if M.store.focusZone == zone then M.store.focusZone = nil else M.store.focusZone = zone end
    f.offset = 0
    mod.Redraw()
end

---------------------------------------------------------------------------
-- Colours / text helpers
---------------------------------------------------------------------------
local function Hex(r, g, b)
    return ("|cff%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end
local GREEN, RED, GREY = Hex(0.35, 1, 0.35), Hex(1, 0.35, 0.35), Hex(0.5, 0.5, 0.5)

local function LevelColour(level)
    if M.db.levelColors and GetQuestDifficultyColor and level and level > 0 then
        local ok, c = pcall(GetQuestDifficultyColor, level)
        if ok and type(c) == "table" and c.r then return Hex(c.r, c.g, c.b) end
    end
    return nil
end

local function ClassHex(key)
    local m = MMT.db.team[key]
    local s = MMT.status[key]
    local class = (m and m.class) or (s and s.class)
    if MMT.IsSelf(key) and not class then class = select(2, UnitClass("player")) end
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and Hex(c.r, c.g, c.b) or nil
end

-- progress of one member on one objective (oi), or on the quest (oi = nil)
local function Progress(q, oi)
    if q.state == -1 then return RED .. "failed|r", false end
    local o = oi and q.obj[oi]
    if not o then
        if q.state == 1 then return GREEN .. "done|r", true end
        return "open", false
    end
    if o.done or q.state == 1 then
        return GREEN .. ((o.need or 0) > 1 and (o.need .. "/" .. o.need) or "done") .. "|r", true
    end
    if (o.need or 0) > 1 then return ("%d/%d"):format(o.have or 0, o.need), false end
    return "open", false
end

---------------------------------------------------------------------------
-- Building the list
---------------------------------------------------------------------------
-- team members shown in the member rows: you, plus online members (and offline
-- ones with stored data if enabled), in team order
local function Members()
    local list, inTeam = {}, false
    for _, key in ipairs(MMT.SortedMembers()) do
        if MMT.IsSelf(key) then
            inTeam = true
            list[#list + 1] = key
        elseif mod.QuestsOf(key) and (MMT.IsOnline(key) or M.db.showOffline) then
            list[#list + 1] = key
        end
    end
    if not inTeam then table.insert(list, 1, MMT.PlayerFull()) end
    return list
end

-- entries: { kind, key (collapse key), text, indent, collapsible, collapsed, questID, member, ... }
function mod.BuildEntries()
    local me = MMT.PlayerFull()
    local data = mod.AllData()
    local own = (me and data[me] and data[me].quests) or {}
    local members = Members()
    local cfg = M.db
    local collapsed = Collapsed()

    -- quests: own (log order) first, then quests only teammates have
    local quests, zones, byZone = {}, {}, {}
    local function AddQuest(q, mine)
        if quests[q.id] then return end
        local zone = (q.zone and q.zone ~= "") and q.zone or "Other"
        quests[q.id] = { q = q, mine = mine, zone = zone }
        if not byZone[zone] then byZone[zone] = {}; zones[#zones + 1] = zone end
        table.insert(byZone[zone], q.id)
    end
    for _, id in ipairs(mod.ownOrder or {}) do
        local q = own[id]
        if q and (not cfg.onlyWatched or mod.ownWatched[id]) then AddQuest(q, true) end
    end
    if cfg.teamQuests and not cfg.onlyWatched then
        local extra = {}
        for _, key in ipairs(members) do
            local rec = not MMT.IsSelf(key) and data[key]
            for id, q in pairs(rec and rec.quests or {}) do
                if not own[id] and not extra[id] then extra[id] = q end
            end
        end
        local list = {}
        for _, q in pairs(extra) do list[#list + 1] = q end
        table.sort(list, function(a, b)
            if (a.zone or "") ~= (b.zone or "") then return (a.zone or "") < (b.zone or "") end
            if a.level ~= b.level then return a.level < b.level end
            return a.title < b.title
        end)
        for _, q in ipairs(list) do AddQuest(q, false) end
    end

    local entries = {}
    local function Add(e) entries[#entries + 1] = e return e end

    -- focus on one zone (ignored when that zone has no quests any more)
    local focus = M.store.focusZone
    if focus and not byZone[focus] then focus = nil end
    mod.activeFocus = focus

    for _, zone in ipairs(zones) do
      if not focus or zone == focus then
        local zkey = "z:" .. zone
        Add({ kind = "zone", key = zkey, text = zone, indent = 0, collapsible = true, collapsed = collapsed[zkey] })
        if not collapsed[zkey] then
            for _, id in ipairs(byZone[zone]) do
                local entry = quests[id]
                local q = entry.q
                local qkey = "q:" .. id
                -- quest state from your own log, or "ready" when every owner is done
                local suffix = ""
                local ownQ = own[id]
                if ownQ then
                    if ownQ.state == 1 then suffix = "  " .. GREEN .. "(Ready)|r"
                    elseif ownQ.state == -1 then suffix = "  " .. RED .. "(Failed)|r" end
                end
                local lc = LevelColour(q.level)
                local tag = "[" .. (q.level or "?") .. "]"
                local text = (lc and (lc .. tag .. "|r") or tag) .. " " .. q.title .. suffix
                Add({ kind = "quest", key = qkey, text = text, indent = 1, collapsible = true,
                    collapsed = collapsed[qkey], questID = id, title = q.title, level = q.level,
                    zone = zone, mine = entry.mine })
                if not collapsed[qkey] then
                    -- objective texts from your log, otherwise from the first member who has the quest
                    local objectives = q.obj
                    local n = math.max(#objectives, 1)
                    for oi = 1, n do
                        local o = objectives[oi]
                        local okey = "o:" .. id .. ":" .. oi
                        local otext = o and o.text or "Complete the quest"
                        Add({ kind = "objective", key = okey, text = otext, indent = 2, collapsible = true,
                            collapsed = collapsed[okey], questID = id })
                        if not collapsed[okey] then
                            for _, key in ipairs(members) do
                                local rec = data[key]
                                local mq = rec and rec.quests[id]
                                local status, done
                                if mq then
                                    status, done = Progress(mq, o and oi or nil)
                                elseif cfg.showMissing then
                                    status = GREY .. "not on quest|r"
                                end
                                if status then
                                    local name = MMT.FirstName(key)
                                    local ch = cfg.classColors and ClassHex(key)
                                    if ch then name = ch .. name .. "|r" end
                                    if not MMT.IsSelf(key) and not MMT.IsOnline(key) then
                                        status = status .. GREY .. " (offline)|r"
                                    end
                                    Add({ kind = "member", text = name .. "  " .. status, indent = 3, member = key,
                                        questID = id, done = done })
                                end
                            end
                        end
                    end
                end
            end
        end
      end
    end
    return entries, zones, byZone
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function RowTooltip(row)
    local e = row.entry
    if not e then return end
    if e.kind == "member" then
        local tip = MMT.MemberTooltip(row, e.member, "ANCHOR_LEFT")
        local rec = mod.QuestsOf(e.member)
        if rec and not MMT.IsSelf(e.member) then tip:AddLine("Quest data from " .. MMT.Ago(rec.time), 0.6, 0.6, 0.6) end
        tip:Show()
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    if e.kind == "quest" then
        GameTooltip:SetText(("[%s] %s"):format(tostring(e.level or "?"), e.title), 1, 0.82, 0)
        GameTooltip:AddLine(e.zone, 0.7, 0.7, 0.7)
        if not e.mine then GameTooltip:AddLine("You don't have this quest.", 1, 0.5, 0.5) end
        local data = mod.AllData()
        local have, total = 0, 0
        for _, key in ipairs(Members()) do
            total = total + 1
            local q = data[key] and data[key].quests[e.questID]
            if q then have = have + 1 end
        end
        GameTooltip:AddLine(("%d of %d shown team members are on it."):format(have, total), 1, 1, 1)
        GameTooltip:AddLine(" ")
        if e.mine then
            GameTooltip:AddLine("Click: open in the quest log", 0.5, 0.5, 0.5)
            GameTooltip:AddLine("Shift-click: link in chat", 0.5, 0.5, 0.5)
            GameTooltip:AddLine("Shift-right-click: abandon", 0.5, 0.5, 0.5)
        else
            GameTooltip:AddLine("Shift-click: link in chat", 0.5, 0.5, 0.5)
        end
    elseif e.kind == "zone" then
        GameTooltip:SetText(e.text, 1, 0.82, 0)
        GameTooltip:AddLine("Ctrl-click: collapse / expand all quests of this zone", 0.5, 0.5, 0.5)
        GameTooltip:AddLine(mod.activeFocus == e.text and "Ctrl-right-click: show all zones again"
            or "Ctrl-right-click: show only this zone", 0.5, 0.5, 0.5)
    elseif e.kind == "header" then
        GameTooltip:SetText("Quests", 1, 0.82, 0)
        if mod.activeFocus then GameTooltip:AddLine("Showing only: " .. mod.activeFocus, 1, 1, 1) end
    else
        GameTooltip:SetText(row.text:GetText() or "", 1, 1, 1)
    end
    GameTooltip:AddLine("+ / - at the start of a line: collapse / expand", 0.5, 0.5, 0.5)
    if not M.db.locked then GameTooltip:AddLine("Shift-drag to move, right-click for settings", 0.5, 0.5, 0.5)
    else GameTooltip:AddLine("Right-click for settings", 0.5, 0.5, 0.5) end
    GameTooltip:Show()
end

local function OnRowClick(self, button)
    if JustDragged() then return end
    local e = self.entry
    if not e then return end
    local shift, ctrl = IsShiftKeyDown(), IsControlKeyDown()
    if e.kind == "zone" and ctrl then
        if button == "RightButton" then mod.FocusZone(e.text)
        else
            local _, _, byZone = mod.BuildEntries()
            mod.ToggleZoneQuests(e.text, byZone[e.text] or {})
        end
        return
    end
    if e.kind == "quest" then
        if button == "RightButton" and shift then
            if e.mine then mod.AskAbandon(e.questID, e.title) end
            return
        end
        if button == "LeftButton" and shift then
            local link = mod.QuestLink(e.questID, e.title)
            if ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
            return
        end
        if button == "LeftButton" then
            if e.mine then mod.OpenInQuestLog(e.questID)
            else MMT.Print("%s is not in your quest log (only teammates have it).", mod.QuestLink(e.questID, e.title)) end
            return
        end
    end
    if button == "RightButton" and not shift and not ctrl then MMT.ToggleConfig("QuestTracker") end
end

local function Row(i)
    local row = f.rows[i]
    if row then return row end
    row = CreateFrame("Button", nil, f)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.text = row:CreateFontString(nil, "OVERLAY")
    row.text:SetWordWrap(false)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.05)
    row:SetScript("OnClick", OnRowClick)

    -- +/- : the only place that collapses / expands a line
    row.toggle = CreateFrame("Button", nil, row)
    row.toggle:SetFrameLevel(row:GetFrameLevel() + 2)
    row.toggle:RegisterForClicks("LeftButtonUp")
    row.marker = row.toggle:CreateFontString(nil, "OVERLAY")
    row.marker:SetPoint("CENTER")
    local thl = row.toggle:CreateTexture(nil, "HIGHLIGHT")
    thl:SetAllPoints()
    thl:SetColorTexture(1, 1, 1, 0.12)
    row.toggle:SetScript("OnClick", function()
        local e = row.entry
        if e and e.collapsible then mod.Toggle(e.key) end
    end)

    -- header: [-] collapse everything down to the zones / [+] open everything
    row.all = CreateFrame("Button", nil, row)
    row.all:SetFrameLevel(row:GetFrameLevel() + 2)
    row.all.text = row.all:CreateFontString(nil, "OVERLAY")
    row.all.text:SetPoint("RIGHT")
    local ahl = row.all:CreateTexture(nil, "HIGHLIGHT")
    ahl:SetAllPoints()
    ahl:SetColorTexture(1, 1, 1, 0.12)
    row.all:SetScript("OnClick", function()
        local _, zones = mod.BuildEntries()
        mod.SetAllCollapsed(not mod.AllCollapsed(zones), zones)
    end)
    row.all:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local _, zones = mod.BuildEntries()
        GameTooltip:SetText(mod.AllCollapsed(zones) and "Expand all" or "Collapse all to zones")
        GameTooltip:Show()
    end)
    row.all:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.all:Hide()

    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function() f:GetScript("OnDragStart")(f) end)
    row:SetScript("OnDragStop", function() f:GetScript("OnDragStop")(f) end)
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:EnableMouseWheel(true)
    row:SetScript("OnMouseWheel", function(_, delta) f:GetScript("OnMouseWheel")(f, delta) end)
    f.rows[i] = row
    return row
end

-- true when every zone is collapsed (the [-] / [+] button shows [+] then)
function mod.AllCollapsed(zones)
    local c = Collapsed()
    if not zones or #zones == 0 then return false end
    for _, z in ipairs(zones) do if not c["z:" .. z] then return false end end
    return true
end

local function Style(level)
    local s = M.db.fonts[level] or M.db.fonts.quest
    return s
end

local function FillRow(row, e, y, width)
    local cfg = M.db
    local level = (e.kind == "header") and "zone" or e.kind
    local st = Style(level)
    local h = st.size + 4
    row.entry = e
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", PAD, -y)
    row:SetSize(width, h)
    row:EnableMouse(not cfg.clickThrough)
    row:EnableMouseWheel(not cfg.clickThrough)

    MMT.ApplyFont(row.text, st.font, st.size, cfg.outline)
    MMT.ApplyFont(row.marker, st.font, st.size, cfg.outline)
    local c = st.color or { r = 1, g = 1, b = 1 }
    row.text:SetTextColor(c.r, c.g, c.b)
    row.marker:SetTextColor(0.55, 0.55, 0.55)

    local left = (e.indent or 0) * cfg.indent
    row.toggle:ClearAllPoints()
    row.toggle:SetPoint("LEFT", left - 2, 0)
    row.toggle:SetSize(MARKER_W + 2, h)
    row.marker:SetText(e.collapsible and (e.collapsed and "+" or "-") or "")
    row.toggle:SetShown(e.collapsible and true or false)
    row.toggle:EnableMouse(not cfg.clickThrough)
    if not e.collapsible then row.marker:SetText("") end
    local textLeft = left + ((e.collapsible or e.kind == "member") and MARKER_W or 0)
    if e.kind == "header" then textLeft = 0 end
    local right = 0
    if e.kind == "header" then
        MMT.ApplyFont(row.all.text, st.font, st.size, cfg.outline)
        row.all.text:SetText(e.allCollapsed and "[+]" or "[-]")
        row.all.text:SetTextColor(0.7, 0.7, 0.7)
        row.all:ClearAllPoints()
        row.all:SetPoint("RIGHT", 0, 0)
        row.all:SetSize(row.all.text:GetStringWidth() + 6, h)
        row.all:SetShown(not cfg.clickThrough)
        right = -(row.all:GetWidth() + 4)
    else
        row.all:Hide()
    end
    row.text:ClearAllPoints()
    row.text:SetPoint("LEFT", textLeft, 0)
    row.text:SetPoint("RIGHT", right, 0)
    row.text:SetJustifyH(cfg.align or "LEFT")
    row.text:SetText(e.text)
    row:Show()
    return h
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function MaxQuests()
    if C_QuestLog and C_QuestLog.GetMaxNumQuestsCanAccept then return C_QuestLog.GetMaxNumQuestsCanAccept() end
    return MAX_QUESTS or 25
end

local function Draw()
    local cfg = M.db
    if not (M.enabled and cfg.show and MMT.ready) then f:Hide() return end
    local entries, zones = mod.BuildEntries()
    local ownCount = #(mod.ownOrder or {})
    if #entries == 0 and ownCount == 0 then f:Hide() return end

    local width = cfg.width - PAD * 2
    local y = PAD
    local i = 0
    local header
    if cfg.showHeader then
        i = i + 1
        -- filters that hide quests are named in the header
        local hidden = 0
        if cfg.onlyWatched then
            for _, id in ipairs(mod.ownOrder or {}) do if not mod.ownWatched[id] then hidden = hidden + 1 end end
        end
        header = { kind = "header", text = ("Quests  %s%d/%d|r"):format(GREY, ownCount, MaxQuests())
            .. (mod.activeFocus and ("  " .. GREY .. "(only " .. mod.activeFocus .. ")|r") or "")
            .. (hidden > 0 and ("  " .. GREY .. "(" .. hidden .. " untracked hidden)|r") or ""),
            allCollapsed = mod.AllCollapsed(zones) }
        y = y + FillRow(Row(i), header, y, width) + 2
    end

    f.offset = math.max(0, math.min(f.offset, #entries - 1))
    local more = false
    for idx = f.offset + 1, #entries do
        local e = entries[idx]
        local st = Style(e.kind)
        local gap = (e.kind == "zone" and idx > f.offset + 1) and 4 or 0
        if y + gap + st.size + 4 > cfg.maxHeight - PAD and i > (cfg.showHeader and 1 or 0) then
            more = true
            break
        end
        y = y + gap
        i = i + 1
        y = y + FillRow(Row(i), e, y, width)
    end
    for j = i + 1, #f.rows do f.rows[j]:Hide() end
    f.more = more
    if header and (more or f.offset > 0) then
        -- scroll hint: more rows above / below
        Row(1).text:SetText(header.text .. GREY .. "  " .. (f.offset > 0 and "^" or "") .. (more and "v" or "") .. "|r")
    end

    f:SetScale(cfg.scale)
    f:SetSize(cfg.width, y + PAD)
    local bg = cfg.bg or { r = 0, g = 0, b = 0 }
    f.bg:SetColorTexture(bg.r, bg.g, bg.b, cfg.bgAlpha)
    f:EnableMouse(not cfg.clickThrough)
    f:EnableMouseWheel(not cfg.clickThrough)
    f:Show()
end

-- redraws are bundled (many quest events arrive at once)
local queued = false
function mod.Redraw()
    if queued then return end
    queued = true
    C_Timer.After(0.05, function()
        queued = false
        local ok, err = pcall(Draw)
        if not ok then M:Debug("tracker draw error: %s", tostring(err)) end
    end)
end

function mod.Layout()
    local cfg = M.db
    f:ClearAllPoints()
    local p = cfg.point
    f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    mod.Redraw()
end

function mod.ResetPosition()
    M.db.point = { unpack(M.defaults.point) }
    mod.Layout()
end

---------------------------------------------------------------------------
-- Blizzard quest tracker
---------------------------------------------------------------------------
local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()
local originalParent = {}
local waitingForCombat = false

local function BlizzardTrackers()
    return { _G.ObjectiveTrackerFrame, _G.QuestWatchFrame, _G.WatchFrame }
end

-- The game puts its tracker back into its own container when it shows up
-- (e.g. with the first quest of a new character): hide it again then.
local hooked = {}
local function Rehide()
    C_Timer.After(0, function()
        if M.enabled and M.db.hideBlizzard then mod.UpdateBlizzardTracker() end
    end)
end
local function HookTracker(frame)
    if hooked[frame] then return end
    hooked[frame] = true
    if frame.HookScript then frame:HookScript("OnShow", Rehide) end
    if hooksecurefunc then
        hooksecurefunc(frame, "SetParent", function(self, parent)
            if parent ~= hiddenParent and M.enabled and M.db.hideBlizzard then Rehide() end
        end)
    end
end

function mod.UpdateBlizzardTracker()
    local hide = M.enabled and M.db.hideBlizzard
    if InCombatLockdown() then waitingForCombat = true return end -- its quest item buttons are protected
    waitingForCombat = false
    for _, frame in ipairs(BlizzardTrackers()) do
        if frame and frame.SetParent then
            HookTracker(frame)
            local parent = frame:GetParent()
            if hide and parent ~= hiddenParent then
                originalParent[frame] = parent
                frame:SetParent(hiddenParent)
                M:Debug("Blizzard tracker hidden: %s", frame:GetName() or "?")
            elseif not hide and parent == hiddenParent then
                frame:SetParent(originalParent[frame] or UIParent)
            end
        end
    end
end

-- these run whether or not the module is on: switching it off must restore the tracker
MMT.On("PLAYER_REGEN_ENABLED", function() if waitingForCombat then mod.UpdateBlizzardTracker() end end)
-- a new quest can make the game show its tracker again
MMT.On("QUEST_ACCEPTED", Rehide)
MMT.On("QUEST_WATCH_LIST_CHANGED", Rehide)
MMT.On("ADDON_LOADED", function(name)
    if name == "Blizzard_ObjectiveTracker" or name == "Blizzard_QuestWatch" then mod.UpdateBlizzardTracker() end
end)

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------
function mod.OnEnableTracker()
    mod.Layout()
    mod.UpdateBlizzardTracker()
    C_Timer.After(1, mod.UpdateBlizzardTracker)
end

function mod.OnDisableTracker()
    f:Hide()
    mod.UpdateBlizzardTracker()
end

MMT.OnRefresh(function()
    if not MMT.ready then return end
    if M.enabled then mod.Layout() else f:Hide() end
    mod.UpdateBlizzardTracker()
end)
M:Listen("QUESTS_CHANGED", mod.Redraw)
M:Listen("STATUS_CHANGED", mod.Redraw)
M:Listen("TEAM_CHANGED", mod.Redraw)
MMT.OnLogin(function()
    C_Timer.NewTicker(10, function() if M.enabled then mod.Redraw() end end) -- members going offline
end)
