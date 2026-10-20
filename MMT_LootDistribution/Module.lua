-- MMT module: Loot Distribution.
--
-- 1. Loot method: when a group forms or one of your team characters becomes
--    leader, that character's client sets the chosen loot method and
--    threshold (only the leader is allowed to). It is set once per group /
--    leader change, so a manual change afterwards is respected.
-- 2. Master loot by roles: the master looter's client gives items at or
--    above the threshold to the team member whose roles want them. Several
--    members with that role: the first one in team order who still has more
--    free bag slots than the reserve. Bind on Pickup items are never given:
--    they are announced in group chat for manual assignment.
-- 3. Quest items (Master Looter): given round robin across the team, to the
--    next member in team order that the game offers as a candidate (= on the
--    quest and able to receive it).
-- 4. Group loot & roll automation: when a loot roll opens (Group Loot, Need
--    before Greed, token/chest rolls), each client rolls Need, Greed, Pass or
--    leaves it manual according to your Roles, quest log objectives, bag
--    reserve and unassigned-item rule, and auto-confirms Bind on Pickup rolls
--    that MMT initiated.

local _, mod = ...
local MMT = MMT

local M = MMT.NewModule({
    name = "LootDistribution",
    title = "Loot Distribution",
    description = "Sets the group loot method and handles Master Loot and Group Loot rolls by roles.",
    sync = true,   -- /mmt sync <module> and the Sync button share M.db with the team
    defaults = {
        autoMethod   = true,
        method       = "master",   -- freeforall | roundrobin | group | needbeforegreed | master
        threshold    = 2,          -- item quality (2 = Uncommon)
        looter       = "LEADER",   -- master looter / group receiver: "LEADER" or a team key
        byRoles      = true,
        roleMode     = "ALL",      -- Group Loot when several members have the role: ALL | ORDER | RR
        reserve      = 2,          -- free bag slots every member keeps
        unassigned   = "LEAVE",    -- items no role wants: LEAVE | SELF | GREED | NEED | PASS
        autoRoll     = true,       -- automated Group Loot / roll handling
        rollBoP      = false,      -- allow generic role rules & unassigned rolls on Bind on Pickup
        questRR      = true,       -- quest items: round robin (Master) / smart Need or Pass (Group)
        report       = true,
    },
})
mod.M = M

local BOP = (Enum and Enum.ItemBind and Enum.ItemBind.OnAcquire) or 1
local QUEST_BIND = (Enum and Enum.ItemBind and Enum.ItemBind.Quest) or 4
local QUEST_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12
local ITEM_SLOT = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or 1

---------------------------------------------------------------------------
-- Loot method API (classic globals or C_PartyInfo, whichever exists)
---------------------------------------------------------------------------
local NAMES = { [0] = "freeforall", [1] = "roundrobin", [2] = "master", [3] = "group", [4] = "needbeforegreed", [5] = "personal" }
local ENUM_KEYS = { freeforall = "Freeforall", roundrobin = "Roundrobin", master = "Masterlooter",
    group = "Group", needbeforegreed = "Needbeforegreed" }
local NUMBERS = { freeforall = 0, roundrobin = 1, master = 2, group = 3, needbeforegreed = 4 }

mod.METHOD_TEXT = { freeforall = "Free for All", roundrobin = "Round Robin", master = "Master Looter",
    group = "Group Loot", needbeforegreed = "Need before Greed", personal = "Personal" }

-- returns method name, master looter party index (0 = you), raid index
function mod.GetMethod()
    local fn = GetLootMethod or (C_PartyInfo and C_PartyInfo.GetLootMethod)
    if not fn then return nil end
    local ok, m, partyIndex, raidIndex = pcall(fn)
    if not ok then return nil end
    if type(m) == "number" then
        for name, key in pairs(ENUM_KEYS) do
            if Enum and Enum.LootMethod and Enum.LootMethod[key] == m then m = name break end
        end
        if type(m) == "number" then m = NAMES[m] end
    end
    return m, partyIndex, raidIndex
end

local function SetMethod(method, masterName)
    if SetLootMethod then return pcall(SetLootMethod, method, masterName) end
    if C_PartyInfo and C_PartyInfo.SetLootMethod then
        local value = (Enum and Enum.LootMethod and Enum.LootMethod[ENUM_KEYS[method]]) or NUMBERS[method]
        return pcall(C_PartyInfo.SetLootMethod, value, masterName)
    end
    return false, "no SetLootMethod API"
