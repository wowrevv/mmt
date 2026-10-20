-- MMT Quest Tracker: the quest log of every team member, synced between
-- the clients over the core's team communication.
--
-- Stored account-wide in M.store.quests[teamKey] = { quests = { [questID] = rec },
-- hash = n, time = unix time }. A record:
--   { id, level, zone, title, state (0 in progress, 1 ready for turn-in, -1 failed),
--     obj = { { have, need, done, text }, ... } }
--
-- Traffic (same scheme as Item Compare):
--   * the core heartbeat carries "qt=<hash of your quest log>",
--   * a member whose stored hash differs asks once for a snapshot (QTREQ),
--     the answer comes in chunks (QTS:<id>:<i>:<n>:<data>),
--   * when your quest log changes, only the changed quests are sent
--     (QTD:<hash>#<record>~<record>~-<removed questID>).

local _, mod = ...
local MMT = MMT
local M = mod.M

local CHUNK = 200
local REQUEST_COOLDOWN = 30

mod.ownOrder = {}     -- own quest IDs in quest log order
mod.ownWatched = {}   -- [questID] = true for quests you track

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------
-- separators: ^ between fields, ~ between records, # after the hash
local function Clean(s)
    s = tostring(s or "")
    if MMT.IsSecret(s) then return "" end
    return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[%^~|#\n]", " "))
end

local function EncodeRecord(rec)
    local parts = { rec.id, rec.level or 0, rec.state or 0, Clean(rec.zone), Clean(rec.title) }
    for _, o in ipairs(rec.obj or {}) do
        parts[#parts + 1] = ("%d,%d,%d,%s"):format(o.have or 0, o.need or 0, o.done and 1 or 0, Clean(o.text))
    end
    return table.concat(parts, "^")
end
mod.EncodeRecord = EncodeRecord

local function DecodeRecord(s)
    local f = { strsplit("^", s) }
    local id = tonumber(f[1])
    if not id then return nil end
    local rec = { id = id, level = tonumber(f[2]) or 0, state = tonumber(f[3]) or 0, zone = f[4] or "", title = f[5] or "", obj = {} }
    for i = 6, #f do
        local have, need, done, text = f[i]:match("^(%-?%d+),(%-?%d+),([01]),(.*)$")
        if have then
            rec.obj[#rec.obj + 1] = { have = tonumber(have), need = tonumber(need), done = done == "1", text = text }
        end
    end
    return rec
end

local function SortedIDs(quests)
    local ids = {}
    for id in pairs(quests) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

local function Hash(quests)
    local h = 5381
    for _, id in ipairs(SortedIDs(quests)) do
        local s = EncodeRecord(quests[id])
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
        h = (h * 33 + 126) % 2147483647
    end
    return h
end
mod.Hash = Hash

---------------------------------------------------------------------------
-- Database
---------------------------------------------------------------------------
local function DB()
    M.store.quests = M.store.quests or {}
    return M.store.quests
end

function mod.QuestsOf(key)
    return M.store and DB()[key]
end

function mod.AllData() return DB() end

local function Store(key, quests)
    local rec = { quests = quests, hash = Hash(quests), time = time() }
    DB()[key] = rec
    MMT.Fire("QUESTS_CHANGED", key)
    return rec
end

---------------------------------------------------------------------------
-- Reading your own quest log
---------------------------------------------------------------------------
-- "3/8 Kobold Vermin slain" / "Kobold Vermin slain: 3/8" -> "Kobold Vermin slain"
function mod.ObjectiveName(text)
    text = tostring(text or "")
    local s = text:gsub("^%s*%d+%s*/%s*%d+%s*", ""):gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", "")
    s = s:gsub("%s*%(%d+%%%)%s*$", "")
    return s ~= "" and s or text
end

local function ParseCounts(text)
    local have, need = tostring(text or ""):match("(%d+)%s*/%s*(%d+)")
    return tonumber(have), tonumber(need)
end

local function Objectives(questID, logIndex)
    local list = {}
    if C_QuestLog and C_QuestLog.GetQuestObjectives then
        for _, o in ipairs(C_QuestLog.GetQuestObjectives(questID) or {}) do
            local have, need = o.numFulfilled, o.numRequired
            if not need or need == 0 then
                local h, n = ParseCounts(o.text)
                have, need = h or (o.finished and 1 or 0), n or 1
            end
            list[#list + 1] = { have = have or 0, need = need or 1, done = o.finished and true or false,
                text = mod.ObjectiveName(o.text) }
        end
    elseif GetNumQuestLeaderBoards and logIndex then
        for j = 1, (GetNumQuestLeaderBoards(logIndex) or 0) do
            local text, _, finished = GetQuestLogLeaderBoard(j, logIndex)
            local have, need = ParseCounts(text)
            list[#list + 1] = { have = have or (finished and 1 or 0), need = need or 1, done = finished and true or false,
                text = mod.ObjectiveName(text) }
        end
    end
    return list
end

local function StateOf(questID, isComplete)
    if C_QuestLog and C_QuestLog.IsFailed and C_QuestLog.IsFailed(questID) then return -1 end
    if isComplete == -1 then return -1 end
    local ready = (C_QuestLog and C_QuestLog.ReadyForTurnIn and C_QuestLog.ReadyForTurnIn(questID))
        or (C_QuestLog and C_QuestLog.IsComplete and C_QuestLog.IsComplete(questID))
        or isComplete == 1 or isComplete == true
    return ready and 1 or 0
end

local function IsWatched(questID, logIndex)
    if C_QuestLog and C_QuestLog.GetQuestWatchType then return C_QuestLog.GetQuestWatchType(questID) ~= nil end
    if IsQuestWatched and logIndex then return IsQuestWatched(logIndex) and true or false end
    return true
end

-- returns quests { [id] = rec }, order { id, ... }, watched { [id] = true }
function mod.ReadQuestLog()
    local quests, order, watched = {}, {}, {}
    local zone = ""
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo then
        for i = 1, (C_QuestLog.GetNumQuestLogEntries() or 0) do
            local info = C_QuestLog.GetInfo(i)
            if info then
                if info.isHeader then
                    zone = info.title or ""
                elseif info.questID and info.questID > 0 and not info.isHidden and not info.isTask and not info.isBounty then
                    local id = info.questID
                    quests[id] = { id = id, level = info.level or 0, zone = zone, title = info.title or ("Quest " .. id),
                        state = StateOf(id, info.isComplete), obj = Objectives(id, i) }
                    order[#order + 1] = id
                    if IsWatched(id, i) then watched[id] = true end
                end
            end
        end
    elseif GetNumQuestLogEntries then
        for i = 1, (GetNumQuestLogEntries() or 0) do
            local title, level, _, isHeader, _, isComplete, _, questID = GetQuestLogTitle(i)
            if isHeader then
                zone = title or ""
            elseif title and questID then
                quests[questID] = { id = questID, level = level or 0, zone = zone, title = title,
                    state = StateOf(questID, isComplete), obj = Objectives(questID, i) }
                order[#order + 1] = questID
                if IsWatched(questID, i) then watched[questID] = true end
            end
        end
    end
    return quests, order, watched
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local function SendChunks(payload, target)
    local id = tostring(math.random(100000, 999999))
    local total = math.max(1, math.ceil(#payload / CHUNK))
    for i = 1, total do
        local msg = ("QTS:%s:%d:%d:%s"):format(id, i, total, payload:sub((i - 1) * CHUNK + 1, i * CHUNK))
        -- the core queue paces the parts (bulk prefix, low priority)
        if target then MMT.SendAddon(msg, "WHISPER", target, "BULK", nil, MMT.bulkPrefix)
        else MMT.SendToTeam(msg, true, "BULK", MMT.bulkPrefix) end
    end
end

local function Payload(rec)
    local parts = {}
    for _, id in ipairs(SortedIDs(rec.quests)) do parts[#parts + 1] = EncodeRecord(rec.quests[id]) end
    return rec.hash .. "#" .. table.concat(parts, "~")
end

function mod.SendQuests(target)
    local rec = DB()[MMT.PlayerFull()]
    if not rec then return end
    local payload = Payload(rec)
    M:Debug("quest snapshot to %s (%d bytes)", target and MMT.Repr(target) or "team", #payload)
    SendChunks(payload, target)
end

function mod.OwnHash()
    local key = MMT.PlayerFull()
    local rec = key and DB()[key]
    return rec and rec.hash
end
M:Heartbeat("qt", mod.OwnHash)

---------------------------------------------------------------------------
-- Scanning (debounced) and sending changes
---------------------------------------------------------------------------
local scanned = false   -- first scan done (no announcements for the login state)
local listeners = {}

-- fn(changes, firstScan): changes = { { id, old = rec|nil, new = rec|nil }, ... }
function mod.OnOwnQuestsChanged(fn) listeners[#listeners + 1] = fn end

function mod.Scan(announce)
    local key = MMT.PlayerFull()
    if not key then return end
    local quests, order, watched = mod.ReadQuestLog()
    mod.ownOrder, mod.ownWatched = order, watched
    local old = (DB()[key] and DB()[key].quests) or {}
    local changes, parts = {}, {}
    for id, rec in pairs(quests) do
        local enc = EncodeRecord(rec)
        if not old[id] or EncodeRecord(old[id]) ~= enc then
            changes[#changes + 1] = { id = id, old = old[id], new = rec }
            parts[#parts + 1] = enc
        end
    end
    for id, rec in pairs(old) do
        if not quests[id] then
            changes[#changes + 1] = { id = id, old = rec }
            parts[#parts + 1] = "-" .. id
        end
    end
    local first = not scanned
    scanned = true
    if #changes == 0 and DB()[key] then
        MMT.Fire("QUESTS_CHANGED", key) -- watched list may have changed
        return
    end
    local rec = Store(key, quests)
    for _, fn in ipairs(listeners) do pcall(fn, changes, first) end
    if announce == false or first then return end
    local msg = "QTD:" .. rec.hash .. "#" .. table.concat(parts, "~")
    if #msg <= 250 then
        MMT.SendToTeam(msg, true)
    else
        mod.SendQuests() -- many quests changed: send a snapshot instead
    end
end

local pending = false
function mod.ScanSoon()
    if pending then return end
    pending = true
    C_Timer.After(0.5, function()
        pending = false
        if M.enabled then mod.Scan() end
    end)
end

for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_WATCH_UPDATE", "QUEST_WATCH_LIST_CHANGED", "QUEST_ACCEPTED",
    "QUEST_REMOVED", "QUEST_TURNED_IN", "UNIT_QUEST_LOG_CHANGED" }) do
    local valid = C_EventUtils and C_EventUtils.IsEventValid
    if not valid or valid(event) then
        M:On(event, function(unit)
            if event == "UNIT_QUEST_LOG_CHANGED" and unit ~= "player" then return end
            mod.ScanSoon()
        end)
    end
end

function mod.OnEnableData()
    scanned = false
    C_Timer.After(2, function()
        if not M.enabled then return end
        mod.Scan(false)
        MMT.BroadcastXP(true) -- tell the team the new hash right away
    end)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local lastRequest = {}
local function Request(key, sender)
    if lastRequest[key] and GetTime() - lastRequest[key] < REQUEST_COOLDOWN then return end
    lastRequest[key] = GetTime()
    M:Debug("quest request to %s", MMT.Repr(sender))
    MMT.SendAddon("QTREQ", "WHISPER", sender)
end

function mod.RequestAll()
    wipe(lastRequest)
    MMT.SendToTeam("QTREQ", true)
end

M:Listen("XP_RECEIVED", function(key, sender, s)
    local hash = tonumber(s.ext and s.ext.qt)
    if not hash then return end
    local rec = DB()[key]
    if not rec or rec.hash ~= hash then Request(key, sender) end
end)

local buffers, lastReply = {}, {}

local function Decode(data)
    local quests = {}
    for s in (data or ""):gmatch("[^~]+") do
        local rec = DecodeRecord(s)
        if rec then quests[rec.id] = rec end
    end
    return quests
end

M:Listen("TEAM_MESSAGE", function(key, sender, text)
    if text == "QTREQ" then
        if lastReply[key] and GetTime() - lastReply[key] < 5 then return end
        lastReply[key] = GetTime()
        mod.SendQuests(sender)
        return
    end

    local hash, list = text:match("^QTD:(%d+)#(.*)$")
    if hash then
        local rec = DB()[key]
        local quests = rec and MMT.CopyTable(rec.quests) or {}
        for s in list:gmatch("[^~]+") do
            local removed = s:match("^%-(%d+)$")
            if removed then
                quests[tonumber(removed)] = nil
            else
                local q = DecodeRecord(s)
                if q then quests[q.id] = q end
            end
        end
        rec = Store(key, quests)
        M:Debug("quest delta from %s (%d bytes)", MMT.Repr(sender), #list)
        if rec.hash ~= tonumber(hash) then Request(key, sender) end
        return
    end

    local id, idx, total, chunk = text:match("^QTS:(%d+):(%d+):(%d+):(.*)$")
    if id then
        idx, total = tonumber(idx), tonumber(total)
        if total < 1 or total > 60 or idx < 1 or idx > total then return end
        local buf = buffers[key]
        if not buf or buf.id ~= id then
            buf = { id = id, total = total, got = 0, parts = {} }
            buffers[key] = buf
        end
        if not buf.parts[idx] then buf.parts[idx] = chunk; buf.got = buf.got + 1 end
        if buf.got == buf.total then
            buffers[key] = nil
            local h, data = table.concat(buf.parts):match("^(%d+)#(.*)$")
            if h then
                local rec = Store(key, Decode(data))
                M:Debug("quest snapshot from %s: hash %s / %s", MMT.Repr(sender), h, tostring(rec.hash))
            end
        end
    end
end)

function mod.Clear()
    wipe(DB())
    mod.Scan(false)
end

function mod.QuestCount(rec)
    local n = 0
    if rec then for _ in pairs(rec.quests) do n = n + 1 end end
    return n
end
