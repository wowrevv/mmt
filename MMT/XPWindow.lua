-- MMT: vertical, movable window with XP %, rested XP %, layer and phasing
-- of every online team member. Offline members are hidden.

local _, ns = ...

local PAD = 3
local function Gap() return ns.db.xp.rowGap or 3 end
local A = { 0.31, 0.70, 1.00 }

local f = CreateFrame("Frame", "MMTXPFrame", UIParent)
f:SetFrameStrata("MEDIUM")
f:SetClampedToScreen(true)
f:SetMovable(true)
f:RegisterForDrag("LeftButton")
f:Hide()
f.bg = f:CreateTexture(nil, "BACKGROUND")
f.bg:SetAllPoints()
f.rows = {}

-- moving: Shift + drag (unless locked)
local dragging, dragEnd = false, 0
f:SetScript("OnDragStart", function(self)
    if ns.db.xp.locked or not IsShiftKeyDown() then return end
    dragging = true
    self:StartMoving()
end)
f:SetScript("OnDragStop", function(self)
    if not dragging then return end
    dragging, dragEnd = false, GetTime()
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    ns.db.xp.point = { point, relPoint, math.floor(x + 0.5), math.floor(y + 0.5) }
end)
-- the window's own border / background: right-click = settings
f:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" and GetTime() - dragEnd > 0.2 then ns.ToggleConfig("xp") end
end)

---------------------------------------------------------------------------
-- Row actions
--   click: FTL leader   right-click: invite   middle-click: invite the team
--   Ctrl-click: inspect   Ctrl-right-click: talents
--   Shift + drag: move   Shift-right-click: settings
---------------------------------------------------------------------------
local function GroupUnit(key)
    if ns.IsSelf(key) then return "player" end
    return ns.UnitForMember(key)
end

local function CanLead()
    return not IsInGroup() or UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
end

local function Invite(key)
    if ns.IsSelf(key) then return end
    if ns.UnitForMember(key) then ns.Print("%s is already in your group.", ns.FullDisplay(key)) return end
    if not CanLead() then ns.Print("Only the group leader can invite.") return end
    local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    local ok, err = pcall(invite, ns.WhisperTarget(key))
    ns.Debug("XP window invite %s -> %s %s", ns.Repr(ns.WhisperTarget(key)), tostring(ok), tostring(err or ""))
    if ok then ns.Print("Invited %s.", ns.FullDisplay(key)) end
end

-- middle-click: invite every team member who isn't in the group yet
local function InviteTeam()
    if not CanLead() then ns.Print("Only the group leader can invite.") return end
    local n = 0
    for _, key in ipairs(ns.SortedMembers()) do
        if not ns.IsSelf(key) and not ns.UnitForMember(key) then
            local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
            if pcall(invite, ns.WhisperTarget(key)) then n = n + 1 end
        end
    end
    if n > 0 then ns.Print("Invited %d team member(s).", n) else ns.Print("The whole team is in your group already.") end
end

local function MakeLeader(key)
    if not ns.db.ftl.enabled then ns.Print("FTL is switched off (/mmt > FTL).") return end
    ns.SetFTLLeader(key)
end

-- Blizzard windows are only opened outside combat (opening them from addon
-- code in combat can trigger the "blocked action" message)
local function NotInCombat()
    if InCombatLockdown() then ns.Print("Not in combat.") return false end
    return true
end

-- Forever's unit menu has "View Talents" (below "Inspect"), which opens the
-- talents in their own window. The menu entry is a UnitPopup button mixin;
-- MMT finds it by name and calls its OnClick the way the menu does. Fallback:
-- inspect, then the inspect window's Talents button / tab.
local talentMixin

