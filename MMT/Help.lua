-- MMT: Help page (CORE section): debug tools with a how-to, and short
-- guides for writing modules and using the team communication.

local _, ns = ...
local UI = ns.UI
local A = UI.ACCENT
local H = ns.ConfigHelpers
local PAGE_W, COL_W, COL2_X = H.PAGE_W, H.COL_W, H.COL2_X

---------------------------------------------------------------------------
-- Texts
---------------------------------------------------------------------------
local DEBUG_STEPS = table.concat({
    "1. Tick \"Debug log\" (or type /mmt debug).",
    "2. Press \"Clear log\" so the report only shows the new problem.",
    "3. Do what goes wrong: add the team, open a trade, press the Item Compare key, ...",
    "4. For team problems press \"Ping team\" and wait 5 seconds.",
    "5. Press \"Debug report\", then Select all and Ctrl+C.",
    "6. Paste it to Claude. For team problems, do steps 1-5 on every client.",
}, "\n")

local DEBUG_COMMANDS = table.concat({
    "/mmt debug                debug log on/off",
    "/mmt debug dump           copyable report",
    "/mmt debug log | clear    show or clear the log",
    "/mmt debug chat           also print log lines to chat",
    "/mmt debug name <text>    how a typed name is understood",
    "/mmt ping                 test reaching every team member",
}, "\n")

local MODULE_TEXT = "A module is its own addon in Interface/AddOns, next to MMT. It shows up under MODULES and in the game's AddOns list. Copy the example below into a folder MMT_Example (two files), then restart the game completely, because new folders only show up after a restart."

local MODULE_CODE = [[
-- MMT_Example/MMT_Example.toc ------------------------------
## Interface: 16001
## Title: MMT - Example
## Notes: One line about the module.
## Version: 1.0.0
## Author: YourName
## X-Repository: https://github.com/you/your-repo
## Dependencies: MMT
## X-MMT-Module: 1
## X-MMT-Title: Example

Module.lua

-- MMT_Example/Module.lua -----------------------------------
local MMT = MMT
local M = MMT.NewModule({
    name = "Example",                 -- unique; also the settings key
    title = "Example",
    description = "One line for Manage modules.",
    defaults = { greeting = true },   -- per profile, read/write M.db
    sync = true,                      -- optional: share M.db with the team
    syncExclude = { "point" },        -- optional: keys that stay per client
})

-- M.db     settings in the active profile (defaults merged in)
-- M.store  account-wide data (e.g. a database), kept across profiles

M.OnEnable = function(self) end   -- switched on (also at login)
M.OnDisable = function(self) end  -- switched off: hide frames, stop timers

-- game events and core callbacks only run while the module is on
M:On("PLAYER_LEVEL_UP", function(level)
    if M.db.greeting then MMT.Print("Level %d!", level) end
end)
M:Listen("TEAM_CHANGED", function() M:Debug("team changed") end)

-- optional settings page (shown under MODULES)
M.Page = function(self, page)
    local col = MMT.UI.Column(page, 0, 0, MMT.ConfigHelpers.COL_W)
    col:Header("Example")
    col:Check("Greeting on level up",
        function() return M.db.greeting end,
        function(v) M.db.greeting = v end)
end

-- Settings sync (with sync = true): the core adds a "Sync to team"
-- button in the bottom right of M.Page and /mmt sync example. Only M.db
-- is sent (never M.store); the recipient accepts in a dialog. Optional:
M.OnSyncReceived = function(self, from)   -- after the team's settings
    MMT.Print("Example settings from %s applied.", from or "?")
end
-- For a frame of your own: M:SyncButton(frame), or M:SyncToTeam().

-- optional lines for /mmt debug dump
M.Report = function(self, add)
    add("Example: greeting=" .. tostring(M.db.greeting))
end

-- Names: internally, characters are always addressed by their full name
-- (team key "First-Last"; messages, whispers, invites, unit lookups), so
-- features find the right character. Everything the player SEES uses the
-- privacy setting (Team > Privacy: first name by default, last or full
-- name, "Druid 1", "Slot 2"): MMT.ShownName(key) (MMT.FirstName and
-- MMT.FullDisplay do the same) in frames, chat lines, tooltips, warnings.
-- Real names only where the game needs them, e.g. macros:
-- MMT.RealName(key), MMT.RealFirst(key), MMT.RealLast(key).
-- Mouseover: MMT.HoverMember(frame, function() return key end).

-- Useful core functions: MMT.Print, M:Debug, MMT.SortedMembers(),
-- MMT.IsOnline(key), MMT.IsSelf(key), MMT.PlayerFull(),
-- MMT.UI (widgets), MMT.Listen("PROFILE_CHANGED", fn)
]]

