-- MMT: debug report, copyable text window and /mmt debug commands.

local _, ns = ...
local UI = ns.UI
local Repr = ns.Repr

---------------------------------------------------------------------------
-- Copyable text window (flat look)
---------------------------------------------------------------------------
local textFrame

function ns.ShowText(title, text)
    if not textFrame then
        local f = CreateFrame("Frame", "MMTTextFrame", UIParent)
        f:SetSize(620, 440)
        f:SetPoint("CENTER")
        -- above the settings window (DIALOG, or FULLSCREEN_DIALOG when opened from the game options)
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:SetClampedToScreen(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        UI.Fill(f, 0.05, 0.05, 0.06, 0.96)
        UI.Border(f, 0.22, 0.22, 0.24, 1)

        f.title = UI.Label(f, "", "GameFontNormalLarge")
        f.title:SetPoint("TOPLEFT", 16, -14)
        local close = UI.TextButton(f, "x", function() f:Hide() end, 20)
        close:SetPoint("TOPRIGHT", -8, -8)

        f.area = UI.TextArea(f, 588, 340)
        f.area:SetPoint("TOPLEFT", 16, -44)

        local select = UI.Button(f, 120, "Select all", function()
            f.area.edit:SetFocus()
            f.area.edit:HighlightText()
        end)
        select:SetPoint("BOTTOMLEFT", 16, 16)
        local hint = UI.Label(f, "Select all, then Ctrl+C and paste it to Claude.")
        hint:SetPoint("LEFT", select, "RIGHT", 10, 0)
        hint:SetTextColor(0.6, 0.6, 0.6)

        UI.CloseOnEscape(f)
        textFrame = f
    end
    textFrame.title:SetText(title)
    -- "Keep full names in debug logs" off: also older log lines and the report
    if ns.db and ns.db.privacy and not ns.db.privacy.debugFull and ns.ReplaceNames then
        text = ns.ReplaceNames(text, true)
    end
    textFrame.area.edit:SetText(text)
    -- same strata as the settings window: put it well above that window and its widgets
    local config = _G.MMTConfigFrame
    if config and config:IsShown() and config:GetFrameStrata() == textFrame:GetFrameStrata() then
        textFrame:SetFrameLevel(math.min(9000, config:GetFrameLevel() + 100))
    end
    textFrame:Show()
    textFrame:Raise()
end

---------------------------------------------------------------------------
-- Report
---------------------------------------------------------------------------
local function UnitLine(unit)
    if not UnitExists(unit) then return nil end
    local n, r = ns.Safe(UnitFullName, unit)
    local _, _, key = ns.SplitUnit(unit)
    local phase = UnitPhaseReason and ns.Safe(UnitPhaseReason, unit)
    return ("%s: UnitName=%s  UnitFullName=%s / %s  isPlayer=%s  key=%s  teamKey=%s  phaseReason=%s  guid=%s"):format(
        unit, Repr((ns.Safe(UnitName, unit))), Repr(n), Repr(r), tostring(UnitIsPlayer(unit)),
        Repr(key), Repr(ns.Resolve(key)), tostring(phase), tostring(ns.Safe(UnitGUID, unit)))
end

function ns.BuildDebugReport()
    local L = {}
    local function add(s) L[#L + 1] = s end

    local ver, build, _, toc = GetBuildInfo()
    add(("MMT %s  client %s build %s  interface %s  locale %s"):format(
        ns.version, tostring(ver), tostring(build), tostring(toc), tostring(GetLocale())))
    add(("API: C_Container=%s C_ChatInfo=%s GetNormalizedRealmName=%s MAX_TRADABLE_ITEMS=%s maxLevel=%s UnitPhaseReason=%s"):format(
        tostring(C_Container ~= nil), tostring(C_ChatInfo ~= nil), tostring(GetNormalizedRealmName ~= nil),
        tostring(MAX_TRADABLE_ITEMS), tostring(GetMaxPlayerLevel and GetMaxPlayerLevel()), tostring(UnitPhaseReason ~= nil)))
    add("ERR_CHAT_PLAYER_NOT_FOUND_S = " .. Repr(ERR_CHAT_PLAYER_NOT_FOUND_S))
    local reasons = {}
    for value, label in pairs(ns.PHASE_LABELS) do reasons[#reasons + 1] = value .. "=" .. label end
    table.sort(reasons)
    add("Phase reasons: " .. table.concat(reasons, ", "))
    add("")

    add("-- Identity")
    local n, r = ns.Safe(UnitFullName, "player")
    add("UnitName(player)       = " .. Repr((UnitName("player"))) .. "   second return: " .. Repr(select(2, UnitName("player"))))
    add("UnitFullName(player)   = " .. Repr(n) .. " / " .. Repr(r))
    add("GetRealmName           = " .. Repr(GetRealmName()))
    add("GetNormalizedRealmName = " .. Repr(GetNormalizedRealmName and GetNormalizedRealmName()))
    add("PlayerFull (team key)  = " .. Repr(ns.PlayerFull()))
    add("RealName / ShownName   = " .. Repr(ns.RealName(ns.PlayerFull())) .. " / " .. Repr(ns.ShownName(ns.PlayerFull())))
    add("IsSelf(PlayerFull)     = " .. tostring(ns.IsSelf(ns.PlayerFull())))
    local registered = C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered
        and C_ChatInfo.IsAddonMessagePrefixRegistered(ns.prefix)
    add("Addon prefix registered = " .. tostring(registered) .. "   faction=" .. tostring((UnitFactionGroup("player"))))
    local own = ns.status[ns.PlayerFull() or ""] or {}
    add(("Status: money=%s free=%s/%s durability avg=%s lowest=%s"):format(tostring(own.money), tostring(own.free),
        tostring(own.slots), tostring(own.durAvg), tostring(own.durMin)))
    do
        local st = ns.commStats or {}
        local qa, qn, qb = 0, 0, 0
        if ns.CommQueued then qa, qn, qb = ns.CommQueued() end
        add(("Comm: sent=%s bytes=%s throttled=%s failed=%s queued alert/normal/bulk=%d/%d/%d (max %s) rate=%s B/s guildMode=%s inGuild=%s inInstance=%s"):format(
            tostring(st.sent), tostring(st.bytes), tostring(st.throttled), tostring(st.failed), qa, qn, qb,
            tostring(st.maxQueued), tostring(ns.CommRate and ns.CommRate()), tostring(ns.GuildMode and ns.GuildMode()),
            tostring(IsInGuild()), tostring(IsInInstance and IsInInstance())))
        if ns.GuildMode and ns.GuildMode() then
            local outside = {}
            for _, k in ipairs(ns.TeamOutsideGuild()) do outside[#outside + 1] = Repr(k) end
            add("  team outside the guild: " .. (#outside > 0 and table.concat(outside, ", ") or "none"))
        end
    end
    add(("Layer hop: pending=%s source=%s countdown=%s watched events=[%s] api=%s"):format(
        tostring(ns.hop.pending), tostring(ns.hop.source), tostring(ns.HopCountdownRunning()),
        table.concat(ns.hop.events or {}, ","),
        tostring(C_PlayerInteractionManager and C_PlayerInteractionManager.ShardTransferConfirm ~= nil)))
    add("Layer = " .. tostring(ns.layer) .. "   layer key = " .. tostring(ns.layerKey)
        .. "   zone = " .. tostring(GetZoneText and GetZoneText()) .. "   time = " .. date("%Y-%m-%d %H:%M:%S"))
    add("")

    add(("-- Group  inGroup=%s inRaid=%s"):format(tostring(IsInGroup()), tostring(IsInRaid())))
    local units = { "target", "party1", "party2", "party3", "party4" }
    if IsInRaid() then
        for i = 1, math.min(GetNumGroupMembers(), 10) do units[#units + 1] = "raid" .. i end
    end
    for _, unit in ipairs(units) do
        local line = UnitLine(unit)
        if line then add(line) end
    end
    add("")

    add("-- Team (profile " .. tostring(ns.CurrentProfileName()) .. ")")
    for _, key in ipairs(ns.SortedMembers()) do
        local m = ns.db.team[key]
        local s = ns.status[key]
        add(("key=%s first=%s last=%s class=%s order=%s roles=[%s] online=%s lastSender=%s whisperTo=%s layer=%s phase=%s"):format(
            Repr(key), Repr(m.name), Repr(m.last), tostring(m.class), tostring(m.order),
            table.concat(ns.MemberRoleList(key), ","), tostring(ns.IsOnline(key)),
            Repr(s and s.sender), Repr(ns.WhisperTarget(key)), tostring(s and s.layerKey), tostring((ns.PhaseOf(key)))))
    end
    add("")

    add("-- Modules")
    for _, e in ipairs(ns.InstalledModules()) do
        add(("%s (%s): loaded=%s enabledInAddOns=%s active=%s reason=%s"):format(e.title, e.addon,
            tostring(e.loaded), tostring(e.enabled), tostring(e.module and e.module.enabled), tostring(e.reason)))
    end
    for _, m in ipairs(ns.moduleList) do
        if m.Report then
            local ok, err = pcall(m.Report, m, add)
            if not ok then add("report error: " .. tostring(err)) end
        end
    end
    add("")

    add("-- Trade window")
    add("TradeFrame shown = " .. tostring(TradeFrame and TradeFrame:IsShown()))
    local tn, tr = ns.Safe(UnitFullName, "NPC")
    add("UnitFullName(npc) = " .. Repr(tn) .. " / " .. Repr(tr))
    add("TradeFrameRecipientNameText = " .. Repr(TradeFrameRecipientNameText and TradeFrameRecipientNameText:GetText()))
    add("")

    add("-- Last received MMT addon messages (empty = nothing ever arrived on this client)")
    if #ns.recent == 0 then add("(none)") end
    for _, line in ipairs(ns.recent) do add(line) end
    add("")

    add("-- Log (newest last)")
    for _, line in ipairs(MMTDB.debuglog or {}) do add(line) end
    return table.concat(L, "\n")
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
local function State(on) return on and "|cff33ff33ON|r" or "|cffff5555OFF|r" end

function ns.HandleDebugCommand(arg)
    local sub, rest = (arg or ""):match("^(%S*)%s*(.-)$")
    sub = (sub or ""):lower()

    if sub == "" or sub == "on" or sub == "off" then
        if sub == "" then MMTDB.debug = not MMTDB.debug else MMTDB.debug = (sub == "on") end
        ns.Print("Debug logging is now %s", State(MMTDB.debug))
        if MMTDB.debug then
            ns.Print("Test steps: /mmt debug clear, add your characters, /mmt ping, open a trade, then /mmt debug dump and copy the text to Claude.")
        end
        ns.RefreshConfig()
    elseif sub == "dump" or sub == "report" then
        ns.ShowText("MMT debug report", ns.BuildDebugReport())
    elseif sub == "log" then
        ns.ShowText("MMT debug log", table.concat(MMTDB.debuglog or {}, "\n"))
    elseif sub == "clear" then
        MMTDB.debuglog = {}
        ns.Print("Debug log cleared.")
    elseif sub == "chat" then
        MMTDB.debugChat = not MMTDB.debugChat
        ns.Print("Printing debug lines to chat: %s", State(MMTDB.debugChat))
        ns.RefreshConfig()
    elseif sub == "talents" then
        -- what the game offers for viewing talents (for fixing Ctrl-click in the XP window)
        local lines = { "MMT " .. ns.version .. " talent view candidates (global names with Talent / Inspect / UnitPopup...Talent)" }
        for _, l in ipairs(ns.ListTalentGlobals and ns.ListTalentGlobals() or {}) do lines[#lines + 1] = l end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "-- log lines about the talent view:"
        for _, l in ipairs(MMTDB.debuglog or {}) do
            if l:find("talent view", 1, true) or l:find("InspectUnit", 1, true) then lines[#lines + 1] = l end
        end
        ns.ShowText("MMT talent view report", table.concat(lines, "\n"))
    elseif sub == "name" then
        if rest == "" then ns.Print("Usage: /mmt debug name First Last") return end
        local bare = ns.StripRealm(rest)
        ns.Print("input    = %s", Repr(rest))
        ns.Print("no realm = %s", Repr(bare))
        ns.Print("NormKey  = %s", Repr(ns.NormKey(bare)))
        ns.Print("team key = %s   isSelf = %s", Repr(ns.Resolve(rest)), tostring(ns.IsSelf(rest)))
    else
        ns.Print("/mmt debug - toggle debug logging (now %s)", State(MMTDB.debug))
        ns.Print("/mmt debug dump - copyable report (identity, group, layer, team, trade, log)")
        ns.Print("/mmt debug log | clear | chat - show log, clear it, print lines live to chat")
        ns.Print("/mmt debug name <text> - test how a typed name is understood")
        ns.Print("/mmt debug talents - what the game offers to view talents (for the XP window's Ctrl-click)")
        ns.Print("/mmt ping - whisper all team members (3 name spellings) and show which one answers")
    end
end

---------------------------------------------------------------------------
-- If the game ever blocks an MMT action, say which one (for bug reports)
---------------------------------------------------------------------------
local reported = {}
local function Blocked(addon, func)
    if type(addon) ~= "string" or not addon:find("^MMT") then return end
    ns.Debug("ACTION BLOCKED: %s called %s (in combat: %s)", addon, tostring(func), tostring(InCombatLockdown()))
    local key = addon .. tostring(func)
    if reported[key] then return end
    reported[key] = true
    ns.Print("The game blocked %s from calling %s. Please send /mmt debug dump to Claude.", addon, tostring(func))
end
ns.On("ADDON_ACTION_BLOCKED", Blocked)
ns.On("ADDON_ACTION_FORBIDDEN", Blocked)
