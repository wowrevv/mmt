-- MMT: dying as a team (as in EMA's "Toon" module) and accepting
-- resurrections and summons.
--
-- Every client reports its character's state:
--   DEATH:<state>:<corpse delay>   A alive, D dead (not released),
--                                  G ghost away from the corpse, C ghost at the corpse
-- A small MMT panel sits under Blizzard's death dialog ("Release Spirit") and
-- under the corpse dialog ("Resurrect Now"), on every character it concerns:
--   * "Release as team": every dead team member releases its spirit.
--   * "Revive as team": every ghost at its corpse revives; one whose corpse
--     still has a delay revives when the delay is over; one away from its
--     corpse says so in the leader's chat.
-- The panel lists the team members who aren't alive and whether they can
-- revive now. Blizzard's dialogs are not changed (no taint).
--
-- Resurrections and warlock summons are accepted automatically from the
-- chosen sources: team, friends, guild, anyone (any combination).

local _, ns = ...
local UI = ns.UI

local function Cfg() return ns.db and ns.db.death end
local function Safe(fn, ...) if fn then return ns.Safe(fn, ...) end end

ns.death = {}   -- [teamKey] = { state, readyAt (GetTime), at }

local LABEL = {
    D = "dead, not released",
    G = "ghost, not at the corpse",
    C = "at the corpse",
}

---------------------------------------------------------------------------
-- Own state
---------------------------------------------------------------------------
local corpseInRange = false

local function CorpseDelay()
    local d = Safe(GetCorpseRecoveryDelay)
    return (type(d) == "number" and d > 0) and d or 0
end

local function OwnState()
    if Safe(UnitIsGhost, "player") then return corpseInRange and "C" or "G" end
    if Safe(UnitIsDead, "player") then return "D" end
    return "A"
end

local lastSent
local function Report()
    local state = OwnState()
    local delay = (state == "C" or state == "G") and math.ceil(CorpseDelay()) or 0
    local me = ns.PlayerFull()
    if me then
        ns.death[me] = state ~= "A" and { state = state, readyAt = GetTime() + delay, at = GetTime() } or nil
    end
    local msg = ("DEATH:%s:%d"):format(state, delay)
    if msg ~= lastSent and ns.SendToTeam then
        lastSent = msg
        ns.SendToTeam(msg, true, "ALERT")
    end
    if ns.UpdateDeathPanel then ns.UpdateDeathPanel() end
end

ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    local state, delay = text:match("^DEATH:(%u):(%d+)$")
    if not state then return end
    ns.death[key] = state ~= "A" and { state = state, readyAt = GetTime() + tonumber(delay), at = GetTime() } or nil
    if ns.UpdateDeathPanel then ns.UpdateDeathPanel() end
end)

---------------------------------------------------------------------------
-- Release and revive (here, and on request of the team)
---------------------------------------------------------------------------
local reviveTimer

local function Note(msg) if ns.TellLeader then ns.TellLeader(msg) end end

local function ReleaseHere()
    if OwnState() ~= "D" then return end
    if Safe(IsEncounterInProgress) then
        ns.Print("Can't release during a boss fight.")
        Note("NOTE:DEATH:0:e")
        return
    end
    local ok, err = pcall(RepopMe)
    ns.Debug("death: release -> %s %s", tostring(ok), tostring(err or ""))
end

local function ReviveHere()
    local state = OwnState()
    if state == "G" then
        ns.Print("Not at the corpse: can't revive yet.")
        Note("NOTE:DEATH:0:a")
        return
    end
    if state ~= "C" then return end
    local delay = CorpseDelay()
    if delay > 0 then
        ns.Print("Reviving in %d seconds (corpse delay).", math.ceil(delay))
        Note(("NOTE:DEATH:%d:w"):format(math.ceil(delay)))
        if reviveTimer then reviveTimer:Cancel() end
        reviveTimer = C_Timer.NewTimer(delay + 0.3, function()
            reviveTimer = nil
            if OwnState() == "C" and CorpseDelay() == 0 then pcall(RetrieveCorpse) end
        end)
        return
    end
    local ok, err = pcall(RetrieveCorpse)
    ns.Debug("death: revive -> %s %s", tostring(ok), tostring(err or ""))