local COMM_TEXT = "Every client runs its own MMT. Everything is sent through one queue in the core, which keeps to the game's limits (about 10 messages per prefix, then 1 per second, on group and guild channels) and sends throttled messages again. Give important messages priority \"ALERT\", large ones \"BULK\" (default \"NORMAL\"). Long texts: MMT.SendLong splits them and the other side gets the whole text. Only messages from characters in this client's team are passed on. Keep single messages under 250 bytes and start them with your own tag. Leader tag (FTL): MMT.SendToLeader reaches only the FTL leader; scope \"FOLLOWERS\" reaches everybody but the leader. Each client checks against the leader it knows. MMT.SendAlert(msg) sends to the leader first, then to everybody else. Taken: XP, XP2, BYE, PING, PONG, SYNC, SYNCHI, SYNCACK, EQREQ, EQD, EQS, QNQ, QNA, LH, LHGO, LHC, QTREQ, QTS, QTD, QTAB, FOL, CC, TAXI, NOTE, MOUNT, DISMOUNT, DEATH, RELEASE, REVIVE, MPT, FTL, FTLM, and the tag prefixes @L: and @F:."

local COMM_CODE = [[
-- send to the whole team (true = only members that are online);
-- optional priority: "ALERT" (first) | "NORMAL" | "BULK" (last)
MMT.SendToTeam("EXPING:" .. GetMoney(), true, "ALERT")

-- send to one character, e.g. answer the sender of a message
MMT.SendAddon("EXPONG:ok", "WHISPER", sender)

-- a long text (any size): sent in parts, arrives in one piece
-- (to the team, or to one character as second argument)
MMT.SendLong("EXDATA:" .. MMT.Serialize(myTable))

-- only for the FTL leader (returns "self" and sends nothing when this
-- character IS the leader: handle it here then)
if MMT.SendToLeader("EXCOME:" .. GetZoneText()) == "self" then
    -- this character leads
end
-- everybody but the leader: scope as 5th argument of SendToTeam
-- (4th of SendLong); "LEADER" works there too
MMT.SendToTeam("EXWAIT", true, "NORMAL", nil, "FOLLOWERS")

-- receive: called for every team message the core doesn't handle itself
--   key    team key of the sender ("First-Last")
--   sender name as the game reported it (use it to whisper back)
--   scope  nil, "LEADER" or "FOLLOWERS" (the tag is already removed
--          and messages not meant for this client never arrive)
M:Listen("TEAM_MESSAGE", function(key, sender, text, scope)
    local money = text:match("^EXPING:(%d+)$")
    if money then
        MMT.Print("%s has %s", MMT.FullDisplay(key),
            MMT.FormatMoney(tonumber(money)))
    end
end)

-- small values can ride on the heartbeat (every 30 s and on changes):
-- no extra messages. Values must not contain ":" "," or "=".
M:Heartbeat("ex", function() return UnitLevel("player") end)
M:Listen("XP_RECEIVED", function(key, sender, status)
    local value = status.ext.ex       -- string, or nil
end)

-- what the core already shares, in MMT.status[key]:
--   level, cur, max, rested, class, isMax, layer, layerKey,
--   money, free, slots, durAvg, durMin, online, sender

-- longer data (more than 250 bytes): split it into numbered parts
-- ("EXD:<id>:<part>:<total>:<data>") and put them together on
-- arrival. MMT_ItemCompare/Equipment.lua (EQS) shows how.
]]

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------
-- read-only, selectable text box for code
local function CodeBox(parent, width, height, text)
    local area = UI.TextArea(parent, width, height)
    local e = area.edit
    e:SetFontObject("GameFontHighlightSmall")
    e:SetText(text)
    e:SetScript("OnTextChanged", function(self, userInput)
        if userInput then self:SetText(text) end
    end)
    return area
