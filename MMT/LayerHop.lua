-- MMT: Layer Hop. When the game offers to move this character to another
-- layer/phase, the XP window shows a pulsing red "Layer Hop" next to the
-- name. Clicking it confirms after 3 seconds; optionally it is confirmed
-- automatically after X seconds. Both count down in chat.
--
-- Confirming = C_PlayerInteractionManager.ShardTransferConfirm() (Forever API).
-- Forever announces it with the event SHARD_TRANSFER_IMMINENT and shows the
-- "World refresh in N minutes" toast (ShardTransferImminentFrame from
-- Blizzard_SocialToast, with a separate minimize button). The offer counts as
-- pending while that toast or its minimize button is visible. Other likely
-- signals are watched as a fallback, and with the debug log on every event
-- name containing SHARD, LAYER or TRANSFER is logged.
--
-- The team sees each other's pending hops (LH:1 / LH:0) and countdowns
-- (LHC:<seconds>, LHC:0 = stopped) in the XP window; clicking a
-- teammate's "Layer Hop" asks that client to confirm (LHGO).

local _, ns = ...

local MANUAL_DELAY = 3
local PENDING_TIMEOUT = 20 * 60 -- fallback only: forget an offer after 20 min if no toast can be watched

ns.hop = { pending = false, since = nil, source = nil }
local countdown        -- ticker of the running countdown

local function Confirm()
    local api = C_PlayerInteractionManager and C_PlayerInteractionManager.ShardTransferConfirm
    if not api then
        ns.Print("Layer hop isn't available on this client (no ShardTransferConfirm).")
        return false
    end
    local ok, err = pcall(api)
    ns.Debug("ShardTransferConfirm() -> %s %s", tostring(ok), tostring(err or ""))
    if ok then ns.Print("Layer hop confirmed.") else ns.Print("Layer hop failed: %s", tostring(err)) end
    return ok
end

ns.hopRemote = {}     -- [teamKey] = true while that member has a hop pending (LH:1 / LH:0)
ns.hopRemoteEnd = {}  -- [teamKey] = GetTime() when that member's countdown ends (LHC:<seconds>)

local function SendCountdown(seconds)
    if ns.SendAlert then ns.SendAlert("LHC:" .. seconds) end   -- leader first
end

function ns.CancelHopCountdown(reason)
    if countdown then
        countdown:Cancel()
        countdown = nil
        ns.hop.countdownEnd = nil
        SendCountdown(0)
        if reason then ns.Print("Layer hop countdown stopped (%s).", reason) end
        ns.Fire("STATUS_CHANGED")
    end
end

-- seconds left of the running countdown of a member (you or a teammate), or nil
function ns.HopCountdownFor(key)
    local endTime
    if ns.IsSelf(key) then endTime = ns.hop.countdownEnd else endTime = ns.hopRemoteEnd[key] end
    if not endTime then return nil end
    local left = math.ceil(endTime - GetTime())
    return left > 0 and left or nil
end

-- seconds: delay; why: "auto", "manual" or "requested by <name>"
function ns.StartHopCountdown(seconds, why)
    ns.CancelHopCountdown()
    seconds = math.max(1, math.floor(seconds + 0.5))
    ns.Print("Layer hop in %d s (%s)...", seconds, why)
    ns.hop.countdownEnd = GetTime() + seconds
    SendCountdown(seconds)   -- the team's XP windows count down too
    ns.Fire("STATUS_CHANGED")
    local left = seconds
    countdown = C_Timer.NewTicker(1, function(self)
        left = left - 1
        if not ns.hop.pending then
            self:Cancel(); countdown = nil
            ns.hop.countdownEnd = nil
            SendCountdown(0)
            ns.Print("Layer hop cancelled: the game no longer offers it.")
            ns.Fire("STATUS_CHANGED")
            return
        end
        if left > 0 then
            ns.Print("Layer hop in %d...", left)
            ns.Fire("STATUS_CHANGED")
        else
            self:Cancel(); countdown = nil
            ns.hop.countdownEnd = nil
            if Confirm() then ns.SetHopPending(false, "confirmed") else SendCountdown(0); ns.Fire("STATUS_CHANGED") end
        end
    end)
end

function ns.HopCountdownRunning() return countdown ~= nil end

---------------------------------------------------------------------------
-- Pending state
---------------------------------------------------------------------------
local timeoutTimer

