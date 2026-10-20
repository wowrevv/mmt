-- MMT Item Compare: hover an item and press the Item Compare key to see
-- what every team member wears in that slot, as real item tooltips next to
-- the hovered one, plus the stat changes if they equipped the hovered item.

local _, mod = ...
local MMT = MMT
local M = mod.M
local UI = MMT.UI

BINDING_HEADER_MMT_ITEMCOMPARE = "MMT - Item Compare"
BINDING_NAME_MMT_ITEM_COMPARE = "Item Compare (team items in the hovered item's slot)"
local ACTION = "MMT_ITEM_COMPARE"

-- equip location -> inventory slots
local SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16, 17 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 },
    INVTYPE_RELIC = { 18 }, INVTYPE_TABARD = { 19 },
}
local SLOT_NAMES = { [11] = "Ring 1", [12] = "Ring 2", [13] = "Trinket 1", [14] = "Trinket 2",
    [16] = "Main Hand", [17] = "Off Hand" }

local active = false     -- key held (HOLD) or switched on (TOGGLE)
local shownLink
local tips, used = {}, 0

---------------------------------------------------------------------------
-- Tooltip pool (real item tooltips with a flat name header)
---------------------------------------------------------------------------
local function Tip(i)
    local t = tips[i]
    if t then return t end
    t = CreateFrame("GameTooltip", "MMTCompareTip" .. i, UIParent, "GameTooltipTemplate")
    t:SetFrameStrata("TOOLTIP")
    t:SetClampedToScreen(true)
    local h = CreateFrame("Frame", nil, t)
    h:SetHeight(18)
    h:SetPoint("BOTTOMLEFT", t, "TOPLEFT", 0, 1)
    h:SetPoint("BOTTOMRIGHT", t, "TOPRIGHT", 0, 1)
    UI.Fill(h, 0.05, 0.05, 0.06, 0.92)
    h.text = UI.Label(h, "")
    h.text:SetPoint("LEFT", 6, 0)
    h.text:SetPoint("RIGHT", -6, 0)
    h.text:SetJustifyH("LEFT")
    h.text:SetWordWrap(false)
    t.header = h
    tips[i] = t
    return t
end

local function HideAll()
    for _, t in ipairs(tips) do t:Hide() end
    used = 0
    shownLink = nil
end

---------------------------------------------------------------------------
-- Stats
---------------------------------------------------------------------------
local function Stats(link)
    if not link then return {} end
    local fn = (C_Item and C_Item.GetItemStats) or GetItemStats
    return (fn and fn(link)) or {}
end

local function ItemLevel(link)
    if not link then return nil end
    local fn = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo
    local lvl = fn and fn(link)
    if not lvl then lvl = select(4, MMT.ItemInfo(link)) end
    return lvl
end

