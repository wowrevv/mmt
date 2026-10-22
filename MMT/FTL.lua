-- MMT: FTL (Focusless, Targetless, Leaderless), after the ISBoxer feature.
--
-- Macros written in MMT with {FTL} (e.g. "/follow {FTL}") become real WoW
-- macros in which {FTL} is the character you are playing right now, "the
-- leader". When the leader changes, every client rewrites its macros.
--
-- WoW lets addons change macros only outside combat: a leader change in
-- combat is applied as soon as combat ends (ISBoxer can switch in combat
-- because it sends modifier keys from outside the game).
--
-- The leader is set by
--   * a left-click on a character in the XP window,
--   * the key binding "MMT: Make this character the leader",
--   * /mmt leader (this character) or /mmt leader <name>,
--   * automatically when you move a character that isn't following (setting).
-- and sent to the team: FTL:<server time>:<team key> (the newest wins; two
-- claims in the same second: the team key that sorts first wins, on every
-- client alike, so the clients can't end up with different leaders).
--
-- Automatic detection ignores
--   * movement in combat (the macros can't change then anyway),
--   * movement while following, on a flight path, or without control of the
--     character (feared, charmed, confused, mind controlled),
--   * movement of several team characters at once (a movement key or
--     "Interact with Target" broadcast to every window): every client reports
--     when its character starts moving on its own (FTLM), and a character only
--     becomes the leader if no other team character started moving within
--     MOVE_WINDOW seconds of it. The current leader stays then.
-- The leader is kept account-wide (MMTDB.ftl), so a /reload keeps it.

local _, ns = ...

local MAX_GLOBAL_MACROS = MAX_ACCOUNT_MACROS or 120
local DEFAULT_ICON = "INV_Misc_QuestionMark"

local pending = false   -- macros to update once combat ends

local function State()
    MMTDB.ftl = MMTDB.ftl or {}
    MMTDB.ftl.managed = MMTDB.ftl.managed or {}   -- [macro name] = true for macros MMT created
    return MMTDB.ftl
end

function ns.FTLLeader()
    return MMTDB and MMTDB.ftl and MMTDB.ftl.leader
end

function ns.IsFTLLeader(key)
    local l = ns.FTLLeader()
    return l ~= nil and key ~= nil and ns.NormKey(l) == ns.NormKey(key)
end

---------------------------------------------------------------------------
-- {FTL} -> name of the leader
---------------------------------------------------------------------------
-- the text {FTL} stands for on this client, or nil (no leader known)
function ns.FTLName()
    local key = ns.FTLLeader()
    if not key then return nil end
    local fmt = ns.db.ftl.nameFormat
    -- real names: the game must find the character (privacy settings don't apply)
    if fmt == "FIRST" then return ns.RealFirst(key) end
    if fmt == "UNIT" then
        if ns.IsSelf(key) then return "player" end
        return (ns.UnitForMember and ns.UnitForMember(key)) or ns.RealName(key)
    end
    return ns.RealName(key)
end

-- template -> macro text for this client; second value: true if cut at 255 characters
function ns.FTLResolve(body)
    local key = ns.FTLLeader()
    local name = ns.FTLName()
    local skip = key and ns.IsSelf(key) and ns.db.ftl.skipSelf
    local lines = {}
    for line in ((body or "") .. "\n"):gmatch("(.-)\n") do
        if line:find("{FTL}", 1, true) then
            -- no leader yet, or the leader's own client: leave the line out
            if name and not skip then lines[#lines + 1] = (line:gsub("{FTL}", (name:gsub("%%", "%%%%")))) end
        else
            lines[#lines + 1] = line
        end
    end
    local text = table.concat(lines, "\n")
    if #text > 255 then return text:sub(1, 255), true end
    return text, false
end

---------------------------------------------------------------------------
-- Writing the WoW macros (account macros of this client)
---------------------------------------------------------------------------
local function GlobalMacroCount()
    local n = GetNumMacros and GetNumMacros() or 0
    return n
end

-- returns a short status for the settings page
function ns.FTLUpdateMacros(reason)
    if not ns.db or not ns.db.ftl then return end
    if InCombatLockdown() then
        pending = true
        return "combat"
    end
    pending = false
    if not (CreateMacro and EditMacro and GetMacroIndexByName) then return "no macro API" end
    local st = State()
    local cfg = ns.db.ftl
    local wanted = {}
    if cfg.enabled then
        for _, m in ipairs(cfg.macros or {}) do
            local name = ns.Trim(m.name or "")
            if name ~= "" then
                wanted[name] = true
                local text = ns.FTLResolve(m.body)
                local icon = (m.icon and m.icon ~= "") and m.icon or DEFAULT_ICON
                local index = GetMacroIndexByName(name)
                if not index or index == 0 then
                    if GlobalMacroCount() < MAX_GLOBAL_MACROS then
                        local ok, err = pcall(CreateMacro, name, icon, text, nil)
                        ns.Debug("FTL: create macro %s -> %s %s", ns.Repr(name), tostring(ok), tostring(err or ""))
                        if ok then st.managed[name] = true end
                    else
                        ns.Print("FTL: no room for the macro \"%s\" (the account macros are full).", name)
                    end
                else
                    st.managed[name] = true
                    local current = GetMacroBody and GetMacroBody(index)
                    if current ~= text then
                        local ok, err = pcall(EditMacro, index, name, icon, text)
                        ns.Debug("FTL: edit macro %s -> %s %s", ns.Repr(name), tostring(ok), tostring(err or ""))
                    end
                end
            end
        end
    end
    -- macros MMT created that are no longer wanted (deleted, renamed, FTL off)
    for name in pairs(st.managed) do
        if not wanted[name] then
            local index = GetMacroIndexByName(name)
            if index and index > 0 and DeleteMacro then pcall(DeleteMacro, index) end
            st.managed[name] = nil
            ns.Debug("FTL: removed macro %s", ns.Repr(name))
        end
    end
    ns.Fire("FTL_MACROS_CHANGED", reason)
    return "ok"
end

-- put a macro on the cursor (to drag it to an action bar)
function ns.FTLPickup(name)
    if InCombatLockdown() then ns.Print("Not in combat.") return end
    local index = GetMacroIndexByName and GetMacroIndexByName(name)
    if index and index > 0 and PickupMacro then PickupMacro(index) end
end

---------------------------------------------------------------------------
-- Leader
---------------------------------------------------------------------------
local function Now() return (GetServerTime and GetServerTime()) or time() end

-- same second: the team key that sorts first wins (the same answer on every client)
local function Wins(key, other)
    return ns.NormKey(key) < ns.NormKey(other)
end

local function Send(msg, target)
    if target then ns.SendAddon(msg, "WHISPER", target, "ALERT")
    elseif ns.SendToTeam then ns.SendToTeam(msg, true, "ALERT") end
end

-- key: team key of the new leader. fromTeam: the change came from another client.
function ns.SetFTLLeader(key, fromTeam, when)
    if not key or not ns.db then return end
    local st = State()
    when = when or Now()
    if st.leader and ns.NormKey(st.leader) == ns.NormKey(key) then
        st.time = math.max(st.time or 0, when)
        return
    end
    if fromTeam and st.time then
        if when < st.time then return end                                  -- an older change
        if when == st.time and st.leader and not Wins(key, st.leader) then return end
    end
    st.leader, st.time = key, when
    ns.Debug("FTL: leader %s (%s)", ns.Repr(key), fromTeam and "from team" or "here")
    local status = ns.FTLUpdateMacros("leader")
    if ns.db.ftl.announce then
        if status == "combat" then
            ns.Print("FTL: %s is the leader now. The macros change when combat ends.", ns.FullDisplay(key))
        else
            ns.Print("FTL: %s is the leader now.", ns.FullDisplay(key))
        end
    elseif status == "combat" then
        ns.Print("FTL: the macros change to %s when combat ends.", ns.FullDisplay(key))
    end
    if not fromTeam then Send(("FTL:%d:%s"):format(when, key)) end
    ns.Fire("FTL_LEADER", key)
    ns.Fire("STATUS_CHANGED")
end

-- a claim here is always newer than the leader we know (the same second
-- would be a tie that this claim might lose on the other clients)
function ns.ClaimFTLLeader()
    local me = ns.PlayerFull()
    if not me then return end
    local st = State()
    ns.SetFTLLeader(me, false, math.max(Now(), (st.time or 0) + 1))
end

-- key binding (Bindings.xml)
function MMT_FTL_SetLeader()
    if ns.ready and ns.db and ns.db.ftl.enabled then ns.ClaimFTLLeader() end
end
BINDING_HEADER_MMT = BINDING_HEADER_MMT or "MMT - Manage My Team"
BINDING_NAME_MMT_FTL_LEADER = "Make this character the leader (FTL)"

ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    local when, who = text:match("^FTL:(%d+):(.+)$")
    if not when then return end
    local leader = ns.IsSelf(who) and ns.PlayerFull() or ns.Resolve(who)
    if leader then ns.SetFTLLeader(leader, true, tonumber(when)) end
end)

-- a member comes online: tell them who leads
ns.Listen("MEMBER_ONLINE", function(key, sender)
    local st = MMTDB.ftl
    if ns.db.ftl.enabled and st and st.leader then Send(("FTL:%d:%s"):format(st.time or Now(), st.leader), sender) end
end)

---------------------------------------------------------------------------
-- Automatic: moving a character on its own makes it the leader
---------------------------------------------------------------------------
local MOVE_WINDOW = 1.2   -- seconds: team characters starting to move this close together = broadcast
local othersMoved = {}    -- [teamKey] = GetTime() of their last FTLM
local lastReport = 0

-- moving or not, from the game's start/stop events (the speed itself is a
-- secret value in combat and can't be compared)
local moving = false
local function Moving() return moving end
ns.On("PLAYER_STOPPED_MOVING", function() moving = false end)
ns.On("PLAYER_ENTERING_WORLD", function() moving = false end)

local function Plain(v) if v ~= nil and not ns.IsSecret(v) then return v end end

-- moving, and because of the player: not following, no flight path, in control
local function MovingOnItsOwn()
    if not Moving() then return false end
    if ns.IsFollowing and ns.IsFollowing() then return false end
    if UnitOnTaxi and ns.Safe(UnitOnTaxi, "player") then return false end
    if HasFullControl and Plain(HasFullControl()) == false then return false end   -- fear, charm, confuse
    local me = ns.PlayerFull()
    local cc = me and ns.CCState and ns.CCState(me)
    if cc and cc.kind ~= "R" then return false end
    return true
end

-- another team character started moving close to `at`
local function OthersMovedNear(at)
    for key, t in pairs(othersMoved) do
        if math.abs(t - at) <= MOVE_WINDOW then return key end
    end
end

local function InCombat()
    return InCombatLockdown() or (UnitAffectingCombat and ns.Safe(UnitAffectingCombat, "player")) or false
end

ns.On("PLAYER_STARTED_MOVING", function()
    moving = true
    local cfg = ns.db.ftl
    if not (cfg.enabled and cfg.detect == "MOVE") then return end
    -- not in combat: the macros can't change then anyway
    if InCombat() then return end
    -- wait a moment: a short bump or the start of a follow doesn't count
    C_Timer.After(0.5, function()
        if InCombat() or not MovingOnItsOwn() then return end
        local at = GetTime()
        -- every client reports, the leader too, so the others can see a broadcast
        if at - lastReport > 1 then
            lastReport = at
            ns.SendToTeam("FTLM", true, "ALERT")
        end
        if ns.IsFTLLeader(ns.PlayerFull()) then return end
        C_Timer.After(MOVE_WINDOW, function()
            local other = OthersMovedNear(at)
            if other then
                ns.Debug("FTL: %s moved at the same time: broadcast, the leader stays", ns.Repr(other))
                return
            end
            if not InCombat() and not ns.IsFTLLeader(ns.PlayerFull()) then ns.ClaimFTLLeader() end
        end)
    end)
end)

ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    if text == "FTLM" then othersMoved[key] = GetTime() end
end)

---------------------------------------------------------------------------
-- When the macros are (re)written
---------------------------------------------------------------------------
ns.On("PLAYER_REGEN_ENABLED", function()
    if pending then
        ns.FTLUpdateMacros("after combat")
        if ns.db.ftl.announce then ns.Print("FTL: macros updated after combat.") end
    end
end)
ns.On("GROUP_ROSTER_UPDATE", function()
    if ns.db.ftl.enabled and ns.db.ftl.nameFormat == "UNIT" then ns.FTLUpdateMacros("group") end
end)
ns.OnLogin(function() C_Timer.After(2, function() ns.FTLUpdateMacros("login") end) end)
ns.Listen("PROFILE_CHANGED", function() if ns.ready then ns.FTLUpdateMacros("profile") end end)