function ns.SetHopPending(on, source)
    on = on and true or false
    if ns.hop.pending == on then return end
    ns.hop.pending, ns.hop.since, ns.hop.source = on, on and GetTime() or nil, source
    ns.Debug("Layer hop pending=%s (%s)", tostring(on), tostring(source))
    if timeoutTimer then timeoutTimer:Cancel(); timeoutTimer = nil end
    if on then
        timeoutTimer = C_Timer.NewTimer(PENDING_TIMEOUT, function()
            if not ns.HopToastVisible() then ns.SetHopPending(false, "timeout") end
        end)
        local x = ns.db.xp
        if x.layerHopNotify then ns.Print("Layer hop offered. Click \"Layer Hop\" in the XP window to accept.") end
        if x.layerHopAuto then ns.StartHopCountdown(x.layerHopDelay or 5, "auto") end
    else
        ns.CancelHopCountdown(source ~= "confirmed" and "the game no longer offers it" or nil)
    end
    if ns.SendAlert then ns.SendAlert(on and "LH:1" or "LH:0") end   -- leader first
    ns.Fire("STATUS_CHANGED")
end

-- click on "Layer Hop" in the XP window
function ns.HopClicked(key)
    if ns.IsSelf(key) then
        if ns.hop.pending then ns.StartHopCountdown(MANUAL_DELAY, "manual") end
        return
    end
    -- a teammate's hop: ask that client to confirm it
    ns.SendAddon("LHGO", "WHISPER", ns.WhisperTarget(key), "ALERT")
    ns.Print("Asked %s to take the layer hop.", ns.FullDisplay(key))
end

ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    local flag = text:match("^LH:([01])$")
    local cd = text:match("^LHC:(%d+)$")
    if flag then
        ns.hopRemote[key] = (flag == "1") or nil
        if flag == "0" then ns.hopRemoteEnd[key] = nil end
        ns.Fire("STATUS_CHANGED")
    elseif cd then
        cd = tonumber(cd)
        ns.hopRemoteEnd[key] = (cd > 0) and (GetTime() + cd) or nil
        if cd > 0 then ns.hopRemote[key] = true end
        ns.Fire("STATUS_CHANGED")
        -- redraw every second while a teammate's countdown runs
        if cd > 0 then
            for i = 1, cd + 1 do
                C_Timer.After(i, function() ns.Fire("STATUS_CHANGED") end)
            end
        end
    elseif text == "LHGO" and ns.hop.pending then
        ns.StartHopCountdown(MANUAL_DELAY, "requested by " .. ns.FullDisplay(key))
    end
end)

function ns.HopPendingFor(key)
    if ns.IsSelf(key) then return ns.hop.pending end
    return ns.hopRemote[key] and ns.IsOnline(key) or false
end

---------------------------------------------------------------------------
-- Detection
---------------------------------------------------------------------------
local watch = CreateFrame("Frame")
local handlers = {}

local function Watch(event, fn)
    local valid = C_EventUtils and C_EventUtils.IsEventValid
    if valid and not valid(event) then return false end
    if not pcall(watch.RegisterEvent, watch, event) then return false end
    handlers[event] = fn
    return true
end

watch:SetScript("OnEvent", function(_, event, ...)
    if handlers[event] and ns.ready then pcall(handlers[event], event, ...) end
end)

-- 1. shard transfer events (names guessed; only the ones the client knows are used)
local START = { "SHARD_TRANSFER_IMMINENT", "SHARD_TRANSFER_REQUESTED", "SHARD_TRANSFER_PROMPT", "SHARD_TRANSFER_PENDING",
    "SHARD_TRANSFER_OFFERED", "SHARD_TRANSFER_OFFER", "SHARD_TRANSFER_SHOW", "SHARD_TRANSFER_START",
    "SHARD_TRANSFER_STARTED", "SHARD_TRANSFER_CONFIRMATION", "PLAYER_SHARD_TRANSFER_PENDING",
    "LAYER_TRANSFER_PENDING", "LAYER_TRANSFER_REQUESTED" }
local STOP = { "SHARD_TRANSFER_CANCELED", "SHARD_TRANSFER_CANCELLED", "SHARD_TRANSFER_COMPLETE",
    "SHARD_TRANSFER_COMPLETED", "SHARD_TRANSFER_FINISHED", "SHARD_TRANSFER_EXPIRED", "SHARD_TRANSFER_HIDE",
    "SHARD_TRANSFER_FAILED", "LAYER_TRANSFER_COMPLETE", "LAYER_TRANSFER_CANCELED" }
