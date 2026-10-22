-- MMT: crowd control check. Shows when a team character can't move:
-- stunned, feared/charmed, incapacitated (polymorph, sap, sleep) or rooted.
--
-- The game only tells a client about ITS OWN loss of control, so every
-- client watches its character and reports it (high priority):
--   CC:<kind>:<seconds left>:<spell id>   kind: S stun, F fear/charm,
--                                         I incapacitate, R root, X unknown
--   CC:-                                  free again
-- Seconds left is "" when the game doesn't tell. A mark that isn't renewed
-- or ended expires on its own (end of the effect, or 30 s), so a lost
-- message can't leave a row marked.
--
-- Every client's XP window marks the row (orange, pulsing) with a countdown.
-- The raid warning and the sound come only from the FTL leader's client (the
-- character you play), so they don't go off on every client at once; with no
-- leader known, every client warns. No chat lines: in a fight they would
-- flood the chat.

local _, ns = ...

ns.cc = {}   -- [teamKey] = { kind, ends (GetTime) | nil, spell, at }

local LABEL = { S = "stunned", F = "feared", I = "incapacitated", R = "rooted", X = "lost control" }
local OPTION = { S = "stun", F = "fear", I = "incap", R = "root", X = "stun" }

-- loss of control types (C_LossOfControl) that keep a character from moving
local KIND = {
    STUN = "S", STUN_MECHANIC = "S",
    FEAR = "F", FEAR_MECHANIC = "F", CHARM = "F", POSSESS = "F",
    CONFUSE = "I", SLEEP = "I",
    ROOT = "R",
}
-- the stronger effect wins when several are active
local RANK = { S = 4, F = 3, I = 3, X = 2, R = 1 }

local UNKNOWN_TIMEOUT = 30   -- seconds a mark without known duration is kept

function ns.CCLabel(kind) return LABEL[kind] or "crowd controlled" end

-- the active crowd control of a member, or nil
function ns.CCState(key)
    local c = ns.cc[key]
    if not c then return nil end
    local now = GetTime()
    if (c.ends and now > c.ends + 1) or (not c.ends and now - c.at > UNKNOWN_TIMEOUT) then
        ns.cc[key] = nil
        return nil
    end
    return c
end

-- seconds left (rounded up), or nil if unknown
function ns.CCLeft(c)
    if not (c and c.ends) then return nil end
    return math.max(0, math.ceil(c.ends - GetTime()))
end

-- "stunned 4" (for the XP window)
function ns.CCShort(key)
    local c = ns.CCState(key)
    if not c then return nil end
    local left = ns.CCLeft(c)
    return ns.CCLabel(c.kind) .. (left and left > 0 and (" " .. left) or "")
end

function ns.CCSpellName(c)
    if not (c and c.spell) then return nil end
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(c.spell)
        or (GetSpellInfo and GetSpellInfo(c.spell))
    if name and not ns.IsSecret(name) then return name end
end

---------------------------------------------------------------------------
-- Redraw once a second while anybody is marked (countdown, expiry)
---------------------------------------------------------------------------
local ticker
local function Tick()
    local any = false
    for key in pairs(ns.cc) do if ns.CCState(key) then any = true end end
    ns.Fire("STATUS_CHANGED")
    if not any and ticker then ticker:Cancel(); ticker = nil end
end
local function StartTicker()
    if not ticker and C_Timer.NewTicker then ticker = C_Timer.NewTicker(1, Tick) end
end

---------------------------------------------------------------------------
-- Warning
---------------------------------------------------------------------------
local RAID_WARNING_SOUND = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959

local function WarnHere(key)
    if ns.IsSelf(key) then return false end   -- your own character: you see it
    local leader = ns.FTLLeader and ns.FTLLeader()
    return not leader or ns.IsSelf(leader)
end

local function Warn(key, c)
    local cfg = ns.db.cc
    local left = ns.CCLeft(c)
    local msg = ("%s is %s%s"):format(ns.FullDisplay(key), ns.CCLabel(c.kind), left and left > 0 and (" (" .. left .. " s)") or "")
    if cfg.warn and RaidNotice_AddMessage and RaidWarningFrame then
        pcall(RaidNotice_AddMessage, RaidWarningFrame, msg, { r = 1, g = 0.6, b = 0.1 })
    end
    if cfg.sound then pcall(PlaySound, RAID_WARNING_SOUND, "Master") end
end