end

ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    local cfg = Cfg()
    if not cfg then return end
    if text == "RELEASE" and cfg.release then ReleaseHere()
    elseif text == "REVIVE" and cfg.revive then ReviveHere() end
end)

-- the leader's chat: who can't (yet)
ns.Listen("TEAM_MESSAGE", function(key, sender, text)
    local seconds, why = text:match("^NOTE:DEATH:(%d+):(%a)$")
    if not why or not ns.IsNoticeLeaderHere() then return end
    local who = ns.ShownName(key)
    if why == "e" then ns.Print("|cffff6666%s can't release during a boss fight.|r", who)
    elseif why == "a" then ns.Print("|cffff6666%s isn't at the corpse.|r", who)
    elseif why == "w" then ns.Print("%s revives in %s seconds (corpse delay).", who, seconds) end
end)

local function ReleaseTeam()
    ns.SendToTeam("RELEASE", true, "ALERT")
    ReleaseHere()
end

local function ReviveTeam()
    ns.SendToTeam("REVIVE", true, "ALERT")
    ReviveHere()
end

---------------------------------------------------------------------------
-- The panel under Blizzard's dialog
---------------------------------------------------------------------------
local panel

local function TeamSize()
    local n = 0
    for _ in pairs(ns.db.team) do n = n + 1 end
    return n
end

-- the Blizzard dialog to sit under (or nil)
local function BlizzardDialog(state)
    if not StaticPopup_FindVisible then return nil end
    if state == "D" then return StaticPopup_FindVisible("DEATH") end
    return StaticPopup_FindVisible("RECOVER_CORPSE") or StaticPopup_FindVisible("RECOVER_CORPSE_INSTANCE")
end