end

ns.RegisterPage("help", "Help", function(page)
    local panels, buttons = {}, {}
    local function Show(key)
        for k, p in pairs(panels) do p:SetShown(k == key) end
        for k, b in pairs(buttons) do
            if k == key then b.label:SetTextColor(A[1], A[2], A[3]) else b.label:SetTextColor(0.7, 0.7, 0.7) end
        end
    end

    local tabs = { { "debug", "Debugging" }, { "modules", "Writing modules" }, { "comm", "Team communication" } }
    for i, t in ipairs(tabs) do
        local b = UI.Button(page, 166, t[2], function() Show(t[1]) end)
        b:SetPoint("TOPLEFT", (i - 1) * 176, 0)
        buttons[t[1]] = b
        local p = CreateFrame("Frame", nil, page)
        p:SetPoint("TOPLEFT", 0, -30)
        p:SetSize(PAGE_W, page:GetHeight() - 30)
        panels[t[1]] = p
    end

    -- Debugging --------------------------------------------------------------
    local d = panels.debug
    local L = UI.Column(d, 0, 0, COL_W)
    L:Header("Debug tools")
    L:Check("Debug log", function() return MMTDB.debug end, function(v) MMTDB.debug = v end,
        "Logs what MMT detects and does. The log keeps the last 300 lines.")
    L:Check("Also print log lines to chat", function() return MMTDB.debugChat end,
        function(v) MMTDB.debugChat = v end)
    local R = UI.Column(d, COL2_X, -28, COL_W)
    local half = (COL_W - 8) / 2
    local report = UI.Button(d, half, "Debug report", function() ns.HandleDebugCommand("dump") end)
    R:Add(report, 0)
    local log = UI.Button(d, half, "Show log", function() ns.HandleDebugCommand("log") end)
    log:SetPoint("LEFT", report, "RIGHT", 8, 0)
    R:Space(UI.ROW + 2)
    local clear = UI.Button(d, half, "Clear log", function() ns.HandleDebugCommand("clear") end)
    R:Add(clear, 0)
    local ping = UI.Button(d, half, "Ping team", function() ns.Ping() end)
    ping:SetPoint("LEFT", clear, "RIGHT", 8, 0)
    UI.Tooltip(ping, "Ping team", "Whispers every team member with three spellings of the name and prints which one answered.")

    local col = UI.Column(d, 0, L.y - 8, PAGE_W)
    col:Header("How to report a problem")
    col:Note(DEBUG_STEPS)
    col:Header("Commands")
    col:Add(CodeBox(d, PAGE_W, 100, DEBUG_COMMANDS), 108)
    col:Note("The report contains your character names, team, layer, modules, the last addon messages and the log. Blocked game actions are logged too and announced in chat.")

    -- Writing modules ----------------------------------------------------------
    local m = panels.modules
    local mc = UI.Column(m, 0, 0, PAGE_W)
    mc:Header("Add a module")
    mc:Note(MODULE_TEXT)
    mc:Add(CodeBox(m, PAGE_W, 400, MODULE_CODE), 408)

    -- Team communication ---------------------------------------------------------
    local c = panels.comm
    local cc = UI.Column(c, 0, 0, PAGE_W)
    cc:Header("Talking to the other clients")
    cc:Note(COMM_TEXT)
    cc:Add(CodeBox(c, PAGE_W, 400, COMM_CODE), 408)

    Show("debug")
end)
