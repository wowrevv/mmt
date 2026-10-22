-- MMT Quest Tracker: marks on the quest reward choices (as in MBAssist).
--   * a coin on the reward that sells for the most gold,
--   * a green arrow on every reward that is an upgrade for this character:
--     equippable by it (no red text in the tooltip) and of a higher item
--     level than what it wears in that slot (or the slot is empty).
-- The marks are small MMT frames placed on top of Blizzard's reward buttons;
-- Blizzard's buttons are not changed. Choosing stays manual.

local _, mod = ...
local MMT = MMT
local M = mod.M

-- equipment slots an item type goes into
local SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 },
    INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}

local function ItemLevel(item)
    if GetDetailedItemLevelInfo then
        local lvl = GetDetailedItemLevelInfo(item)
        if lvl then return lvl end
    end
    local _, _, _, lvl = MMT.ItemInfo(item)
    return lvl
end

-- the game shows requirements this character doesn't meet in red
local function Usable(link)
    if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return true end
    local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
    if not ok or not data then return true end
    local function Red(c) return c and c.r and c.r > 0.95 and c.g < 0.2 and c.b < 0.2 end
    for _, line in ipairs(data.lines or {}) do
        if Red(line.leftColor) or Red(line.rightColor) then return false end
    end
    return true
end

-- is the item an upgrade for this character? (nil = can't tell yet)
function mod.IsUpgrade(link)
    local _, _, _, _, _, _, _, _, equipLoc = MMT.ItemInfo(link)
    if equipLoc == nil then return nil end
    local slots = SLOTS[equipLoc]
    if not slots or not Usable(link) then return false end
    local level = ItemLevel(link)
    if not level then return nil end
    local lowest
    for _, slot in ipairs(slots) do
        local worn = GetInventoryItemLink("player", slot)
        local wornLevel = worn and ItemLevel(worn) or 0
        if not lowest or wornLevel < lowest then lowest = wornLevel end
    end
    return level > (lowest or 0)
end

---------------------------------------------------------------------------
-- Marks on the reward buttons
---------------------------------------------------------------------------
local marks = {}   -- [i] = frame with .coin and .arrow

local function Mark(i)
    local m = marks[i]
    if m then return m end
    m = CreateFrame("Frame", nil, UIParent)
    m:SetSize(16, 16)
    m:EnableMouse(false)
    m.coin = m:CreateTexture(nil, "OVERLAY")
    m.coin:SetSize(14, 14)
    m.coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
    m.arrow = m:CreateTexture(nil, "OVERLAY")
    m.arrow:SetSize(16, 16)
    if m.arrow.SetAtlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("bags-greenarrow") then
        m.arrow:SetAtlas("bags-greenarrow")
    else
        m.arrow:SetTexture("Interface\\Buttons\\UI-MicroStream-Green")
    end
    marks[i] = m
    return m
end

local function HideMarks()
    for _, m in pairs(marks) do m:Hide() end
end

-- reward choice buttons by choice index
local function ChoiceButtons(n)
    local list = {}
    local rewards = (_G.QuestInfoFrame and _G.QuestInfoFrame.rewardsFrame) or _G.QuestInfoRewardsFrame
    if rewards and rewards.RewardButtons then
        for _, b in ipairs(rewards.RewardButtons) do
            if b:IsVisible() and b.type == "choice" and b.GetID then list[b:GetID()] = b end
        end
    end
    if not next(list) then
        for i = 1, n do
            local b = _G["QuestInfoRewardsFrameQuestInfoItem" .. i]
            if b and b:IsVisible() then list[i] = b end
        end
    end
    return list
end

function mod.MarkRewards()
    HideMarks()
    if not (M.enabled and M.db.markRewards) then return end
    local n = GetNumQuestChoices and GetNumQuestChoices() or 0
    if n < 1 then return end
    local buttons = ChoiceButtons(n)
    local best, bestValue, retry = nil, 0, false
    local upgrades = {}
    for i = 1, n do
        local link = GetQuestItemLink("choice", i)
        if link then
            local _, _, count = GetQuestItemInfo("choice", i)
            local price = select(11, MMT.ItemInfo(link))
            if price == nil then retry = true end
            local value = (price or 0) * math.max(1, count or 1)
            if value > bestValue then best, bestValue = i, value end
            local up = mod.IsUpgrade(link)
            if up == nil then retry = true end
            upgrades[i] = up
        else
            retry = true
        end
    end
    for i = 1, n do
        local b = buttons[i]
        if b then
            local m = Mark(i)
            local icon = b.Icon or b.icon or _G[(b:GetName() or "") .. "IconTexture"] or b
            m:ClearAllPoints()
            m:SetPoint("TOPLEFT", icon, "TOPLEFT", -2, 2)
            m:SetSize(40, 40)
            m:SetFrameStrata(b:GetFrameStrata())
            m:SetFrameLevel(b:GetFrameLevel() + 5)
            m.coin:ClearAllPoints()
            m.coin:SetPoint("TOPRIGHT", m, "TOPRIGHT", 2, 0)
            m.arrow:ClearAllPoints()
            m.arrow:SetPoint("TOPLEFT", m, "TOPLEFT", 0, 0)
            m.coin:SetShown(n > 1 and i == best)
            m.arrow:SetShown(upgrades[i] == true)
            m:SetShown(m.coin:IsShown() or m.arrow:IsShown())
        end
    end
    -- item data not loaded yet: look again in a moment
    if retry and (mod.rewardRetries or 0) < 5 then
        mod.rewardRetries = (mod.rewardRetries or 0) + 1
        C_Timer.After(0.3, mod.MarkRewards)
    end
end

local function Soon()
    mod.rewardRetries = 0
    C_Timer.After(0.05, mod.MarkRewards)
end

M:On("QUEST_COMPLETE", Soon)
M:On("QUEST_FINISHED", HideMarks)
M:On("QUEST_DETAIL", Soon)   -- the rewards are shown before accepting too
M:On("GOSSIP_SHOW", HideMarks)
M:On("GET_ITEM_INFO_RECEIVED", function()
    if _G.QuestFrame and _G.QuestFrame:IsShown() then mod.MarkRewards() end
end)
