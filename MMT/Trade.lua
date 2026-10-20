-- MMT: when a trade opens with a team member, put every item that matches
-- that member's role rules into the trade window. Trades are never
-- accepted automatically. /mmt trade fills an open trade again.

local _, ns = ...

local GetNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local Pickup = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem

local tradeOpen = false
local token = 0

local function GetItem(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if not info then return end
        return info.itemID, info.hyperlink, info.quality, info.isLocked, info.isBound
    end
    local tex, _, locked, quality, _, _, link, _, _, itemID, isBound = GetContainerItemInfo(bag, slot)
    if not tex then return end
    return itemID, link, quality, locked, isBound
end

-- soulbound / quest items can't be traded; the tooltip is the reliable check
local scanTip
local function IsUntradeable(bag, slot)
    local ok, result = pcall(function()
        if not scanTip then
            scanTip = CreateFrame("GameTooltip", "MMTScanTooltip", nil, "GameTooltipTemplate")
        end
        scanTip:SetOwner(UIParent, "ANCHOR_NONE")
        scanTip:ClearLines()
        scanTip:SetBagItem(bag, slot)
        for i = 2, 7 do
            local fs = _G["MMTScanTooltipTextLeft" .. i]
            local text = fs and fs:GetText()
            if text and (text == ITEM_SOULBOUND or text == ITEM_BIND_QUEST) then return true end
        end
        return false
    end)
    return ok and result
end

local RuleMatches = function(...) return ns.RuleMatches(...) end

local function MatchesAny(rules, itemID, name, quality, classID, bindType, subClassID)
    for _, rule in ipairs(rules) do
        if RuleMatches(rule, itemID, name, quality, classID, bindType, subClassID) then return true end
    end
    return false
end

local function CollectItems(rules, passRules)
    local result = {}
    for bag = 0, ns.BAGS do
        for slot = 1, (GetNumSlots(bag) or 0) do
            local itemID, link, quality, locked, bound = GetItem(bag, slot)
            if itemID and not locked then
                if not bound then bound = IsUntradeable(bag, slot) end
                if not bound then
                    local name, _, q, _, _, _, _, _, _, _, _, classID, subClassID, bindType = ns.ItemInfo(link or itemID)
                    if not classID then _, classID, subClassID = ns.ItemCategory(link or itemID) end
                    quality = quality or q
                    if MatchesAny(rules, itemID, name, quality, classID, bindType, subClassID)
                        and not MatchesAny(passRules, itemID, name, quality, classID, bindType, subClassID) then
                        result[#result + 1] = { bag = bag, slot = slot, itemID = itemID }
                    end
                end
            end
        end
    end
    return result
end

-- Finds the trade partner in the team, trying every way the game exposes the name.
local function ResolvePartner()
    local n, r = ns.Safe(UnitFullName, "NPC")
    local frameName = TradeFrameRecipientNameText and TradeFrameRecipientNameText:GetText()
    ns.Debug("TRADE partner: UnitFullName(npc)=%s / %s UnitName(npc)=%s frameText=%s",
        ns.Repr(n), ns.Repr(r), ns.Repr((ns.Safe(UnitName, "NPC"))), ns.Repr(frameName))
    local candidates = {}
    if n then
        candidates[#candidates + 1] = r and (n .. "-" .. r) or n
        candidates[#candidates + 1] = n
    end
    if frameName and frameName ~= "" and not ns.IsSecret(frameName) then candidates[#candidates + 1] = frameName end
    for _, c in ipairs(candidates) do
        local key = ns.Resolve(c)
        if key then
            ns.Debug("TRADE partner resolved via %s -> team key %s", ns.Repr(c), ns.Repr(key))
            return key
        end
    end
end

function ns.FillTrade(force)
    if not ns.db or not tradeOpen then
        if force then ns.Print("Open a trade with a team member first.") end
        return
    end
    if not ns.db.trade.enabled and not force then return end

    local partner = ResolvePartner()
    local member = partner and ns.db.team[partner]
    if not member then
        ns.Debug("TRADE partner is not a team member -> nothing to do")
        return
    end

    local rules, passRules, roleNames = {}, {}, {}
    for _, role in ipairs(ns.MemberRoleList(partner)) do
        local target = (ns.RoleRoll(role) == "PASS") and passRules or rules
        if target == rules then roleNames[#roleNames + 1] = role end
        for _, rule in ipairs(ns.db.roles[role].rules) do target[#target + 1] = rule end
    end
    ns.Debug("TRADE roles: %s rules: %d", table.concat(roleNames, ","), #rules)
    if #rules == 0 then return end

    local items = CollectItems(rules, passRules)
    ns.Debug("TRADE matching stacks in bags: %d", #items)
    if #items == 0 then return end

    local limit = MAX_TRADABLE_ITEMS or 6
    local free = {}
    for s = 1, limit do
        if not GetTradePlayerItemLink(s) then free[#free + 1] = s end
    end
    local count = math.min(#items, #free)
    if count == 0 then return end

    token = token + 1
    local mine = token
    for i = 1, count do
        C_Timer.After(0.3 * (i - 1) + 0.1, function()
            if mine ~= token or not tradeOpen then return end
            local it = items[i]
            ClearCursor()
            Pickup(it.bag, it.slot)
            if CursorHasItem() then ClickTradeButton(free[i]) end
            if CursorHasItem() then ClearCursor() end
        end)
    end

    ns.Print("%d stack(s) put into the trade with %s (%s).", count, ns.FullDisplay(partner), table.concat(roleNames, ", "))
    if #items > count then
        ns.Print("%d more stack(s) did not fit. Trade again to hand over the rest.", #items - count)
    end
end

ns.On("TRADE_SHOW", function()
    tradeOpen = true
    ns.FillTrade(false)
end)

ns.On("TRADE_CLOSED", function()
    tradeOpen = false
    token = token + 1
end)