end

function mod.GetThreshold()
    local fn = GetLootThreshold or (C_PartyInfo and C_PartyInfo.GetLootThreshold)
    return fn and select(2, pcall(fn)) or nil
end

local function SetThreshold(q)
    local fn = SetLootThreshold or (C_PartyInfo and C_PartyInfo.SetLootThreshold)
    if fn then return pcall(fn, q) end
    return false, "no SetLootThreshold API"
end

function mod.IsMasterLooter()
    if IsMasterLooter then
        local ok, r = pcall(IsMasterLooter)
        if ok then return r and true or false end
    end
    local m, partyIndex, raidIndex = mod.GetMethod()
    if m ~= "master" then return false end
    if partyIndex == 0 then return true end
    if raidIndex and raidIndex > 0 then return UnitIsUnit("raid" .. raidIndex, "player") end
    return false
end

local function IsLeader()
    return IsInGroup() and UnitIsGroupLeader("player")
end

local function IsMemberActive(key)
    if MMT.IsSelf(key) then return true end
    local unit = MMT.UnitForMember(key)
    return unit ~= nil and UnitIsConnected(unit)
end

---------------------------------------------------------------------------
-- 1. Set the loot method
---------------------------------------------------------------------------
-- name the game accepts for a group member (as the group frames show it)
local function GroupName(key)
    if MMT.IsSelf(key) then return (UnitName("player")) end
    local unit = MMT.UnitForMember(key)
    return unit and GetUnitName(unit, true) or nil
end

function mod.MasterLooterName()
    local key = M.db.looter
    if key ~= "LEADER" and MMT.db.team[key] then
        local name = GroupName(key)
        if name then return name, key end
    end
    return (UnitName("player")), MMT.PlayerFull()
end

-- Returns whether this client is the configured looter/receiver, and their team key.
function mod.TargetLooter()
    local key = M.db.looter
    if key ~= "LEADER" and MMT.db.team[key] and IsMemberActive(key) then
        return MMT.IsSelf(key), key
    end
    if IsLeader() then return true, MMT.PlayerFull() end
    for _, unit in ipairs(MMT.GroupUnits()) do
        if UnitIsGroupLeader(unit) then
            local _, _, uKey = MMT.SplitUnit(unit)
            return false, (uKey and MMT.Resolve(uKey)) or uKey
        end
    end
    return not IsInGroup(), MMT.PlayerFull()
end

-- force: apply even if this group/leader situation was handled already
function mod.ApplyLootSettings(force)
    if not (M.enabled and M.db.autoMethod) then return false, "off" end
    if not IsLeader() then return false, "You need to be the group leader." end
    if InCombatLockdown() then return false, "Not in combat." end
    local cfg = M.db
    local current, partyIndex = mod.GetMethod()
    local masterName, masterKey = nil, nil
    if cfg.method == "master" then masterName, masterKey = mod.MasterLooterName() end
    local changed = false
    local wrongLooter = cfg.method == "master" and current == "master"
        and (MMT.IsSelf(masterKey) ~= (partyIndex == 0))
    if force or current ~= cfg.method or wrongLooter then
        local ok, err = SetMethod(cfg.method, masterName)
        M:Debug("SetLootMethod(%s, %s) -> %s %s", cfg.method, tostring(masterName), tostring(ok), tostring(err or ""))
        changed = true
    end
    if cfg.method ~= "freeforall" and (force or mod.GetThreshold() ~= cfg.threshold) then
        -- the game needs a moment after a method change before the threshold sticks
        C_Timer.After(changed and 0.8 or 0, function()
            local ok, err = SetThreshold(cfg.threshold)
            M:Debug("SetLootThreshold(%s) -> %s %s", tostring(cfg.threshold), tostring(ok), tostring(err or ""))
        end)
        changed = true
    end
    return true, changed
end

-- once per group / leader situation
local handledFor
local function CheckGroup()
    if not (M.enabled and M.db.autoMethod) then return end
    if not IsInGroup() then handledFor = nil return end
    if not IsLeader() then handledFor = nil return end
    local situation = tostring(GetNumGroupMembers()) .. (IsInRaid() and "R" or "P")
    if handledFor then return end
    handledFor = situation
    C_Timer.After(1, function()
        local ok, changed = mod.ApplyLootSettings(false)
        if ok and changed and M.db.report then
            MMT.Print("Loot set to %s%s.", mod.METHOD_TEXT[M.db.method] or M.db.method,
                M.db.method ~= "freeforall" and (" from " .. MMT.QualityName(M.db.threshold)) or "")
        end
    end)
