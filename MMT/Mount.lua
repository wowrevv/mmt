-- MMT: mount and dismount with the leader (as in EMA and MAMA).
--
-- The leader (FTL leader, or the group leader without one) tells the team
-- when it starts summoning a mount (MOUNT:<mount ID>) and when it dismounts
-- (DISMOUNT). Team members then summon the same mount if they have it, else
-- one of the same kind (ground / flying / ...), else a random favourite; and
-- dismount, but never in the air. Holding Shift while mounting or
-- dismounting keeps it to the leader.

local _, ns = ...

local function Cfg() return ns.db and ns.db.mount end
local function Safe(fn, ...) if fn then return ns.Safe(fn, ...) end end

local function InCombat()
    return InCombatLockdown() or Safe(UnitAffectingCombat, "player") or false
end

local function Mounted() return Safe(IsMounted) and true or false end

---------------------------------------------------------------------------
-- Mount journal helpers (retail mount system)
---------------------------------------------------------------------------

local function MountFromSpell(spellID)
    local J = C_MountJournal
    if not (J and spellID) or ns.IsSecret(spellID) then return nil end
    if J.GetMountFromSpell then
        local id = Safe(J.GetMountFromSpell, spellID)
        if id then return id end
    end
    for _, id in ipairs((J.GetMountIDs and J.GetMountIDs()) or {}) do
        local _, mountSpell = J.GetMountInfoByID(id)
        if mountSpell == spellID then return id end
    end
end

local function ActiveMount()
    local J = C_MountJournal
    if not J then return nil end
    for _, id in ipairs((J.GetMountIDs and J.GetMountIDs()) or {}) do
        local _, _, _, active = J.GetMountInfoByID(id)
        if active then return id end
    end
end

local function MountType(id)
    local J = C_MountJournal
    if not (J and J.GetMountInfoExtraByID) then return nil end
    local _, _, _, _, mountType = J.GetMountInfoExtraByID(id)
    return mountType
end

-- the mount to summon here for the leader's mount: same, same kind, or 0 (random favourite)
local function ChooseMount(leaderMount)
    local J = C_MountJournal
    if not J then return nil end
    local _, _, _, _, usable = J.GetMountInfoByID(leaderMount)
    if usable then return leaderMount end
    local kind = MountType(leaderMount)
    local fallback
    for _, id in ipairs((J.GetMountIDs and J.GetMountIDs()) or {}) do
        local _, _, _, _, isUsable, _, isFavorite, _, _, hidden, collected = J.GetMountInfoByID(id)
        if isUsable and collected ~= false and not hidden and MountType(id) == kind then
            if isFavorite then return id end
            fallback = fallback or id
        end
    end
    return fallback or 0
end

---------------------------------------------------------------------------
-- Leader: tell the team
---------------------------------------------------------------------------
local following = false   -- this client mounts because the leader did: don't send
local lastSent = 0
local wasMounted = false

local function IsLeader() return ns.IsNoticeLeaderHere and ns.IsNoticeLeaderHere() end

local function SendMount(mountID)
    local cfg = Cfg()
    if not (cfg and cfg.mount) or following or not mountID or not IsLeader() then return end
    if IsShiftKeyDown() then return end
    if GetTime() - lastSent < 3 then return end
    lastSent = GetTime()
    ns.Debug("mount: leader mounts %s, telling the team", tostring(mountID))
    ns.SendAlert("MOUNT:" .. mountID)
end

ns.On("UNIT_SPELLCAST_START", function(unit, castGUID, spellID)
    if unit ~= "player" then return end
    local id = MountFromSpell(spellID)
    if id then SendMount(id) end
end)

ns.On("PLAYER_MOUNT_DISPLAY_CHANGED", function()
    local mounted = Mounted()
    local cfg = Cfg()
    if mounted and not wasMounted then
        -- mounts without a cast (or a cast event the game hid): send now
        if GetTime() - lastSent >= 3 then SendMount(ActiveMount()) end
    elseif not mounted and wasMounted then
        if cfg and cfg.dismount and not following and IsLeader() and not IsShiftKeyDown()
            and not Safe(UnitOnTaxi, "player") then
            ns.Debug("mount: leader dismounted, telling the team")
            ns.SendAlert("DISMOUNT")
        end
    end
    wasMounted = mounted
end)
ns.On("PLAYER_ENTERING_WORLD", function() wasMounted = Mounted() end)

---------------------------------------------------------------------------
-- Team members
---------------------------------------------------------------------------
-- the leader is near enough to see (when in a group)
local function LeaderNearby(key)
    local unit = ns.UnitForMember and ns.UnitForMember(key)
    if not unit then return true end
    local visible = Safe(UnitIsVisible, unit)
    return visible ~= false
end

local function MountUp(mountID, key)
    local J = C_MountJournal
    if Mounted() or InCombat() then return end
    if Safe(UnitIsDeadOrGhost, "player") or Safe(IsIndoors) then return end
    if not LeaderNearby(key) then return end
    local id = ChooseMount(mountID)
    if not id then return end
    following = true
    local ok, err = pcall(J.SummonByID, id)
    C_Timer.After(3, function() following = false end)
    ns.Debug("mount: following %s -> SummonByID(%s) %s %s", ns.Repr(key), tostring(id), tostring(ok), tostring(err or ""))
end

local function DismountHere(key)
    if not Mounted() then return end
    if Safe(IsFlying) then
        ns.Debug("mount: not dismounting in the air")
        return
    end
    following = true
    local ok, err = pcall(Dismount)
    C_Timer.After(1, function() following = false end)
    ns.Debug("mount: following %s -> Dismount %s %s", ns.Repr(key), tostring(ok), tostring(err or ""))
end

ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    local J = C_MountJournal
    local cfg = Cfg()
    if not cfg then return end
    local id = text:match("^MOUNT:(%d+)$")
    if id then
        if cfg.mount and J and J.SummonByID then MountUp(tonumber(id), key) end
        return
    end
    if text == "DISMOUNT" and cfg.dismount and Dismount then DismountHere(key) end
end)
