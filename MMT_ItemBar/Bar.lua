-- MMT Item Bar: the bar. Its slots are secure buttons (the game only lets
-- such buttons use items); their item is set outside combat, so changes that
-- arrive in combat are applied when combat ends.
--
-- Mouse on a slot:
--   drop an item       put it in this slot (every character)
--   left click         use the item here
--   right click        use it here and on the team (see Module.lua)
--   Ctrl-click         remove it (every character)
--   Shift + drag       move the bar
--   Shift-right-click  settings

local _, mod = ...
local MMT = MMT
local M = mod.M
local UI = MMT.UI

local SIZE, GAP, PAD = 36, 4, 6
local SMALL = 16

local f = CreateFrame("Frame", "MMTItemBarFrame", UIParent)
f:SetMovable(true)
f:SetClampedToScreen(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:Hide()
f.bg = f:CreateTexture(nil, "BACKGROUND")
f.bg:SetAllPoints()
f.bg:SetColorTexture(0, 0, 0, 0.35)

local function StartMove()
    if IsShiftKeyDown() and not M.db.locked then f:StartMoving() end
end
local function StopMove()
    f:StopMovingOrSizing()
    local point, _, relPoint, x, y = f:GetPoint()
    M.db.point = { point, relPoint, math.floor(x + 0.5), math.floor(y + 0.5) }
end
f:SetScript("OnDragStart", StartMove)
f:SetScript("OnDragStop", StopMove)
f:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" and IsShiftKeyDown() then MMT.ToggleConfig("mod:ItemBar") end
end)

local function ItemIcon(id)
    return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)) or (GetItemIcon and GetItemIcon(id))
end

---------------------------------------------------------------------------
-- Slots
---------------------------------------------------------------------------
local buttons = {}
local pendingAttributes = false

local function ApplyAttributes(b)
    if InCombatLockdown() then pendingAttributes = true return end
    local id = mod.Items()[b.slot]
    local item = id and ("item:" .. id) or nil
    b:SetAttribute("type1", id and "item" or nil)
    b:SetAttribute("type2", id and "item" or nil)
    b:SetAttribute("item", item)
    -- modified clicks are MMT's own (remove, settings, move)
    for _, m in ipairs({ "shift-", "ctrl-" }) do
        b:SetAttribute(m .. "type1", "none")
        b:SetAttribute(m .. "type2", "none")
    end
end

local function DropOn(b)
    local kind, id = GetCursorInfo()
    if kind ~= "item" or not id then return false end
    if InCombatLockdown() then MMT.Print("Item Bar: not in combat.") return true end
    ClearCursor()
    mod.SetSlot(b.slot, id)
    return true
end

local function Tooltip(b)
    local id = mod.Items()[b.slot]
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    if not id then
        GameTooltip:SetText("Empty slot " .. b.slot)
        GameTooltip:AddLine("Drop an item from your bags here: it appears on every team member's bar.", 1, 1, 1, true)
    else
        GameTooltip:SetItemByID(id)
        GameTooltip:AddLine(" ")
        local gbank = -1
        for _, key in ipairs(MMT.SortedMembers()) do
            local c
            if MMT.IsSelf(key) then c = { mod.OwnCount(id) }
            else c = mod.counts[key] and mod.counts[key][id] end
            if c then
                if (c[3] or -1) > gbank then gbank = c[3] end
                GameTooltip:AddLine(("%s - bag: %d / bank: %d"):format(MMT.ShownName(key), c[1], c[2]), 1, 1, 1)
            else
                GameTooltip:AddLine(("%s - no data"):format(MMT.ShownName(key)), 0.5, 0.5, 0.5)
            end
        end
        if M.db.guildBank then
            GameTooltip:AddLine(gbank >= 0 and ("Guild bank: %d"):format(gbank) or "Guild bank: open it once to count",
                gbank >= 0 and 1 or 0.5, gbank >= 0 and 1 or 0.5, gbank >= 0 and 1 or 0.5)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: use   Right-click: use on the team", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Ctrl-click: remove   Shift-drag: move   Shift-right-click: settings", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

-- The secure template acts on the key/mouse press when "cast on key down" is
-- on (the default) and on the release otherwise: slots get both, and MMT's
-- own click handling runs only in the phase the game uses.
local function ActivePhase(down)
    local onDown = GetCVarBool and GetCVarBool("ActionButtonUseKeyDown")
    return (down and true or false) == (onDown and true or false)
end