end

M:On("GROUP_ROSTER_UPDATE", CheckGroup)
M:On("PARTY_LEADER_CHANGED", function() handledFor = nil CheckGroup() end)
M:On("GROUP_JOINED", function() handledFor = nil CheckGroup() end)

---------------------------------------------------------------------------
-- 2. Master loot by roles
---------------------------------------------------------------------------
-- free bag slots: live for you, from the team heartbeat for the others,
-- minus what was given to them since their last update
local given = {}  -- [key] = { count, time }

local function FreeSlots(key)
    if MMT.IsSelf(key) then return (MMT.UpdateOwnStatus().free) end
    local s = MMT.status[key]
    if not s or not s.free then return nil end
    local g = given[key]
    if g and g.time > s.last then return s.free - g.count end
    given[key] = nil
    return s.free
end

local function NoteGiven(key)
    local g = given[key]
    if not g or (MMT.status[key] and MMT.status[key].last > g.time) then g = { count = 0 } end
    g.count, g.time = g.count + 1, GetTime()
    given[key] = g
end

-- loot window candidate index for a team member
local function CandidateIndex(slot, key)
    for i = 1, 40 do
        local name = GetMasterLootCandidate(slot, i)
        if name and MMT.Resolve(name) == key then return i end
    end
    return nil
end

local announced = {}
local function AnnounceBoP(link)
    local now = GetTime()
    if announced[link] and now - announced[link] < 60 then return end
    announced[link] = now
    local channel = IsInRaid() and "RAID" or "PARTY"
    local msg = ("MMT: %s is Bind on Pickup and was not given out. Master looter, please assign it."):format(link)
    local ok, err = pcall(SendChatMessage, msg, channel)
    if not ok then MMT.Print(msg) M:Debug("SendChatMessage failed: %s", tostring(err)) end
end

-- free slots, minus what is already planned for you in this loot window
local function Free(key, planned)
    local free = FreeSlots(key)
    if free and planned and MMT.IsSelf(key) then free = free - (planned[key] or 0) end
    return free
end