-- lines describing what changes if this member equips the hovered item
local function DeltaLines(hovered, equipped)
    local new, old = Stats(hovered), Stats(equipped)
    local keys, lines = {}, {}
    for k in pairs(new) do keys[k] = true end
    for k in pairs(old) do keys[k] = true end
    local sorted = {}
    for k in pairs(keys) do sorted[#sorted + 1] = k end
    table.sort(sorted, function(a, b) return (_G[a] or a) < (_G[b] or b) end)
    for _, k in ipairs(sorted) do
        local d = (new[k] or 0) - (old[k] or 0)
        if d ~= 0 then
            local label = _G[k] or k:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):lower()
            lines[#lines + 1] = { ("%+g %s"):format(math.floor(d * 10 + 0.5) / 10, label), d > 0 }
        end
    end
    local li, lo = ItemLevel(hovered), ItemLevel(equipped)
    if li and lo and li ~= lo then
        table.insert(lines, 1, { ("%+d item level"):format(li - lo), li > lo })
    end
    return lines
end

---------------------------------------------------------------------------
-- Building the comparison
---------------------------------------------------------------------------
local function HoveredLink()
    if not (GameTooltip and GameTooltip:IsShown()) then return nil end
    local link
    if TooltipUtil and TooltipUtil.GetDisplayedItem then
        local ok, _, l = pcall(TooltipUtil.GetDisplayedItem, GameTooltip)
        if ok then link = l end
    end
    if not link and GameTooltip.GetItem then
        local ok, _, l = pcall(GameTooltip.GetItem, GameTooltip)
        if ok then link = l end
    end
    if type(link) ~= "string" or MMT.IsSecret(link) then return nil end
    return link
end

local function EquipLoc(link)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if fn then
        local _, _, _, loc = fn(link)
        if loc then return loc end
    end
    return select(9, MMT.ItemInfo(link))
end

-- entries: { key, slot, link (or nil), state = "item" | "empty" | "nodata", time }
local function Entries(slots)
    local cfg = M.db
    local list = {}
    for _, key in ipairs(MMT.SortedMembers()) do
        local isSelf = MMT.IsSelf(key)
        if not isSelf or cfg.includeSelf then
            local rec = mod.EquipmentOf(key)
            local online = MMT.IsOnline(key)
            if rec and (online or cfg.showStale) then
                for _, slot in ipairs(slots) do
                    local item
                    if isSelf then item = GetInventoryItemLink("player", slot)
                    else item = mod.ExpandItem(rec.items[slot]) end
                    list[#list + 1] = { key = key, slot = slot, link = item, state = item and "item" or "empty",
                        time = (not online) and rec.time or nil }
                end
            elseif not rec and cfg.showStale then
                list[#list + 1] = { key = key, slot = slots[1], state = "nodata" }
            end
        end
    end
    return list
end

local function HeaderText(e, multi)
    local m = MMT.db.team[e.key]
    local c = m and m.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[m.class]
    local name = MMT.FirstName(e.key)
    if c then name = ("|cff%02x%02x%02x%s|r"):format(math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255), name) end
    local extra = {}
    if multi and SLOT_NAMES[e.slot] then extra[#extra + 1] = SLOT_NAMES[e.slot] end
    if e.time then extra[#extra + 1] = MMT.Ago(e.time) end
    if #extra > 0 then name = name .. "  |cff888888" .. table.concat(extra, " · ") .. "|r" end
    return name
end

local function Render(link)
    local cfg = M.db
    HideAll()
    local loc = EquipLoc(link)
    local slots = loc and SLOTS[loc]
    if not slots then return end
    local entries = Entries(slots)
    if #entries == 0 then return end
    shownLink = link

    for i, e in ipairs(entries) do
        local t = Tip(i)
        t:SetOwner(UIParent, "ANCHOR_NONE")
        t:SetScale(cfg.scale)
        if e.state == "item" then
            t:SetHyperlink(e.link)
            if cfg.showDelta then
                local lines = DeltaLines(link, e.link)
                if #lines > 0 then
                    t:AddLine(" ")
                    t:AddLine(("If %s equips the hovered item:"):format(MMT.FirstName(e.key)), 0.6, 0.6, 0.6)
                    for _, l in ipairs(lines) do
                        if l[2] then t:AddLine(l[1], 0.3, 1, 0.3) else t:AddLine(l[1], 1, 0.35, 0.35) end
                    end
                end
            end
        elseif e.state == "empty" then
            t:ClearLines()
            t:AddLine("Nothing equipped", 0.6, 0.6, 0.6)
        else
            t:ClearLines()
            t:AddLine("No item data yet", 0.6, 0.6, 0.6)
            t:AddLine("Log in this character with MMT once.", 0.5, 0.5, 0.5, true)
        end
        t.header.text:SetText(HeaderText(e, #slots > 1))
        t:Show()
        used = i
    end

    -- layout: rows of cfg.perRow next to the hovered tooltip, on the side with room
    local first = tips[1]
    local rowWidth = 0
    for i = 1, math.min(used, cfg.perRow) do rowWidth = rowWidth + tips[i]:GetWidth() + 6 end
    local screenRight = UIParent:GetRight() * UIParent:GetEffectiveScale()
    -- start beyond the game's "Equipped" comparison tooltips (ShoppingTooltip1/2),
    -- they sit next to GameTooltip too
    local gs = GameTooltip:GetEffectiveScale()
    local tipLeft, tipRight = (GameTooltip:GetLeft() or 0) * gs, (GameTooltip:GetRight() or 0) * gs
    local edgeLeft, edgeRight = tipLeft, tipRight
    for _, s in ipairs({ ShoppingTooltip1, ShoppingTooltip2 }) do
        if s and s:IsShown() and s:GetLeft() then
            local ss = s:GetEffectiveScale()
            local sl, sr = s:GetLeft() * ss, s:GetRight() * ss
            if sl >= tipRight - 4 then edgeRight = math.max(edgeRight, sr)
            elseif sr <= tipLeft + 4 then edgeLeft = math.min(edgeLeft, sl) end
        end
    end
    local toRight = edgeRight + rowWidth * first:GetEffectiveScale() <= screenRight
    local fs = first:GetEffectiveScale()

    local rowStart, rowHeight = 1, 0
    for i = 1, used do
        local t = tips[i]
        t:ClearAllPoints()
        local col = (i - 1) % cfg.perRow
        if i == 1 then
            if toRight then t:SetPoint("TOPLEFT", GameTooltip, "TOPRIGHT", (edgeRight - tipRight) / fs + 6, -20)
            else t:SetPoint("TOPRIGHT", GameTooltip, "TOPLEFT", (edgeLeft - tipLeft) / fs - 6, -20) end
        elseif col == 0 then
            t:SetPoint(toRight and "TOPLEFT" or "TOPRIGHT", tips[rowStart], toRight and "TOPLEFT" or "TOPRIGHT", 0, -(rowHeight + 26))
            rowStart, rowHeight = i, 0
        elseif toRight then
            t:SetPoint("TOPLEFT", tips[i - 1], "TOPRIGHT", 6, 0)
        else
            t:SetPoint("TOPRIGHT", tips[i - 1], "TOPLEFT", -6, 0)
        end
        rowHeight = math.max(rowHeight, t:GetHeight())
    end
end

local function Update()
    if not (active and M.enabled) then HideAll() return end
    local link = HoveredLink()
    if not link then HideAll() return end
    Render(link)
end
mod.Update = Update

---------------------------------------------------------------------------
-- Key binding (Bindings.xml calls this; keystate is "down" or "up")
---------------------------------------------------------------------------
function MMT_ItemCompareKey(keystate)
    if not (MMT.ready and M.enabled) then return end
    local cfg = M.db
    if cfg.mode == "TOGGLE" then
        if keystate == "down" then active = not active end
    else
        active = (keystate == "down")
    end
    M:Debug("key %s -> %s", tostring(keystate), tostring(active))
    Update()
end

function mod.Keys()
    local keys = { GetBindingKey(ACTION) }
    return keys
end

-- key = "ALT-C" etc. Returns ok, message
function mod.SetKey(key)
    if InCombatLockdown() then return false, "Key bindings can't be changed in combat." end
    for _, old in ipairs(mod.Keys()) do SetBinding(old) end
    local msg
    if key then
        local previous = GetBindingAction(key)
        if previous and previous ~= "" and previous ~= ACTION then
            msg = ("%s was bound to %s before."):format(GetBindingText(key), _G["BINDING_NAME_" .. previous] or previous)
        end
        SetBinding(key, ACTION)
    end
    SaveBindings(GetCurrentBindingSet())
    return true, msg
end

---------------------------------------------------------------------------
-- Follow the hovered item
---------------------------------------------------------------------------
local function OnItemTooltip(tooltip)
    if tooltip == GameTooltip and active then
        C_Timer.After(0, function()
            local link = HoveredLink()
            if link ~= shownLink then Update() end
        end)
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetItem", OnItemTooltip)
end
if GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnHide", function()
        C_Timer.After(0, function()
            if not GameTooltip:IsShown() then HideAll() end
        end)
    end)
end

-- the comparison tooltips can appear or move after we laid out -> lay out again
for _, s in ipairs({ ShoppingTooltip1, ShoppingTooltip2 }) do
    if s and s.HookScript then
        local function Relayout() if used > 0 then C_Timer.After(0, Update) end end
        s:HookScript("OnShow", Relayout)
        s:HookScript("OnHide", Relayout)
    end
end

-- item data arrives from the server -> redraw (tooltips fill in)
local redraw = false
M:On("GET_ITEM_INFO_RECEIVED", function()
    if used == 0 or redraw then return end
    redraw = true
    C_Timer.After(0.2, function() redraw = false; if shownLink then Update() end end)
end)
M:Listen("EQUIPMENT_CHANGED", function() if used > 0 then Update() end end)

---------------------------------------------------------------------------
-- Module on/off
---------------------------------------------------------------------------
M.OnEnable = function()
    C_Timer.After(2, function() if M.enabled then mod.UpdateOwn(false) end end)
end

M.OnDisable = function()
    active = false
    HideAll()
end
