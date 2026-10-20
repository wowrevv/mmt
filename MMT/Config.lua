-- MMT: configuration window (/mmt).
-- Navigation: CORE pages (always on), then MODULES: one entry per installed
-- module (greyed out when switched off) and "Manage modules". At most 16
-- entries are visible; the mouse wheel scrolls; clicking CORE or MODULES
-- collapses / expands that section.

local _, ns = ...
local UI = ns.UI
local A = UI.ACCENT

local WIDTH, HEIGHT, NAV = 700, 620, 150
local NAV_ROWS = 16                                     -- page entries visible at once
local NAV_ROW, NAV_HEAD, NAV_TOP = 26, 22, -58
local NAV_VIEW = NAV_ROWS * NAV_ROW + 2 * NAV_HEAD      -- height of the page list
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.6, 2.0, 0.05
local window
local pages, coreOrder = {}, {}
local current

-- Core pages register themselves from ConfigPages.lua.
function ns.RegisterPage(key, title, build)
    pages[key] = { key = key, title = title, build = build }
    if key ~= "modules" then coreOrder[#coreOrder + 1] = key end
end

-- settings pages of loaded modules (m.Page(m, frame)), added when the window is built
local function RegisterModulePages()
    for _, m in ipairs(ns.moduleList) do
        if m.Page and not pages["mod:" .. m.name] then
            pages["mod:" .. m.name] = { key = "mod:" .. m.name, title = m.title, module = m,
                build = function(frame)
                    m.Page(m, frame)
                    m:SyncButton(frame)   -- only with sync = true
                end }
        end
    end
end

local function RefreshPage(page)
    if not page or not page.frame then return end
    for _, w in ipairs(page.frame.widgets) do w.Refresh() end
    if page.frame.OnRefresh then pcall(page.frame.OnRefresh) end
    if page.overlay then page.overlay:SetShown(not page.module.enabled) end
end

local function RefreshNav()
    if not window then return end
    for _, tab in ipairs(window.tabs) do tab.Update() end
    for _, wd in ipairs(window.navWidgets) do wd.Refresh() end
end

function ns.RefreshConfig()
    if window and window:IsShown() then
        RefreshPage(pages[current])
        RefreshNav()
    end
end
ns.OnRefresh(ns.RefreshConfig)
ns.Listen("TEAM_CHANGED", function() ns.RefreshConfig() end)
ns.Listen("ROLES_CHANGED", function() ns.RefreshConfig() end)

-- grey cover over the page of a switched-off module
local function Overlay(page, frame)
    local o = CreateFrame("Frame", nil, frame)
    o:SetAllPoints()
    o:SetFrameLevel(frame:GetFrameLevel() + 30)
    o:EnableMouse(true)
    UI.Fill(o, 0.05, 0.05, 0.06, 0.85)
    local text = UI.Label(o, page.title .. " is switched off.", "GameFontNormal")
    text:SetPoint("TOP", 0, -120)
    local sub = UI.Label(o, "Its settings are kept. Switch it on to use and change them.")
    sub:SetPoint("TOP", text, "BOTTOM", 0, -8)
    sub:SetTextColor(0.6, 0.6, 0.6)
    local on = UI.Button(o, 160, "Switch on", function()
        for _, entry in ipairs(ns.InstalledModules()) do
            if entry.module == page.module then ns.SetModuleEnabled(entry, true) end
        end
        ns.RefreshConfig()
    end)
    on:SetPoint("TOP", sub, "BOTTOM", 0, -14)
    page.overlay = o
end

local function Select(key)
    if not pages[key] then key = "team" end
    current = key
    for k, page in pairs(pages) do
        local selected = (k == key)
        if selected and not page.frame then
            local frame = CreateFrame("Frame", nil, window)
            frame:SetPoint("TOPLEFT", NAV + 16, -44)
            frame:SetSize(WIDTH - NAV - 32, HEIGHT - 56)
            frame.widgets = {}
            page.build(frame)
            if page.module then Overlay(page, frame) end
            page.frame = frame
        end
        if page.frame then page.frame:SetShown(selected) end
    end
    window.pageTitle:SetText(pages[key].title)
    RefreshPage(pages[key])
    RefreshNav()
    if window.ShowInNav then window.ShowInNav(key) end
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------
-- isOn(): nil = no on/off state, true/false = module state
local function Tab(parent, title, target, isOn)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(NAV, 26)
    local bg = UI.Fill(b, 1, 1, 1, 0)
    local bar = b:CreateTexture(nil, "ARTWORK")
    bar:SetColorTexture(A[1], A[2], A[3], 1)
    bar:SetPoint("TOPLEFT"); bar:SetPoint("BOTTOMLEFT")
    bar:SetWidth(2)
    local label = UI.Label(b, title, "GameFontNormal")
    label:SetPoint("LEFT", 16, 0)
    local state = UI.Label(b, "")
    state:SetPoint("RIGHT", -10, 0)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.03)
    b.Update = function()
        local selected = (current == target)
        local on = isOn and isOn()
        bar:SetShown(selected)
        bg:SetColorTexture(1, 1, 1, selected and 0.06 or 0)
        if isOn and not on then
            label:SetTextColor(0.4, 0.4, 0.4)
            state:SetText("off")
            state:SetTextColor(0.4, 0.4, 0.4)
        else
            if selected then label:SetTextColor(1, 1, 1) else label:SetTextColor(0.65, 0.65, 0.65) end
            state:SetText("")
        end
    end
    b:SetScript("OnClick", function() Select(target) end)
    return b
