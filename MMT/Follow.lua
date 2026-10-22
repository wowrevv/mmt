-- MMT: follow check. Warns when a team character stops following.
--
-- The game only tells a client about ITS OWN follow (AUTOFOLLOW_BEGIN /
-- AUTOFOLLOW_END), so every client reports its character's follow state:
--   FOL:1:<name>   started following <name>
--   FOL:0:<why>    stopped following; why = "" (follow broke), "c" (in combat),
--                  "t" (on a flight path: the game ends follow, not a break)
-- The heartbeat (XP2, field 16) repeats the state every 30 s, so a lost
-- message is caught up.
--
-- A break marks that member's row in the XP window (on every client). The
-- raid warning "<Name> stopped following" and the sound come from the client
-- of the character that was followed (the one you play), so they don't go off
-- on every client at once; if that character isn't in the team, every client
-- warns. With "ignore during combat", a break in combat is only reported if
-- the character still isn't following a few seconds (setting) after its combat ends.

local _, ns = ...

ns.follow = {}   -- [teamKey] = { following, target (name), targetKey, broken, since, combatBreak }

local function InCombat()
    return (UnitAffectingCombat and ns.Safe(UnitAffectingCombat, "player")) or InCombatLockdown()
end

local function F(key)
    ns.follow[key] = ns.follow[key] or {}
    return ns.follow[key]
end

ns.FOLLOW_PULSE_TIME = 10   -- seconds the XP window row pulses after a break

function ns.FollowBroken(key)
    local f = ns.follow[key]
    return f and f.broken or false
end

-- true during the first seconds after the break (row pulses)
function ns.FollowJustBroke(key)
    local f = ns.follow[key]
    return f and f.broken and f.brokenAt and (GetTime() - f.brokenAt) < ns.FOLLOW_PULSE_TIME or false
end

function ns.FollowInfo(key) return ns.follow[key] end

---------------------------------------------------------------------------
-- Warning
---------------------------------------------------------------------------
local RAID_WARNING_SOUND = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959

local function Warn(key)
    if not ns.AlertAllowed("follow", key) then return end
    local x = ns.db.xp
    local msg = ("%s stopped following"):format(ns.FullDisplay(key))
    if x.followWarn then
        if RaidNotice_AddMessage and RaidWarningFrame then
            local info = (ChatTypeInfo and ChatTypeInfo["RAID_WARNING"]) or { r = 1, g = 0.28, b = 0 }
            pcall(RaidNotice_AddMessage, RaidWarningFrame, msg, info)
        end
        ns.Print("|cffff5555%s|r", msg)
    end
    if x.followSound then pcall(PlaySound, RAID_WARNING_SOUND, "Master") end
end

---------------------------------------------------------------------------
-- State changes (own client and messages from the team)
---------------------------------------------------------------------------
local function Started(key, target)
    local f = F(key)
    f.following, f.target, f.broken, f.combatBreak, f.since = true, target, false, false, GetTime()
    f.targetKey = target and (ns.IsSelf(target) and ns.PlayerFull() or ns.Resolve(target)) or nil
    -- whoever is followed is leading: not a broken follower
    if f.targetKey then F(f.targetKey).broken = false end
    ns.Debug("FOLLOW %s -> %s", ns.Repr(key), ns.Repr(target))
    ns.Fire("STATUS_CHANGED")
end

local function Stopped(key, why)
    local f = F(key)
    local was = f.following or f.combatBreak
    f.following, f.since = false, GetTime()
    if not was then return end               -- wasn't following: nothing broke
    ns.Debug("FOLLOW %s stopped (%s)", ns.Repr(key), why ~= "" and why or "break")
    if why == "t" then f.combatBreak = false return end   -- flight path ends follow for everybody
    local x = ns.db.xp
    if not x.followCheck then return end
    -- in combat on either side: the break only counts if it lasts until
    -- after combat (checked when combat ends here, see below)
    if x.followIgnoreCombat and (why == "c" or InCombat()) then
        f.combatBreak = true                  -- reported later if still not following after combat
        ns.Fire("STATUS_CHANGED")
        return
    end
    f.combatBreak = false
    f.broken = true
    f.brokenAt = GetTime()
    -- the row pulses for PULSE_TIME, then shows "(no follow)": redraw then
    C_Timer.After(ns.FOLLOW_PULSE_TIME + 0.1, function() ns.Fire("STATUS_CHANGED") end)
    local warnHere = (not f.targetKey) or ns.IsSelf(f.targetKey)
    if warnHere then Warn(key) end
    ns.Fire("STATUS_CHANGED")
