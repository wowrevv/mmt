-- MMT: privacy. Replaces the names of your team's characters in text with the
-- name chosen in Team > Privacy ("Catsi", "Purrita", "Druid 1", "Slot 2").
--
--   * ns.ReplaceNames(text, forDebug): used for debug logs and reports when
--     "Keep full names in debug logs" is off.
--   * "Hide names outside MMT too": chat (every chat window), unit frames
--     (player, target, focus, target of target, party, raid), nameplates,
--     unit tooltips and any text other addons show in their own frames (raid
--     frames of other addons), as far as the game allows: values the game
--     hands out as secrets can't be read and stay as they are.
--
-- Only what is shown changes: player links in chat keep the real name, so
-- clicking a name still whispers the right character. Addon messages,
-- macros, invites and whispers always use the real names.

local _, ns = ...

local function Settings() return ns.db and ns.db.privacy end

local function Active()
    local p = Settings()
    return p and p.hideOutside and p.nameMode ~= "FULL"
end

---------------------------------------------------------------------------
-- Text replacement
---------------------------------------------------------------------------
local LETTER = "%w\128-\255"
local function Esc(s) return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")) end
-- upper / lower case don't matter: the game reports "Mcquiding", other
-- addons may show "McQuiding"
local function Caseless(pattern)
    return (pattern:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

-- { pattern, replacement } for every spelling of every team name, longest first
local function Rules(forDebug)
    local rules = {}
    local team = ns.db and ns.db.team
    if not team then return rules end
    local mode = Settings() and Settings().nameMode or "FIRST"
    for key, m in pairs(team) do
        local first, last = ns.RealFirst(key), ns.RealLast(key)
        local alias
        if forDebug and mode == "FULL" then alias = ns.NameFor(key, "SLOT")
        else alias = ns.ShownName(key) end
        local function Add(text)
            if text and text ~= "" and text ~= alias then
                rules[#rules + 1] = { text = text, alias = alias }
            end
        end
        if first and last then
            Add(first .. " " .. last)
            Add(first .. "-" .. last)
            if forDebug then
                Add(first .. "<20>" .. last)   -- ns.Repr spellings
                Add(first .. "<2d>" .. last)
            end
        end
        Add(first)
        Add(last)
    end
    table.sort(rules, function(a, b) return #a.text > #b.text end)
    for _, r in ipairs(rules) do
        r.pattern = "%f[" .. LETTER .. "]" .. Caseless(Esc(r.text)) .. "%f[^" .. LETTER .. "]"
        r.repl = r.alias:gsub("%%", "%%%%")
    end
    -- first name + space/hyphen + the start of the last name: other addons
    -- shorten names to fit ("Gunter Mcquidin", "Gunter Mcq", "Gunter M.").
    -- These go first, before the single names.
    local shortened = {}
    for key in pairs(team) do
        local first, last = ns.RealFirst(key), ns.RealLast(key)
        if first and last and first ~= "" and last ~= "" then
            local alias = (forDebug and mode == "FULL") and ns.NameFor(key, "SLOT") or ns.ShownName(key)
            local lastLower = last:lower()
            shortened[#shortened + 1] = {
                text = first .. " " .. last, alias = alias, first = #first,
                pattern = "%f[" .. LETTER .. "]" .. Caseless(Esc(first)) .. "[%s%-]+([" .. LETTER .. "]+)%f[^" .. LETTER .. "]",
                repl = function(part)
                    if lastLower:sub(1, #part) == part:lower() then return alias end
                end,
            }
        end
    end
    table.sort(shortened, function(a, b) return a.first > b.first end)
    for i = #shortened, 1, -1 do table.insert(rules, 1, shortened[i]) end
    return rules
end

local cache = {}
local function CachedRules(forDebug)
    local k = forDebug and "debug" or "show"
    if not cache[k] then
        local rules = Rules(forDebug)
        -- quick test: the names that must appear for any rule to match
        local needles, seen = {}, {}
        for _, r in ipairs(rules) do
            local word = (r.text:match("^[^%s%-<]+") or r.text):lower()
            if not seen[word] then seen[word] = true; needles[#needles + 1] = Caseless(Esc(word)) end
        end
        rules.needles = needles
        cache[k] = rules
    end
    return cache[k]
end
local Reapply   -- below
-- the setting, the team or a class changed: new rules, and everything shown again
function ns.PrivacyChanged()
    cache = {}
    if ns.RefreshNameFrames then ns.RefreshNameFrames() end
    if Reapply then Reapply() end
end
ns.Listen("TEAM_CHANGED", function() ns.PrivacyChanged() end)
ns.Listen("PROFILE_CHANGED", function() ns.PrivacyChanged() end)
-- a class learned later turns "Slot 4" into "Druid 3"
local knownClass = {}
ns.Listen("XP_RECEIVED", function(key, sender, st)
    local class = st and st.class
    if class and class ~= "" and knownClass[key] ~= class then
        knownClass[key] = class
        ns.PrivacyChanged()
    end
end)

local function ReplacePlain(text, rules)
    if text == "" then return text end
    for _, r in ipairs(rules) do text = text:gsub(r.pattern, r.repl) end
    return text
end

-- escape sequences that are not shown text: links (data part), textures,
-- atlases, Battle.net names, colour codes, "|r", "||", "|n". They separate
-- words, so "|cffaad372Gunter McQuiding|r" is found as a whole name.
local ESCAPES = { "^|H.-|h", "^|T.-|t", "^|A.-|a", "^|K.-|k", "^|c%x%x%x%x%x%x%x%x", "^|cn[^:]*:", "^|r", "^||", "^|n" }

local function Contains(text, needles)
    for _, n in ipairs(needles) do
        if text:find(n) then return true end
    end
    return false
end

-- replaces the names in shown text; escape sequences stay as they are
function ns.ReplaceNames(text, forDebug)
    if type(text) ~= "string" or ns.IsSecret(text) or text == "" then return text end
    local rules = CachedRules(forDebug)
    if #rules == 0 or not Contains(text, rules.needles) then return text end
    local out, pos, len = {}, 1, #text
    while pos <= len do
        local bar = text:find("|", pos, true)
        if not bar then break end
        out[#out + 1] = ReplacePlain(text:sub(pos, bar - 1), rules)
        local stop
        for _, pattern in ipairs(ESCAPES) do
            local _, e = text:find(pattern, bar)
            if e then stop = e break end
        end
        stop = stop or bar
        out[#out + 1] = text:sub(bar, stop)
        pos = stop + 1
    end
    out[#out + 1] = ReplacePlain(text:sub(pos), rules)
    return table.concat(out)
end

---------------------------------------------------------------------------
-- Chat: every chat window shows the replaced text
---------------------------------------------------------------------------
local wrapped = {}
-- replaced chat line -> original line (the last 500), so a changed setting can redo them
local chatOriginal, chatOrder = {}, {}
local function RememberChat(shown, orig)
    if chatOriginal[shown] == nil then
        chatOrder[#chatOrder + 1] = shown
        if #chatOrder > 500 then chatOriginal[table.remove(chatOrder, 1)] = nil end
    end
    chatOriginal[shown] = orig
end

local function WrapChatFrame(frame)
    if not frame or wrapped[frame] or type(frame.AddMessage) ~= "function" then return end
    wrapped[frame] = true
    local original = frame.AddMessage
    frame.AddMessage = function(self, text, ...)
        if Active() and type(text) == "string" and not ns.IsSecret(text) then
            local ok, replaced = pcall(ns.ReplaceNames, text)
            if ok and replaced ~= text then
                RememberChat(replaced, text)
                text = replaced
            end
        end
        return original(self, text, ...)
    end
end

-- lines already in the chat windows: shown again with the current setting
-- (original names back when the option is off); needs TransformMessages
local function ReapplyChat()
    for frame in pairs(wrapped) do
        if frame.TransformMessages then
            pcall(frame.TransformMessages, frame,
                function(entry)
                    return type(entry) == "table" and type(entry.message) == "string" and not ns.IsSecret(entry.message)
                end,
                function(entry)
                    local orig = chatOriginal[entry.message] or entry.message
                    local new = Active() and ns.ReplaceNames(orig) or orig
                    if new ~= entry.message then
                        entry.message = new
                        if new ~= orig then RememberChat(new, orig) end
                    end
                end)
        end
    end
end

local function WrapAllChatFrames()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do WrapChatFrame(_G["ChatFrame" .. i]) end
    for _, name in ipairs(CHAT_FRAMES or {}) do WrapChatFrame(_G[name]) end
end

---------------------------------------------------------------------------
-- Unit frames, nameplates
---------------------------------------------------------------------------
local function NameText(frame)
    if not frame then return nil end
    local content = frame.TargetFrameContent and frame.TargetFrameContent.TargetFrameContentMain
    local fs = frame.name or frame.Name or (content and content.Name)
    if not fs and frame.GetName and frame:GetName() then
        fs = _G[frame:GetName() .. "Name"] or _G[frame:GetName() .. "TextureFrameName"]
    end
    if fs and fs.GetText and fs.SetText then return fs end
end

local AfterSetText   -- below: replaces and remembers the original text
local function FixFrame(frame)
    if not Active() then return end
    local fs = NameText(frame)
    if fs then AfterSetText(fs, nil) end
end

local FRAMES = { "PlayerFrame", "TargetFrame", "FocusFrame", "TargetFrameToT", "FocusFrameToT",
    "PartyMemberFrame1", "PartyMemberFrame2", "PartyMemberFrame3", "PartyMemberFrame4" }

function ns.RefreshNameFrames()
    if not Active() then return end
    for _, name in ipairs(FRAMES) do FixFrame(_G[name]) end
    if PlayerName then FixFrame({ name = PlayerName }) end
    local party = _G.PartyFrame
    if party then
        for i = 1, 4 do FixFrame(party["MemberFrame" .. i]) end
    end
end

local function RefreshSoon() C_Timer.After(0, ns.RefreshNameFrames) end

if hooksecurefunc then
    if UnitFrame_Update then hooksecurefunc("UnitFrame_Update", function(self) FixFrame(self) end) end
    if CompactUnitFrame_UpdateName then
        hooksecurefunc("CompactUnitFrame_UpdateName", function(self) FixFrame(self) end)   -- raid frames, nameplates
    end
    if FCF_OpenTemporaryWindow then hooksecurefunc("FCF_OpenTemporaryWindow", function() C_Timer.After(0, WrapAllChatFrames) end) end
end

for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED", "GROUP_ROSTER_UPDATE", "UNIT_NAME_UPDATE",
    "PLAYER_ENTERING_WORLD" }) do
    ns.On(e, RefreshSoon)
end

---------------------------------------------------------------------------
-- Every other text in the interface (unit and raid frames of other addons,
-- e.g. Ellesmere): after any FontString:SetText / SetFormattedText the text
-- is checked. Cheap when no team name is in it (a few plain searches).
---------------------------------------------------------------------------
local busy = false
-- texts MMT replaced: [fontString] = { orig = text before, shown = text now }
local tracked = setmetatable({}, { __mode = "k" })

local function SetQuietly(fs, text)
    busy = true
    pcall(fs.SetText, fs, text)
    busy = false
end

AfterSetText = function(fs, text)
    if busy or not Active() then return end
    if text == nil then text = fs:GetText() end
    if type(text) ~= "string" or ns.IsSecret(text) then return end
    local new = ns.ReplaceNames(text)
    if new ~= text then
        tracked[fs] = { orig = text, shown = new }
        SetQuietly(fs, new)
    elseif tracked[fs] and tracked[fs].shown ~= text then
        tracked[fs] = nil   -- new text without names
    end
end

-- everything MMT replaced: again with the current setting, or back to the
-- original when the option is off; chat history too
Reapply = function()
    for fs, t in pairs(tracked) do
        local ok, current = pcall(fs.GetText, fs)
        if ok and current == t.shown then
            local new = Active() and ns.ReplaceNames(t.orig) or t.orig
            if new ~= current then SetQuietly(fs, new) end
            t.shown = new   -- kept when restored, so switching on again redoes it
        else
            tracked[fs] = nil   -- the frame shows something else by now
        end
    end
    ReapplyChat()
end

do
    local probe = UIParent and UIParent.CreateFontString and UIParent:CreateFontString()
    local meta = probe and getmetatable(probe)
    local methods = meta and meta.__index
    if hooksecurefunc and type(methods) == "table" then
        if methods.SetText then hooksecurefunc(methods, "SetText", function(fs, text) AfterSetText(fs, text) end) end
        if methods.SetFormattedText then hooksecurefunc(methods, "SetFormattedText", function(fs) AfterSetText(fs, nil) end) end
    end
end

---------------------------------------------------------------------------
-- Unit tooltips
---------------------------------------------------------------------------
local function FixTooltip(tt)
    if not Active() or not tt or not tt.NumLines or not tt.GetName or not tt:GetName() then return end
    for i = 1, math.min(3, tt:NumLines() or 0) do
        local fs = _G[tt:GetName() .. "TextLeft" .. i]
        local text = fs and fs:GetText()
        if type(text) == "string" and not ns.IsSecret(text) then
            local new = ns.ReplaceNames(text)
            if new ~= text then fs:SetText(new) end
        end
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, FixTooltip)
elseif GameTooltip and GameTooltip.HookScript then
    pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", FixTooltip)
end

ns.OnLogin(function()
    WrapAllChatFrames()
    RefreshSoon()
end)
ns.On("UPDATE_CHAT_WINDOWS", function() WrapAllChatFrames() end)