end


local function Build()
    RegisterModulePages()
    local w = CreateFrame("Frame", "MMTConfigFrame", UIParent)
    w:SetSize(WIDTH, HEIGHT)
    w:SetPoint("CENTER")
    w:SetFrameStrata("DIALOG")
    w:SetClampedToScreen(true)
    w:SetMovable(true)
    w:EnableMouse(true)
    w:RegisterForDrag("LeftButton")
    w:SetScript("OnDragStart", w.StartMoving)
    w:SetScript("OnDragStop", w.StopMovingOrSizing)
    w:Hide()
    UI.CloseOnEscape(w)
    w.tabs = {}

    UI.Fill(w, 0.05, 0.05, 0.06, 0.94)
    UI.Border(w, 0.22, 0.22, 0.24, 1)

    local nav = CreateFrame("Frame", nil, w)
    nav:SetPoint("TOPLEFT", 1, -1)
    nav:SetPoint("BOTTOMLEFT", 1, 1)
    nav:SetWidth(NAV)
    UI.Fill(nav, 1, 1, 1, 0.025)
    local divider = w:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 1, 1, 0.06)
    divider:SetPoint("TOPLEFT", nav, "TOPRIGHT")
    divider:SetPoint("BOTTOMLEFT", nav, "BOTTOMRIGHT")
    divider:SetWidth(1)

    -- logo: Interface\AddOns\MMT\Media\Logo.tga (128x128, transparent)
    local logo = nav:CreateTexture(nil, "ARTWORK")
    logo:SetSize(36, 36)
    logo:SetPoint("TOPLEFT", 10, -8)
    logo:SetTexture(ns.LOGO)
    local title = UI.Label(nav, "MMT", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 50, -14)
    title:SetTextColor(A[1], A[2], A[3])
    local sub = UI.Label(nav, "Manage My Team")
    sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    sub:SetTextColor(0.6, 0.6, 0.6)

    -- page list: at most NAV_ROWS entries visible, mouse wheel scrolls,
    -- CORE / MODULES collapse and expand (remembered per account)
    local items = {}
    local function Item(kind, section, frame, height)
        items[#items + 1] = { kind = kind, section = section, frame = frame, height = height }
    end
    local function Collapsed(section)
        return MMTDB.navCollapsed and MMTDB.navCollapsed[section] or false
    end
    local LayoutNav
    local function Header(text, section)
        local b = CreateFrame("Button", nil, nav)
        b:SetSize(NAV, NAV_HEAD)
        local label = UI.Label(b, text)
        label:SetPoint("LEFT", 16, -2)
        label:SetTextColor(A[1], A[2], A[3], 0.8)
        local sign = UI.Label(b, "")
        sign:SetPoint("RIGHT", -12, -2)
        sign:SetTextColor(A[1], A[2], A[3], 0.8)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.03)
        b.Update = function() sign:SetText(Collapsed(section) and "+" or "-") end
        b:SetScript("OnClick", function()
            MMTDB.navCollapsed = MMTDB.navCollapsed or {}
            MMTDB.navCollapsed[section] = not Collapsed(section) or nil
            LayoutNav()
        end)
        w.tabs[#w.tabs + 1] = b
        Item("head", section, b, NAV_HEAD)
    end
    local function AddTab(tab, section, target)
        tab.target = target
        w.tabs[#w.tabs + 1] = tab
        Item("tab", section, tab, NAV_ROW)
    end

    Header("CORE", "core")
    for _, key in ipairs(coreOrder) do AddTab(Tab(nav, pages[key].title, key), "core", key) end
    Header("MODULES", "modules")
    for _, entry in ipairs(ns.InstalledModules()) do
        local m = entry.module
        local target = (m and pages["mod:" .. m.name]) and ("mod:" .. m.name) or "modules"
        AddTab(Tab(nav, entry.title, target, function()
            if m then return m.enabled end
            return false
        end), "modules", target)
    end
    AddTab(Tab(nav, "Manage modules", "modules"), "modules", "modules")

    -- scroll position marker (only when the list is longer than the view)
    local track = nav:CreateTexture(nil, "ARTWORK")
    track:SetColorTexture(1, 1, 1, 0.05)
    track:SetWidth(2)
    track:SetPoint("TOPRIGHT", nav, "TOPRIGHT", -2, NAV_TOP)
    track:SetHeight(NAV_VIEW)
    local thumb = nav:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(A[1], A[2], A[3], 0.6)
    thumb:SetWidth(2)

    local offset = 0   -- entries scrolled away at the top
    local function Visible()
        local list = {}
        for _, it in ipairs(items) do
            if it.kind == "head" or not Collapsed(it.section) then list[#list + 1] = it
            else it.frame:Hide() end
        end
        return list
    end
    -- entries after `from` that fit: at most NAV_ROWS pages and the view height
    local function Fit(list, from)
        local used, tabs, last = 0, 0, from
        for i = from + 1, #list do
            local it = list[i]
            if used + it.height > NAV_VIEW or (it.kind == "tab" and tabs >= NAV_ROWS) then break end
            used = used + it.height
            if it.kind == "tab" then tabs = tabs + 1 end
            last = i
        end
        return last
    end
    -- smallest offset that shows the last entry
    local function MaxOffset(list)
        for k = 0, #list do
            if Fit(list, k) >= #list then return k end
        end
        return #list
    end
    LayoutNav = function()
        local list = Visible()
        local maxOffset = MaxOffset(list)
        offset = math.max(0, math.min(offset, maxOffset))
        local last = Fit(list, offset)
        local y = NAV_TOP
        for i, it in ipairs(list) do
            if i > offset and i <= last then
                it.frame:ClearAllPoints()
                it.frame:SetPoint("TOPLEFT", nav, "TOPLEFT", 0, y)
                it.frame:Show()
                y = y - it.height
            else
                it.frame:Hide()
            end
            if it.frame.Update then it.frame.Update() end
        end
        local scrolls = maxOffset > 0
        track:SetShown(scrolls)
        thumb:SetShown(scrolls)
        if scrolls then
            local n = #list
            local size = math.max(16, NAV_VIEW * (n - maxOffset) / n)
            thumb:SetHeight(size)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPRIGHT", nav, "TOPRIGHT", -2, NAV_TOP - (NAV_VIEW - size) * offset / maxOffset)
        end
    end
    -- scroll so the tab of a page is in view (its section must be open)
    w.ShowInNav = function(key)
        local list = Visible()
        for i, it in ipairs(list) do
            if it.kind == "tab" and it.frame.target == key then
                if i <= offset then
                    offset = i - 1
                    if offset > 0 and list[offset].kind == "head" then offset = offset - 1 end   -- with its section title
                else
                    while Fit(list, offset) < i and offset < i - 1 do offset = offset + 1 end
                end
                break
            end
        end
        LayoutNav()
    end
    nav:EnableMouseWheel(true)
    nav:SetScript("OnMouseWheel", function(_, delta)
        offset = offset - delta
        LayoutNav()
    end)
    w.LayoutNav = LayoutNav
    LayoutNav()

    -- footer: window scale and version (debug tools are on the Help page)
    nav.widgets = {}
    local version = UI.Label(nav, "v" .. ns.version)
    version:SetPoint("BOTTOMLEFT", 16, 12)
    version:SetTextColor(0.4, 0.4, 0.4)
    -- buttons instead of a slider: dragging a slider while the window under it
    -- changes size would make the slider jump away from the mouse
    local scaleLabel = UI.Label(nav, "")
    scaleLabel:SetPoint("BOTTOMLEFT", 16, 32)
    scaleLabel:SetTextColor(0.6, 0.6, 0.6)
    local plus = UI.TextButton(nav, "+", function() ns.SetConfigScale(ns.ConfigScale() + SCALE_STEP) end, 18)
    plus:SetPoint("BOTTOMRIGHT", -10, 28)
    local minus = UI.TextButton(nav, "-", function() ns.SetConfigScale(ns.ConfigScale() - SCALE_STEP) end, 18)
    minus:SetPoint("RIGHT", plus, "LEFT", -2, 0)
    local scaleTip = "Size of this settings window, for high screen resolutions. Right-click to reset to 100%. Also /mmt scale <percent>."
    for _, b in ipairs({ plus, minus }) do
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local click = b:GetScript("OnClick")
        b:SetScript("OnClick", function(self, button)
            if button == "RightButton" then ns.SetConfigScale(1) else click(self, button) end
        end)
        b:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Window scale")
            GameTooltip:AddLine(scaleTip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local scaleWidget = { Refresh = function()
        scaleLabel:SetText(("Scale %d%%"):format(math.floor(ns.ConfigScale() * 100 + 0.5)))
    end }
    table.insert(nav.widgets, scaleWidget)
    scaleWidget.Refresh()
    w.navWidgets = nav.widgets
    w:SetScale(ns.ConfigScale())

    w.pageTitle = UI.Label(w, "", "GameFontNormalLarge")
    w.pageTitle:SetPoint("TOPLEFT", NAV + 16, -14)
    local close = UI.TextButton(w, "x", function() w:Hide() end, 20)
    close:SetPoint("TOPRIGHT", -8, -8)

    w:SetScript("OnShow", function()
        ns.configOpen = true
        Select(current or "team")
        if ns.UpdateDistanceVisibility then ns.UpdateDistanceVisibility() end
    end)
    w:SetScript("OnHide", function()
        w:SetFrameStrata("DIALOG")
        ns.configOpen = false
        if ns.UpdateDistanceVisibility then ns.UpdateDistanceVisibility() end
    end)
    return w
end

---------------------------------------------------------------------------
-- Window scale (account-wide: same screen for every character and profile)
---------------------------------------------------------------------------
function ns.ConfigScale()
    return (MMTDB and tonumber(MMTDB.configScale)) or 1
end

function ns.SetConfigScale(v)
    v = math.floor(math.max(SCALE_MIN, math.min(SCALE_MAX, v)) * 20 + 0.5) / 20
    MMTDB.configScale = v
    if window then
        window:SetScale(v)
        RefreshNav()
    end
    return v
end

-- key: page key ("team", "xp", "modules", ...) or a module name
function ns.ToggleConfig(key)
    window = window or Build()
    RegisterModulePages()
    if key then
        if not pages[key] and pages["mod:" .. key] then key = "mod:" .. key end
        if pages[key] then
            current = key
            if window:IsShown() then Select(key) return end
        end
    end
    window:SetShown(not window:IsShown())
end

---------------------------------------------------------------------------
-- Game options entry (Esc > Options > AddOns > MMT)
---------------------------------------------------------------------------
ns.OnLogin(function()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    local panel = CreateFrame("Frame")
    local logo = panel:CreateTexture(nil, "ARTWORK")
    logo:SetSize(48, 48)
    logo:SetPoint("TOPLEFT", 12, -10)
    logo:SetTexture(ns.LOGO)
    local t = UI.Label(panel, "MMT - Manage My Team", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 68, -22)
    -- opens MMT on top of the game options (closing Blizzard's panel from addon code would taint it)
    local open = UI.Button(panel, 160, "Open settings", function()
        window = window or Build()
        window:SetFrameStrata("FULLSCREEN_DIALOG")
        window:Show()
    end)
    open:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -12)
    local category = Settings.RegisterCanvasLayoutCategory(panel, "MMT")
    Settings.RegisterAddOnCategory(category)
end)

---------------------------------------------------------------------------
-- Slash command
---------------------------------------------------------------------------
SLASH_MMT1 = "/mmt"
SlashCmdList.MMT = function(msg)
    local raw = ns.Trim(msg)
    local cmd, arg = raw:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if not ns.ready then return end
    if cmd == "" or cmd == "config" then
        ns.ToggleConfig()
    elseif cmd == "xp" then
        ns.ToggleXPWindow()
    elseif cmd == "trade" then
        ns.FillTrade(true)
    elseif cmd == "sync" then
        if arg == "" then
            ns.SendProfileToTeam()
        else
            local m, ambiguous = ns.FindSyncModule(arg)
            if m then
                m:SyncToTeam()
            else
                local names = {}
                for _, mod in ipairs(ns.SyncableModules()) do names[#names + 1] = mod.name:lower() end
                ns.Print("%s \"%s\". Use /mmt sync for the core settings, or /mmt sync <module>: %s",
                    ambiguous and "More than one module matches" or "No module with settings to share matches",
                    arg, #names > 0 and table.concat(names, ", ") or "(no module loaded)")
            end
        end
    elseif cmd == "ping" then
        ns.Ping()
    elseif cmd == "debug" then
        ns.HandleDebugCommand(arg)
    elseif cmd == "modules" then
        ns.ToggleConfig("modules")
    elseif cmd == "help" then
        ns.ToggleConfig("help")
    elseif cmd == "leader" or cmd == "ftl" then
        if not ns.db.ftl.enabled then ns.Print("FTL is switched off (/mmt > FTL).") return end
        if arg == "" then
            ns.ClaimFTLLeader()
        else
            local key = ns.IsSelf(arg) and ns.PlayerFull() or ns.Resolve(arg) or ns.Resolve((arg:gsub("%s+", "-")))
            if key then ns.SetFTLLeader(key) else ns.Print("%s is not in your team.", arg) end
        end
    elseif cmd == "scale" then
        local pct = tonumber((arg or ""):match("^(%d+)"))
        if pct then
            local v = ns.SetConfigScale(pct / 100)
            ns.Print("Settings window scale: %d%%.", math.floor(v * 100 + 0.5))
        else
            ns.Print("Settings window scale: %d%%. Use /mmt scale <percent>, e.g. /mmt scale 130 (60 to 200).",
                math.floor(ns.ConfigScale() * 100 + 0.5))
        end
    elseif cmd == "reset" then
        ns.ResetProfile()
        ns.Print("Profile \"%s\" reset to defaults.", ns.CurrentProfileName())
    else
        ns.Print("/mmt - open settings")
        ns.Print("/mmt xp - show/hide the XP window")
        ns.Print("/mmt trade - (re)fill the open trade window for the partner's roles")
        ns.Print("/mmt sync - send the core settings of the active profile to your team (no module settings)")
        local names = {}
        for _, m in ipairs(ns.SyncableModules()) do names[#names + 1] = m.name:lower() end
        if #names > 0 then
            ns.Print("/mmt sync <module> - send only that module's settings (%s)", table.concat(names, ", "))
        end
        ns.Print("/mmt ping - test whispering every team member by name")
        ns.Print("/mmt modules - show installed modules")
        ns.Print("/mmt help - debug tools and guides for writing modules")
        ns.Print("/mmt debug - debug tools (on, off, dump, log, clear, chat, name <text>)")
        ns.Print("/mmt leader [name] - make this character (or <name>) the FTL leader")
        if ns.jambaCommand then ns.Print("/jamba-team iammaster all - same as /mmt leader (Jamba isn't loaded)") end
        ns.Print("/mmt scale <percent> - size of the settings window (e.g. 130)")
        ns.Print("/mmt reset - reset the active profile")
    end
end

---------------------------------------------------------------------------
-- Jamba compatibility: without Jamba, "/jamba-team iammaster all" (from old
-- Jamba macros and key setups) does the same as /mmt leader.
---------------------------------------------------------------------------
local function JambaLoaded()
    local A = C_AddOns or {}
    local num = A.GetNumAddOns or GetNumAddOns
    local info = A.GetAddOnInfo or GetAddOnInfo
    local loaded = A.IsAddOnLoaded or IsAddOnLoaded
    if not (num and info and loaded) then return false end
    for i = 1, num() do
        local name = info(i)
        if type(name) == "string" and name:lower():find("^jamba") and loaded(name) then return true end
    end
    return false
end

ns.OnLogin(function()
    if JambaLoaded() then
        ns.Debug("Jamba is loaded: /jamba-team stays Jamba's")
        return
    end
    ns.jambaCommand = true
    SLASH_MMTJAMBATEAM1 = "/jamba-team"
    SlashCmdList.MMTJAMBATEAM = function(msg)
        local cmd = (ns.Trim(msg or ""):match("^(%S*)") or ""):lower()
        if cmd == "iammaster" then
            SlashCmdList.MMT("leader")
        else
            ns.Print("Of /jamba-team, MMT only knows \"iammaster all\": it makes this character the FTL leader (/mmt leader).")
        end
    end
end)
