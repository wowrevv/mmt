-- MMT module: Item Bar (after EMA's item bar).
--
-- A small bar of item slots that is the same on every team member. Drop an
-- item from your bags on a slot and it appears in that slot on every
-- character, also on those that don't have the item; Ctrl-click or "Clear"
-- removes it everywhere. The tooltip lists every character's count in bags
-- and bank (and the guild bank, option).
--
-- Using items: WoW lets an addon use an item only on the client where you
-- click or press a key. So
--   * left click: uses the item here,
--   * right click: uses it here and asks the team: on the others MMT opens
--     or equips it if that needs no key press (containers, equipment); items
--     with a spell (potions, food, quest items) can't be used from a message,
--     their slot lights up there instead,
--   * key bindings per slot (Esc > Options > Keybindings > AddOns): with key
--     broadcasting, one key press uses the item on every client.
--
-- Messages:
--   IBS:<slot>:<itemID>      slot set (0 = empty)
--   IBA:<n>:<id,id,...>      the whole bar (refresh button; empty list = clear)
--   IBU:<slot>:<itemID>      right click: use it too
--   IBC:<id>,<bags>,<bank>,<guild bank>;...   this character's counts
--                                          (guild bank -1 = not seen)

local _, mod = ...
local MMT = MMT

local M = MMT.NewModule({
    name = "ItemBar",
    title = "Item Bar",
    description = "Item slots shared by the whole team, with each character's count in bags and bank.",
    sync = true,
    syncExclude = { "point", "items" },
    defaults = {
        slots       = 4,          -- 2 .. 8
        layout      = "H",        -- H horizontal | V vertical
        scale       = 1,          -- 0.8 .. 2
        showRefresh = true,
        showClear   = true,
        guildBank   = false,      -- guild bank count in the tooltip
        locked      = false,
        items       = {},         -- [slot] = itemID
        point       = { "CENTER", "CENTER", 0, -220 },
    },
})
mod.M = M
mod.MAX_SLOTS = 8

mod.counts = {}     -- [teamKey] = { [itemID] = { bags, bank, gbank } }
mod.flash = {}      -- [slot] = GetTime() until which the slot lights up

local function Send(msg, prio) MMT.SendToTeam(msg, true, prio or "NORMAL") end

---------------------------------------------------------------------------
-- Bar contents
---------------------------------------------------------------------------
function mod.Items()
    M.db.items = M.db.items or {}
    return M.db.items
end

-- set a slot here (fromTeam: don't send it on)
function mod.SetSlot(slot, itemID, fromTeam)
    if slot < 1 or slot > mod.MAX_SLOTS then return end
    itemID = (itemID and itemID > 0) and itemID or nil
    mod.Items()[slot] = itemID
    if not fromTeam then Send(("IBS:%d:%d"):format(slot, itemID or 0)) end
    if itemID and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    mod.SendCountsSoon()
    if mod.Update then mod.Update() end
end

function mod.ClearAll(fromTeam)
    wipe(mod.Items())
    if not fromTeam then Send("IBA:0:") end
    if mod.Update then mod.Update() end
end

-- the refresh button: this bar to everyone, and everyone's counts back
function mod.SendBar()
    local ids = {}
    for slot = 1, mod.MAX_SLOTS do ids[slot] = tostring(mod.Items()[slot] or 0) end
    Send(("IBA:%d:%s"):format(mod.MAX_SLOTS, table.concat(ids, ",")))
    mod.SendCounts()
end

M:Listen("TEAM_MESSAGE", function(key, sender, text)
    local slot, id = text:match("^IBS:(%d+):(%d+)$")
    if slot then mod.SetSlot(tonumber(slot), tonumber(id), true) return end

    local n, list = text:match("^IBA:(%d+):(.*)$")
    if n then
        if list == "" then mod.ClearAll(true) return end
        local slotIndex = 0
        for value in (list .. ","):gmatch("(%d*),") do
            slotIndex = slotIndex + 1
            local v = tonumber(value)
            mod.Items()[slotIndex] = (v and v > 0) and v or nil
        end
        if mod.Update then mod.Update() end
        mod.SendCountsSoon()
        return
    end

    local uslot, uid = text:match("^IBU:(%d+):(%d+)$")
    if uslot then mod.UseFromTeam(tonumber(uslot), tonumber(uid), key) return end

    local counts = text:match("^IBC:(.*)$")
    if counts then
        local t = {}
        for id, bags, bank, gbank in counts:gmatch("(%d+),(%d+),(%d+),(%-?%d+)") do
            t[tonumber(id)] = { tonumber(bags), tonumber(bank), tonumber(gbank) }
        end
        mod.counts[key] = t
    end
end)

---------------------------------------------------------------------------
-- Counts: bags, bank, guild bank
---------------------------------------------------------------------------
local guildBank = {}   -- [itemID] = count, from the last look into the guild bank

local function Count(id, includeBank)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id, includeBank) or 0 end
    return GetItemCount and GetItemCount(id, includeBank) or 0
end

-- this character: bags, bank, guild bank (-1 = not seen)
function mod.OwnCount(id)
    local bags = Count(id, false)
    local total = Count(id, true)
    return bags, math.max(0, total - bags), guildBank[id] or -1
end

function mod.SendCounts()
    local parts = {}
    for slot = 1, mod.MAX_SLOTS do
        local id = mod.Items()[slot]
        if id then
            local b, k, g = mod.OwnCount(id)
            parts[#parts + 1] = ("%d,%d,%d,%d"):format(id, b, k, g)
        end
    end
    local me = MMT.PlayerFull()
    if me then
        mod.counts[me] = {}
        for slot = 1, mod.MAX_SLOTS do
            local id = mod.Items()[slot]
            if id then mod.counts[me][id] = { mod.OwnCount(id) } end
        end
    end
    if #parts > 0 then Send("IBC:" .. table.concat(parts, ";"), "BULK") end
end

local countsPending = false
function mod.SendCountsSoon()
    if countsPending then return end
    countsPending = true
    C_Timer.After(2, function()
        countsPending = false
        if M.enabled then mod.SendCounts() end
    end)
end

M:On("BAG_UPDATE_DELAYED", function() mod.SendCountsSoon() if mod.Update then mod.Update() end end)
M:On("PLAYERBANKSLOTS_CHANGED", mod.SendCountsSoon)
M:On("BANKFRAME_CLOSED", mod.SendCountsSoon)

-- guild bank: counted whenever it is open (only tabs the game has sent)
local function ScanGuildBank()
    if not (GetNumGuildBankTabs and GetGuildBankItemLink) then return end
    local wanted = {}
    for slot = 1, mod.MAX_SLOTS do local id = mod.Items()[slot] if id then wanted[id] = 0 end end
    if not next(wanted) then return end
    for tab = 1, (GetNumGuildBankTabs() or 0) do
        for slot = 1, (MAX_GUILDBANK_SLOTS_PER_TAB or 98) do
            local link = GetGuildBankItemLink(tab, slot)
            local id = link and tonumber(link:match("item:(%d+)"))
            if id and wanted[id] then
                local _, count = GetGuildBankItemInfo(tab, slot)
                wanted[id] = wanted[id] + (count or 1)
            end
        end
    end
    for id, n in pairs(wanted) do guildBank[id] = n end
    mod.SendCountsSoon()
end
M:On("GUILDBANKBAGSLOTS_CHANGED", function() C_Timer.After(0.5, ScanGuildBank) end)

---------------------------------------------------------------------------
-- Right click on another client: use it too (where the game allows it)
---------------------------------------------------------------------------
local function FindInBags(id)
    for bag = 0, (MMT.BAGS or NUM_BAG_SLOTS or 4) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if C_Container.GetContainerItemID(bag, slot) == id then return bag, slot end
        end
    end
end

function mod.UseFromTeam(slot, id, fromKey)
    if not M.enabled or not id then return end
    if Count(id, false) == 0 then return end
    local hasSpell = GetItemSpell and GetItemSpell(id)
    if hasSpell or InCombatLockdown() then
        -- an item with a spell needs a key press or click on this client
        mod.flash[slot] = GetTime() + 4
        if mod.Update then mod.Update() end
        return
    end
    local bag, bagSlot = FindInBags(id)
    if bag then
        local ok, err = pcall(C_Container.UseContainerItem, bag, bagSlot)
        M:Debug("used %s for %s -> %s %s", tostring(id), MMT.Repr(fromKey), tostring(ok), tostring(err or ""))
    end
end

M.OnEnable = function()
    if mod.Update then mod.Update() end
    C_Timer.After(3, mod.SendCounts)
end
M.OnDisable = function() if mod.Hide then mod.Hide() end end
M.OnProfileChanged = function() if mod.Update then mod.Update() end end
M.OnSyncReceived = function() if mod.Update then mod.Update() end end

M.Report = function(_, add)
    local ids = {}
    for slot = 1, mod.MAX_SLOTS do ids[#ids + 1] = tostring(mod.Items()[slot] or "-") end
    add(("-- Item Bar 1.0.2  slots=%d layout=%s scale=%s items=[%s]"):format(M.db.slots, M.db.layout,
        tostring(M.db.scale), table.concat(ids, ",")))
    for key, t in pairs(mod.counts) do
        local parts = {}
        for id, c in pairs(t) do parts[#parts + 1] = ("%d=%d/%d/%d"):format(id, c[1], c[2], c[3]) end
        add(("  counts %s: %s"):format(MMT.Repr(key), table.concat(parts, " ")))
    end
end
