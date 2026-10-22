-- MMT: take flight paths with the team (as in EMA).
--
-- When a character picks a destination at a flight master, its client tells
-- the team (TAXI:<destination name>, leader first). Every team member whose
-- flight map is open at that moment (talking to a flight master) takes the
-- same destination. A member who opens the flight map within a few seconds
-- after the message still follows (broadcast "interact" arrives a bit later
-- on some clients). Destinations are matched by name.

local _, ns = ...

local GRACE = 5            -- seconds a request waits for this client's flight map to open
local mapOpen = false
local followingTaxi = false   -- MMT itself takes the flight: don't announce it again
local pending                 -- { name, from, untilTime }

local function Cfg() return ns.db and ns.db.taxi end

---------------------------------------------------------------------------
-- Flight map nodes
---------------------------------------------------------------------------
-- index of the destination with that name on the open flight map, and whether it can be flown to
local function FindNode(name)
    if NumTaxiNodes and TaxiNodeName then
        for i = 1, (NumTaxiNodes() or 0) do
            if TaxiNodeName(i) == name then
                local kind = TaxiNodeGetType and TaxiNodeGetType(i)
                return i, kind == nil or kind == "REACHABLE"
            end
        end
    end
    if C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and GetTaxiMapID then
        local ok, nodes = pcall(C_TaxiMap.GetAllTaxiNodes, GetTaxiMapID())
        for _, node in ipairs(ok and nodes or {}) do
            if node.name == name then
                local reachable = not (Enum and Enum.FlightPathState) or node.state == Enum.FlightPathState.Reachable
                return node.slotIndex, reachable
            end
        end
    end
end

local function NodeName(index)
    if TaxiNodeName then
        local ok, name = pcall(TaxiNodeName, index)
        if ok and type(name) == "string" and not ns.IsSecret(name) and name ~= "" then return name end
    end
end

---------------------------------------------------------------------------
-- Following a team member's flight
---------------------------------------------------------------------------
-- the leader's chat: who followed, who couldn't (k = not known, u = can't be reached)
local function Tell(ok, name, why)
    local cfg = Cfg()
    if not (cfg and cfg.tellLeader and ns.TellLeader) then return end
    ns.TellLeader(ok and ("NOTE:TAXI:1:" .. name) or ("NOTE:TAXI:0:" .. why .. ":" .. name))
end

local function Take(name, fromKey)
    local index, reachable = FindNode(name)
    local who = fromKey and ns.ShownName(fromKey) or "a team member"
    if not index then
        ns.Print("%s flies to %s, but that flight path isn't known on this character.", who, name)
        Tell(false, name, "k")
        return
    end
    if not reachable then
        ns.Print("%s flies to %s, but it can't be reached from here.", who, name)
        Tell(false, name, "u")
        return
    end
    followingTaxi = true
    local ok, err = pcall(TakeTaxiNode, index)
    followingTaxi = false
    ns.Debug("taxi: follow %s to %s (node %s) -> %s %s", ns.Repr(fromKey), name, tostring(index), tostring(ok), tostring(err or ""))
    if ok and Cfg().report then ns.Print("Flying to %s with %s.", name, who) end
    if ok then Tell(true, name) end
end

-- the leader's client: notes from the team
ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    local okFlag, rest = text:match("^NOTE:TAXI:([01]):(.+)$")
    if not okFlag or not ns.IsNoticeLeaderHere() then return end
    local who = ns.ShownName(key)
    if okFlag == "1" then
        ns.Print("%s flies to %s too.", who, rest)
    else
        local why, name = rest:match("^(%a):(.+)$")
        ns.Print("|cffff6666%s can't fly to %s: %s.|r", who, name or rest,
            why == "u" and "it can't be reached from there" or "that flight path isn't known there")
    end
end)

ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    local name = text:match("^TAXI:(.+)$")
    if not name then return end
    local cfg = Cfg()
    if not (cfg and cfg.enabled) then return end
    if mapOpen then
        Take(name, key)
    else
        pending = { name = name, from = key, untilTime = GetTime() + GRACE }
        ns.Debug("taxi: %s flies to %s; flight map not open here (waiting %d s)", ns.Repr(key), name, GRACE)
    end
end)

ns.On("TAXIMAP_OPENED", function()
    mapOpen = true
    local p = pending
    pending = nil
    local cfg = Cfg()
    if p and cfg and cfg.enabled and GetTime() <= p.untilTime then
        -- the map needs a moment to fill
        C_Timer.After(0.2, function() if mapOpen then Take(p.name, p.from) end end)
    end
end)
ns.On("TAXIMAP_CLOSED", function() mapOpen = false end)

---------------------------------------------------------------------------
-- Announcing the own choice
---------------------------------------------------------------------------
if hooksecurefunc and TakeTaxiNode then
    hooksecurefunc("TakeTaxiNode", function(index)
        local cfg = Cfg()
        if followingTaxi or not (cfg and cfg.enabled) then return end
        local name = NodeName(index)
        if not name then return end
        ns.Debug("taxi: taking %s, telling the team", name)
        if ns.SendAlert then ns.SendAlert("TAXI:" .. name) end
    end)
end
