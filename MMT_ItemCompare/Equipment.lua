-- MMT Item Compare: database of the team's equipped items, synced between
-- the clients.
--
-- Stored account-wide in M.store.equipment[teamKey] = { items = {[slot] = itemString},
-- hash = n, time = unix time }, so items of offline members stay available.
--
-- Only item strings travel (e.g. "4567:0:0:0:0:0:-17"), never tooltips;
-- every client asks the server for the item data itself. Traffic:
--   * the core heartbeat carries "eq=<hash of your equipment>",
--   * a member whose stored hash differs asks for a snapshot once (EQREQ),
--   * when you change gear, only the changed slots are sent (EQD).

local _, mod = ...
local MMT = MMT
local M = mod.M

local SLOTS = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }
local CHUNK = 200
local REQUEST_COOLDOWN = 60

---------------------------------------------------------------------------
-- Item strings
---------------------------------------------------------------------------
-- Link -> compact item string. Link level and spec (fields 9 and 10) change
-- with the character's level and don't affect the item, so they're blanked.
function mod.CompressItem(link)
    if type(link) ~= "string" or MMT.IsSecret(link) then return nil end
    local s = link:match("item:([%-%d:]+)")
    if not s then return nil end
    local f = { strsplit(":", s) }
    for i = 9, 10 do if f[i] then f[i] = "" end end
    local n = #f
    while n > 1 and (f[n] == "" or f[n] == "0") do n = n - 1 end
    return table.concat(f, ":", 1, n)
end

function mod.ExpandItem(s)
    return s and ("item:" .. s) or nil
end

local function Encode(items)
    local parts = {}
    for _, slot in ipairs(SLOTS) do
        if items[slot] then parts[#parts + 1] = slot .. "=" .. items[slot] end
    end
    return table.concat(parts, ";")
end

local function Decode(data)
    local items = {}
    for slot, item in (data or ""):gmatch("(%d+)=([^;]*)") do
        if item ~= "" then items[tonumber(slot)] = item end
    end
    return items
end

local function Hash(items)
    local s = Encode(items)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    return h
end
mod.Hash = Hash

---------------------------------------------------------------------------
-- Database
---------------------------------------------------------------------------
local function DB()
    M.store.equipment = M.store.equipment or {}
    return M.store.equipment
end

function mod.EquipmentOf(key)
    return M.store and DB()[key]
end

local function Store(key, items)
    local rec = { items = items, hash = Hash(items), time = time() }
    DB()[key] = rec
    MMT.Fire("EQUIPMENT_CHANGED", key)
    return rec
end

local function ReadOwn()
    local items = {}
    for _, slot in ipairs(SLOTS) do
        items[slot] = mod.CompressItem(GetInventoryItemLink("player", slot))
    end
    return items
end

function mod.OwnHash()
    local key = MMT.PlayerFull()
    local rec = key and DB()[key]
    return rec and rec.hash
end

-- the core puts this into every heartbeat as eq=<hash>
M:Heartbeat("eq", mod.OwnHash)

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local function SendChunks(payload, target)
    local id = tostring(math.random(100000, 999999))
    local total = math.max(1, math.ceil(#payload / CHUNK))
    for i = 1, total do
        local msg = ("EQS:%s:%d:%d:%s"):format(id, i, total, payload:sub((i - 1) * CHUNK + 1, i * CHUNK))
        -- the core queue paces the parts (bulk prefix, low priority)
        if target then MMT.SendAddon(msg, "WHISPER", target, "BULK", nil, MMT.bulkPrefix)
        else MMT.SendToTeam(msg, true, "BULK", MMT.bulkPrefix) end
    end
end

-- full snapshot to one character (reply to a request) or to the whole team
function mod.SendEquipment(target)
    local rec = DB()[MMT.PlayerFull()]
    if not rec then return end
    local payload = rec.hash .. "#" .. Encode(rec.items)
    M:Debug("snapshot to %s (%d bytes)", target and MMT.Repr(target) or "team", #payload)
    SendChunks(payload, target)
end

local previous
function mod.UpdateOwn(announce)
    local key = MMT.PlayerFull()
    if not key then return end
    local items = ReadOwn()
    local old = previous or (DB()[key] and DB()[key].items) or {}
    local changed = {}
    for _, slot in ipairs(SLOTS) do
        if old[slot] ~= items[slot] then changed[#changed + 1] = slot .. "=" .. (items[slot] or "") end
    end
    previous = items
    if #changed == 0 and DB()[key] then return end
    local rec = Store(key, items)
    if not announce or #changed == 0 then return end
    local msg = "EQD:" .. rec.hash .. "#" .. table.concat(changed, ";")
    if #msg <= 250 then
        MMT.SendToTeam(msg, true)
    else
        mod.SendEquipment() -- many slots changed (gear set): send a snapshot instead
    end
end

local pending = false
M:On("PLAYER_EQUIPMENT_CHANGED", function()
    if pending then return end
    pending = true
    C_Timer.After(1.5, function()
        pending = false
        if M.enabled then mod.UpdateOwn(true) end
    end)
end)

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local lastRequest = {}
local function Request(key, sender)
    if lastRequest[key] and GetTime() - lastRequest[key] < REQUEST_COOLDOWN then return end
    lastRequest[key] = GetTime()
    M:Debug("request to %s", MMT.Repr(sender))
    MMT.SendAddon("EQREQ", "WHISPER", sender)
end

function mod.RequestAll()
    wipe(lastRequest)
    MMT.SendToTeam("EQREQ", true)
end

M:Listen("XP_RECEIVED", function(key, sender, s)
    local hash = tonumber(s.ext and s.ext.eq)
    if not hash then return end
    local rec = DB()[key]
    if not rec or rec.hash ~= hash then Request(key, sender) end
end)

local buffers, lastReply = {}, {}

M:Listen("TEAM_MESSAGE", function(key, sender, text)
    if text == "EQREQ" then
        if lastReply[key] and GetTime() - lastReply[key] < 5 then return end
        lastReply[key] = GetTime()
        mod.SendEquipment(sender)
        return
    end

    local hash, list = text:match("^EQD:(%d+)#(.*)$")
    if hash then
        local rec = DB()[key]
        local items = rec and MMT.CopyTable(rec.items) or {}
        for slot, item in list:gmatch("(%d+)=([^;]*)") do
            items[tonumber(slot)] = (item ~= "") and item or nil
        end
        rec = Store(key, items)
        M:Debug("delta from %s: %s", MMT.Repr(sender), list)
        if rec.hash ~= tonumber(hash) then Request(key, sender) end
        return
    end

    local id, idx, total, chunk = text:match("^EQS:(%d+):(%d+):(%d+):(.*)$")
    if id then
        idx, total = tonumber(idx), tonumber(total)
        if total < 1 or total > 20 or idx < 1 or idx > total then return end
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
                M:Debug("snapshot from %s: hash %s / %s", MMT.Repr(sender), h, tostring(rec.hash))
            end
        end
    end
end)

function mod.Clear()
    wipe(DB())
    previous = nil
    mod.UpdateOwn(false)
end

function mod.ItemCount(rec)
    local n = 0
    if rec then for _ in pairs(rec.items) do n = n + 1 end end
    return n
end