-- the plan for one item: returns key, candidateIndex, reason
-- planned[key]: items already planned for that member in this loot window
local function Choose(slot, link, planned)
    local cfg = M.db
    local keys, roles = MMT.MembersForItem(link)
    for _, key in ipairs(keys) do
        local free = Free(key, planned)
        local index = CandidateIndex(slot, key)
        if index and free and free > cfg.reserve then
            return key, index, roles[key]
        end
        M:Debug("skip %s for %s: candidate=%s free=%s reserve=%d", MMT.Repr(key), link,
            tostring(index), tostring(free), cfg.reserve)
    end
    if #keys == 0 and cfg.unassigned == "SELF" then
        local me = MMT.PlayerFull()
        local free = Free(me, planned)
        local index = CandidateIndex(slot, me)
        if index and free and free > cfg.reserve then return me, index, nil end
    end
    return nil, nil, (#keys == 0) and "no role" or "no space"
end

---------------------------------------------------------------------------
-- Quest items: who still needs them
--
-- When a corpse holds quest items, the master looter asks the team
-- (QNQ:<id>:<name;name>) and every client checks its own quest log and
-- answers (QNA:<id>:<codes>), one code per item name:
--   Y = an objective for it is not finished yet
--   N = the objective is already complete (skip this character)
--   U = no objective for it (e.g. an item that starts a quest)
-- Members who don't answer within a moment count as U.
---------------------------------------------------------------------------
local function ItemName(link) return link and link:match("%[(.-)%]") end

-- item objectives of your quest log: { text, done }
local function ItemObjectives()
    local list = {}
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetQuestObjectives then
        for i = 1, C_QuestLog.GetNumQuestLogEntries() do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID then
                for _, o in ipairs(C_QuestLog.GetQuestObjectives(info.questID) or {}) do
                    if o.type == "item" then list[#list + 1] = { text = o.text or "", done = o.finished } end
                end
            end
        end
    elseif GetNumQuestLogEntries then
        for i = 1, GetNumQuestLogEntries() do
            local _, _, _, isHeader = GetQuestLogTitle(i)
            if not isHeader then
                for j = 1, (GetNumQuestLeaderBoards(i) or 0) do
                    local text, kind, done = GetQuestLogLeaderBoard(j, i)
                    if kind == "item" then list[#list + 1] = { text = text or "", done = done } end
                end
            end
        end
    end
    return list
end

function mod.NeedCode(name)
    if not name then return "U" end
    local lower, code = name:lower(), "U"
    for _, o in ipairs(ItemObjectives()) do
        if o.text:lower():find(lower, 1, true) then
            if not o.done then return "Y" end
            code = "N"
        end
    end
    return code
end

-- answer the master looter
M:Listen("TEAM_MESSAGE", function(key, sender, text)
    local id, names = text:match("^QNQ:(%d+):(.+)$")
    if not id then return end
    local codes = {}
    for name in names:gmatch("[^;]+") do codes[#codes + 1] = mod.NeedCode(name) end
    MMT.SendAddon(("QNA:%s:%s"):format(id, table.concat(codes)), "WHISPER", sender)
    M:Debug("quest need asked by %s: %s -> %s", MMT.Repr(sender), names, table.concat(codes))
end)

local asks = {}  -- [id] = { names = {...}, answers = {[key] = "YNU"}, done = fn }
M:Listen("TEAM_MESSAGE", function(key, sender, text)
    local id, codes = text:match("^QNA:(%d+):(%a*)$")
    local ask = id and asks[id]
    if not ask then return end
    ask.answers[key] = codes
    M:Debug("quest need from %s: %s", MMT.Repr(key), codes)
    for _, k in ipairs(ask.waitFor) do if not ask.answers[k] then return end end
    ask.finish()
end)

-- asks the online team about these item names; calls done(needOf) with
-- needOf(key, name) -> "Y" | "N" | "U"
local function AskQuestNeed(names, done)
    local id = tostring(math.random(100000, 999999))
    local waitFor = {}
    for _, key in ipairs(MMT.SortedMembers()) do
        if not MMT.IsSelf(key) and MMT.IsOnline(key) then waitFor[#waitFor + 1] = key end
    end
    local index = {}
    for i, n in ipairs(names) do index[n] = i end
    local function needOf(key, name)
        if MMT.IsSelf(key) then return mod.NeedCode(name) end
        local codes = asks[id] and asks[id].answers[key]
        local c = codes and codes:sub(index[name], index[name])
        return (c and c ~= "") and c or "U"
    end
    local finished = false
    asks[id] = { names = names, answers = {}, waitFor = waitFor, finish = function()
        if finished then return end
        finished = true
        done(needOf)
        asks[id] = nil
    end }
    if #waitFor == 0 then asks[id].finish() return end
    MMT.SendToTeam(("QNQ:%s:%s"):format(id, table.concat(names, ";")), true)
    C_Timer.After(0.8, function() if asks[id] then asks[id].finish() end end)
end

---------------------------------------------------------------------------
-- Failed hand-outs: if the game refuses an item (the loot window closes
-- before the slot empties), that member is skipped for that item for a while.
---------------------------------------------------------------------------
local BLOCK_TIME = 600
local blocked = {}   -- [itemID] = { [key] = time }
local pending = {}   -- [slot] = { link, key }  (open loot window)
local closing = {}   -- pending of the window that just closed

local function ItemID(link) return tonumber(link:match("item:(%d+)")) or link end

local function IsBlocked(link, key)
    local t = blocked[ItemID(link)] and blocked[ItemID(link)][key]
    return t and (GetTime() - t) < BLOCK_TIME
end

M:On("LOOT_SLOT_CLEARED", function(slot) pending[slot] = nil; closing[slot] = nil end)

local function CheckFailed()
    for slot, p in pairs(closing) do
        local id = ItemID(p.link)
        blocked[id] = blocked[id] or {}
        blocked[id][p.key] = GetTime()
        M:Debug("give failed: %s to %s (blocked for %d s)", p.link, MMT.Repr(p.key), BLOCK_TIME)
        MMT.Print("%s couldn't receive %s. Loot the corpse again and it goes to the next one.", MMT.FullDisplay(p.key), p.link)
        closing[slot] = nil
    end
end

---------------------------------------------------------------------------
-- Quest items: round robin
---------------------------------------------------------------------------
-- next team member after the last receiver of this item who is a loot
-- candidate, still needs it and isn't blocked. Members who said "needs it"
-- (Y) go first; "no objective" (U, e.g. quest starters) only if nobody has Y.
-- Stacks usually fit, so one free slot is enough.
local function NextQuestReceiver(slot, link, planned, needOf)
    M.store.questRR = M.store.questRR or {}
    local itemID = ItemID(link)
    local name = ItemName(link)
    local order = MMT.SortedMembers()
    if #order == 0 then return nil end
    local start = 1
    local last = M.store.questRR[itemID]
    for i, key in ipairs(order) do if key == last then start = i + 1 end end
    for _, wanted in ipairs({ "Y", "U" }) do
        for n = 0, #order - 1 do
            local key = order[(start - 1 + n) % #order + 1]
            local need = needOf(key, name)
            local index = CandidateIndex(slot, key)
            local free = Free(key, planned)
            if need == wanted and index and (free == nil or free > 0) and not IsBlocked(link, key) then
                M.store.questRR[itemID] = key
                M:Debug("quest %s -> %s (need %s)", link, MMT.Repr(key), need)
                return key, index
            end
            M:Debug("quest %s skip %s: need=%s candidate=%s free=%s blocked=%s", link, MMT.Repr(key),
                tostring(need), tostring(index), tostring(free), tostring(IsBlocked(link, key)))
        end
    end
    return nil
end

local busy = false

local function Plan(needOf)
    local cfg = M.db
    local threshold = mod.GetThreshold() or cfg.threshold
    local plan, planned = {}, {}
    for slot = 1, GetNumLootItems() do
        local slotType = GetLootSlotType and GetLootSlotType(slot) or ITEM_SLOT
        local link = GetLootSlotLink(slot)
        local _, _, _, _, quality, locked, isQuestItem = GetLootSlotInfo(slot)
        local bind = link and select(14, MMT.ItemInfo(link))
        if slotType == ITEM_SLOT and link and not locked and isQuestItem and cfg.questRR and bind ~= BOP then
            local key, index = NextQuestReceiver(slot, link, planned, needOf)
            if key then
                plan[#plan + 1] = { slot = slot, link = link, key = key, index = index, role = "quest, round robin" }
                planned[key] = (planned[key] or 0) + 1
                if not MMT.IsSelf(key) then NoteGiven(key) end
            else
                M:Debug("left quest item %s: no team member needs or can receive it", link)
            end
        elseif slotType == ITEM_SLOT and link and not locked and cfg.byRoles and (isQuestItem or (quality or 0) >= threshold) then
            if bind == BOP then
                AnnounceBoP(link)                -- never auto-assigned, never looted
            elseif bind == nil then
                M:Debug("left %s: item data not loaded yet, can't rule out Bind on Pickup", link)
            else
                local key, index, role = Choose(slot, link, planned)
                if key then
                    plan[#plan + 1] = { slot = slot, link = link, key = key, index = index, role = role }
                    planned[key] = (planned[key] or 0) + 1
                    if not MMT.IsSelf(key) then NoteGiven(key) end
                else
                    M:Debug("left %s in the loot window (%s)", link, tostring(role))
                end
            end
        end
    end
    if #plan == 0 then busy = false return end
    for i, p in ipairs(plan) do
        C_Timer.After((i - 1) * 0.25, function()
            if busy and GetLootSlotLink(p.slot) == p.link then
                pending[p.slot] = { link = p.link, key = p.key }
                GiveMasterLoot(p.slot, p.index)
                M:Debug("GiveMasterLoot(%d, %d) %s -> %s", p.slot, p.index, p.link, MMT.Repr(p.key))
                if cfg.report then
                    MMT.Print("Gave %s to %s%s.", p.link, MMT.FullDisplay(p.key), p.role and (" (" .. p.role .. ")") or "")
                end
            end
            if i == #plan then busy = false end
        end)
    end
end

local function Distribute()
    local cfg = M.db
    if busy or not M.enabled or not (cfg.byRoles or cfg.questRR) or not mod.IsMasterLooter() then return end
    busy = true
    -- quest items in this corpse? ask the team first who still needs them
    local names, seen = {}, {}
    if cfg.questRR then
        for slot = 1, GetNumLootItems() do
            local link = GetLootSlotLink(slot)
            local isQuestItem = select(7, GetLootSlotInfo(slot))
            local name = isQuestItem and ItemName(link)
            if name and not seen[name] then seen[name] = true; names[#names + 1] = name end
        end
    end
    if #names == 0 then
        Plan(function() return "U" end)
    else
        AskQuestNeed(names, function(needOf) if busy then Plan(needOf) end end)
    end
end

M:On("LOOT_OPENED", function() wipe(pending) C_Timer.After(0.1, Distribute) end)
M:On("LOOT_CLOSED", function()
    busy = false
    -- hand-outs still not cleared a moment after the window closed were refused by the game
    closing, pending = pending, {}
    C_Timer.After(0.3, CheckFailed)
end)

---------------------------------------------------------------------------
-- 3. Group loot & automated roll handling
---------------------------------------------------------------------------
local ROLL_WORD = { [0] = PASS or "Pass", [1] = NEED or "Need", [2] = GREED or "Greed" }
local CLAIM_RANK = { MANUAL = 3, NEED = 2, GREED = 1 }
local autoRolls = {}   -- [rollID] = true for rolls initiated by MMT
local retryRolls = {}  -- [rollID] = attempts

local function DoRoll(rollID, link, action, canNeed, canGreed, reason)
    if not action or action == "MANUAL" or action == "LEAVE" then return end
    local num
    if action == "NEED" then
        if canNeed then num = 1 elseif canGreed then num = 2 end
    elseif action == "GREED" then
        if canGreed then num = 2 end
    elseif action == "PASS" then
        num = 0
    end
    if num == nil then
        M:Debug("roll %s on %s skipped: action=%s canNeed=%s canGreed=%s",
            tostring(rollID), link, action, tostring(canNeed), tostring(canGreed))
        return
    end
    autoRolls[rollID] = true
    RollOnLoot(rollID, num)
    M:Debug("RollOnLoot(%s, %d [%s]) %s (%s)", tostring(rollID), num, ROLL_WORD[num], link, tostring(reason or ""))
    if M.db.report then
        MMT.Print("%s on %s%s.", ROLL_WORD[num], link, reason and (" (" .. reason .. ")") or "")
    end
end

-- Evaluates role rules for a Group Loot item; returns action ("NEED"|"GREED"|"PASS"|"MANUAL"), reason or nil.
function mod.DecideRoleRoll(link, itemID, isBoP)
    local cfg = M.db
    if not cfg.byRoles then return nil end

    -- Explicit item rules ("item") take priority over generic rules ("rule").
    -- Generic rules only apply to BoP items when cfg.rollBoP is enabled.
    local tier
    for _, role in ipairs(MMT.SortedRoleNames()) do
        local kind = MMT.RoleMatchKind(role, link)
        if kind == "item" then
            tier = "item"
            break
        elseif kind == "rule" and (not isBoP or cfg.rollBoP) then
            tier = "rule"
        end
    end
    if not tier then return nil end

    local bestAction, bestRole, passRole = {}, {}, {}
    local claimers = {}
    for _, key in ipairs(MMT.SortedMembers()) do
        if IsMemberActive(key) then
            for _, role in ipairs(MMT.MemberRoleList(key)) do
                if MMT.RoleMatchKind(role, link) == tier then
                    local r = MMT.RoleRoll(role)
                    if r == "PASS" then
                        passRole[key] = passRole[key] or role
                    elseif (CLAIM_RANK[r] or 0) > (CLAIM_RANK[bestAction[key]] or 0) then
                        bestAction[key], bestRole[key] = r, role
                    end
                end
            end
            if bestAction[key] and not passRole[key] then
                claimers[#claimers + 1] = key
            end
        end
    end

    local me = MMT.PlayerFull()
    if #claimers > 0 then
        local withSpace = {}
        for _, key in ipairs(claimers) do
            local free = Free(key)
            if bestAction[key] == "MANUAL" or free == nil or free > cfg.reserve then
                withSpace[#withSpace + 1] = key
            end
        end
        local pool = (#withSpace > 0) and withSpace or claimers
        local winners = {}
        if cfg.roleMode == "ORDER" then
            winners[pool[1]] = true
        elseif cfg.roleMode == "RR" then
            M.store.groupRR = M.store.groupRR or {}
            local last = M.store.groupRR[itemID]
            local chosen = pool[1]
            for i, key in ipairs(pool) do
                if key == last then chosen = pool[(i % #pool) + 1] break end
            end
            M.store.groupRR[itemID] = chosen
            winners[chosen] = true
        else
            for _, key in ipairs(pool) do winners[key] = true end
        end

        if me and winners[me] then
            return bestAction[me], bestRole[me]
        end
        local firstWinner = pool[1]
        for _, key in ipairs(pool) do if winners[key] then firstWinner = key break end end
        return "PASS", (bestRole[firstWinner] or "role") .. " -> " .. MMT.FirstName(firstWinner)
    end

    if me and passRole[me] then
        return "PASS", passRole[me]
    end
    return nil
end

function mod.EvaluateRoll(rollID)
    local cfg = M.db
    if not (M.enabled and cfg and cfg.autoRoll) then return true end

    local _, rollName, _, _, rollBoP, canNeed, canGreed = GetLootRollItemInfo(rollID)
    local link = GetLootRollItemLink(rollID)
    if not link then return false end

    local itemName, _, _, _, _, _, _, _, _, _, _, classID, _, bindType = MMT.ItemInfo(link)
    if not itemName then return false end

    local itemID = ItemID(link)
    local name = itemName or rollName
    local isBoP = (bindType == BOP) or (rollBoP == true)
    local isQuest = (classID == QUEST_CLASS) or (bindType == QUEST_BIND)

    -- 1. Role rules (explicit item rules run ahead of BoP and quest checks)
    local roleAction, roleReason = mod.DecideRoleRoll(link, itemID, isBoP)
    if roleAction then
        DoRoll(rollID, link, roleAction, canNeed, canGreed, roleReason)
        return true
    end

    -- 2. Quest items: Need when an objective for this item is open, Pass when finished
    if isQuest and cfg.questRR then
        local need = mod.NeedCode(name)
        if need == "Y" then
            DoRoll(rollID, link, "NEED", canNeed, canGreed, "quest")
            return true
        elseif need == "N" then
            DoRoll(rollID, link, "PASS", canNeed, canGreed, "quest done")
            return true
        end
    end

    -- 3. Unassigned items (no role matched)
    if (isBoP and not cfg.rollBoP) or (isQuest and cfg.unassigned ~= "PASS") then
        return true
    end

    local u = cfg.unassigned
    if u == "LEAVE" then
        return true
    elseif u == "SELF" then
        local isMe, looterKey = mod.TargetLooter()
        local looterFree = looterKey and Free(looterKey)
        if looterFree ~= nil and looterFree <= cfg.reserve then return true end
        if isMe then
            DoRoll(rollID, link, "GREED", canNeed, canGreed, "looter")
        elseif looterKey then
            DoRoll(rollID, link, "PASS", canNeed, canGreed, "for " .. MMT.FirstName(looterKey))
        end
    elseif u == "GREED" or u == "NEED" then
        local myFree = Free(MMT.PlayerFull())
        if myFree ~= nil and myFree <= cfg.reserve then
            DoRoll(rollID, link, "PASS", canNeed, canGreed, "bag reserve")
        else
            DoRoll(rollID, link, u, canNeed, canGreed)
        end
    elseif u == "PASS" then
        DoRoll(rollID, link, "PASS", canNeed, canGreed)
    end
    return true
end

local function RetryRoll(rollID)
    if not retryRolls[rollID] then return end
    retryRolls[rollID] = retryRolls[rollID] + 1
    if mod.EvaluateRoll(rollID) or retryRolls[rollID] >= 150 then
        retryRolls[rollID] = nil
        return
    end
    C_Timer.After(0.5, function() RetryRoll(rollID) end)
end

M:On("START_LOOT_ROLL", function(rollID)
    if mod.EvaluateRoll(rollID) then return end
    if not retryRolls[rollID] then
        retryRolls[rollID] = 0
        C_Timer.After(0.5, function() RetryRoll(rollID) end)
    end
end)

M:On("CONFIRM_LOOT_ROLL", function(rollID, rollAction)
    if not autoRolls[rollID] then return end
    autoRolls[rollID] = nil
    ConfirmLootRoll(rollID, rollAction)
end)

M:On("CANCEL_LOOT_ROLL", function(rollID)
    autoRolls[rollID] = nil
    retryRolls[rollID] = nil
end)

M.OnEnable = function() handledFor = nil; CheckGroup() end
M.OnDisable = function() busy = false; wipe(autoRolls); wipe(retryRolls) end