local function FindTalentMixin()
    if talentMixin then return talentMixin end   -- only a find is kept (the menu code may load later)
    local names = {}
    for name, v in pairs(_G) do
        if type(name) == "string" and type(v) == "table" and name:find("^UnitPopup") and name:find("Talent")
            and type(rawget(v, "OnClick")) == "function" then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    -- prefer "View..." / "Inspect..." over others
    for _, name in ipairs(names) do
        if name:find("View") or name:find("Inspect") then talentMixin = _G[name] break end
    end
    talentMixin = talentMixin or (names[1] and _G[names[1]])
    ns.Debug("talent view: menu entries %s -> %s", table.concat(names, ", "), tostring(#names > 0))
    return talentMixin
end

-- debug: every global name about talents / inspect (/mmt debug talents)
function ns.ListTalentGlobals()
    local out = {}
    for name, v in pairs(_G) do
        if type(name) == "string" and #out < 300 and (name:find("Talent") or name:find("Inspect")
            or (name:find("^UnitPopup") and name:find("Mixin$"))) then
            out[#out + 1] = name .. " (" .. type(v) .. ")"
        end
    end
    table.sort(out)
    return out
end

local function ClickTalentsButton(frame, depth)
    if not frame or depth > 4 or not frame.GetChildren then return false end
    for _, child in ipairs({ frame:GetChildren() }) do
        if child.IsShown and child:IsShown() and child.GetText and child.Click then
            local text = child:GetText()
            if type(text) == "string" and not ns.IsSecret(text)
                and (text == (TALENTS or "Talents") or text:lower():find("talent", 1, true)) then
                pcall(child.Click, child)
                ns.Debug("talent view: clicked %s (%s)", child:GetName() or "button", text)
                return true
            end
        end
        if ClickTalentsButton(child, depth + 1) then return true end
    end
    return false
end

local function ViewTalents(unit, key)
    local mixin = FindTalentMixin()
    if mixin then
        local ctx = { unit = unit, name = GetUnitName(unit, true), guid = UnitGUID(unit) }
        local ok, err = pcall(mixin.OnClick, mixin, ctx)
        ns.Debug("talent view: menu entry OnClick(%s) -> %s %s", unit, tostring(ok), tostring(err or ""))
        if ok then return end
    end
    -- fallback: inspect window, then its Talents button / tab
    local ok, err = pcall(InspectUnit, unit)
    ns.Debug("InspectUnit(%s) -> %s %s", unit, tostring(ok), tostring(err or ""))
    if not ok then return end
    C_Timer.After(0.6, function()
        if ClickTalentsButton(InspectFrame, 0) then return end
        if InspectFrameTab3 and InspectFrameTab3:IsShown() then pcall(InspectFrameTab3.Click, InspectFrameTab3) return end
        ns.Debug("talent view: no Talents button found; /mmt debug talents lists candidates")
        ns.Print("Couldn't open the talents of %s. Please run /mmt debug talents and send me the report.", ns.FullDisplay(key))
    end)
end

local function Inspect(key, talents)
    if not NotInCombat() then return end
    if ns.IsSelf(key) then
        if talents then
            if ToggleTalentFrame then pcall(ToggleTalentFrame)
            elseif PlayerSpellsUtil and PlayerSpellsUtil.ToggleClassTalentFrame then pcall(PlayerSpellsUtil.ToggleClassTalentFrame) end
        elseif ToggleCharacter then
            pcall(ToggleCharacter, "PaperDollFrame")
        end
        return
    end
    local unit = GroupUnit(key)
    if not unit then ns.Print("%s must be in your group to be inspected.", ns.FullDisplay(key)) return end
    if CanInspect and not CanInspect(unit) then ns.Print("%s is too far away to inspect.", ns.FullDisplay(key)) return end
    if not InspectUnit then return end
    if talents then ViewTalents(unit, key) return end
    local ok, err = pcall(InspectUnit, unit)
    ns.Debug("InspectUnit(%s) -> %s %s", unit, tostring(ok), tostring(err or ""))
end

local function RowClick(row, button)
    local key = row.key
    if not key or dragging or GetTime() - dragEnd < 0.2 then return end
    local shift, ctrl = IsShiftKeyDown(), IsControlKeyDown()
    if button == "MiddleButton" then InviteTeam() return end
    if button == "RightButton" and shift then ns.ToggleConfig("xp") return end
    if shift then return end                      -- Shift + drag moves the window
    if button == "LeftButton" then
        if ctrl then Inspect(key, false) else MakeLeader(key) end
    elseif button == "RightButton" then
        if ctrl then Inspect(key, true) else Invite(key) end
    end
end

-- mouseover on a row: full name and all details of that member
local function RowTooltip(row)
    local key, s = row.key, row.status
    if not key or not s then return end
    local tip = ns.MemberTooltip(row, key, "ANCHOR_RIGHT")
    tip:AddLine(" ")
    if s.isMax or s.max <= 0 then
        tip:AddDoubleLine("Level " .. s.level, "max level", 1, 1, 1, 0.7, 0.7, 0.7)
    else
        tip:AddDoubleLine("Level " .. s.level, ("%d / %d XP (%.1f%%)"):format(s.cur, s.max, s.cur / s.max * 100), 1, 1, 1, 1, 1, 1)
        if s.rested > 0 then
            tip:AddDoubleLine("Rested", ("%d XP (%d%%)"):format(s.rested, math.floor(s.rested / s.max * 100 + 0.5)), 0.75, 0.6, 1, 0.75, 0.6, 1)
        end
    end
    if s.money then tip:AddDoubleLine("Gold", GetCoinTextureString and GetCoinTextureString(s.money) or ns.FormatMoney(s.money), 1, 1, 1, 1, 1, 1) end
    if s.free then tip:AddDoubleLine("Bags", ("%d of %d slots free"):format(s.free, s.slots or 0), 1, 1, 1, 1, 1, 1) end
    if s.durMin then
        tip:AddDoubleLine("Durability", ("lowest %d%%, average %d%%"):format(s.durMin, s.durAvg or s.durMin), 1, 1, 1, 1, 1, 1)
    end
    if s.rep then
        local c = FACTION_BAR_COLORS and FACTION_BAR_COLORS[s.rep.standing]
        local standing = _G["FACTION_STANDING_LABEL" .. tostring(s.rep.standing)] or ""
        tip:AddDoubleLine(s.rep.name, ("%s  %d / %d"):format(standing, s.rep.cur or 0, s.rep.max or 0),
            1, 1, 1, c and c.r or 1, c and c.g or 1, c and c.b or 1)
    end
    tip:AddDoubleLine("Layer", s.layer and ("#" .. s.layer) or "unknown", 1, 1, 1, 0.7, 0.7, 0.7)
    local phase = ns.PhaseOf(key)
    if phase then tip:AddDoubleLine("Phasing", phase, 1, 1, 1, 1, 0.25, 0.25) end
    if ns.db.xp.followCheck then
        local fi = ns.FollowInfo(key)
        if fi and fi.broken then
            tip:AddDoubleLine("Follow", "stopped following " .. ns.Ago(time() - math.floor(GetTime() - (fi.since or GetTime()))), 1, 1, 1, 1, 0.3, 0.3)
        elseif fi and fi.combatBreak then
            tip:AddDoubleLine("Follow", "broke in combat", 1, 1, 1, 1, 0.85, 0.2)
        elseif fi and fi.following then
            local t = fi.targetKey and ns.FullDisplay(fi.targetKey) or fi.target
            tip:AddDoubleLine("Follow", t and ("following " .. t) or "following", 1, 1, 1, 0.4, 1, 0.4)
        end
    end
    local cc = ns.db.cc.enabled and ns.CCState and ns.CCState(key)
    if cc then
        local left, spell = ns.CCLeft(cc), ns.CCSpellName(cc)
        tip:AddDoubleLine("Control", ns.CCLabel(cc.kind) .. (left and (", " .. left .. " s") or "") .. (spell and (" (" .. spell .. ")") or ""),
            1, 1, 1, 1, 0.6, 0.1)
    end
    if ns.IsFTLLeader(key) then tip:AddLine("FTL leader: {FTL} macros point to this character.", 1, 0.82, 0) end
    tip:AddLine(" ")
    tip:AddLine("Click: make FTL leader   Right-click: invite", 0.5, 0.5, 0.5)
    tip:AddLine(ns.IsSelf(key) and "Ctrl-click: character   Ctrl-right-click: talents"
        or "Ctrl-click: inspect   Ctrl-right-click: talents", 0.5, 0.5, 0.5)
    tip:AddLine("Middle-click: invite the whole team", 0.5, 0.5, 0.5)
    tip:AddLine((ns.db.xp.locked and "" or "Shift-drag: move   ") .. "Shift-right-click: settings", 0.5, 0.5, 0.5)
    tip:Show()
end

local function Row(i)
    local row = f.rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, f)
    -- gold, bags, durability: own column left of the name
    row.inv = row:CreateFontString(nil, "OVERLAY")
    row.inv:SetPoint("LEFT", 4, 0)
    row.inv:SetJustifyH("LEFT")
    row.inv:SetWordWrap(false)
    -- the bar starts at the name
    row.bar = CreateFrame("Frame", nil, row)
    row.bar:SetPoint("TOPRIGHT"); row.bar:SetPoint("BOTTOMRIGHT")
    row.bar:SetPoint("LEFT", 0, 0)
    row.track = row.bar:CreateTexture(nil, "BACKGROUND")
    row.track:SetAllPoints()
    row.track:SetColorTexture(1, 1, 1, 0.04)
    row.fill = row.bar:CreateTexture(nil, "BORDER")
    row.fill:SetPoint("TOPLEFT"); row.fill:SetPoint("BOTTOMLEFT")
    row.rest = row.bar:CreateTexture(nil, "BORDER")
    row.rest:SetPoint("TOPLEFT", row.fill, "TOPRIGHT"); row.rest:SetPoint("BOTTOMLEFT", row.fill, "BOTTOMRIGHT")
    row.rest:SetColorTexture(0.65, 0.45, 1.0, 0.30)
    -- red, pulsing mark: this member stopped following
    row.alertLayer = CreateFrame("Frame", nil, row)   -- above the bar area
    row.alertLayer:SetAllPoints()
    row.alertLayer:SetFrameLevel(row:GetFrameLevel() + 3)
    row.alert = row.alertLayer:CreateTexture(nil, "OVERLAY")
    row.alert:SetAllPoints()
    row.alert:SetColorTexture(1, 0.1, 0.1, 0.35)
    row.alert.pulse = row.alert:CreateAnimationGroup()
    row.alert.pulse:SetLooping("BOUNCE")
    local afade = row.alert.pulse:CreateAnimation("Alpha")
    afade:SetFromAlpha(1); afade:SetToAlpha(0.3); afade:SetDuration(0.8)
    row.alert:Hide()
    -- orange, pulsing mark: this member can't move (stun, fear, root ...)
    row.ccMark = row.alertLayer:CreateTexture(nil, "OVERLAY")
    row.ccMark:SetAllPoints()
    row.ccMark:SetColorTexture(1, 0.55, 0.05, 0.35)
    row.ccMark.pulse = row.ccMark:CreateAnimationGroup()
    row.ccMark.pulse:SetLooping("BOUNCE")
    local cfade = row.ccMark.pulse:CreateAnimation("Alpha")
    cfade:SetFromAlpha(1); cfade:SetToAlpha(0.3); cfade:SetDuration(0.4)
    row.ccMark:Hide()
    row.value = row.bar:CreateFontString(nil, "OVERLAY")
    row.value:SetPoint("RIGHT", -4, 0)
    row.value:SetJustifyH("RIGHT")
    row.name = row.bar:CreateFontString(nil, "OVERLAY")
    row.name:SetPoint("LEFT", 4, 0)
    row.name:SetPoint("RIGHT", row.value, "LEFT", -4, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.line = row.bar:CreateFontString(nil, "OVERLAY")
    row.line:SetPoint("LEFT", 4, 0)
    row.line:SetPoint("RIGHT", -4, 0)
    row.line:SetWordWrap(false)
    -- pulsing red "Layer Hop" left of the name; clickable even when the window is click-through
    row.hop = CreateFrame("Button", nil, row.bar)
    row.hop:SetPoint("LEFT", 2, 0)
    row.hop:SetFrameLevel(row:GetFrameLevel() + 5)
    row.hop.text = row.hop:CreateFontString(nil, "OVERLAY")
    row.hop.text:SetPoint("LEFT")
    row.hop.text:SetTextColor(1, 0.2, 0.2)
    local pulse = row.hop.text:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1); fade:SetToAlpha(0.25); fade:SetDuration(0.6)
    row.hop.pulse = pulse
    row.hop:SetScript("OnClick", function() ns.HopClicked(row.key) end)
    row.hop:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Layer Hop", 1, 0.2, 0.2)
        if ns.IsSelf(row.key) then
            GameTooltip:AddLine("The game offers to move you to another layer. Click to accept in 3 seconds.", 1, 1, 1, true)
        else
            GameTooltip:AddLine(("%s has a layer hop pending. Click to make %s accept it in 3 seconds."):format(
                ns.FullDisplay(row.key), ns.FirstName(row.key)), 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    row.hop:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.hop:Hide()
    -- rows show details on mouseover and pass dragging / right-click to the window
    row:RegisterForDrag("LeftButton")
    row:SetScript("OnDragStart", function() f:GetScript("OnDragStart")(f) end)
    row:SetScript("OnDragStop", function() f:GetScript("OnDragStop")(f) end)
    row:SetScript("OnMouseUp", function(self, button) if self:IsMouseOver() then RowClick(self, button) end end)
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.rows[i] = row
    return row
end

local function Hex(r, g, b)
    return ("|cff%02x%02x%02x"):format(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return nil
end

-- names to show, in team order (your own character first if not in the team)
local function Members()
    local list = {}
    local me = ns.PlayerFull()
    local inTeam = false
    for _, key in ipairs(ns.SortedMembers()) do
        if ns.IsSelf(key) then
            inTeam = true
            if ns.db.xp.showSelf then list[#list + 1] = key end
        elseif ns.IsOnline(key) and ns.status[key] then
            list[#list + 1] = key
        end
    end
    if not inTeam and ns.db.xp.showSelf and me then table.insert(list, 1, me) end
    return list
end

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:1:0|t"
local BAG_ICON = "|TInterface\\Icons\\INV_Misc_Bag_08:0:0:0:0:64:64:6:58:6:58|t"
local DUR_ICON = "|TInterface\\Icons\\Trade_BlackSmithing:0:0:0:0:64:64:6:58:6:58|t"

local function Thousands(n)
    local s = tostring(n)
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function DurabilityColour(pct)
    if pct >= 60 then return Hex(0.4, 1, 0.4) elseif pct >= 25 then return Hex(1, 0.85, 0.2) end
    return Hex(1, 0.3, 0.3)
end

-- gold, free bag slots and durability
local function InventoryText(s)
    local x = ns.db.xp
    local parts = {}
    if x.showGold and s.money then
        if x.goldFormat == "FULL" and GetCoinTextureString then
            parts[#parts + 1] = GetCoinTextureString(s.money)
        else
            parts[#parts + 1] = Thousands(math.floor(s.money / 10000)) .. GOLD_ICON
        end
    end
    if x.showBags and s.free then
        local colour = (s.free == 0 and Hex(1, 0.3, 0.3)) or (s.free <= 4 and Hex(1, 0.85, 0.2)) or ""
        parts[#parts + 1] = BAG_ICON .. " " .. colour .. s.free .. (colour ~= "" and "|r" or "")
    end
    if x.showDurability then
        local pct = (x.durability == "AVERAGE") and s.durAvg or s.durMin
        if pct then parts[#parts + 1] = DUR_ICON .. " " .. DurabilityColour(pct) .. pct .. "%|r" end
    end
    return parts
end

local function ValueText(key, s)
    local x = ns.db.xp
    local parts = {}
    if x.showLevel then parts[#parts + 1] = Hex(0.75, 0.75, 0.75) .. "L" .. s.level .. "|r" end
    if s.isMax or s.max <= 0 then
        parts[#parts + 1] = "max"
    else
        parts[#parts + 1] = ("%.1f%%"):format(s.cur / s.max * 100)
        if x.showRested and s.rested > 0 then
            parts[#parts + 1] = Hex(0.75, 0.6, 1) .. ("R %d%%"):format(math.floor(s.rested / s.max * 100 + 0.5)) .. "|r"
        end
    end
    return table.concat(parts, "  ")
end

-- reputation mode: "<standing> 45%" of the watched faction
local function StandingLabel(standing)
    return _G["FACTION_STANDING_LABEL" .. tostring(standing)] or ("Standing " .. tostring(standing))
end

local function RepColour(standing)
    local c = FACTION_BAR_COLORS and FACTION_BAR_COLORS[standing]
    if c then return c.r, c.g, c.b end
    return 0.3, 0.7, 0.3
end

local function RepValueText(s)
    local x = ns.db.xp
    local parts = {}
    if x.showLevel then parts[#parts + 1] = Hex(0.75, 0.75, 0.75) .. "L" .. s.level .. "|r" end
    local r = s.rep
    if not r then
        parts[#parts + 1] = Hex(0.5, 0.5, 0.5) .. "no faction|r"
    else
        local cr, cg, cb = RepColour(r.standing)
        local text = StandingLabel(r.standing)
        if (r.max or 0) > 0 then text = text .. (" %d%%"):format(math.floor(r.cur / r.max * 100)) end
        parts[#parts + 1] = Hex(cr, cg, cb) .. text .. "|r"
    end
    return table.concat(parts, "  ")
end

local function Update()
    local x = ns.db.xp
    if not x.enabled or not ns.ready then f:Hide() return end
    ns.UpdateOwnStatus()
    local list = Members()
    if #list == 0 then f:Hide() return end

    local h = math.max(x.barHeight, x.size + 4)
    -- first pass: inventory texts and the widest one (all bars start at the same x)
    local invText, invW = {}, 0
    for i, key in ipairs(list) do
        local s = ns.status[key] or ns.UpdateOwnStatus()
        local row = Row(i)
        invText[i] = table.concat(InventoryText(s), "  ")
        ns.ApplyFont(row.inv, x.font, x.size, x.outline)
        row.inv:SetText(invText[i])
        if invText[i] ~= "" then invW = math.max(invW, row.inv:GetStringWidth() or 0) end
    end
    local barLeft = invW > 0 and math.floor(invW + 10) or 0
    local barWidth = math.max(20, x.width - barLeft)
    local rep = x.barMode == "REP"

    for i, key in ipairs(list) do
        local s = ns.status[key] or ns.UpdateOwnStatus()
        local row = Row(i)
        row.key, row.status = key, s
        row:EnableMouse(not x.clickThrough)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", PAD, -(PAD + (i - 1) * (h + Gap())))
        row:SetSize(x.width, h)
        local broken = x.followCheck and ns.FollowBroken and ns.FollowBroken(key)
        local ccText = ns.db.cc.enabled and ns.CCShort and ns.CCShort(key)
        local pulsing = broken and ns.FollowJustBroke(key) and not ccText
        row.alert:SetShown(pulsing and true or false)
        if pulsing then
            if not row.alert.pulse:IsPlaying() then row.alert.pulse:Play() end
        else
            row.alert.pulse:Stop()
        end
        row.ccMark:SetShown(ccText and true or false)
        if ccText then
            if not row.ccMark.pulse:IsPlaying() then row.ccMark.pulse:Play() end
        else
            row.ccMark.pulse:Stop()
        end
        -- after the name: "(no follow)", "(stunned 4)"
        local suffix = (broken and " |cffff4040(no follow)|r" or "") .. (ccText and (" |cffffa020(" .. ccText .. ")|r") or "")

        local cr, cg, cb = ClassColor(s.class)
        local useClass = x.classColors and cr
        local r, g, b = useClass and cr or A[1], useClass and cg or A[2], useClass and cb or A[3]

        row.inv:SetShown(invText[i] ~= "")
        row.bar:SetPoint("LEFT", barLeft, 0)

        local pct, restPct
        if rep then
            local rp = s.rep
            pct = (rp and (rp.max or 0) > 0) and math.min(1, math.max(0, rp.cur / rp.max)) or (rp and 1 or 0)
            restPct = 0
            local rr, rg, rb = RepColour(rp and rp.standing or 4)
            row.fill:SetColorTexture(rr * 0.7, rg * 0.7, rb * 0.7, 0.85)
        else
            pct = (s.isMax or s.max <= 0) and 0 or math.min(1, s.cur / s.max)
            restPct = (s.isMax or s.max <= 0) and 0 or math.min(1 - pct, s.rested / s.max)
            row.fill:SetColorTexture(r * 0.6, g * 0.6, b * 0.6, 0.85)
        end
        row.fill:SetShown(x.showBars and pct > 0)
        row.fill:SetWidth(math.max(1, barWidth * pct))
        row.rest:SetShown(x.showBars and not rep and x.showRested and restPct > 0)
        row.rest:SetWidth(math.max(1, barWidth * restPct))
        row.track:SetShown(x.showBars)

        local name = ns.Display(key)
        if ns.db.ftl.enabled and ns.db.ftl.crown and ns.IsFTLLeader(key) then
            name = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:0:0:0:-1|t" .. name
        end
        local values = rep and RepValueText(s) or ValueText(key, s)

        -- Layer Hop tag
        local hop = x.layerHopNotify and ns.HopPendingFor(key)
        local left = 4
        if hop then
            ns.ApplyFont(row.hop.text, x.font, x.size, x.outline)
            local cdLeft = ns.HopCountdownFor and ns.HopCountdownFor(key)
            row.hop.text:SetText(cdLeft and ("Layer Hop " .. cdLeft) or "Layer Hop")
            row.hop:SetSize(row.hop.text:GetStringWidth() + 4, h)
            row.hop:Show()
            if not row.hop.pulse:IsPlaying() then row.hop.pulse:Play() end
            left = row.hop:GetWidth() + 8
        else
            row.hop.pulse:Stop()
            row.hop:Hide()
        end
        row.name:SetPoint("LEFT", left, 0)
        row.line:SetPoint("LEFT", left, 0)
        local nr, ng, nb = useClass and cr or 1, useClass and cg or 1, useClass and cb or 1
        if x.align == "SPLIT" then
            ns.ApplyFont(row.name, x.font, x.size, x.outline)
            ns.ApplyFont(row.value, x.font, x.size, x.outline)
            row.name:SetText(name .. suffix)
            row.name:SetTextColor(nr, ng, nb)
            row.value:SetText(values)
            row.value:SetTextColor(1, 1, 1)
            row.name:Show(); row.value:Show(); row.line:Hide()
        else
            ns.ApplyFont(row.line, x.font, x.size, x.outline)
            row.line:SetJustifyH(x.align)
            row.line:SetText(Hex(nr, ng, nb) .. name .. "|r" .. suffix .. "  " .. values)
            row.line:SetTextColor(1, 1, 1)
            row.line:Show(); row.name:Hide(); row.value:Hide()
        end
        row:Show()
    end
    for i = #list + 1, #f.rows do f.rows[i]:Hide() end

    f:SetScale(x.scale)
    f:SetAlpha(x.alpha)
    f:SetSize(x.width + PAD * 2, #list * (h + Gap()) - Gap() + PAD * 2)
    f.bg:SetColorTexture(0, 0, 0, x.bgAlpha)
    f:Show()
end
ns.UpdateXPWindow = Update

local function Layout()
    local x = ns.db.xp
    f:ClearAllPoints()
    local p = x.point
    f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
    f:EnableMouse(not x.clickThrough)
    Update()
end

function ns.ResetXPPosition()
    ns.db.xp.point = { unpack(ns.defaults.xp.point) }
    Layout()
end

function ns.ToggleXPWindow()
    ns.db.xp.enabled = not ns.db.xp.enabled
    ns.Refresh()
end

ns.OnRefresh(Layout)
ns.Listen("STATUS_CHANGED", Update)
ns.Listen("TEAM_CHANGED", Update)
ns.Listen("PROFILE_CHANGED", function() if ns.ready then Layout() end end)
ns.OnLogin(function()
    C_Timer.NewTicker(5, Update) -- drops members whose heartbeat stopped, updates phase tags
end)