local function Button(slot)
    local b = CreateFrame("Button", "MMTItemBarButton" .. slot, f, "SecureActionButtonTemplate")
    b.slot = slot
    b:SetSize(SIZE, SIZE)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:RegisterForDrag("LeftButton")
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(1, 1, 1, 0.06)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 2, -2)
    b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.count:SetPoint("BOTTOMRIGHT", -2, 2)
    b.glow = b:CreateTexture(nil, "OVERLAY")
    b.glow:SetAllPoints()
    b.glow:SetColorTexture(1, 0.82, 0, 0.35)
    b.glow:Hide()
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)

    -- an item on the cursor goes into the slot instead of using the old one
    b:SetScript("PreClick", function(self, _, down)
        if ActivePhase(down) and GetCursorInfo() == "item" and not InCombatLockdown() then
            self:SetAttribute("type1", nil) self:SetAttribute("type2", nil)
        end
    end)
    b:SetScript("PostClick", function(self, button, down)
        if not ActivePhase(down) then return end
        if DropOn(self) then ApplyAttributes(self) return end
        local id = mod.Items()[self.slot]
        if IsShiftKeyDown() then
            if button == "RightButton" then MMT.ToggleConfig("mod:ItemBar") end
            return
        end
        if IsControlKeyDown() then
            if id then
                if InCombatLockdown() then MMT.Print("Item Bar: not in combat.") return end
                mod.SetSlot(self.slot, nil)
            end
            return
        end
        if button == "RightButton" and id then
            MMT.SendToTeam(("IBU:%d:%d"):format(self.slot, id), true, "ALERT")
        end
    end)
    b:SetScript("OnReceiveDrag", function(self) if DropOn(self) then ApplyAttributes(self) end end)
    b:SetScript("OnDragStart", StartMove)
    b:SetScript("OnDragStop", StopMove)
    b:SetScript("OnEnter", Tooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    buttons[slot] = b
    _G["BINDING_NAME_CLICK MMTItemBarButton" .. slot .. ":LeftButton"] = "Item Bar slot " .. slot
    return b
end
BINDING_HEADER_MMT_ITEMBAR = "MMT - Item Bar"
for slot = 1, mod.MAX_SLOTS do Button(slot) end

-- small buttons: refresh (sync) and clear
local function Small(texture, tipTitle, tipText, onClick)
    local s = CreateFrame("Button", nil, f)
    s:SetSize(SMALL, SMALL)
    s:SetNormalTexture(texture)
    s:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    s:SetScript("OnClick", onClick)
    UI.Tooltip(s, tipTitle, tipText)
    return s
end
f.refresh = Small("Interface\\Buttons\\UI-RefreshButton", "Refresh",
    "Sends this bar to every team member and asks for their counts.", function() mod.SendBar() end)
f.clear = Small("Interface\\Buttons\\UI-GroupLoot-Pass-Up", "Clear",
    "Removes every item from the bar, on every team member.", function()
        UI.Confirm("Remove every item from the Item Bar, on every team member?", "Clear", function() mod.ClearAll() end, "Cancel")
    end)

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
-- icons, counts and lit slots (allowed in combat)
local function UpdateIcons(n)
    for slot = 1, n do
        local b = buttons[slot]
        local id = mod.Items()[slot]
        if id then
            b.icon:SetTexture(ItemIcon(id))
            local have = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id)) or (GetItemCount and GetItemCount(id)) or 0
            b.count:SetText(have > 1 and have or (have == 1 and "" or "0"))
            b.icon:SetDesaturated(have == 0)
            b.icon:Show()
        else
            b.icon:Hide()
            b.count:SetText("")
        end
        b.glow:SetShown((mod.flash[slot] or 0) > GetTime())
    end
end

function mod.Update()
    local cfg = M.db
    local n = math.max(2, math.min(mod.MAX_SLOTS, cfg.slots or 4))
    -- the bar holds secure buttons: no layout changes in combat
    if InCombatLockdown() then
        pendingAttributes = true
        if f:IsShown() then UpdateIcons(n) end
        return
    end
    if not (M.enabled and MMT.ready) then f:Hide() return end
    local vertical = cfg.layout == "V"
    for slot, b in ipairs(buttons) do
        b:ClearAllPoints()
        if slot <= n then
            local offset = PAD + (slot - 1) * (SIZE + GAP)
            if vertical then b:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -offset)
            else b:SetPoint("TOPLEFT", f, "TOPLEFT", offset, -PAD) end
            b:Show()
        else
            b:Hide()
        end
        ApplyAttributes(b)
    end
    UpdateIcons(n)
    -- small buttons after the last slot
    local smalls = {}
    if cfg.showRefresh then smalls[#smalls + 1] = f.refresh else f.refresh:Hide() end
    if cfg.showClear then smalls[#smalls + 1] = f.clear else f.clear:Hide() end
    local length = PAD + n * (SIZE + GAP) - GAP
    for i, s in ipairs(smalls) do
        s:ClearAllPoints()
        if vertical then s:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (i - 1) * (SMALL + 4), -(length + 4))
        else s:SetPoint("TOPLEFT", f, "TOPLEFT", length + 4, -(PAD + (i - 1) * (SMALL + 4))) end
        s:Show()
    end
    local extra = #smalls > 0 and (SMALL + 4) or 0
    if vertical then f:SetSize(SIZE + PAD * 2, length + PAD + extra)
    else f:SetSize(length + PAD + extra, SIZE + PAD * 2) end
    f:SetScale(cfg.scale or 1)
    if not f:IsShown() then
        f:ClearAllPoints()
        local p = cfg.point or M.defaults.point
        f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
        f:Show()
    end
end

function mod.Hide() if not InCombatLockdown() then f:Hide() else pendingAttributes = true end end

function mod.ResetPosition()
    M.db.point = { unpack(M.defaults.point) }
    f:ClearAllPoints()
    local p = M.db.point
    f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

M:On("PLAYER_REGEN_ENABLED", function()
    if pendingAttributes then pendingAttributes = false mod.Update() end
end)
-- slots that light up (right click on another client) go dark again
C_Timer.NewTicker(1, function()
    for slot, untilTime in pairs(mod.flash) do
        if untilTime <= GetTime() then mod.flash[slot] = nil if M.enabled then mod.Update() end end
    end
end)
MMT.OnRefresh(function() if MMT.ready then mod.Update() end end)
