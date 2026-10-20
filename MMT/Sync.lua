-- MMT: settings sync between the team's game clients.
--
--   /mmt sync            core settings of the active profile (team, roles,
--                        XP window incl. position, automations, distance
--                        window ...). Settings of modules are NOT included.
--   /mmt sync <module>   only the settings of that module, e.g.
--                        /mmt sync questtracker. Modules opt in with
--                        sync = true; see Modules.lua for the module API.
--
-- Sending goes through the core's send queue (Comm.lua): the parts use the
-- bulk prefix "MMTB" at low priority, outside instances by whisper to each
-- recipient (not throttled there), inside instances to the group. A throttled
-- message is sent again instead of being lost. Answers (SYNCACK) use the
-- normal prefix at high priority.
--
-- Messages:
--   SYNCHI:<id>:<parts>:<kind>:<label>   announces a transfer (kind: core | mod:<Name>)
--   SYNC:<id>:<i>:<parts>:<chunk>        payload parts (same format as MMT 0.6.3)
--   SYNCACK:<id>:<status>                answer of a recipient:
--       RECV (all parts there), ACCEPT, DECLINE, NOMOD (module not loaded),
--       FAIL:<got>/<parts> (parts missing), BAD (payload could not be read)
-- Payloads: core "MMT1:<serialized {name, data}>",
--           module "MMTM1:<ModuleName>:<serialized settings>".

local _, ns = ...

local CHUNK      = 225   -- payload bytes per message (whole message stays under 255)
local RECV_TIMEOUT = 25  -- recipient: seconds without a new part = incomplete
local ACK_TIMEOUT  = 20  -- sender: seconds after the last part to wait for answers

local HL = "|cff4fb3ff"   -- accent colour for names in chat
local OK = "|cff66ff66"
local BAD = "|cffff6666"

local function Name(s) return HL .. s .. "|r" end

---------------------------------------------------------------------------
-- Sending through the core queue
---------------------------------------------------------------------------
-- parts and announcements: bulk prefix, low priority; answers: high priority
local function Queue(msg, channel, target, done)
    ns.SendAddon(msg, channel, target, "BULK", done and function(ok) done(ok) end, ns.bulkPrefix)
end

local function QueueAnswer(msg, channel, target)
    ns.SendAddon(msg, channel, target, "ALERT")
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function GroupChannel()
    if IsInRaid() then return "RAID" elseif IsInGroup() then return "PARTY" end
end

