-- MMT Item Bar: settings page (under MODULES in /mmt).

local _, mod = ...
local MMT = MMT
local M = mod.M
local UI = MMT.UI
local H = MMT.ConfigHelpers
local COL_W, COL2_X = H.COL_W, H.COL2_X

local function Opt(key)
    return function() return M.db[key] end,
           function(v) M.db[key] = v; mod.Update() end
end

M.Page = function(_, page)
    local L = UI.Column(page, 0, 0, COL_W)
    L:Header("Item Bar")
    L:Note("Item slots that are the same on every team member. Drop an item from your bags on a slot: it appears there on every character, also on those that don't have it.")
    local gl, sl = Opt("layout")
    L:Cycle("Layout", {
        { value = "H", text = "Horizontal" },
        { value = "V", text = "Vertical" },
    }, gl, sl)
    local gn, sn = Opt("slots")
    L:Slider("Number of slots", 2, mod.MAX_SLOTS, 1, gn, sn)
    local gs, ss = Opt("scale")
    L:Slider("Scale", 0.8, 2, 0.05, gs, ss, "%.2f")
    local gr, sr = Opt("showRefresh")
    L:Check("Show refresh button", gr, sr, "Sends this bar to every team member and asks for their counts.")
    local gc, sc = Opt("showClear")
    L:Check("Show clear button", gc, sc, "Removes every item from the bar, on every team member (asks first).")
    local gg, sg = Opt("guildBank")
    L:Check("Guild bank in the tooltip", gg, sg, "Adds the guild bank count. It is counted whenever a team member opens the guild bank.")
    local glk, slk = Opt("locked")
    L:Check("Lock position", glk, slk, "Unlocked, Shift + drag moves the bar.")
    L:Button("Reset position", function() mod.ResetPosition() end)

    local R = UI.Column(page, COL2_X, 0, COL_W)
    R:Header("Mouse")
    R:Note("Drop an item on a slot: it is added on every character.\nLeft-click: use the item on this character.\nRight-click: use it here and on the team.\nCtrl-click: remove it from every character.\nShift + drag: move the bar.\nShift-right-click: these settings.\nTooltip: every character's count in bags and bank.")
    R:Header("Using items on the team")
    R:Note("WoW lets an addon use an item only where you click or press a key. On the other characters, right-click opens or equips items that need no key press (bags, clams, equipment). Items with a spell (potions, food, quest items) light up there instead.")
    R:Note("For those: Esc > Options > Keybindings > AddOns > \"MMT - Item Bar\" has a key per slot. With key broadcasting, one key press uses the item on every character.")
end
