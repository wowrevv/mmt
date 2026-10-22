-- MMT: gossip goes straight to the vendor pane or the flight map, and
-- dialog-only NPCs are clicked through (options that only advance the
-- conversation).
--
-- Quest automation (accept, turn in, announce, share) lives in the Quest
-- Tracker module (MMT_QuestTracker). It adds a gossip handler that runs
-- first: when a handler picks a quest, the vendor step is skipped.

local _, ns = ...

local gossipHandlers = {}

-- fn() returns true when it handled the gossip window (e.g. picked a quest)
function ns.AddGossipHandler(fn)
    gossipHandlers[#gossipHandlers + 1] = fn
end

local VENDOR_ICON = 132060 -- Interface\GossipFrame\VendorGossipIcon
local CHAT_ICON = 132053   -- Interface\GossipFrame\GossipGossipIcon (plain dialog line)
local TAXI_ICON = 132057   -- Interface\GossipFrame\TaxiGossipIcon (flight master)

-- the flight master's "I need a ride" line (icon, or the usual texts)
local TAXI_TEXTS = { "i need a ride", "show me where i can fly", "i'd like to fly", "where can i fly" }
local function IsTaxiOption(opt)
    if opt.icon == TAXI_ICON or opt.type == "taxi" then return true end
    local name = opt.name
    if type(name) ~= "string" or ns.IsSecret(name) then return false end
    name = name:lower()
    for _, t in ipairs(TAXI_TEXTS) do
        if name:find(t, 1, true) then return true end
    end
    return false
end

-- Dialog options are only picked when the text has none of these words:
-- they can cost gold, change the character or start something big.
local UNSAFE = { "reset", "unlearn", "forget", "talent", "teleport", "port me", "flight", "taxi",
    "bind", "hearth", "train", "buy", "purchase", "pay", "gold", "silver", "copper", "cost",
    "bank", "guild", "tabard", "arena", "battle", "duel", "fight", "challenge", "attack", "begin",
    "start the", "ready", "skip", "abandon", "leave", "exit", "decline", "no thanks", "goodbye",
    "nevermind", "never mind", "deposit", "stable", "mount", "transmog", "barber" }

local function IsVendorOption(opt)
    if opt.icon == VENDOR_ICON then return true end
    local name = opt.name
    if type(name) == "string" and not ns.IsSecret(name) then
        name = name:lower()
        return name:find("browse your goods", 1, true) ~= nil
    end
    return false
end

---------------------------------------------------------------------------
-- Dialog-only NPCs: pick the next plain dialog line
---------------------------------------------------------------------------
local picked = {}      -- option IDs chosen in this conversation (no loops)
local pickCount = 0
local MAX_PICKS = 8

local function IsDialogOption(opt)
    if opt.icon ~= CHAT_ICON and opt.type ~= "gossip" then return false end
    if opt.spellID or (opt.status and opt.status ~= 0) then return false end -- spell casts, locked lines
    local name = opt.name
    if type(name) ~= "string" or ns.IsSecret(name) or name == "" then return false end
    local text = name:lower()
    for _, word in ipairs(UNSAFE) do
        if text:find(word, 1, true) then return false end
    end
    return true
end

local function HasQuests()
    return #(C_GossipInfo.GetActiveQuests() or {}) > 0 or #(C_GossipInfo.GetAvailableQuests() or {}) > 0
end

-- returns true if a dialog line was picked
local function AdvanceDialog(options)
    if not ns.db.gossip.dialog or HasQuests() or pickCount >= MAX_PICKS then return false end
    for _, opt in ipairs(options) do
        -- an NPC with anything but plain dialog lines (vendor, trainer, flights, ...) stays manual
        if not IsDialogOption(opt) then
            ns.Debug("Gossip dialog: left manual (option %s, icon %s)", tostring(opt.name), tostring(opt.icon))
            return false
        end
    end
    for _, opt in ipairs(options) do
        local id = opt.gossipOptionID or opt.orderIndex
        if id and not picked[id] then
            picked[id] = true
            pickCount = pickCount + 1
            ns.Debug("Gossip dialog: picking %s (id %s)", tostring(opt.name), tostring(id))
            C_GossipInfo.SelectOption(id)
            return true
        end
    end
    return false
end

ns.On("GOSSIP_CLOSED", function() wipe(picked) pickCount = 0 end)

ns.On("GOSSIP_SHOW", function()
    if ns.IsBypassed() then ns.Debug("Shift held: gossip left manual") return end
    for _, fn in ipairs(gossipHandlers) do
        local ok, handled = pcall(fn)
        if not ok then ns.Debug("gossip handler error: %s", tostring(handled)) end
        if ok and handled then return end
    end

    local options = C_GossipInfo.GetOptions() or {}
    for _, opt in ipairs(options) do
        ns.Debug("Gossip option: %s (icon %s, id %s)", tostring(opt.name), tostring(opt.icon), tostring(opt.gossipOptionID))
    end
    if ns.db.gossip.taxi then
        for _, opt in ipairs(options) do
            if IsTaxiOption(opt) then
                ns.Debug("Gossip: flight master, opening the flight map")
                C_GossipInfo.SelectOption(opt.gossipOptionID)
                return
            end
        end
    end
    if ns.db.gossip.vendor then
        for _, opt in ipairs(options) do
            if IsVendorOption(opt) then
                C_GossipInfo.SelectOption(opt.gossipOptionID)
                return
            end
        end
    end
    if #options > 0 then AdvanceDialog(options) end
end)
