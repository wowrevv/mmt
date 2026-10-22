-- MMT Loot Distribution: settings page (under MODULES in /mmt) and debug report.

local _, mod = ...
local MMT = MMT
local M = mod.M
local UI = MMT.UI
local H = MMT.ConfigHelpers
local COL_W, COL2_X = H.COL_W, H.COL2_X
local StatusLine = H.StatusLine

local function Opt(key)
    return function() return M.db[key] end,
           function(v) M.db[key] = v end
end

M.Page = function(_, page)
    local status

    -- left: loot method & group loot rolls --------------------------------
    local L = UI.Column(page, 0, 0, COL_W)
    L:Header("Loot method")
    local ga, sa = Opt("autoMethod")
    L:Check("Set loot method automatically", ga, sa,
        "When a group forms or one of your team characters becomes leader, that character sets the method and threshold below. Only the group leader can change loot settings.")
    local gm, sm = Opt("method")
    L:Cycle("Method", {
        { value = "freeforall",      text = "Free for All" },
        { value = "roundrobin",      text = "Round Robin" },
        { value = "group",           text = "Group Loot" },
        { value = "needbeforegreed", text = "Need before Greed" },
        { value = "master",          text = "Master Looter" },
    }, gm, sm)
    local gog, sog = Opt("outsiderGroup")
    L:Check("Group Loot when outsiders join", gog, sog,
        "While a player who isn't in your team list is in the group, the loot method is Group Loot. When they leave, the method above is set again.")
    local qualities = {}
    for q = 0, 5 do qualities[#qualities + 1] = { value = q, text = MMT.QualityName(q) } end
    local gt, st = Opt("threshold")
    L:Cycle("Threshold", qualities, gt, st)
    local gl, sl = Opt("looter")
    local looter = L:Cycle("Looter / receiver", function()
        local l = { { value = "LEADER", text = "Group leader" } }
        for _, key in ipairs(MMT.SortedMembers()) do l[#l + 1] = { value = key, text = MMT.FirstName(key) } end
        return l
    end, gl, sl)
    UI.Tooltip(looter, "Looter / receiver",
        "Master Looter: who becomes the master looter.\nGroup Loot: who rolls Greed (while others Pass) when 'No role wants it' is set to 'To looter / leader'.")
    MMT.HoverMember(looter, function() return M.db.looter ~= "LEADER" and M.db.looter or nil end)
    L:Space(4)
    L:Button("Apply now", function()
        local ok, err = mod.ApplyLootSettings(true)
        status.Show_(ok and "Loot settings applied." or err, not ok)
    end)
    status = StatusLine(page)
    status:SetWidth(COL_W)
    L:Add(status, 20)
    local current = L:Note("")

    L:Header("Group loot rolls")
    local groupOnly = {}
    local gar, sar = Opt("autoRoll")
    L:Check("Roll automatically on Group Loot", gar, sar,
        "Automatically rolls Need, Greed or Pass on loot roll popups using your Roles (see the Roles tab to set Need/Greed/Pass/Manual per role and drop in items), quest log and the settings on the right. Auto-confirms Bind on Pickup rolls made by MMT.")
    local grm, srm = Opt("roleMode")
    groupOnly[#groupOnly + 1] = L:Cycle("Multiple role members", {
        { value = "ALL",   text = "All with role roll" },
        { value = "ORDER", text = "First in team order" },
        { value = "RR",    text = "Round robin" },
    }, grm, srm)
    UI.Tooltip(groupOnly[#groupOnly], "Multiple role members",
        "When several team members in your group share the matching role:\n\n- All with role roll: all of them roll the role's action (Need/Greed), others Pass.\n- First in team order: only the first one with free bag slots rolls, others Pass (like Master Looter).\n- Round robin: takes turns among them per item, others Pass.")
    local gbop, sbop = Opt("rollBoP")
    groupOnly[#groupOnly + 1] = L:Check("Roll on Bind on Pickup items", gbop, sbop,
        "Items added explicitly by ID or name to a Role always roll on Bind on Pickup drops.\nTick this to also roll on Bind on Pickup items for category/quality roles and 'No role wants it'.")

    L:Header("Passing on loot")
    local gp, sp = Opt("autoPass")
    L:Check("Automatically pass on loot rolls", gp, sp,
        "With Group Loot or Need before Greed, every character passes on its rolls by itself, except the leader chosen below, who rolls as usual. Set it on every client.")
    local go, so = Opt("optOut")
    L:Check("Enable 'Pass on Loot' while in a group", go, so,
        "Switches on the game's \"Pass on Loot\" for every character in a group except the leader chosen below, so they don't get loot (rolls and Round Robin). Switched off again when the character leaves the group or becomes the leader. Set it on every client.")
    local ge, se = Opt("passExcept")
    L:Cycle("Unless I'm the", {
        { value = "GROUP", text = "Group leader" },
        { value = "FTL", text = "FTL leader (character you play)" },
    }, ge, se)

    -- right: roles, unassigned & quest items ------------------------------
    local R = UI.Column(page, COL2_X, 0, COL_W)
    R:Header("Loot by roles")
    local gr, sr = Opt("byRoles")
    R:Check("Use roles for loot", gr, sr,
        "Master Looter: items at or above the threshold go to the team member whose roles want them.\nGroup Loot: members of the matching role roll that role's action (Need, Greed, Pass or Manual on the Roles tab) while other team members roll Pass.")
    local gmr, smr = Opt("multiRole")
    local multiRole = R:Cycle("Several have the role", {
        { value = "FILL", text = "Fill up by team order" },
        { value = "RR", text = "Round robin" },
    }, gmr, smr)
    UI.Tooltip(multiRole, "Several have the role (Master Looter)",
        "Fill up by team order: the first of them in team order gets everything until their bags are full (keeping the free slots below), then the next. Round robin: they get the items in turns.")
    local gnr, snr = Opt("noRoom")
    local noRoom = R:Cycle("Role members have no room", {
        { value = "LEAVE", text = "Leave for manual" },
        { value = "RR", text = "Next team member with room" },
        { value = "SELF", text = "Give to master looter" },
    }, gnr, snr)
    UI.Tooltip(noRoom, "Role members have no room (Master Looter)",
        "When a role wants the item but none of its members has room: leave it in the loot window, give it to the next team member with room (round robin, keeping the free slots), or to the master looter. Quest items are handled by their own round robin.")
    local gres, sres = Opt("reserve")
    R:Slider("Keep free bag slots", 0, 20, 1, gres, sres)
    local gu, su = Opt("unassigned")
    local unassigned = R:Cycle("No role wants it", {
        { value = "LEAVE", text = "Leave for manual" },
        { value = "SELF",  text = "To looter / leader" },
        { value = "RR",    text = "Round robin to the team" },
        { value = "GREED", text = "Everyone rolls Greed" },
        { value = "NEED",  text = "Everyone rolls Need" },
        { value = "PASS",  text = "Everyone Passes" },
    }, gu, su)
    UI.Tooltip(unassigned, "No role wants it",
        "What happens when no Role matches an item:\n\n- Leave for manual: leave in the loot window / leave roll popup open.\n- To looter / leader: Master Looter gives to self; Group Loot has the chosen Looter/leader roll Greed while others Pass.\n- Round robin to the team: gives or rolls Greed in turns across the team.\n- Everyone rolls Greed / Need / Passes: Group Loot roll for all team members (respecting bag reserve).")
    local grr, srr = Opt("rrNotice")
    R:Check("Say so in chat (round robin)", grr, srr,
        "Prints \"[Item] is not part of any role or rule, so it was given round robin to <Name>.\" (only for you). Round robin keeps the free bag slots above; quest items are never part of it.")
    local grep, srep = Opt("report")
    R:Check("Report in chat", grep, srep, "Prints each item given or rolled on and the loot settings that were applied (only for you).")
    R:Note("Tip: on the Roles tab you can drop in specific items or pick item groups, tick team members (or click All), and choose whether that role rolls Need, Greed, Pass or Manual.")

    R:Header("Quest items")
    local gq, sq = Opt("questRR")
    R:Check("Auto-handle quest items", gq, sq,
        "Master Looter: quest items go to team members who still need them in turns (free bag slots reserve doesn't apply).\nGroup Loot: characters with an open quest objective for the item roll Need; characters who finished the objective roll Pass.")

    page.OnRefresh = function()
        local method = mod.GetMethod()
        local text = IsInGroup() and ("Current: " .. (mod.METHOD_TEXT[method] or tostring(method)))
            or "Not in a group."
        if IsInGroup() and method and method ~= "freeforall" then
            local t = mod.GetThreshold()
            if t then text = text .. ", from " .. MMT.QualityName(t) end
        end
        if IsInGroup() and method == "master" then
            text = text .. (mod.IsMasterLooter() and " (you are master looter)" or "")
        end
        current:SetText(text)
        local rollsOn = M.db.autoRoll and true or false
        for _, w in ipairs(groupOnly) do w:SetAlpha(rollsOn and 1 or 0.4) end
    end
    M:On("PARTY_LOOT_METHOD_CHANGED", function() if page:IsVisible() then page.OnRefresh() end end)
end

function M.Report(_, add)
    local method, partyIndex, raidIndex = mod.GetMethod()
    add(("-- Loot Distribution  current=%s partyML=%s raidML=%s threshold=%s isMaster=%s leader=%s"):format(
        tostring(method), tostring(partyIndex), tostring(raidIndex), tostring(mod.GetThreshold()),
        tostring(mod.IsMasterLooter()), tostring(IsInGroup() and UnitIsGroupLeader("player"))))
    add(("settings: auto=%s outsiderGroup=%s method=%s threshold=%s looter=%s byRoles=%s roleMode=%s multiRole=%s noRoom=%s reserve=%s unassigned=%s rrNotice=%s autoRoll=%s rollBoP=%s autoPass=%s optOut=%s (game: %s) passExcept=%s questRR=%s"):format(
        tostring(M.db.autoMethod), tostring(M.db.outsiderGroup), tostring(M.db.method), tostring(M.db.threshold), tostring(M.db.looter),
        tostring(M.db.byRoles), tostring(M.db.roleMode), tostring(M.db.multiRole), tostring(M.db.noRoom), tostring(M.db.reserve), tostring(M.db.unassigned),
        tostring(M.db.rrNotice), tostring(M.db.autoRoll), tostring(M.db.rollBoP),
        tostring(M.db.autoPass), tostring(M.db.optOut),
        tostring(GetOptOutOfLoot and GetOptOutOfLoot()), tostring(M.db.passExcept), tostring(M.db.questRR)))
    add("quest round robin=" .. tostring(M.db.questRR))
    for itemID, key in pairs(M.store.questRR or {}) do add(("  quest item %s: last given to %s"):format(tostring(itemID), MMT.Repr(key))) end
    for itemID, key in pairs(M.store.groupRR or {}) do add(("  group RR item %s: last rolled by %s"):format(tostring(itemID), MMT.Repr(key))) end
    for _, key in ipairs(MMT.SortedMembers()) do
        local s = MMT.status[key]
        add(("  %s free=%s roles=[%s]"):format(MMT.Repr(key), tostring(s and s.free), table.concat(MMT.MemberRoleList(key), ",")))
    end
end