ns.hop.events = {}
for _, e in ipairs(START) do
    if Watch(e, function(ev) ns.SetHopPending(true, ev) end) then ns.hop.events[#ns.hop.events + 1] = e end
end
for _, e in ipairs(STOP) do
    if Watch(e, function(ev) ns.SetHopPending(false, ev) end) then ns.hop.events[#ns.hop.events + 1] = e end
end

-- 2. player interaction frame of a shard/layer type
local hopTypes = {}
if Enum and Enum.PlayerInteractionType then
    for name, value in pairs(Enum.PlayerInteractionType) do
        local n = tostring(name):lower()
        if n:find("shard") or n:find("layer") then hopTypes[value] = name end
    end
end
Watch("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
    if hopTypes[kind] then ns.SetHopPending(true, "interaction " .. hopTypes[kind]) end
    ns.Debug("interaction frame show: %s", tostring(kind))
end)
Watch("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
    if hopTypes[kind] then ns.SetHopPending(false, "interaction hide") end
end)

-- 3. Blizzard popups about shards/layers (hooks only observe, nothing is replaced)
local function PopupIsHop(which)
    if type(which) ~= "string" then return false end
    local w = which:upper()
    return w:find("SHARD", 1, true) or w:find("LAYER", 1, true)
end
if hooksecurefunc then
    if StaticPopup_Show then
        hooksecurefunc("StaticPopup_Show", function(which)
            if PopupIsHop(which) then ns.SetHopPending(true, "popup " .. which) end
        end)
    end
    if StaticPopup_Hide then
        hooksecurefunc("StaticPopup_Hide", function(which)
            if PopupIsHop(which) then ns.SetHopPending(false, "popup hidden") end
        end)
    end
end

---------------------------------------------------------------------------
-- 4. Forever's "World refresh" toast: pending while it (or its minimize
--    button, after minimizing) is visible. HookScript only observes.
---------------------------------------------------------------------------
local hookedToast = {}

local function ToastFrames()
    return _G.ShardTransferImminentFrame, _G.ShardTransferImminentMinimizeButton
end

function ns.HopToastVisible()
    local main, button = ToastFrames()
    return (main and main:IsShown()) or (button and button:IsShown()) or false
end

local function ToastChanged()
    -- minimizing hides the toast and shows the button: check a moment later
    C_Timer.After(0.1, function()
        local visible = ns.HopToastVisible()
        if visible then ns.SetHopPending(true, "world refresh toast")
        elseif ns.hop.pending then
            local src = ns.hop.source or ""
            if src:find("SHARD_TRANSFER_IMMINENT", 1, true) or src:find("toast", 1, true) then
                ns.SetHopPending(false, "world refresh toast closed")
            end
        end
    end)
end

local function HookToast()
    for _, f in ipairs({ ToastFrames() }) do
        if f and not hookedToast[f] and f.HookScript then
            hookedToast[f] = true
            f:HookScript("OnShow", ToastChanged)
            f:HookScript("OnHide", ToastChanged)
            ns.Debug("Layer hop: watching %s", f:GetName() or "toast")
        end
    end
    if ns.HopToastVisible() then ns.SetHopPending(true, "world refresh toast") end
end

Watch("ADDON_LOADED", function(_, name)
    if name == "Blizzard_SocialToast" or _G.ShardTransferImminentFrame then HookToast() end
end)
Watch("SHARD_TRANSFER_IMMINENT", function(ev, ...)
    local args = {}
    for i = 1, select("#", ...) do args[i] = tostring((select(i, ...))) end
    ns.Debug("SHARD_TRANSFER_IMMINENT %s", table.concat(args, " "))
    ns.SetHopPending(true, ev)
    C_Timer.After(0, HookToast) -- the toast frame may only exist now
end)
ns.OnLogin(function() C_Timer.After(1, HookToast) end) -- also catches a toast shown before /reload

-- after a loading screen the offer is gone, unless the toast is still up
ns.On("PLAYER_ENTERING_WORLD", function()
    C_Timer.After(1, function()
        if not ns.HopToastVisible() then ns.SetHopPending(false, "loading screen") end
    end)
end)

---------------------------------------------------------------------------
-- Discovery (debug log only): log every event about shards/layers/transfers
---------------------------------------------------------------------------
local sniffer = CreateFrame("Frame")
sniffer:SetScript("OnEvent", function(_, event, ...)
    local e = event
    if e:find("SHARD", 1, true) or e:find("LAYER", 1, true) or e:find("TRANSFER", 1, true)
        or e == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        local args = {}
        for i = 1, math.min(select("#", ...), 4) do args[i] = tostring((select(i, ...))) end
        ns.Debug("EVENT %s %s", event, table.concat(args, " "))
    end
end)
local sniffing = false
local function UpdateSniffer()
    local on = MMTDB and MMTDB.debug and true or false
    if on == sniffing then return end
    sniffing = on
    if on then pcall(sniffer.RegisterAllEvents, sniffer) else sniffer:UnregisterAllEvents() end
end
ns.OnRefresh(UpdateSniffer)
ns.OnLogin(UpdateSniffer)
C_Timer.NewTicker(5, UpdateSniffer) -- picks up /mmt debug toggles
