-- MMT: mailbox and guild bank (Trade / Mail / Vendor page; as in EMA's Mail
-- and Guild modules, but with MMT's roles).
--
-- Mailbox: a "Mail to team" button next to the mail window sends every item
-- in your bags that another team member's role wants to that member (team
-- order, as for trades; items your own role wants stay), up to 12 items per
-- mail. Optionally the gold above an amount goes to one team member. The
-- button is needed: one click sends all mails one after another.
--
-- Guild bank: a "Deposit" button next to the guild bank puts the items of
-- the chosen role (list) into the chosen tab, and optionally the gold above
-- an amount.

local _, ns = ...
local UI = ns.UI

local MAX_ATTACH = ATTACHMENTS_MAX_SEND or 12
local STEP = 0.25

local function Safe(fn, ...) if fn then return ns.Safe(fn, ...) end end

-- every bag item: bag, slot, link, info
local function BagItems()
    local list = {}
    for bag = 0, ns.BAGS do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.hyperlink and not info.isLocked then
                list[#list + 1] = { bag = bag, slot = slot, link = info.hyperlink, info = info }
            end
        end
    end
    return list
end

-- a small button beside a Blizzard window (the window itself is not changed)
local function SideButton(name, text, onClick)
    local b = UI.Button(UIParent, 150, text, onClick)
    b:SetFrameStrata("HIGH")
    b:Hide()
    b.Place = function(anchor)
        b:ClearAllPoints()
        if anchor and anchor:IsShown() then b:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, -30)
        else b:SetPoint("TOP", UIParent, "TOP", 0, -120) end
        b:Show()
    end
    return b
end

local function InteractionType(name)
    return Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType[name]
end

---------------------------------------------------------------------------
-- Mail
---------------------------------------------------------------------------
local mailOpen = false
local queue        -- mails still to send: { { to, key, items = {...}, money } }
local sending = false

-- the team member to mail an item to (nil: keep it)
local function Recipient(link)
    local keys = ns.MembersForItem(link)
    for _, key in ipairs(keys) do
        if ns.IsSelf(key) then return nil end   -- your own role wants it: keep
        return key
    end
end