local function StatusLines()
    local lines = {}
    for _, key in ipairs(ns.SortedMembers()) do
        local d = ns.death[key]
        if d then
            local text = LABEL[d.state] or d.state
            if d.state == "C" then
                local left = math.ceil((d.readyAt or 0) - GetTime())
                text = left > 0 and ("at the corpse, can revive in " .. left .. " s") or "at the corpse, can revive"
            end
            local colour = (d.state == "C" and (d.readyAt or 0) <= GetTime()) and "|cff66ff66" or "|cffaaaaaa"
            lines[#lines + 1] = ("%s%s|r: %s"):format(colour, ns.ShownName(key), text)
        end
    end
    return lines
end

local function BuildPanel()
    local f = CreateFrame("Frame", "MMTDeathPanel", UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetSize(320, 60)
    f:SetClampedToScreen(true)
    UI.Fill(f, 0.05, 0.05, 0.06, 0.92)
    UI.Border(f, UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 0.5)
    f.button = UI.Button(f, 180, "", function()
        if f.mode == "D" then ReleaseTeam() else ReviveTeam() end
    end)
    f.button:SetPoint("TOP", 0, -10)
    f.status = UI.Label(f, "")
    f.status:SetPoint("TOP", f.button, "BOTTOM", 0, -8)
    f.status:SetWidth(296)
    f.status:SetJustifyH("LEFT")
    f:Hide()
    -- countdowns
    f.elapsed = 0
    f:SetScript("OnUpdate", function(self, e)
        self.elapsed = self.elapsed + e
        if self.elapsed > 1 then self.elapsed = 0; ns.UpdateDeathPanel() end
    end)
    return f
end

function ns.UpdateDeathPanel()
    local cfg = Cfg()
    local state = OwnState()
    local want = cfg and ((state == "D" and cfg.release) or (state == "C" and cfg.revive)) and TeamSize() > 1
    if not want then
        if panel then panel:Hide() end
        return
    end
    panel = panel or BuildPanel()
    panel.mode = state
    panel.button.label:SetText(state == "D" and "Release as team" or "Revive as team")
    local lines = StatusLines()
    panel.status:SetText(table.concat(lines, "\n"))
    panel:SetHeight(44 + (#lines > 0 and (panel.status:GetStringHeight() or 0) + 6 or 0))
    panel:ClearAllPoints()
    local dialog = BlizzardDialog(state)
    if dialog then panel:SetPoint("TOP", dialog, "BOTTOM", 0, -4)
    else panel:SetPoint("TOP", UIParent, "TOP", 0, -260) end
    panel:Show()
end

-- Blizzard's dialog appears a moment after the event: place the panel after it
local function Soon() Report() C_Timer.After(0.3, ns.UpdateDeathPanel) end

ns.On("PLAYER_DEAD", Soon)
ns.On("PLAYER_ALIVE", Soon)
ns.On("PLAYER_UNGHOST", function() corpseInRange = false Soon() end)
ns.On("CORPSE_IN_RANGE", function() corpseInRange = true Soon() end)
ns.On("CORPSE_OUT_OF_RANGE", function() corpseInRange = false Soon() end)
ns.On("PLAYER_ENTERING_WORLD", Soon)
ns.OnRefresh(function() if ns.ready then ns.UpdateDeathPanel() end end)

---------------------------------------------------------------------------
-- Accepting resurrections and summons
---------------------------------------------------------------------------
local function Bare(name)
    if type(name) ~= "string" or ns.IsSecret(name) then return nil end
    return ns.NormKey(ns.StripRealm(name))
end

local function IsFriend(name)
    local bare = Bare(name)
    if not bare or not C_FriendList then return false end
    for i = 1, (C_FriendList.GetNumFriends and C_FriendList.GetNumFriends() or 0) do
        local info = C_FriendList.GetFriendInfoByIndex(i)
        if info and info.name and Bare(info.name) == bare then return true end
    end
    return false
end

local function IsGuildMate(name)
    local bare = Bare(name)
    if not bare or not IsInGuild() or not GetNumGuildMembers then return false end
    for i = 1, (GetNumGuildMembers() or 0) do
        local member = GetGuildRosterInfo(i)
        if member and Bare(member) == bare then return true end
    end
    return false
end

-- sources = { team = bool, friends = bool, guild = bool, anyone = bool }
local function Allowed(sources, name)
    if not sources then return false end
    if sources.anyone then return true end
    if type(name) ~= "string" or ns.IsSecret(name) then return false end
    if sources.team and ns.Resolve(name) then return true end
    if sources.friends and IsFriend(name) then return true end
    if sources.guild and IsGuildMate(name) then return true end
    return false
end

local function Who(name)
    local key = ns.Resolve(name)
    return key and ns.ShownName(key) or tostring(name)
end

ns.On("RESURRECT_REQUEST", function(name)
    local cfg = Cfg()
    if not (cfg and Allowed(cfg.acceptRes, name)) then return end
    -- some resurrections can only be accepted after a few seconds: try again
    local tries = 0
    local function Try()
        tries = tries + 1
        if not Safe(UnitIsDeadOrGhost, "player") then return end
        pcall(AcceptResurrect)
        ns.Debug("death: accept resurrection from %s (try %d)", ns.Repr(name), tries)
        if tries < 10 then C_Timer.After(1, Try) end
    end
    ns.Print("Accepting the resurrection from %s.", Who(name))
    Try()
end)

local function SummonInfo()
    local S = C_SummonInfo
    if S then
        return Safe(S.GetSummonConfirmSummoner), Safe(S.GetSummonConfirmAreaName), Safe(S.GetSummonConfirmTimeLeft)
    end
    return Safe(GetSummonConfirmSummoner), Safe(GetSummonConfirmAreaName), Safe(GetSummonConfirmTimeLeft)
end

local function AcceptSummon()
    local cfg = Cfg()
    local summoner, area, left = SummonInfo()
    if not (cfg and summoner and (left or 0) > 0 and Allowed(cfg.acceptSummon, summoner)) then return end
    if InCombatLockdown() then return end   -- tried again when combat ends
    local confirm = (C_SummonInfo and C_SummonInfo.ConfirmSummon) or ConfirmSummon
    if not confirm then return end
    local ok, err = pcall(confirm)
    ns.Debug("death: accept summon from %s -> %s %s", ns.Repr(summoner), tostring(ok), tostring(err or ""))
    if ok then ns.Print("Accepted the summon from %s%s.", Who(summoner), area and (" to " .. area) or "") end
end

ns.On("CONFIRM_SUMMON", function() C_Timer.After(0.2, AcceptSummon) end)
ns.On("PLAYER_REGEN_ENABLED", function() C_Timer.After(0.5, AcceptSummon) end)
