-- MMT Quest Tracker: quest automation.
--   * accept quests from NPCs and from group members, turn in completed ones
--     (moved here from Core > Automations; Shift skips it, see Core),
--   * announce "[Quest] is ready for turn-in." in party chat,
--   * share newly accepted quests with the group, or announce that a quest
--     can't be shared,
--   * abandoning a quest asks whether to abandon it on the whole team,
--   * announce looted items that start a quest in party chat.

local _, mod = ...
local MMT = MMT
local M = mod.M

local recent = {}
local function Recently(key)
    local t = recent[key]
    return t and (GetTime() - t) < 5
end
local function Mark(key) recent[key] = GetTime() end

local function OfferedByPlayer()
    return MMT.Safe(UnitIsPlayer, "questnpc") == true
end

---------------------------------------------------------------------------
-- Gossip window: turn in / pick up quests (runs before Core's vendor step)
---------------------------------------------------------------------------
MMT.AddGossipHandler(function()
    if not M.enabled then return false end
    local q = M.db
    if q.turnIn then
        for _, info in ipairs(C_GossipInfo.GetActiveQuests() or {}) do
            if info.isComplete and not Recently("active" .. info.questID) then
                Mark("active" .. info.questID)
                M:Debug("Turning in: %s", tostring(info.title))
                C_GossipInfo.SelectActiveQuest(info.questID)
                return true
            end
        end
    end
    if q.acceptNPC then
        for _, info in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
            local skip = (q.skipTrivial and info.isTrivial) or info.isIgnored
            if not skip and not Recently("avail" .. info.questID) then
                Mark("avail" .. info.questID)
                M:Debug("Picking up: %s", tostring(info.title))
                C_GossipInfo.SelectAvailableQuest(info.questID)
                return true
            end
        end
    end
    return false
end)

-- old-style quest greeting (NPC with several quests, no gossip)
M:On("QUEST_GREETING", function()
    if MMT.IsBypassed() then return end
    local q = M.db
    if q.turnIn then
        for i = 1, GetNumActiveQuests() do
            local title, isComplete = GetActiveTitle(i)
            if isComplete and not Recently("gactive" .. tostring(title)) then
                Mark("gactive" .. tostring(title))
                SelectActiveQuest(i)
                return
            end
        end
    end
    if q.acceptNPC then
        for i = 1, GetNumAvailableQuests() do
            local isTrivial, _, _, _, questID = GetAvailableQuestInfo(i)
            local key = "gavail" .. tostring(questID or GetAvailableTitle(i))
            if not (q.skipTrivial and isTrivial) and not Recently(key) then
                Mark(key)
                SelectAvailableQuest(i)
                return
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Accept
---------------------------------------------------------------------------
local sharedOffer = {} -- [questID] = time a group member offered it (those aren't shared again)

M:On("QUEST_DETAIL", function()
    local shared = OfferedByPlayer()
    if shared and GetQuestID then
        local id = GetQuestID()
        if id and id > 0 then sharedOffer[id] = GetTime() end
    end
    if MMT.IsBypassed() then return end
    local q = M.db
    if shared and not q.acceptShared then return end
    if not shared and not q.acceptNPC then return end
    M:Debug("Accepting %s quest: %s", shared and "shared" or "NPC", tostring(GetTitleText()))
    if QuestGetAutoAccept and QuestGetAutoAccept() and AcknowledgeAutoAcceptQuest then
        AcknowledgeAutoAcceptQuest()
    else
        AcceptQuest()
    end
end)

-- escort quests started by a group member ask for confirmation
M:On("QUEST_ACCEPT_CONFIRM", function(_, questTitle)
    if not M.db.acceptShared then return end
    M:Debug("Confirming escort quest: %s", tostring(questTitle))
    ConfirmAcceptQuest() -- Blizzard's popup is left alone (closing it from addon code taints)
end)

---------------------------------------------------------------------------
-- Turn in
---------------------------------------------------------------------------
M:On("QUEST_PROGRESS", function()
    if MMT.IsBypassed() or not M.db.turnIn then return end
    if not IsQuestCompletable() then return end
    if GetQuestMoneyToGet and (GetQuestMoneyToGet() or 0) > 0 then -- never hand over gold automatically
        M:Debug("Quest costs money, left manual")
        return
    end
    CompleteQuest()
end)

M:On("QUEST_COMPLETE", function()
    if MMT.IsBypassed() or not M.db.turnIn then return end
    local choices = GetNumQuestChoices() or 0
    if choices > 1 then
        MMT.Print("Choose your quest reward.")
        return
    end
    GetQuestReward(choices)
end)

---------------------------------------------------------------------------
-- Announce quests that become ready for turn-in
---------------------------------------------------------------------------
mod.OnOwnQuestsChanged(function(changes, first)
    if first or not M.enabled or not M.db.announce then return end
    for _, c in ipairs(changes) do
        -- only quests we saw unfinished before, so a login or reload announces nothing
        if c.new and c.old and c.new.state == 1 and c.old.state ~= 1 then
            local msg = ("%s is ready for turn-in."):format(mod.QuestLink(c.id, c.new.title))
            M:Debug("QUEST ready: %s", tostring(c.new.title))
            mod.SayGroup(msg)
        end
    end
end)

---------------------------------------------------------------------------
-- Share new quests / announce quests that can't be shared
---------------------------------------------------------------------------
local function LogIndex(questID)
    if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then return C_QuestLog.GetLogIndexForQuestID(questID) end
    if GetQuestLogIndexByID then return GetQuestLogIndexByID(questID) end
    return nil
end

local function Select(questID)
    if C_QuestLog and C_QuestLog.SetSelectedQuest then
        C_QuestLog.SetSelectedQuest(questID)
        return true
    end
    local index = LogIndex(questID)
    if index and index > 0 and SelectQuestLogEntry then SelectQuestLogEntry(index) return true end
    return false
end

local function IsPushable(questID)
    if C_QuestLog and C_QuestLog.IsPushableQuest then return C_QuestLog.IsPushableQuest(questID) and true or false end
    if Select(questID) and GetQuestLogPushable then return GetQuestLogPushable() and true or false end
    return false
end

-- true if a group member may still need the quest: team members whose synced
-- quest log has it don't; everybody else (no data, not in the team) might
local function SomeoneNeeds(questID)
    local n = GetNumGroupMembers() or 0
    if n <= 1 then return false end
    local prefix = IsInRaid() and "raid" or "party"
    for i = 1, (IsInRaid() and n or n - 1) do
        local unit = prefix .. i
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local _, _, key = MMT.SplitUnit(unit)
            key = key and MMT.Resolve(key)
            local rec = key and mod.QuestsOf(key)
            if not (rec and rec.quests[questID]) then return true end
        end
    end
    return false
end

local function ShareNew(questID)
    if not M.enabled or not IsInGroup() then return end
    local cfg = M.db
    if not (cfg.autoShare or cfg.announceNoShare) then return end
    if sharedOffer[questID] and GetTime() - sharedOffer[questID] < 120 then
        M:Debug("quest %s came from a group member, not shared again", tostring(questID))
        return
    end
    if not SomeoneNeeds(questID) then M:Debug("quest %s: the whole group has it", tostring(questID)) return end
    local rec = mod.QuestsOf(MMT.PlayerFull())
    local title = rec and rec.quests[questID] and rec.quests[questID].title
    local link = mod.QuestLink(questID, title)
    if IsPushable(questID) then
        if cfg.autoShare and Select(questID) and QuestLogPushQuest then
            local ok, err = pcall(QuestLogPushQuest)
            M:Debug("QuestLogPushQuest(%s) -> %s %s", tostring(questID), tostring(ok), tostring(err or ""))
            if ok then MMT.Print("Shared %s with your group.", link) end
        end
    elseif cfg.announceNoShare then
        mod.SayGroup(("%s can't be shared."):format(link))
    end
end

M:On("QUEST_ACCEPTED", function(a, b)
    -- Mainline: (questID); Classic: (questLogIndex, questID)
    local questID = (type(b) == "number" and b > 0) and b or a
    if type(questID) ~= "number" then return end
    C_Timer.After(1, function() ShareNew(questID) end) -- let the quest log and the team data settle
end)

---------------------------------------------------------------------------
-- Abandon on the whole team
---------------------------------------------------------------------------
local abandoning          -- { id, title } of the quest set up for abandoning
local remoteAbandon = false

local function OthersOnline()
    for _, key in ipairs(MMT.SortedMembers()) do
        if not MMT.IsSelf(key) and MMT.IsOnline(key) then return true end
    end
    return false
end

local function RememberAbandon()
    if remoteAbandon then return end
    local id, title
    if C_QuestLog and C_QuestLog.GetAbandonQuest then id = C_QuestLog.GetAbandonQuest() end
    if (not id or id == 0) and C_QuestLog and C_QuestLog.GetSelectedQuest then id = C_QuestLog.GetSelectedQuest() end
    if (not id or id == 0) and GetQuestLogSelection and GetQuestLogTitle then
        local _, _, _, _, _, _, _, qid = GetQuestLogTitle(GetQuestLogSelection())
        id = qid
    end
    if GetAbandonQuestName then title = GetAbandonQuestName() end
    if (not title or title == "") and id and C_QuestLog and C_QuestLog.GetTitleForQuestID then
        title = C_QuestLog.GetTitleForQuestID(id)
    end
    if id and id > 0 then abandoning = { id = id, title = title } end
end

local function OnAbandoned()
    if remoteAbandon or not abandoning then return end
    local q = abandoning
    abandoning = nil
    if not (M.enabled and M.db.abortTeam) or not OthersOnline() then return end
    local link = mod.QuestLink(q.id, q.title)
    MMT.UI.Confirm(("You abandoned %s.\n\nDo you want to abort this quest on your entire team?"):format(link),
        "Yes", function()
            MMT.SendToTeam("QTAB:" .. q.id, true, "ALERT")
            MMT.Print("Asked your team to abandon %s.", link)
        end, "No")
end

if hooksecurefunc then
    if C_QuestLog and C_QuestLog.SetAbandonQuest then hooksecurefunc(C_QuestLog, "SetAbandonQuest", RememberAbandon) end
    if C_QuestLog and C_QuestLog.AbandonQuest then hooksecurefunc(C_QuestLog, "AbandonQuest", OnAbandoned) end
    if SetAbandonQuest then hooksecurefunc("SetAbandonQuest", RememberAbandon) end
    if AbandonQuest then hooksecurefunc("AbandonQuest", OnAbandoned) end
end

---------------------------------------------------------------------------
-- Tracker actions: open a quest in the quest log, abandon one
---------------------------------------------------------------------------
function mod.OpenInQuestLog(questID)
    if InCombatLockdown() then
        MMT.Print("The quest log is opened from the tracker outside combat only.")
        return
    end
    local ok, err = pcall(function()
        if QuestMapFrame_OpenToQuestDetails then              -- quest log in the world map
            QuestMapFrame_OpenToQuestDetails(questID)
            return
        end
        local index = LogIndex(questID)
        if not index or index <= 0 then return end
        if QuestLog_OpenToQuest then QuestLog_OpenToQuest(index) return end
        if QuestLogFrame and not QuestLogFrame:IsShown() and ToggleQuestLog then ToggleQuestLog() end
        if SelectQuestLogEntry then SelectQuestLogEntry(index) end
        if QuestLog_Update then QuestLog_Update() end
    end)
    M:Debug("open quest %s in log -> %s %s", tostring(questID), tostring(ok), tostring(err or ""))
end

-- Shift-right-click in the tracker. Abandoning goes through the game's normal
-- abandon calls, so "Abandon quests on the whole team" asks afterwards as usual.
function mod.AskAbandon(questID, title)
    local link = mod.QuestLink(questID, title)
    MMT.UI.Confirm(("Abandon %s?"):format(link), "Yes", function()
        local ok, err = pcall(function()
            Select(questID)
            if C_QuestLog and C_QuestLog.SetAbandonQuest and C_QuestLog.AbandonQuest then
                C_QuestLog.SetAbandonQuest()
                C_QuestLog.AbandonQuest()
            else
                SetAbandonQuest()
                AbandonQuest()
            end
        end)
        M:Debug("abandon %s from tracker -> %s %s", tostring(questID), tostring(ok), tostring(err or ""))
        if ok then MMT.Print("Abandoned %s.", link) else MMT.Print("Couldn't abandon %s: %s", link, tostring(err)) end
        mod.ScanSoon()
    end, "No")
end

-- a teammate asks to abandon a quest
local function AbandonHere(questID, key)
    local index = LogIndex(questID)
    if not index or index <= 0 then M:Debug("QTAB %s: not in my quest log", tostring(questID)) return end
    local rec = mod.QuestsOf(MMT.PlayerFull())
    local title = rec and rec.quests[questID] and rec.quests[questID].title
    remoteAbandon = true
    local ok, err = pcall(function()
        Select(questID)
        if C_QuestLog and C_QuestLog.SetAbandonQuest and C_QuestLog.AbandonQuest then
            C_QuestLog.SetAbandonQuest()
            C_QuestLog.AbandonQuest()
        else
            SetAbandonQuest()
            AbandonQuest()
        end
    end)
    remoteAbandon = false
    M:Debug("abandon %s for %s -> %s %s", tostring(questID), MMT.Repr(key), tostring(ok), tostring(err or ""))
    if ok then
        MMT.Print("Abandoned %s (requested by %s).", mod.QuestLink(questID, title), MMT.FullDisplay(key))
    else
        MMT.Print("Couldn't abandon %s: %s", mod.QuestLink(questID, title), tostring(err))
    end
    mod.ScanSoon()
end

M:Listen("TEAM_MESSAGE", function(key, sender, text)
    local id = text:match("^QTAB:(%d+)$")
    if not id then return end
    if not M.db.abortTeam then
        MMT.Print("%s asked to abandon a quest, but \"Abandon on the whole team\" is off here.", MMT.FullDisplay(key))
        return
    end
    AbandonHere(tonumber(id), key)
end)

---------------------------------------------------------------------------
-- Announce looted items that start a quest
--
-- The bags are compared with the last look: an item that is new in the bags
-- and starts a quest (that isn't in the quest log yet) is posted in party
-- chat as "Looted [Item] - it starts a quest!" (not in a group: only for you).
-- What is in the bags at login is not announced.
---------------------------------------------------------------------------
local known          -- [itemID] = true: items in the bags at the last look
local NUM_BAGS = NUM_BAG_SLOTS or 4

local Container = C_Container or {}
local NumSlots  = Container.GetContainerNumSlots or GetContainerNumSlots
local ItemIDAt  = Container.GetContainerItemID or GetContainerItemID
local LinkAt    = Container.GetContainerItemLink or GetContainerItemLink
local QuestInfoAt = Container.GetContainerItemQuestInfo or GetContainerItemQuestInfo

-- questID (or true if only known to start one) and whether that quest is in the log
local function StartsQuest(bag, slot)
    if QuestInfoAt then
        local ok, a, b, c = pcall(QuestInfoAt, bag, slot)
        if not ok then return nil end
        if type(a) == "table" then return a.questID, a.isActive end
        return b, c   -- isQuestItem, questID, isActive
    end
    -- no API: the tooltip line "This Item Begins a Quest"
    if C_TooltipInfo and C_TooltipInfo.GetBagItem and ITEM_STARTS_QUEST then
        local data = C_TooltipInfo.GetBagItem(bag, slot)
        for _, line in ipairs(data and data.lines or {}) do
            if line.leftText == ITEM_STARTS_QUEST then return true, false end
        end
    end
    return nil
end

local function LookAtBags(announce)
    if not (NumSlots and ItemIDAt) then return end
    local now = {}
    for bag = 0, NUM_BAGS do
        for slot = 1, (NumSlots(bag) or 0) do
            local id = ItemIDAt(bag, slot)
            if id and not now[id] then
                now[id] = true
                if announce and known and not known[id] then
                    local questID, active = StartsQuest(bag, slot)
                    if questID and not active then
                        local link = LinkAt and LinkAt(bag, slot) or ("item " .. id)
                        local msg = ("Looted %s - it starts a quest!"):format(link)
                        M:Debug("quest starter %s (quest %s)", link, tostring(questID))
                        if not mod.SayGroup(msg) then MMT.Print(msg) end
                    end
                end
            end
        end
    end
    known = now
end

local lookPending = false
M:On("BAG_UPDATE_DELAYED", function()
    if lookPending then return end
    lookPending = true
    C_Timer.After(0.2, function()
        lookPending = false
        LookAtBags(M.enabled and M.db.announceStarter)
    end)
end)
-- the bags at login are only remembered
MMT.OnLogin(function() C_Timer.After(2, function() LookAtBags(false) end) end)