local function PlanMail()
    local cfg = ns.db.mail
    local byKey, order = {}, {}
    for _, it in ipairs(BagItems()) do
        local key = (not it.info.isBound) and Recipient(it.link)
        if key then
            if not byKey[key] then byKey[key] = {}; order[#order + 1] = key end
            table.insert(byKey[key], it)
        end
    end
    local mails = {}
    for _, key in ipairs(order) do
        local items = byKey[key]
        for i = 1, #items, MAX_ATTACH do
            local chunk = {}
            for j = i, math.min(i + MAX_ATTACH - 1, #items) do chunk[#chunk + 1] = items[j] end
            mails[#mails + 1] = { key = key, to = ns.WhisperTarget(key), items = chunk }
        end
    end
    -- gold above the amount to keep
    local goldKey = cfg.goldTo ~= "" and ns.db.team[cfg.goldTo] and cfg.goldTo or nil
    if goldKey and not ns.IsSelf(goldKey) then
        local spare = GetMoney() - (cfg.keepGold or 0) * 10000 - 30 * (#mails + 1)
        if spare > 0 then mails[#mails + 1] = { key = goldKey, to = ns.WhisperTarget(goldKey), items = {}, money = spare } end
    end
    return mails
end

local function SendNext()
    if not mailOpen or not queue or #queue == 0 then
        if queue and #queue == 0 then ns.Print("Mail to team: done.") end
        queue, sending = nil, false
        return
    end
    local mail = table.remove(queue, 1)
    sending = true
    local n = 0
    for _, it in ipairs(mail.items) do
        local info = C_Container.GetContainerItemInfo(it.bag, it.slot)
        if info and info.hyperlink == it.link then
            n = n + 1
            ClearCursor()
            C_Container.PickupContainerItem(it.bag, it.slot)
            ClickSendMailItemButton(n)
        end
    end
    if mail.money then SetSendMailMoney(mail.money) end
    if n == 0 and not mail.money then sending = false C_Timer.After(STEP, SendNext) return end
    local subject = mail.money and "MMT: gold" or ("MMT: " .. n .. (n == 1 and " item" or " items"))
    local ok, err = pcall(SendMail, mail.to, subject, "")
    ns.Debug("mail: %s -> %s (%d items, %s copper) %s %s", subject, ns.Repr(mail.to), n, tostring(mail.money or 0), tostring(ok), tostring(err or ""))
    if ok then
        ns.Print("Mailing %s to %s.", mail.money and ns.FormatMoney(mail.money) or (n .. (n == 1 and " item" or " items")), ns.ShownName(mail.key))
    else
        sending = false
    end
end

ns.On("MAIL_SEND_SUCCESS", function() if sending then sending = false C_Timer.After(0.5, SendNext) end end)
ns.On("MAIL_FAILED", function()
    if sending then
        sending = false
        ns.Print("|cffff6666A mail could not be sent; stopped.|r")
        queue = nil
        ClearSendMail()
    end
end)

local mailButton = SideButton("MMTMailButton", "Mail to team", function()
    if queue then return end
    queue = PlanMail()
    if #queue == 0 then
        ns.Print("Mail to team: nothing to send (no items another team member's role wants).")
        queue = nil
        return
    end
    SendNext()
end)
UI.Tooltip(mailButton, "Mail to team", "Sends every item in your bags that another team member's role wants to that member (items your own role wants stay), and the gold above the amount to keep if set. Trade / Mail / Vendor page.")

local function MailShown()
    mailOpen = true
    if ns.db.mail.enabled then mailButton.Place(_G.MailFrame) end
end
local function MailHidden()
    mailOpen, queue, sending = false, nil, false
    mailButton:Hide()
end
ns.On("MAIL_SHOW", MailShown)
ns.On("MAIL_CLOSED", MailHidden)

---------------------------------------------------------------------------
-- Guild bank
---------------------------------------------------------------------------
local bankOpen = false

local function DepositAll()
    local cfg = ns.db.gbank
    local role = cfg.role ~= "" and ns.db.roles[cfg.role] and cfg.role or nil
    local items = {}
    if role then
        for _, it in ipairs(BagItems()) do
            if not it.info.isBound and ns.RoleWantsItem(role, it.link) then items[#items + 1] = it end
        end
    end
    if SetCurrentGuildBankTab then pcall(SetCurrentGuildBankTab, cfg.tab or 1) end
    local i = 0
    local function Next()
        i = i + 1
        local it = items[i]
        if not it or not bankOpen then
            if cfg.gold and bankOpen and DepositGuildBankMoney then
                local spare = GetMoney() - (cfg.keepGold or 0) * 10000
                if spare > 0 then
                    pcall(DepositGuildBankMoney, spare)
                    ns.Print("Deposited %s into the guild bank.", ns.FormatMoney(spare))
                end
            end
            if #items > 0 then ns.Print("Deposited %d %s into guild bank tab %d.", #items, #items == 1 and "item" or "items", cfg.tab or 1) end
            return
        end
        local info = C_Container.GetContainerItemInfo(it.bag, it.slot)
        if info and info.hyperlink == it.link then C_Container.UseContainerItem(it.bag, it.slot) end
        C_Timer.After(STEP, Next)
    end
    if #items == 0 and not cfg.gold then
        ns.Print("Guild bank: nothing to deposit (choose a role on the Trade / Mail / Vendor page).")
        return
    end
    Next()
end

local bankButton = SideButton("MMTGuildBankButton", "Deposit to guild bank", DepositAll)
UI.Tooltip(bankButton, "Deposit to guild bank", "Puts the items of the chosen role into the chosen tab, and the gold above the amount to keep if set. Trade / Mail / Vendor page.")

local function BankShown()
    bankOpen = true
    if ns.db.gbank.enabled then C_Timer.After(0.2, function() if bankOpen then bankButton.Place(_G.GuildBankFrame) end end) end
end
local function BankHidden()
    bankOpen = false
    bankButton:Hide()
end
ns.On("GUILDBANKFRAME_OPENED", BankShown)
ns.On("GUILDBANKFRAME_CLOSED", BankHidden)

-- retail: frames opened by NPC interaction
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)
    if kind == InteractionType("GuildBanker") then BankShown()
    elseif kind == InteractionType("MailInfo") then MailShown() end
end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind)
    if kind == InteractionType("GuildBanker") then BankHidden()
    elseif kind == InteractionType("MailInfo") then MailHidden() end
end)
