-- MMT: addon messages between the team's game clients (from MMT 0.1.x,
-- tested on WoW: Forever), extended with rested XP and layer.
--
-- Every client runs its own copy of MMT. Characters that play at the same
-- time are on different accounts, so every client has its own saved team.
-- A client only accepts XP messages from characters in ITS team.
--
-- Sending (see "Send queue" below): every message goes through one queue
-- with three priorities (ALERT, NORMAL, BULK). The game allows each addon
-- prefix about 10 messages, then 1 per second, on party/raid/guild (and on
-- whispers inside instances); the queue keeps to that, keeps a data-rate cap
-- (800 bytes/s, 1200 with "faster sending") and sends again what the game
-- throttled. Large transfers use their own prefix "MMTB", so they can't
-- delay heartbeats and alerts, and outside instances they go by whisper to
-- each team member (whispers aren't throttled there).
-- Team messages go to the party/raid (or the guild in guild mode), and by
-- whisper to team members who aren't reached that way.
--
-- Leader tag (FTL): a message can be meant only for the FTL leader ("@L:")
-- or only for everybody but the leader ("@F:"). Each receiving client checks
-- against the leader IT knows, drops the message if it isn't meant for it,
-- and passes it on without the tag. See ns.SendToLeader / scope below.

local _, ns = ...

ns.status = {}   -- [teamKey] = { level, cur, max, rested, class, layer, layerKey, isMax, last, online, sender }
ns.recent = {}   -- last received addon messages (debug report)

local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage

local ONLINE_TIMEOUT = 90
local HEARTBEAT = 30

local RESULT = {
    [0] = "Success", [1] = "InvalidPrefix", [2] = "InvalidMessage", [3] = "AddonMessageThrottle",
    [4] = "InvalidChatType", [5] = "NotInGroup", [6] = "TargetRequiredForChatType",
    [7] = "ChannelThrottle", [8] = "GeneralError",
}

ns.bulkPrefix = ns.prefix .. "B"   -- "MMTB": large transfers

---------------------------------------------------------------------------
-- Send queue
---------------------------------------------------------------------------
local PRIOS = { "ALERT", "NORMAL", "BULK" }
local queues = { ALERT = {}, NORMAL = {}, BULK = {} }
local ALLOWANCE, REGEN = 10, 1        -- per prefix (the game's defaults)
local OVERHEAD = 40                   -- bytes counted per message besides the text
local BURST = 4000                    -- bytes that may go out at once
local MAX_TRIES = 8

local buckets = {}                    -- [prefix] = { tokens, t }
local bytesAvail, bytesTime = BURST, 0
local whisperThrottledUntil = 0       -- the game throttled a whisper: count whispers too for a while
local pumpScheduled, pumping = false, false
ns.commStats = { sent = 0, bytes = 0, throttled = 0, failed = 0, maxQueued = 0 }

local function Rate()
    return (ns.db and ns.db.comm and ns.db.comm.fast) and 1200 or 800
end
ns.CommRate = Rate

local function IsSuccess(res) return res == 0 or res == true or res == nil end
local function IsThrottle(res) return res == 3 or res == 7 end

-- is this message counted against the prefix allowance?
local function Counted(channel)
    if channel ~= "WHISPER" then return true end
    return (IsInInstance and IsInInstance()) or GetTime() < whisperThrottledUntil
end

local function Bucket(prefix)
    local b = buckets[prefix]
    local now = GetTime()
    if not b then b = { tokens = ALLOWANCE, t = now }; buckets[prefix] = b end
    b.tokens = math.min(ALLOWANCE, b.tokens + (now - b.t) * REGEN)
    b.t = now
    return b
end

local function RawSend(item)
    local ok, res = pcall(SendAddon, item.prefix, item.msg, item.channel, item.target)
    if not ok then res = "error: " .. tostring(res) end
    ns.Debug("SEND %s%s %s %s -> %s %s", item.prefix == ns.prefix and "" or (item.prefix .. " "), item.channel or "?",
        item.target and ns.Repr(item.target) or "", item.msg:sub(1, 40), tostring(res), RESULT[res] or "")
    return res
end

local Pump

local function Schedule(delay)
    if pumpScheduled then return end
    pumpScheduled = true
    C_Timer.After(delay or 0.1, function() pumpScheduled = false; Pump() end)
end

Pump = function()
    if pumping then return end
    pumping = true
    local now = GetTime()
    bytesAvail = math.min(BURST, bytesAvail + (now - bytesTime) * Rate())
    bytesTime = now
    local left = 0
    for _, prio in ipairs(PRIOS) do
        local q = queues[prio]
        while q[1] do
            local item = q[1]
            local size = #item.msg + #item.prefix + OVERHEAD
            if bytesAvail < size then break end
            local b = Counted(item.channel) and Bucket(item.prefix)
            if b and b.tokens < 1 then break end
            local res = RawSend(item)
            if IsThrottle(res) then
                ns.commStats.throttled = ns.commStats.throttled + 1
                if b then b.tokens = 0 else whisperThrottledUntil = GetTime() + 15 end
                item.tries = (item.tries or 0) + 1
                if item.tries < MAX_TRIES then break end
                table.remove(q, 1)
                ns.commStats.failed = ns.commStats.failed + 1
                if item.done then pcall(item.done, false, res) end
            else
                table.remove(q, 1)
                bytesAvail = bytesAvail - size
                if b then b.tokens = b.tokens - 1 end
                ns.commStats.sent = ns.commStats.sent + 1
                ns.commStats.bytes = ns.commStats.bytes + size
                if not IsSuccess(res) then ns.commStats.failed = ns.commStats.failed + 1 end
                if item.done then pcall(item.done, IsSuccess(res), res) end
            end
        end
        left = left + #q
    end
    pumping = false
    if left > 0 then Schedule(0.1) end
end

-- Queue one message. prio: "ALERT" | "NORMAL" (default) | "BULK";
-- done(ok, result) is called once it was sent (or given up); prefix defaults to "MMT".
-- Goes out right away when the limits allow it.
local function Send(msg, channel, target, prio, done, prefix)
    prio = queues[prio] and prio or "NORMAL"
    local q = queues[prio]
    q[#q + 1] = { msg = msg, channel = channel, target = target, done = done, prefix = prefix or ns.prefix }
    local n = #queues.ALERT + #queues.NORMAL + #queues.BULK
    if n > ns.commStats.maxQueued then ns.commStats.maxQueued = n end
    Pump()
end

ns.SendAddon = Send

-- messages waiting per priority (debug report, sync progress)
function ns.CommQueued()
    return #queues.ALERT, #queues.NORMAL, #queues.BULK
end

-- rough seconds for sending `messages` messages with `bytes` bytes in total
function ns.CommEstimate(messages, bytes, counted)
    local byRate = (bytes + messages * OVERHEAD) / Rate()
    local byAllowance = counted and math.max(0, messages - ALLOWANCE) / REGEN or 0
    return math.max(1, math.ceil(math.max(byRate, byAllowance)))
end

---------------------------------------------------------------------------
-- Long texts: split into parts on the bulk prefix and put back together on
-- the other side ("MPT:<id>:<part>:<parts>:<text>"). The whole text then
-- arrives like any other message (TEAM_MESSAGE for modules).
---------------------------------------------------------------------------
local MPT_CHUNK = 220

-- leader tag: scope "LEADER" = only the FTL leader handles the message,
-- "FOLLOWERS" = everybody but the leader. nil = everybody.
local SCOPE_TAG = { LEADER = "@L:", FOLLOWERS = "@F:" }
local SCOPE_NAME = { L = "LEADER", F = "FOLLOWERS" }
local function Scoped(msg, scope)
    local tag = scope and SCOPE_TAG[scope]
    return tag and (tag .. msg) or msg
end

local function Parts(text)
    local id = tostring(math.random(100000, 999999))
    local n = math.max(1, math.ceil(#text / MPT_CHUNK))
    local list = {}
    for i = 1, n do
        list[i] = ("MPT:%s:%d:%d:%s"):format(id, i, n, text:sub((i - 1) * MPT_CHUNK + 1, i * MPT_CHUNK))
    end
    return list
end

-- to one character (target = whisper name) or, without target, to the team
function ns.SendLong(text, target, prio, scope)
    text = Scoped(text, scope)   -- the tag is in the whole text, checked after it is put together
    for _, part in ipairs(Parts(text)) do
        if target then Send(part, "WHISPER", target, prio or "BULK", nil, ns.bulkPrefix)
        else ns.SendToTeam(part, true, prio or "BULK", ns.bulkPrefix) end
    end
end

local function Note(line)
    local r = ns.recent
    r[#r + 1] = date("%H:%M:%S") .. " " .. line
    if #r > 15 then table.remove(r, 1) end
end

---------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------
function ns.IsOnline(key)
    if ns.IsSelf(key) then return true end
    local s = ns.status[key]
    return s ~= nil and s.online and (GetTime() - s.last) < ONLINE_TIMEOUT
end

-- free slots in normal bags (profession bags don't count) and total slots
local function BagSpace()
    local free, total = 0, 0
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        local slots = C_Container.GetContainerNumSlots(bag) or 0
        local f, bagType = C_Container.GetContainerNumFreeSlots(bag)
        if slots > 0 and (bagType == nil or bagType == 0) then
            free, total = free + (f or 0), total + slots
        end
    end
    return free, total
end

-- average (all items) and lowest durability in percent, nil without items
local function Durability()
    local cur, max, lowest = 0, 0, nil
    for slot = 1, 18 do
        local c, m = GetInventoryItemDurability(slot)
        if c and m and m > 0 then
            cur, max = cur + c, max + m
            local pct = c / m * 100
            if not lowest or pct < lowest then lowest = pct end
        end
    end
    if max == 0 then return nil, nil end
    return math.floor(cur / max * 100 + 0.5), math.floor(lowest + 0.5)
end

-- the faction watched on the reputation bar: { name, standing (1-8), cur, max }
-- (cur/max within the current standing), or nil
function ns.WatchedFaction()
    if C_Reputation and C_Reputation.GetWatchedFactionData then
        local ok, d = pcall(C_Reputation.GetWatchedFactionData)
        if ok and type(d) == "table" and d.name and not ns.IsSecret(d.name) then
            local lo, hi = d.currentReactionThreshold or 0, d.nextReactionThreshold or 0
            return { name = d.name, standing = d.reaction or 4,
                cur = math.max(0, (d.currentStanding or lo) - lo), max = math.max(0, hi - lo) }
        end
        return nil
    end
    if GetWatchedFactionInfo then
        local name, standing, lo, hi, value = GetWatchedFactionInfo()
        if name and not ns.IsSecret(name) then
            return { name = name, standing = standing or 4, cur = (value or 0) - (lo or 0), max = (hi or 0) - (lo or 0) }
        end
    end
    return nil
end

local function EncodeRep(r)
    if not r then return "" end
    return ("%d,%d,%d,%s"):format(r.standing or 0, r.cur or 0, r.max or 0, (tostring(r.name):gsub("[:|]", " ")))
end

local function DecodeRep(v)
    local standing, cur, max, name = (v or ""):match("^(%d+),(%-?%d+),(%-?%d+),(.*)$")
    if not standing then return nil end
    return { standing = tonumber(standing), cur = tonumber(cur), max = tonumber(max), name = name }
end

function ns.UpdateOwnStatus()
    local level = UnitLevel("player") or 0
    local cur, max = UnitXP("player") or 0, UnitXPMax("player") or 0
    local _, class = UnitClass("player")
    local maxLevel = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
    local isMax = level >= maxLevel or (IsXPUserDisabled and IsXPUserDisabled()) or false
    local s = {
        level = level, cur = cur, max = max, rested = GetXPExhaustion() or 0,
        class = class, layer = ns.layer, layerKey = ns.layerKey, isMax = isMax,
        last = GetTime(), online = true,
    }
    s.money = GetMoney()
    s.free, s.slots = BagSpace()
    s.durAvg, s.durMin = Durability()
    s.rep = ns.WatchedFaction()
    local key = ns.PlayerFull()
    if key then ns.status[key] = s end
    return s
end

-- The name to whisper: exactly as the game reported the sender last time
-- (that spelling is known to work), otherwise "First Last".
function ns.WhisperTarget(key)
    local s = ns.status[key]
    if s and s.sender then return s.sender end
    local m = ns.db.team[key]
    if m and m.name and m.last then return m.name .. " " .. m.last end
    return key
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local function UnitInGroupByKey(key)
    local name = ns.RealName(key)
    return UnitInParty(name) or UnitInRaid(name)
        or UnitInParty(ns.RealFirst(key)) or UnitInRaid(ns.RealFirst(key))
end

---------------------------------------------------------------------------
-- Guild mode: one message on the guild channel reaches every team member in
-- the guild, grouped or not. The guild roster also tells who is online.
---------------------------------------------------------------------------
ns.guildRoster = {}   -- [teamKey] = online (true/false) for team members in your guild

function ns.GuildMode()
    return ns.db and ns.db.comm and ns.db.comm.guild and IsInGuild() and true or false
end

local function RosterKey(name)
    if not name or ns.IsSecret(name) then return nil end
    return ns.Resolve(name) or ns.Resolve((name:gsub("%-[^%-]+$", "")))
end

local function ReadRoster()
    wipe(ns.guildRoster)
    if not IsInGuild() or not GetNumGuildMembers then return end
    for i = 1, (GetNumGuildMembers() or 0) do
        local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(i)
        local key = RosterKey(name)
        if key then
            ns.guildRoster[key] = online and true or false
            -- the roster knows when a member logs off before the heartbeat times out
            local st = ns.status[key]
            if st and not online and st.online then st.online = false; ns.Fire("STATUS_CHANGED") end
        end
    end
end
ns.ReadGuildRoster = ReadRoster

ns.On("GUILD_ROSTER_UPDATE", function() if ns.db and ns.db.comm and ns.db.comm.guild then ReadRoster() end end)
ns.OnLogin(function()
    C_Timer.NewTicker(60, function()
        if ns.GuildMode() then
            if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
        end
    end)
end)

-- team members who are not in your guild (guild mode reaches them by whisper)
function ns.TeamOutsideGuild()
    local list = {}
    if not IsInGuild() then return list end
    for key in pairs(ns.db.team) do
        if not ns.IsSelf(key) and ns.guildRoster[key] == nil then list[#list + 1] = key end
    end
    table.sort(list)
    return list
end

local function GroupChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and not IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return "INSTANCE_CHAT"
    end
    if IsInRaid() then return "RAID" elseif IsInGroup() then return "PARTY" end
end
ns.TeamGroupChannel = GroupChannel

-- Send to the team. onlyOnline: whisper only members believed to be online.
-- prio "BULK" (large transfers) outside instances: one whisper per member,
-- whispers aren't throttled there. Otherwise one message on the guild channel
-- (guild mode) or the party/raid, plus whispers for members it doesn't reach.
function ns.SendToTeam(msg, onlyOnline, prio, prefix, scope)
    if not ns.db then return end
    msg = Scoped(msg, scope)
    local function Whisper(key)
        if not ns.IsSelf(key) and (not onlyOnline or ns.IsOnline(key)) then
            Send(msg, "WHISPER", ns.WhisperTarget(key), prio, nil, prefix)
        end
    end
    if prio == "BULK" and not (IsInInstance and IsInInstance()) then
        for key in pairs(ns.db.team) do Whisper(key) end
        return
    end
    local guild = ns.GuildMode()
    local channel = guild and "GUILD" or GroupChannel()
    if channel then Send(msg, channel, nil, prio, nil, prefix) end
    for key in pairs(ns.db.team) do
        local reached
        if guild then reached = ns.guildRoster[key] ~= nil
        else reached = channel and UnitInGroupByKey(key) end
        if not reached then Whisper(key) end
    end
end

-- XP2:level:cur:max:class:rested:isMax:layerKey:layer:moduleData:money:freeSlots:slots:durAvg:durMin:follow:rep
-- rep = "standing,cur,max,faction name" (watched faction)
-- moduleData is "key=value,..." from modules (e.g. eq=<equipment hash>)
function ns.BuildXPMessage()
    local s = ns.UpdateOwnStatus()
    return ("XP2:%d:%d:%d:%s:%d:%d:%s:%s:%s:%d:%d:%d:%s:%s:%s:%s"):format(s.level, s.cur, s.max, s.class or "",
        s.rested, s.isMax and 1 or 0, s.layerKey or "", s.layer or "", ns.HeartbeatExtra(),
        s.money or 0, s.free or 0, s.slots or 0, s.durAvg or "", s.durMin or "",
        ns.OwnFollowField and ns.OwnFollowField() or "", EncodeRep(s.rep))
end

-- Only for the FTL leader: whispered to the leader this client knows (if
-- online), else sent to the team with the leader tag; whichever client is the
-- leader handles it. Returns "self" (and sends nothing) when this character is
-- the leader: handle it yourself then.
function ns.SendToLeader(msg, prio, prefix)
    if not ns.db then return false end
    local leader = ns.FTLLeader and ns.FTLLeader()
    if leader and ns.IsSelf(leader) then return "self" end
    if leader and ns.IsOnline(leader) then
        Send(Scoped(msg, "LEADER"), "WHISPER", ns.WhisperTarget(leader), prio, nil, prefix)
    else
        ns.SendToTeam(msg, true, prio, prefix, "LEADER")
    end
    return true
end

-- Alerts (follow, crowd control, layer hop): the FTL leader first, then the
-- rest of the team. Both at ALERT priority: the whisper "@L:" to the leader
-- leaves the queue first; the team copy carries "@F:", so the leader (who
-- already has it) ignores it. Without a leader known (or online), or when this
-- character leads, it is one plain team message.
function ns.SendAlert(msg, prefix)
    if not ns.db then return end
    local leader = ns.FTLLeader and ns.FTLLeader()
    if leader and not ns.IsSelf(leader) and ns.IsOnline(leader) then
        Send(Scoped(msg, "LEADER"), "WHISPER", ns.WhisperTarget(leader), "ALERT", nil, prefix)
        ns.SendToTeam(msg, true, "ALERT", prefix, "FOLLOWERS")
    else
        ns.SendToTeam(msg, true, "ALERT", prefix)
    end
end

-- Notes for the leader's chat (flights taken, items sold, repairs): the FTL
-- leader, or the group leader when no FTL leader is known. Returns "self"
-- (nothing sent) when this character is that leader.
function ns.IsNoticeLeaderHere()
    local leader = ns.FTLLeader and ns.FTLLeader()
    if leader then return ns.IsSelf(leader) end
    if IsInGroup() then return UnitIsGroupLeader("player") and true or false end
    return true
end

function ns.TellLeader(msg)
    if not ns.db then return end
    local leader = ns.FTLLeader and ns.FTLLeader()
    if leader then return ns.SendToLeader(msg, "NORMAL") end
    if ns.IsNoticeLeaderHere() then return "self" end
    ns.SendToTeam(msg, true, "NORMAL")   -- each receiver checks whether it is the group leader
    return true
end

function ns.BroadcastXP(onlyOnline)
    if not ns.db then return end
    ns.SendToTeam(ns.BuildXPMessage(), onlyOnline, "NORMAL")
    ns.Fire("STATUS_CHANGED")
end

---------------------------------------------------------------------------
-- System messages: hide "No player named X is currently playing" for team
-- whispers (shown and logged while debugging or pinging).
---------------------------------------------------------------------------
local notFound
if ERR_CHAT_PLAYER_NOT_FOUND_S then
    notFound = "^" .. ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"):gsub("%%s", "(.+)") .. "$"
end
if ChatFrame_AddMessageEventFilter then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, msg)
        if not ns.db or type(msg) ~= "string" or ns.IsSecret(msg) then return end
        local window = ns.noFilterUntil and GetTime() < ns.noFilterUntil
        if window then ns.Debug("SYSTEM %s", msg:sub(1, 160)) end
        local who = notFound and msg:match(notFound)
        if not who then return end
        if window or MMTDB.debug then
            ns.Debug("  'player not found' for %s -> team key %s", ns.Repr(who), ns.Repr(ns.Resolve(who)))
            return
        end
        if ns.Resolve(who) then return true end
    end)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local hinted = {}

local function HandleXP(key, sender, s)
    local old = ns.status[key]
    local wasOnline = old and old.online and (GetTime() - old.last) < ONLINE_TIMEOUT
    s.last, s.online, s.sender = GetTime(), true, sender
    if s.class and s.class ~= "" then ns.db.team[key].class = s.class end
    ns.status[key] = s
    ns.Fire("XP_RECEIVED", key, sender, s)
    if not wasOnline then
        -- they just came online: answer so they see us right away
        Send(ns.BuildXPMessage(), "WHISPER", sender, "NORMAL")
        ns.Fire("MEMBER_ONLINE", key, sender)
    end
    ns.Fire("STATUS_CHANGED")
end

local function ParseXP(text)
    local level, cur, max, class = text:match("^XP:(%d+):(%d+):(%d+):(%a*)$") -- MMT 0.1.x
    if level then
        level, cur, max = tonumber(level), tonumber(cur), tonumber(max)
        return { level = level, cur = cur, max = max, rested = 0, class = class, isMax = max == 0 }
    end
    local f = { strsplit(":", text) }
    if f[1] ~= "XP2" then return nil end
    return {
        level = tonumber(f[2]) or 0, cur = tonumber(f[3]) or 0, max = tonumber(f[4]) or 0,
        class = f[5], rested = tonumber(f[6]) or 0, isMax = f[7] == "1",
        layerKey = (f[8] ~= "" and f[8]) or nil, layer = (f[9] ~= "" and f[9]) or nil,
        ext = ns.ParseHeartbeatExtra(f[10]),
        money = tonumber(f[11]), free = tonumber(f[12]), slots = tonumber(f[13]),
        durAvg = tonumber(f[14]), durMin = tonumber(f[15]),
        follow = f[16],   -- "1" following, "0" not (missing from MMT before 0.8)
        rep = DecodeRep(f[17]),   -- watched faction (from 0.8.3)
    }
end

local function HintUnknown(sender)
    if hinted[sender] then return end
    hinted[sender] = true
    ns.Print("%s (in your group) runs MMT but is not in the team stored on THIS account.", sender)
    ns.Print("Open /mmt > Team > \"Add group\" here too, or accept a profile sent with /mmt sync from the other client.")
end

local longParts = {}   -- [sender .. id] = { n, got, parts }

local Receive

-- a multipart text: collect the parts, then handle the whole text
local function ReceivePart(text, channel, sender)
    local id, i, n, chunk = text:match("^MPT:(%d+):(%d+):(%d+):(.*)$")
    i, n = tonumber(i), tonumber(n)
    if not id or not i or not n or n < 1 or n > 400 or i < 1 or i > n then return end
    local k = sender .. ":" .. id
    local buf = longParts[k]
    if not buf then
        buf = { n = n, got = 0, parts = {} }
        longParts[k] = buf
        -- forget unfinished texts after 2 minutes
        C_Timer.After(120, function() if longParts[k] == buf then longParts[k] = nil end end)
    end
    if not buf.parts[i] then buf.parts[i] = chunk; buf.got = buf.got + 1 end
    if buf.got >= buf.n then
        longParts[k] = nil
        Receive(ns.prefix, table.concat(buf.parts), channel, sender)
    end
end

ns.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    if (prefix == ns.prefix or prefix == ns.bulkPrefix) and type(text) == "string" and not ns.IsSecret(text)
        and text:sub(1, 4) == "MPT:" then
        if ns.db and not ns.IsSelf(sender) then ReceivePart(text, channel, sender) end
        return
    end
    Receive(prefix, text, channel, sender)
end)

Receive = function(prefix, text, channel, sender)
    if (prefix ~= ns.prefix and prefix ~= ns.bulkPrefix) or not ns.db or type(text) ~= "string" or ns.IsSecret(text) then return end
    if ns.IsSelf(sender) then return end
    local fromGroup = channel == "PARTY" or channel == "RAID" or channel == "INSTANCE_CHAT"
    local key = ns.Resolve(sender)
    Note(("%s %s %s %s"):format(tostring(channel), ns.Repr(sender), key and "(team)" or "(NOT in team)", text:sub(1, 30)))
    ns.Debug("RECV %s from %s %s %s", channel or "?", ns.Repr(sender),
        key and ("-> team key " .. ns.Repr(key)) or "-> not in team", text:sub(1, 40))

    -- leader tag: drop what isn't meant for this client, pass the rest on without it
    local scope
    local tag, rest = text:match("^@([LF]):(.*)$")
    if tag then
        scope = SCOPE_NAME[tag]
        local lead = ns.IsFTLLeader ~= nil and ns.IsFTLLeader(ns.PlayerFull())
        if (scope == "LEADER") ~= lead then
            ns.Debug("  ignored: only for %s", scope == "LEADER" and "the FTL leader" or "non-leaders")
            return
        end
        text = rest
    end

    -- connectivity test, answered for everybody
    local pv = text:match("^PING:(%d+)$")
    if pv then Send("PONG:" .. pv, "WHISPER", sender, "ALERT") return end
    local ov = text:match("^PONG:(%d+)$")
    if ov then ns.OnPong(key, sender, tonumber(ov)) return end

    local isSync = text:match("^SYNC") ~= nil   -- SYNC, SYNCHI, SYNCACK (Sync.lua)
    if not key then
        if fromGroup then HintUnknown(sender) end
        if not (isSync and fromGroup) then return end -- settings sync from group members is allowed
    end
    if isSync then ns.OnSyncMessage(key, sender, text, channel) return end

    local s = ParseXP(text)
    if s then
        if key then HandleXP(key, sender, s) end
        return
    end
    if text == "BYE" then
        local st = ns.status[key or sender]
        if st then st.online = false end
        ns.Fire("STATUS_CHANGED")
        return
    end
    if key then ns.Fire("TEAM_MESSAGE", key, sender, text, scope) end -- item compare data etc.; scope: nil | "LEADER" | "FOLLOWERS"
end

---------------------------------------------------------------------------
-- Ping: whispers every team member under three spellings of the name
-- and reports which one got an answer.
---------------------------------------------------------------------------
local VARIANT_LABEL = { "team key", "First Last (space)", "first name only" }
local pending

local function Variants(key)
    local m = ns.db.team[key]
    local first = (m and m.name) or key:match("^([^-]+)") or key
    local last = m and m.last
    return { key, last and (first .. " " .. last) or false, first }
end

function ns.OnPong(key, sender, variant)
    ns.Debug("PONG from %s variant %s %s", ns.Repr(sender), tostring(variant),
        key and ("-> team key " .. ns.Repr(key)) or "-> not in team")
    if key and pending and pending[key] and variant and pending[key][variant] ~= nil then
        pending[key][variant] = true
    end
    ns.Print("PONG from %s%s", key and ns.ShownName(key) or tostring(sender), key and "" or " (not in this team)")
end

function ns.Ping()
    if not ns.db then return end
    pending = {}
    ns.noFilterUntil = GetTime() + 8
    local n = 0
    if IsInGroup() then Send("PING:0", IsInRaid() and "RAID" or "PARTY", nil, "ALERT") end
    for key in pairs(ns.db.team) do
        if not ns.IsSelf(key) then
            n = n + 1
            pending[key] = {}
            for i, name in ipairs(Variants(key)) do
                if name then
                    pending[key][i] = false
                    Send("PING:" .. i, "WHISPER", name, "ALERT")
                end
            end
        end
    end
    if n == 0 and not IsInGroup() then
        ns.Print("No other team members to ping.")
        return
    end
    ns.Print("Ping sent to %d team member(s)%s, waiting for answers...", n, IsInGroup() and " and your group" or "")
    C_Timer.After(5, function()
        for key, vars in pairs(pending or {}) do
            local ok = {}
            for i = 1, 3 do if vars[i] then ok[#ok + 1] = VARIANT_LABEL[i] end end
            ns.Print("%s: %s", ns.FullDisplay(key), #ok > 0 and ("answered via " .. table.concat(ok, ", ")) or "NO answer")
        end
        ns.Print("No answer = other client offline, no MMT there, or the name was not accepted. Run /mmt debug dump on both clients.")
    end)
end

---------------------------------------------------------------------------
-- Events / heartbeat
---------------------------------------------------------------------------
ns.OnLogin(function()
    if RegisterPrefix then
        local ok = RegisterPrefix(ns.prefix)
        local okB = RegisterPrefix(ns.bulkPrefix)
        ns.Debug("RegisterAddonMessagePrefix %s -> %s, %s -> %s", ns.prefix, tostring(ok), ns.bulkPrefix, tostring(okB))
    end
    if ns.GuildMode() then
        if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() elseif GuildRoster then GuildRoster() end
    end
    C_Timer.NewTicker(HEARTBEAT, function() ns.BroadcastXP(true) end)
end)

local lastBroadcast = 0
local function SoonBroadcast()
    if GetTime() - lastBroadcast < 1 then return end
    lastBroadcast = GetTime()
    ns.BroadcastXP(true)
end

-- gold, bags and durability change often: update the window now, tell the team a bit later
local soon = false
local function StatusChanged()
    ns.Fire("STATUS_CHANGED")
    if soon then return end
    soon = true
    C_Timer.After(5, function()
        soon = false
        ns.BroadcastXP(true)
    end)
end
ns.On("PLAYER_MONEY", StatusChanged)
ns.On("BAG_UPDATE_DELAYED", StatusChanged)
ns.On("UPDATE_INVENTORY_DURABILITY", StatusChanged)
ns.On("UPDATE_FACTION", StatusChanged)

ns.On("PLAYER_ENTERING_WORLD", function() ns.BroadcastXP(false) end)
ns.On("PLAYER_XP_UPDATE", SoonBroadcast)
ns.On("UPDATE_EXHAUSTION", SoonBroadcast)
ns.On("PLAYER_LEVEL_UP", function() C_Timer.After(1, function() ns.BroadcastXP(true) end) end)
ns.On("PLAYER_LOGOUT", function() if ns.db then ns.SendToTeam("BYE", true, "ALERT") end end)
ns.Listen("TEAM_CHANGED", function() if ns.ready then ns.BroadcastXP(false) end end)
ns.Listen("LAYER_CHANGED", function() if ns.ready then ns.BroadcastXP(true) end end)
