-- MMT - Manage My Team
-- Core: events, callbacks, chat output, debug log, names and helpers.

local ADDON, ns = ...
_G.MMT = ns
ns.title = "MMT"
ns.version = "0.9.17"
ns.prefix = "MMT"
ns.LOGO = "Interface\\AddOns\\MMT\\Media\\Logo"   -- the MMT mark (Media/Logo.tga)
ns.ICON = "Interface\\AddOns\\MMT\\Media\\Icon"   -- the mark on a dark tile (Media/Icon.tga)

---------------------------------------------------------------------------
-- Fonts (LibSharedMedia fonts are added when that library is present)
---------------------------------------------------------------------------
ns.fonts = {
    { name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
    { name = "Arial Narrow",  path = "Fonts\\ARIALN.TTF" },
    { name = "Morpheus",      path = "Fonts\\MORPHEUS.TTF" },
    { name = "Skurri",        path = "Fonts\\SKURRI.TTF" },
}

function ns.LoadSharedMediaFonts()
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if not LSM then return end
    local known = {}
    for _, f in ipairs(ns.fonts) do known[f.name] = true end
    for _, name in ipairs(LSM:List("font")) do
        if not known[name] then
            ns.fonts[#ns.fonts + 1] = { name = name, path = LSM:Fetch("font", name) }
        end
    end
end

-- name of a font in the list, or a font file path (kept from older profiles)
function ns.FontPath(name)
    for _, f in ipairs(ns.fonts) do
        if f.name == name then return f.path end
    end
    if type(name) == "string" and name:find("\\", 1, true) then return name end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

function ns.FontNameForPath(path)
    for _, f in ipairs(ns.fonts) do
        if f.path:lower() == (path or ""):lower() then return f.name end
    end
    return path
end

function ns.ApplyFont(fontString, name, size, outline)
    outline = (outline and outline ~= "NONE") and outline or ""
    if not fontString:SetFont(ns.FontPath(name), size, outline) then
        fontString:SetFont(STANDARD_TEXT_FONT, size, outline)
    end
end

---------------------------------------------------------------------------
-- Chat output & debug log
---------------------------------------------------------------------------
local PREFIX = "|cff4fb3ffMMT|r: "

function ns.Print(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or tostring(fmt)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

-- Debug lines go into a log (/mmt debug dump) and, optionally, to chat.
-- The same alert about the same character at most once every few seconds
-- (raid warnings, sounds and chat lines of follow, crowd control, room warnings).
local ALERT_COOLDOWN = 5
local lastAlert = {}
function ns.AlertAllowed(kind, key)
    local id = tostring(kind) .. ":" .. tostring(key)
    local now = GetTime()
    if lastAlert[id] and now - lastAlert[id] < ALERT_COOLDOWN then return false end
    lastAlert[id] = now
    return true
end

function ns.Debug(fmt, ...)
    if not (MMTDB and MMTDB.debug) then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    -- "Keep full names in debug logs" off: names become their shown names
    if ns.db and ns.db.privacy and not ns.db.privacy.debugFull and ns.ReplaceNames then
        msg = ns.ReplaceNames(msg, true)
    end
    local line = date("%H:%M:%S") .. " " .. msg
    MMTDB.debuglog = MMTDB.debuglog or {}
    local log = MMTDB.debuglog
    log[#log + 1] = line
    if #log > 300 then table.remove(log, 1) end
    if MMTDB.debugChat then DEFAULT_CHAT_FRAME:AddMessage("|cff888888MMT debug|r " .. line) end
end

-- Shows a string with every non-alphanumeric byte as <hex>, so spaces,
-- hyphens and special characters in names become visible.
function ns.Repr(s)
    if s == nil then return "nil" end
    if ns.IsSecret(s) then return "<secret>" end
    s = tostring(s)
    if not s:find("[^%w]") then return '"' .. s .. '"' end
    local vis = s:gsub("[^%w]", function(c) return string.format("<%02x>", c:byte()) end)
    return '"' .. s .. '" ' .. vis
end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local issecretvalue = issecretvalue
function ns.IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) == true
end

-- Calls fn safely; returns nil if it errors or yields a secret value.
function ns.Safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f, g = pcall(fn, ...)
    if not ok or ns.IsSecret(a) then return nil end
    return a, b, c, d, e, f, g
end

function ns.Trim(s)
    return ((s or ""):match("^%s*(.-)%s*$"))
end

function ns.FormatMoney(copper)
    copper = math.floor(copper or 0)
    local style = ns.db and ns.db.merchant.moneyFormat or "text"
    if style == "coins" and GetCoinTextureString then
        return GetCoinTextureString(copper)
    end
    local g = math.floor(copper / 10000)
    local s = math.floor(copper / 100) % 100
    local c = copper % 100
    local parts = {}
    if style == "short" then
        if g > 0 then parts[#parts + 1] = g .. "g" end
        if s > 0 then parts[#parts + 1] = s .. "s" end
        if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    else
        if g > 0 then parts[#parts + 1] = g .. " gold" end
        if s > 0 then parts[#parts + 1] = s .. " silver" end
        if c > 0 or #parts == 0 then parts[#parts + 1] = c .. " copper" end
    end
    return table.concat(parts, " ")
end

function ns.Ago(t)
    if not t then return "never" end
    local d = time() - t
    if d < 90 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. " min ago" end
    if d < 86400 * 2 then return math.floor(d / 3600) .. " h ago" end
    return math.floor(d / 86400) .. " days ago"
end

ns.BAGS = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
function ns.ItemInfo(item)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    return getInfo(item)
end

---------------------------------------------------------------------------
-- Names (tested on WoW: Forever in MMT 0.1.x)
--
-- Characters have a first and a last name. UnitFullName returns them as
-- (first, last) where other clients return (name, realm). Senders of
-- addon messages arrive as "First Last" and sometimes with "-<realm>".
-- Team keys look like "First-Last"; first and last name are also stored
-- separately, and incoming names are matched tolerantly.
---------------------------------------------------------------------------
local function OwnRealm()
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    if not r or r == "" then r = (GetRealmName() or ""):gsub("%s", "") end
    return r
end
ns.OwnRealm = OwnRealm

function ns.ToFull(name, realm)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    if not realm or realm == "" then realm = OwnRealm() end
    return name .. "-" .. realm
end

-- lower-case, letters/digits only: "Anna Schmidt" == "anna-schmidt"
function ns.NormKey(s)
    return ((s or ""):lower():gsub("[^%w\128-\255]", ""))
end

-- Returns first, last (or nil), teamKey ("First-Last", or "First").
function ns.SplitUnit(unit)
    local n, r = ns.Safe(UnitFullName, unit)
    if not n then n = ns.Safe(UnitName, unit) end
    if not n then return nil end
    local last
    if r and not ns.IsSecret(r) and r ~= "" and ns.NormKey(r) ~= ns.NormKey(OwnRealm()) then last = r end
    return n, last, last and (n .. "-" .. last) or n
end

function ns.PlayerFull()
    local _, _, key = ns.SplitUnit("player")
    return key
end

-- "First-Last-ClassicBetaPvE2" -> "First-Last"
function ns.StripRealm(s)
    s = s or ""
    local realm = OwnRealm()
    if realm ~= "" then
        local suffix = "-" .. realm:lower()
        if #s > #suffix and s:lower():sub(-#suffix) == suffix then
            return s:sub(1, #s - #suffix)
        end
    end
    return s
end

local function Member(key)
    return ns.db and ns.db.team and ns.db.team[key]
end

-- Real names: only for what needs them (macros, invites, whispers, unit
-- lookups). Everything shown to the player uses ns.ShownName (privacy).
function ns.RealFirst(key)
    local m = Member(key)
    if m and m.name then return m.name end
    key = ns.StripRealm(key or "")
    return key:match("^([^%-%s]+)") or key
end

-- the last name: stored with the member, else from the team key
-- ("First-Last") or from the name the character last sent with
local function LastOf(text)
    if not text or text == "" or ns.IsSecret(text) then return nil end
    return ns.StripRealm(text):match("^[^%-%s]+[%-%s]+(.+)$")
end
function ns.RealLast(key)
    local m = Member(key)
    if m and m.last and m.last ~= "" then return m.last end
    local s = ns.status and ns.status[key]
    return LastOf(key) or LastOf(s and s.sender)
end

-- "First Last"
function ns.RealName(key)
    local first, last = ns.RealFirst(key), ns.RealLast(key)
    return last and (first .. " " .. last) or first
end

---------------------------------------------------------------------------
-- Privacy: how characters are shown (Team > Privacy)
--   FIRST "Catsi", LAST "Purrita", FULL "Catsi Purrita",
--   CLASS "Druid 1", "Druid 2" (team order), SLOT "Slot 1", "Slot 2" ...
---------------------------------------------------------------------------
local function NameMode()
    local p = ns.db and ns.db.privacy
    return p and p.nameMode or "FIRST"
end

local function ClassOf(key)
    local m = Member(key)
    local class = m and m.class
    if not class and ns.status and ns.status[key] then class = ns.status[key].class end
    if not class and ns.IsSelf and ns.IsSelf(key) then class = select(2, UnitClass("player")) end
    if class == "" or ns.IsSecret(class) then return nil end
    return class
end

local function ClassLabel(class)
    local names = LOCALIZED_CLASS_NAMES_MALE or {}
    return names[class] or (class:sub(1, 1) .. class:sub(2):lower())
end

-- the name for a mode (nil mode = the current setting)
function ns.NameFor(key, mode)
    if not key then return "?" end
    mode = mode or NameMode()
    local m = Member(key)
    if mode == "FULL" then return ns.RealName(key) end
    if mode == "LAST" then return ns.RealLast(key) or ns.RealFirst(key) end
    if (mode == "CLASS" or mode == "SLOT") and m and ns.SortedMembers then
        local order = ns.SortedMembers()
        local slot
        for i, k in ipairs(order) do if k == key then slot = i end end
        if mode == "CLASS" then
            local class = ClassOf(key)
            if class then
                local n = 0
                for _, k in ipairs(order) do
                    if ClassOf(k) == class then n = n + 1 end
                    if k == key then break end
                end
                return ClassLabel(class) .. " " .. n
            end
        end
        if slot then return "Slot " .. slot end   -- class not known yet
    end
    if not m and (mode == "CLASS" or mode == "SLOT") then return ns.RealName(key) end   -- not in the team
    return ns.RealFirst(key)
end

function ns.ShownName(key) return ns.NameFor(key) end

-- All of these follow the privacy setting (kept for modules and older code).
ns.FirstName = ns.ShownName      -- windows
ns.FullDisplay = ns.ShownName    -- chat messages
function ns.Display(key) return ns.ShownName(key) end

-- Opens GameTooltip for a team member: shown name in class colour, roles and
-- online state. Returns the tooltip so callers can add lines before :Show().
function ns.MemberTooltip(owner, key, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    local m = ns.db and ns.db.team[key]
    local c = m and m.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[m.class]
    GameTooltip:SetText(ns.FullDisplay(key), c and c.r or 1, c and c.g or 1, c and c.b or 1)
    if ns.IsSelf(key) then
        GameTooltip:AddLine("You", 0.6, 0.6, 0.6)
    elseif ns.IsOnline and ns.IsOnline(key) then
        GameTooltip:AddLine("Online with MMT", 0.4, 1, 0.4)
    elseif m then
        GameTooltip:AddLine("Offline", 0.6, 0.6, 0.6)
    end
    if m and ns.MemberRoleList then
        local roles = table.concat(ns.MemberRoleList(key), ", ")
        if roles ~= "" then GameTooltip:AddLine("Roles: " .. roles, 1, 1, 1) end
    end
    return GameTooltip
end

-- Shows the member tooltip while the mouse is over frame; getKey() returns the key.
function ns.HoverMember(frame, getKey, addLines)
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function(self)
        local key = getKey()
        if not key then return end
        local tip = ns.MemberTooltip(self, key)
        if addLines then addLines(tip, key) end
        tip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function ns.IsSelf(name)
    if not name or name == "" or ns.IsSecret(name) then return false end
    local nk = ns.NormKey(ns.StripRealm(name))
    if nk == ns.NormKey(ns.PlayerFull()) then return true end
    return nk == ns.NormKey((ns.Safe(UnitName, "player")))
end

-- Finds the team key for any spelling of a name (or nil).
function ns.Resolve(name)
    if not name or name == "" or not ns.db or ns.IsSecret(name) then return nil end
    local team = ns.db.team
    if team[name] then return name end
    local bare = ns.StripRealm(name)
    if team[bare] then return bare end
    local nk = ns.NormKey(bare)
    for key in pairs(team) do
        if ns.NormKey(key) == nk then return key end
    end
    -- a bare first name matches if it is unambiguous
    local found
    for key, m in pairs(team) do
        if m.name and ns.NormKey(m.name) == nk then
            if found then return nil end
            found = key
        end
    end
    if found then return found end
    -- the shown name ("Druid 1", "Slot 2", a last name), e.g. /mmt leader Druid 1
    local mode = ns.db.privacy and ns.db.privacy.nameMode
    if mode and mode ~= "FIRST" and mode ~= "FULL" then
        for key in pairs(team) do
            if ns.NormKey(ns.NameFor(key)) == nk then return key end
        end
    end
    return nil
end

function ns.NameFromGUID(guid, fallback)
    if guid then
        local _, _, _, _, _, first, last = ns.Safe(GetPlayerInfoByGUID, guid)
        -- a player of another realm comes as "First Last" plus that realm:
        -- the name already holds the last name, the realm is not part of it
        if first and first:find(" ", 1, true) then return first end
        if first and last and last ~= "" and ns.NormKey(last) ~= ns.NormKey(OwnRealm()) then
            return first .. " " .. last
        end
    end
    if fallback and not ns.IsSecret(fallback) then return (ns.StripRealm(fallback):gsub("-", " ")) end
    return "?"
end

---------------------------------------------------------------------------
-- Shift bypass for NPC automation
--
-- Checked by every NPC page (gossip, quest greeting, quest details, progress,
-- reward). Shift held while a page opens keeps THAT page manual. When you
-- then pick an option without Shift, the next page is automated again.
---------------------------------------------------------------------------
function ns.IsBypassed()
    return ns.db.shiftBypass and IsShiftKeyDown() and true or false
end

---------------------------------------------------------------------------
-- Events & callbacks
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        -- events this client doesn't know are skipped (e.g. classic-only ones)
        local valid = not (C_EventUtils and C_EventUtils.IsEventValid) or C_EventUtils.IsEventValid(event)
        if valid then
            local ok = pcall(frame.RegisterEvent, frame, event)
            if not ok then ns.Debug("event %s not available on this client", event) end
        end
    end
    table.insert(handlers[event], fn)
end

frame:SetScript("OnEvent", function(_, event, ...)
    if not ns.ready and event ~= "ADDON_LOADED" and event ~= "PLAYER_LOGIN" then return end
    for _, fn in ipairs(handlers[event]) do
        local ok, err = pcall(fn, ...)
        if not ok then ns.Debug("%s handler error: %s", event, tostring(err)) end
    end
end)

local callbacks = {}
function ns.Listen(name, fn)
    callbacks[name] = callbacks[name] or {}
    table.insert(callbacks[name], fn)
end
function ns.Fire(name, ...)
    for _, fn in ipairs(callbacks[name] or {}) do
        local ok, err = pcall(fn, ...)
        if not ok then ns.Debug("%s callback error: %s", name, tostring(err)) end
    end
end

-- settings changed -> modules re-apply them
function ns.OnRefresh(fn) ns.Listen("REFRESH", fn) end
function ns.Refresh() ns.Fire("REFRESH") end
function ns.OnLogin(fn) ns.Listen("LOGIN", fn) end


ns.On("ADDON_LOADED", function(name)
    if name == ADDON then ns.InitDB() end
end)

ns.On("PLAYER_LOGIN", function()
    ns.SelectCharacterProfile()
    ns.LoadSharedMediaFonts()
    ns.ready = true
    ns.Fire("LOGIN")
    ns.Refresh()

    local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    if isLoaded and isLoaded("OMT") and not ns.justMigrated then
        ns.Print("OMT is now part of MMT. Please disable or delete the OMT addon, otherwise automations run twice.")
    end
end)