end

---------------------------------------------------------------------------
-- Own character
---------------------------------------------------------------------------
local own = { following = false, target = nil, combatBreak = false }

function ns.IsFollowing() return own.following end

function ns.OwnFollowField()
    return (own.following or own.pendingStop) and "1" or "0"
end

local function Send(msg) if ns.SendAlert then ns.SendAlert(msg) end end   -- leader first


ns.On("AUTOFOLLOW_BEGIN", function(name)
    if ns.IsSecret(name) then name = nil end
    own.stopSeq = (own.stopSeq or 0) + 1   -- a pending stop (see below) is void
    own.pendingStop = false
    own.following, own.target, own.combatBreak = true, name, false
    Send("FOL:1:" .. (name or ""))
    local me = ns.PlayerFull()
    if me then Started(me, name) end
end)

-- A stop only counts if follow isn't taken up again within STOP_GRACE
-- seconds: following the same character again (or a new /follow) ends the
-- old follow for a split second first.
local STOP_GRACE = 0.5

ns.On("AUTOFOLLOW_END", function()
    if not own.following then return end
    own.following = false
    local why = ""
    if UnitOnTaxi and ns.Safe(UnitOnTaxi, "player") then why = "t"
    elseif InCombat() then why = "c" end
    own.stopSeq = (own.stopSeq or 0) + 1
    local seq = own.stopSeq
    own.pendingStop = true
    C_Timer.After(STOP_GRACE, function()
        if seq ~= own.stopSeq or own.following then return end   -- following again
        own.pendingStop = false
        if why == "c" then own.combatBreak = true end
        Send("FOL:0:" .. why)
        local me = ns.PlayerFull()
        if me then Stopped(me, why) end
    end)
end)

-- combat over and still not following again: now it counts as a break
ns.On("PLAYER_REGEN_ENABLED", function()
    C_Timer.After(ns.db.xp.followCombatDelay or 5, function()
        if InCombat() then return end   -- the next fight started: checked when it ends
        -- team members whose break fell into a fight (on their or this client)
        for key, f in pairs(ns.follow) do
            if f.combatBreak and not f.following and not ns.IsSelf(key) then Stopped(key, "") end
        end
        if own.following or not own.combatBreak then return end
        own.combatBreak = false
        Send("FOL:0:")
        local me = ns.PlayerFull()
        if me then Stopped(me, "") end
    end)
end)

-- a loading screen ends follow without AUTOFOLLOW_END on some clients
ns.On("PLAYER_ENTERING_WORLD", function()
    own.following, own.combatBreak = false, false
end)

---------------------------------------------------------------------------
-- Team
---------------------------------------------------------------------------
ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    local flag, arg = text:match("^FOL:([01]):(.*)$")
    if not flag then return end
    if flag == "1" then Started(key, arg ~= "" and arg or nil) else Stopped(key, arg) end
end)

-- heartbeat: catch up on a lost FOL message
ns.Listen("XP_RECEIVED", function(key, sender, s)
    local f = ns.follow[key]
    if s.follow == "1" and not (f and f.following) then
        F(key).following = true
        F(key).broken = false
        ns.Fire("STATUS_CHANGED")
    elseif s.follow == "0" and f and f.following then
        Stopped(key, "")
    end
end)

-- switching the check off clears all marks
ns.OnRefresh(function()
    if ns.db and not ns.db.xp.followCheck then
        for _, f in pairs(ns.follow) do f.broken = false; f.combatBreak = false end
    end
end)