---------------------------------------------------------------------------
-- State of a member (own client and messages from the team)
---------------------------------------------------------------------------
local function Set(key, kind, left, spell)
    local old = ns.CCState(key)
    if not kind then
        if old then ns.cc[key] = nil; ns.Fire("STATUS_CHANGED") end
        return
    end
    local cfg = ns.db.cc
    if not (cfg.enabled and cfg[OPTION[kind]]) then return end
    ns.cc[key] = { kind = kind, ends = left and (GetTime() + left) or nil, spell = spell, at = GetTime() }
    ns.Debug("CC %s %s %s", ns.Repr(key), kind, tostring(left))
    if (not old or old.kind ~= kind) and WarnHere(key) then Warn(key, ns.cc[key]) end
    StartTicker()
    ns.Fire("STATUS_CHANGED")
end

ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    if text == "CC:-" then Set(key, nil) return end
    local kind, left, spell = text:match("^CC:(%u):([%d%.]*):(%d*)$")
    if not kind then return end
    Set(key, kind, tonumber(left), tonumber(spell))
end)

---------------------------------------------------------------------------
-- Own character
---------------------------------------------------------------------------
local function Plain(v)
    if v == nil or ns.IsSecret(v) then return nil end
    return v
end

-- strongest active effect that keeps us from moving: kind, seconds left, spell id
local function Scan()
    local cfg = ns.db.cc
    local api = C_LossOfControl
    local count = api and api.GetActiveLossOfControlDataCount and Plain(api.GetActiveLossOfControlDataCount())
    local unreadable = false
    local best, bestLeft, bestSpell
    if count then
        for i = 1, count do
            local d = api.GetActiveLossOfControlData and api.GetActiveLossOfControlData(i)
            local locType = d and Plain(d.locType)
            if d and not locType then unreadable = true end
            local kind = locType and KIND[locType]
            if kind and cfg[OPTION[kind]] then
                local dur, left = Plain(d.duration), Plain(d.timeRemaining)
                if not (dur and dur > 0 and dur < (cfg.minDuration or 0)) then
                    if not best or RANK[kind] > RANK[best] or (RANK[kind] == RANK[best] and (left or 99) > (bestLeft or 99)) then
                        best, bestLeft, bestSpell = kind, left, Plain(d.spellID)
                    end
                end
            end
        end
    end
    -- no readable data: the game at least says whether we control the character
    -- (stun, fear, charm, incapacitate; not roots)
    if not best and (not count or unreadable) and HasFullControl and cfg.stun then
        local full = Plain(HasFullControl())
        if full == false and not (UnitOnTaxi and ns.Safe(UnitOnTaxi, "player")) and not ns.Safe(UnitIsDeadOrGhost, "player") then
            best = "X"
        end
    end
    return best, bestLeft and math.floor(bestLeft * 10 + 0.5) / 10, bestSpell
end

local own = { kind = nil, ends = nil }
local scanTicker

local function Send(msg) if ns.SendAlert then ns.SendAlert(msg) end end   -- leader first

local function Check()
    if not (ns.ready and ns.db and ns.db.cc.enabled) then return end
    local kind, left, spell = Scan()
    local me = ns.PlayerFull()
    if kind then
        local ends = left and (GetTime() + left) or nil
        -- report a new effect, another kind, or a clearly different end (renewed)
        local changed = kind ~= own.kind or (ends and not own.ends) or (ends and own.ends and math.abs(ends - own.ends) > 1)
        own.kind, own.ends = kind, ends
        if changed then
            Send(("CC:%s:%s:%s"):format(kind, left and ("%.1f"):format(left) or "", spell or ""))
            if me then Set(me, kind, left, spell) end
        end
        -- some clients don't announce the end: look again while it lasts
        if not scanTicker and C_Timer.NewTicker then scanTicker = C_Timer.NewTicker(0.5, Check) end
    else
        if scanTicker then scanTicker:Cancel(); scanTicker = nil end
        if own.kind then
            own.kind, own.ends = nil, nil
            Send("CC:-")
            if me then Set(me, nil) end
        end
    end
end
ns.CCCheck = Check

for _, e in ipairs({ "LOSS_OF_CONTROL_ADDED", "LOSS_OF_CONTROL_UPDATE", "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED" }) do
    ns.On(e, function() Check() end)
end
-- dying or a loading screen ends every effect
ns.On("PLAYER_DEAD", function() Check() end)
ns.On("PLAYER_ENTERING_WORLD", function() Check() end)

-- switching the check (or a kind) off clears the marks
ns.OnRefresh(function()
    if not ns.db then return end
    local cfg = ns.db.cc
    for key, c in pairs(ns.cc) do
        if not (cfg.enabled and cfg[OPTION[c.kind]]) then ns.cc[key] = nil end
    end
end)