-- other members of the party/raid: { [normKey] = "First Last" }
local function GroupMembers()
    local list = {}
    local units = {}
    if IsInRaid() then
        for i = 1, (GetNumGroupMembers() or 0) do units[#units + 1] = "raid" .. i end
    elseif IsInGroup() then
        for i = 1, (GetNumSubgroupMembers() or 0) do units[#units + 1] = "party" .. i end
    end
    for _, unit in ipairs(units) do
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local name = ns.NameFromGUID(ns.Safe(UnitGUID, unit), ns.Safe(UnitName, unit))
            if name and name ~= "?" then
                local key = ns.Resolve(name)
                list[key and ns.NormKey(key) or ns.NormKey(name)] = key and ns.FullDisplay(key) or name
            end
        end
    end
    return list
end

local function NameKey(sender) return ns.NormKey(ns.StripRealm(sender or "")) end

local function SenderDisplay(key, sender)
    if key then return ns.FullDisplay(key) end
    return (ns.StripRealm(sender or "?"):gsub("-", " "))
end

local function ModuleTitle(name)
    local m = ns.modules[name]
    return (m and m.title) or name
end

local function KindLabel(kind, profile)
    local modName = kind and kind:match("^mod:(.+)$")
    if modName then return ("%s settings"):format(ModuleTitle(modName)) end
    if profile and profile ~= "" then return ("core settings (profile \"%s\")"):format(profile) end
    return "core settings"
end

---------------------------------------------------------------------------
-- Sender
---------------------------------------------------------------------------
local session   -- the last transfer this client started

function ns.SyncProgress()
    if session and not session.finished then return session.sent, session.total end
    return 0, 0
end

local function Progress()
    if ns.UI and ns.UI.UpdateSyncButtons then ns.UI.UpdateSyncButtons() end
end

local function ReportMissing(s)
    if s.reported then return end
    s.reported = true
    local missing = {}
    for _, nk in ipairs(s.order) do
        if not s.answers[nk] then missing[#missing + 1] = s.expected[nk] end
    end
    if #missing > 0 then
        ns.Print("%sNo confirmation|r for the %s from: %s. (Not running MMT, an older MMT version, or the messages were lost: try again.)",
            BAD, s.label, table.concat(missing, ", "))
    elseif #s.order > 0 then
        ns.Print("%sSync complete:|r everyone received the %s.", OK, s.label)
    end
end

local function Start(kind, label, payload)
    if session and not session.finished then
        ns.Print("A sync is still being sent (%d of %d messages). Please wait a moment.", session.sent, session.total)
        return false
    end

    -- recipients: party/raid members, plus online team members outside the group
    local channel = GroupChannel()
    local expected, order = {}, {}
    local whisperName = {}   -- [nk] = name to whisper
    if channel then
        for nk, name in pairs(GroupMembers()) do expected[nk] = name; whisperName[nk] = name end
    end
    local whisper = {}
    for key in pairs(ns.db.team) do
        if not ns.IsSelf(key) then
            local nk = ns.NormKey(key)
            if expected[nk] then
                whisperName[nk] = ns.WhisperTarget(key)
            elseif ns.IsOnline(key) then
                expected[nk] = ns.FullDisplay(key)
                whisperName[nk] = ns.WhisperTarget(key)
                whisper[#whisper + 1] = key
            end
        end
    end
    for nk in pairs(expected) do order[#order + 1] = nk end
    table.sort(order, function(a, b) return expected[a] < expected[b] end)

    if #order == 0 then
        ns.Print("Nobody to send the %s to: you are not in a group and no team member is online.", label)
        return false
    end

    local id = tostring(math.random(100000, 999999))
    local parts = math.ceil(#payload / CHUNK)
    -- outside instances every recipient gets whispers (not throttled there);
    -- inside, one copy to the group plus whispers for those outside it
    local targets = {}
    local inInstance = IsInInstance and IsInInstance()
    if inInstance and channel then
        targets[#targets + 1] = { channel = channel }
        for _, key in ipairs(whisper) do targets[#targets + 1] = { channel = "WHISPER", target = ns.WhisperTarget(key) } end
    else
        for _, nk in ipairs(order) do targets[#targets + 1] = { channel = "WHISPER", target = whisperName[nk] } end
    end

    local s = {
        id = id, kind = kind, label = label, parts = parts,
        total = (parts + 1) * #targets, sent = 0, failed = 0,
        expected = expected, order = order, answers = {},
    }
    session = s

    local names = {}
    for _, nk in ipairs(order) do names[#names + 1] = Name(expected[nk]) end
    local seconds = ns.CommEstimate(s.total, #payload * #targets, inInstance)
    ns.Print("Sharing %s with: %s", label, table.concat(names, ", "))
    ns.Print("%d part(s), %d message(s), about %d s. Recipients confirm in chat when they have everything.",
        parts, s.total, seconds)

    local function Done(ok)
        s.sent = s.sent + 1
        if not ok then s.failed = s.failed + 1 end
        Progress()
        if s.sent >= s.total then
            s.finished = true
            Progress()
            if s.failed > 0 then
                ns.Print("%s%d message(s) could not be sent|r (throttled by the game). Recipients may get an incomplete transfer.", BAD, s.failed)
            else
                ns.Print("All messages sent. Waiting for confirmations ...")
            end
            C_Timer.After(ACK_TIMEOUT, function() if session == s then ReportMissing(s) end end)
        end
    end

    local hi = ("SYNCHI:%s:%d:%s:%s"):format(id, parts, kind, kind == "core" and ns.CurrentProfileName() or "")
    for _, t in ipairs(targets) do Queue(hi:sub(1, 250), t.channel, t.target, Done) end
    for i = 1, parts do
        local msg = ("SYNC:%s:%d:%d:%s"):format(id, i, parts, payload:sub((i - 1) * CHUNK + 1, i * CHUNK))
        for _, t in ipairs(targets) do Queue(msg, t.channel, t.target, Done) end
    end
    Progress()
    return true
end

function ns.SendProfileToTeam()
    if not ns.db then return end
    return Start("core", KindLabel("core", ns.CurrentProfileName()), ns.ExportCoreSettings())
end

function ns.SendModuleSettings(m)
    if not (m and m.db) then return end
    local payload = "MMTM1:" .. m.name .. ":" .. ns.Serialize(m:SyncData())
    return Start("mod:" .. m.name, KindLabel("mod:" .. m.name), payload)
end

local function OnAck(key, sender, id, status)
    local s = session
    if not s or s.id ~= id then return end
    local nk = NameKey(sender)
    if key then nk = ns.NormKey(key) end
    if not s.expected[nk] then
        -- the group list may only have had a first name (or the reverse)
        for k in pairs(s.expected) do
            if k:sub(1, #nk) == nk or nk:sub(1, #k) == k then nk = k break end
        end
    end
    local who = Name(s.expected[nk] or SenderDisplay(key, sender))
    local base, detail = status:match("^(%u+):?(.*)$")
    if base == "RECV" then
        s.answers[nk] = s.answers[nk] or "RECV"
        ns.Print("%s %sreceived|r the %s completely.", who, OK, s.label)
    elseif base == "ACCEPT" then
        s.answers[nk] = "ACCEPT"
        ns.Print("%s %saccepted|r the %s.", who, OK, s.label)
    elseif base == "DECLINE" then
        s.answers[nk] = "DECLINE"
        ns.Print("%s %sdeclined|r the %s.", who, BAD, s.label)
    elseif base == "NOMOD" then
        s.answers[nk] = "NOMOD"
        ns.Print("%s %scan't use|r the %s: that module isn't loaded there.", who, BAD, s.label)
    elseif base == "FAIL" then
        s.answers[nk] = "FAIL"
        ns.Print("%s %sreceived only %s parts|r of the %s. Send it again.", who, BAD, detail ~= "" and detail or "some", s.label)
    elseif base == "BAD" then
        s.answers[nk] = "BAD"
        ns.Print("%s %scould not read|r the %s.", who, BAD, s.label)
    else
        return
    end
    -- everybody answered: the summary needn't wait for the timeout
    if s.finished then
        local all = true
        for _, k in ipairs(s.order) do if not s.answers[k] then all = false end end
        if all then ReportMissing(s) end
    end
end

---------------------------------------------------------------------------
-- Recipient
---------------------------------------------------------------------------
local incoming = {}   -- [senderNK] = transfer

local function Answer(t, status)
    local msg = ("SYNCACK:%s:%s"):format(t.id, status)
    if t.channel == "WHISPER" then
        QueueAnswer(msg, "WHISPER", t.sender)
    else
        QueueAnswer(msg, t.channel)
    end
end

local function Announce(t)
    if t.announced then return end
    t.announced = true
    ns.Print("%s is sharing %s with you (%d part(s)) ...", Name(t.who), KindLabel(t.kind, t.profile), t.parts)
end

local function Timeout(nk, t)
    if t.timer then t.timer:Cancel() end
    t.timer = C_Timer.NewTimer(RECV_TIMEOUT, function()
        if incoming[nk] ~= t then return end
        incoming[nk] = nil
        ns.Print("%sIncomplete:|r the %s from %s stopped at %d of %d parts. Ask them to send it again.",
            BAD, KindLabel(t.kind, t.profile), Name(t.who), t.got, t.parts)
        Answer(t, ("FAIL:%d/%d"):format(t.got, t.parts))
    end)
end

local function Transfer(nk, key, sender, id, parts, channel)
    local t = incoming[nk]
    if not t or t.id ~= id then
        if t and t.timer then t.timer:Cancel() end
        t = { id = id, parts = parts, got = 0, chunks = {}, sender = sender, key = key,
              who = SenderDisplay(key, sender),
              channel = (channel == "WHISPER") and "WHISPER" or (GroupChannel() or "WHISPER") }
        incoming[nk] = t
    end
    return t
end

local function Complete(t)
    local payload = table.concat(t.chunks)
    local label = KindLabel(t.kind, t.profile)

    local modName, body = payload:match("^MMTM1:([%w_]+):(.*)$")
    if modName then
        label = KindLabel("mod:" .. modName)
        local data = ns.Deserialize(body)
        if type(data) ~= "table" then
            ns.Print("%sCould not read|r the %s from %s.", BAD, label, Name(t.who))
            Answer(t, "BAD")
            return
        end
        local m = ns.modules[modName]
        if not m then
            ns.Print("%s shared the %s, but that module isn't loaded here.", Name(t.who), label)
            Answer(t, "NOMOD")
            return
        end
        ns.Print("%sReceived|r the %s from %s completely.", OK, label, Name(t.who))
        Answer(t, "RECV")
        ns.UI.Confirm(("%s wants to share the %s settings with you.\n\nAccepting replaces your %s settings in the profile \"%s\"."):format(
                t.who, m.title, m.title, ns.CurrentProfileName()),
            "Accept settings",
            function()
                if ns.ImportModuleSettings(modName, data, t.who) then
                    ns.Print("%s settings from %s applied.", m.title, Name(t.who))
                    Answer(t, "ACCEPT")
                end
            end, "Decline",
            function()
                ns.Print("%s settings from %s declined.", m.title, Name(t.who))
                Answer(t, "DECLINE")
            end)
        return
    end

    local name, data = ns.ParseExport(payload)
    if not name then
        ns.Print("%sCould not read|r the settings from %s.", BAD, Name(t.who))
        Answer(t, "BAD")
        return
    end
    label = KindLabel("core", name)
    ns.Print("%sReceived|r the %s from %s completely.", OK, label, Name(t.who))
    Answer(t, "RECV")
    -- own dialog instead of Blizzard's StaticPopup (taint)
    ns.UI.Confirm(("%s wants to share the MMT core settings (profile \"%s\") with you: team, roles, XP window incl. position, automations.\n\nAccepting overwrites them in a profile with that name and makes it your active profile. Module settings stay as they are."):format(t.who, name),
        "Accept settings",
        function()
            if ns.ImportCoreSettings(name, data) then
                ns.Print("Core settings (profile \"%s\") from %s imported and activated.", name, Name(t.who))
                Answer(t, "ACCEPT")
            end
        end, "Decline",
        function()
            ns.Print("Core settings from %s declined.", Name(t.who))
            Answer(t, "DECLINE")
        end)
end

---------------------------------------------------------------------------
-- Incoming messages (called by Comm.lua for every text starting with SYNC)
---------------------------------------------------------------------------
function ns.OnSyncMessage(key, sender, text, channel)
    local nk = key and ns.NormKey(key) or NameKey(sender)

    local aid, status = text:match("^SYNCACK:(%d+):(.+)$")
    if aid then OnAck(key, sender, aid, status) return end

    local hid, hparts, kind, profile = text:match("^SYNCHI:(%d+):(%d+):(mod:[%w_]+):(.*)$")
    if not hid then hid, hparts, kind, profile = text:match("^SYNCHI:(%d+):(%d+):(%a+):(.*)$") end
    if hid then
        local parts = tonumber(hparts)
        if not parts or parts < 1 or parts > 200 then return end
        local t = Transfer(nk, key, sender, hid, parts, channel)
        t.kind, t.profile = kind, profile
        Announce(t)
        Timeout(nk, t)
        return
    end

    local id, idx, total, chunk = text:match("^SYNC:(%d+):(%d+):(%d+):(.*)$")
    if not id then return end
    idx, total = tonumber(idx), tonumber(total)
    if not idx or not total or total < 1 or total > 200 or idx < 1 or idx > total then return end
    local t = Transfer(nk, key, sender, id, total, channel)
    if not t.kind and idx == 1 then
        -- sender without SYNCHI (MMT 0.6.3): the first part tells what it is
        local m = chunk:match("^MMTM1:([%w_]+):")
        t.kind = m and ("mod:" .. m) or "core"
    end
    Announce(t)
    if not t.chunks[idx] then
        t.chunks[idx] = chunk
        t.got = t.got + 1
    end
    if t.got >= t.parts then
        if t.timer then t.timer:Cancel() end
        incoming[nk] = nil
        Complete(t)
    else
        Timeout(nk, t)
    end
end
