-- MMT: team members, roles and item rules (data only; UI in ConfigPages.lua).

local _, ns = ...

---------------------------------------------------------------------------
-- Team members
--   team[key] = { name = "First", last = "Last", class = "MAGE", order = n,
--                 roles = { [roleName] = true } }
---------------------------------------------------------------------------
function ns.IsTeamMember(name) return ns.Resolve(name) ~= nil end

function ns.SortedMembers()
    local t = {}
    for key in pairs(ns.db.team) do t[#t + 1] = key end
    table.sort(t, function(a, b)
        local oa, ob = ns.db.team[a].order or 999, ns.db.team[b].order or 999
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    return t
end

local function Renumber()
    for i, key in ipairs(ns.SortedMembers()) do ns.db.team[key].order = i end
end

local function NextOrder()
    local max = 0
    for _, m in pairs(ns.db.team) do if (m.order or 0) > max then max = m.order end end
    return max + 1
end

function ns.AddMember(key, class, name, last)
    if not key then return false end
    local m = ns.db.team[key]
    if not m then
        m = { roles = {}, order = NextOrder() }
        ns.db.team[key] = m
    end
    if class and class ~= "" then m.class = class end
    if name and name ~= "" then m.name = name end
    if last and last ~= "" then m.last = last end
    ns.Fire("TEAM_CHANGED")
    return true
end

-- Renames an entry, e.g. "Catsi" -> "Catsi-Purrita" once the last name is known.
function ns.MigrateKey(old, new)
    local team = ns.db.team
    if old == new or not team[old] or team[new] then return false end
    team[new], team[old] = team[old], nil
    if ns.status then ns.status[new], ns.status[old] = ns.status[old], nil end
    ns.Debug("MIGRATE team key %s -> %s", ns.Repr(old), ns.Repr(new))
    return true
end

function ns.RemoveMember(key)
    ns.db.team[key] = nil
    if ns.status then ns.status[key] = nil end
    Renumber()
    ns.Fire("TEAM_CHANGED")
end

function ns.MoveMember(key, delta)
    local list = ns.SortedMembers()
    for i, k in ipairs(list) do
        if k == key then
            local j = i + delta
            if j < 1 or j > #list then return end
            list[i], list[j] = list[j], list[i]
            for n, kk in ipairs(list) do ns.db.team[kk].order = n end
            ns.Fire("TEAM_CHANGED")
            return
        end
    end
end

function ns.ClearTeam()
    wipe(ns.db.team)
    ns.Fire("TEAM_CHANGED")
end

-- Adds a unit ("player", "target", "party1", ...). Returns ok, isNew.
function ns.AddUnit(unit)
    if not (UnitExists(unit) and UnitIsPlayer(unit)) then return false end
    local first, last, key = ns.SplitUnit(unit)
    if not key then return false end
    local _, class = UnitClass(unit)
    local existing = ns.Resolve(key)
    if not existing and last then
        -- a member that was added with the first name only
        local byFirst = ns.Resolve(first)
        if byFirst and not ns.db.team[byFirst].last then existing = byFirst end
    end
    if existing and existing ~= key then ns.MigrateKey(existing, key) end
    ns.AddMember(key, class, first, last)
    ns.Debug("ADD %s first=%s last=%s -> key %s", unit, ns.Repr(first), ns.Repr(last), ns.Repr(key))
    return true, existing == nil
end

function ns.AddGroupMembers()
    local added = 0
    local function add(unit)
        local ok, isNew = ns.AddUnit(unit)
        if ok and isNew then added = added + 1 end
    end
    add("player")
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do add("raid" .. i) end
    else
        for i = 1, GetNumSubgroupMembers() do add("party" .. i) end
    end
    return added
end

-- Manual input: "First Last" (or "First-Last"). A trailing own-realm
-- suffix is dropped; all-lowercase input is capitalised.
function ns.AddManual(text)
    text = ns.Trim(text)
    if text == "" then return false, "Enter a name." end
    if text == text:lower() then
        text = text:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end)
    end
    text = ns.StripRealm(text)
    local tokens = {}
    for tok in text:gmatch("[^%s%-]+") do tokens[#tokens + 1] = tok end
    local first, last = tokens[1], tokens[2]
    if not first then return false, "Enter a name." end
    if not last then
        return false, "Use the full name: first and last name (e.g. Gunter McQuiding)."
    end
    local key = first .. "-" .. last
    local existing = ns.Resolve(key)
    ns.Debug("ADD manual %s first=%s last=%s -> key %s", ns.Repr(text), ns.Repr(first), ns.Repr(last), ns.Repr(existing or key))
    if existing then
        ns.AddMember(existing, nil, first, last)
        return false, first .. " " .. last .. " is already in the team."
    end
    return ns.AddMember(key, nil, first, last)
end

---------------------------------------------------------------------------
-- Roles
---------------------------------------------------------------------------
function ns.SortedRoleNames()
    local t = {}
    for name in pairs(ns.db.roles) do t[#t + 1] = name end
    table.sort(t, function(a, b) return a:lower() < b:lower() end)
    return t
end

function ns.AddRole(name)
    name = ns.Trim(name)
    if name == "" then return false, "Enter a role name." end
    for existing in pairs(ns.db.roles) do
        if existing:lower() == name:lower() then return false, "That role already exists." end
    end
    ns.db.roles[name] = { rules = {}, roll = "NEED" }
    ns.Fire("ROLES_CHANGED")
    return name
end

local VALID_ROLLS = { NEED = true, GREED = true, PASS = true, MANUAL = true }

function ns.RoleRoll(name)
    local r = name and ns.db.roles[name]
    return (r and VALID_ROLLS[r.roll] and r.roll) or "NEED"
end

function ns.SetRoleRoll(name, roll)
    local r = name and ns.db.roles[name]
    if not r or not VALID_ROLLS[roll] then return end
    r.roll = roll
    ns.Fire("ROLES_CHANGED")
end

function ns.SetAllMembersRole(role, on)
    if not (role and ns.db.roles[role]) then return end
    for _, m in pairs(ns.db.team) do
        m.roles = m.roles or {}
        m.roles[role] = on and true or nil
    end
    ns.Fire("TEAM_CHANGED")
end

function ns.RemoveRole(name)
    ns.db.roles[name] = nil
    for _, m in pairs(ns.db.team) do
        if m.roles then m.roles[name] = nil end
    end
    ns.Fire("ROLES_CHANGED")
end

function ns.SetMemberRole(key, role, on)
    local m = ns.db.team[key]
    if not m then return end
    m.roles = m.roles or {}
    m.roles[role] = on and true or nil
    ns.Fire("TEAM_CHANGED")
end

function ns.HasRole(key, role)
    local m = ns.db.team[key]
    return m and m.roles and m.roles[role] and true or false
end

function ns.MemberRoleList(key)
    local t = {}
    local m = ns.db.team[key]
    if m and m.roles then
        for role in pairs(m.roles) do
            if ns.db.roles[role] then t[#t + 1] = role end
        end
    end
    table.sort(t)
    return t
end

function ns.MembersWithRole(role)
    local n = 0
    for key in pairs(ns.db.team) do if ns.HasRole(key, role) then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------
-- Item rules of a role
--   { type = "item",    itemID = 2589, name = "Linen Cloth" }
--   { type = "item",    name = "Linen Cloth" }      -- by name, any item ID
--   { type = "quality", quality = 0 }               -- e.g. all grey items
--   { type = "boe" }                                -- all Bind on Equip items
--   { type = "class",   classID = 7 }               -- item type, e.g. Trade Goods
---------------------------------------------------------------------------
local function SameRule(a, b)
    if a.type ~= b.type then return false end
    if a.type == "item" then
        if a.itemID and b.itemID then return a.itemID == b.itemID end
        return a.name and b.name and a.name:lower() == b.name:lower()
    elseif a.type == "quality" then
        return a.quality == b.quality
    elseif a.type == "class" then
        return a.classID == b.classID
    elseif a.type == "group" then
        return a.group == b.group
    end
    return true
end

function ns.AddRule(role, rule)
    local r = ns.db.roles[role]
    if not r then return false, "Select or create a role first." end
    for _, existing in ipairs(r.rules) do
        if SameRule(existing, rule) then return false, "That rule is already on this role." end
    end
    table.insert(r.rules, rule)
    ns.Fire("ROLES_CHANGED")
    return true
end

function ns.RemoveRule(role, index)
    local r = ns.db.roles[role]
    if r and r.rules[index] then
        table.remove(r.rules, index)
        ns.Fire("ROLES_CHANGED")
    end
end

-- Builds a rule from typed text: an item ID, an item link or an item name.
function ns.RuleFromText(text)
    text = ns.Trim(text)
    if text == "" then return nil end
    local id = tonumber(text:match("item:(%d+)") or (text:match("^%d+$") and text))
    if id then return { type = "item", itemID = id, name = (ns.ItemInfo(id)) } end
    return { type = "item", name = text }
end

function ns.QualityName(q)
    return _G["ITEM_QUALITY" .. tostring(q) .. "_DESC"] or ("Quality " .. tostring(q))
end

function ns.ItemClassName(id)
    return (GetItemClassInfo and GetItemClassInfo(id))
        or (C_Item and C_Item.GetItemClassInfo and C_Item.GetItemClassInfo(id))
        or ("Item type " .. tostring(id))
end

-- returns text, icon, r, g, b
function ns.DescribeRule(rule)
    if rule.type == "item" then
        if rule.itemID then
            local name, _, quality = ns.ItemInfo(rule.itemID)
            if not name and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(rule.itemID) end
            local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(rule.itemID))
                or (GetItemIcon and GetItemIcon(rule.itemID))
            local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
            return (name or rule.name or ("Item " .. rule.itemID)), icon or 134400,
                c and c.r or 1, c and c.g or 1, c and c.b or 1
        end
        return tostring(rule.name) .. " |cff888888(by name)|r", 134400, 1, 1, 1
    elseif rule.type == "quality" then
        local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[rule.quality]
        return "All " .. ns.QualityName(rule.quality) .. " items", nil,
            c and c.r or 1, c and c.g or 1, c and c.b or 1
    elseif rule.type == "boe" then
        return "All Bind on Equip items", nil, 1, 1, 1
    elseif rule.type == "class" then
        return "All items of type " .. ns.ItemClassName(rule.classID), nil, 1, 1, 1
    elseif rule.type == "group" then
        local g = ns.ItemGroup(rule.group)
        return "Group: " .. (g and g.name or tostring(rule.group)), nil, 0.85, 0.85, 1
    end
    return "?", nil, 1, 1, 1
end

---------------------------------------------------------------------------
-- Matching items against role rules (used by trading and by modules,
-- e.g. Loot Distribution)
---------------------------------------------------------------------------
local BOE = (Enum and Enum.ItemBind and Enum.ItemBind.OnEquip) or 2

---------------------------------------------------------------------------
-- Item groups: ready-made rules like "Cloth" or "Consumables". An item is in
-- a group when its category (classID) and sub-category (subClassID) match,
-- or when its ID is on the group's list (a fallback for the classic items).
---------------------------------------------------------------------------
local function Set(list) local t = {} for _, v in ipairs(list) do t[v] = true end return t end

ns.ITEM_GROUPS = {
    { header = "Trade goods" },
    { id = "cloth", name = "Cloth", class = 7, subs = { 5 },
      ids = Set({ 2589, 2592, 4306, 4338, 14047, 14256, 2996, 2997, 4305, 4339, 14048 }) },
    { id = "leather", name = "Leather & hides", class = 7, subs = { 6 },
      ids = Set({ 2318, 2319, 4234, 4304, 8170, 783, 4232, 4235, 8169, 8171, 17012, 15417, 15412 }) },
    { id = "metal", name = "Ore, bars & stone", class = 7, subs = { 7 },
      ids = Set({ 2770, 2771, 2772, 3858, 10620, 2775, 2776, 7911, 2840, 3576, 2842, 3575, 3577,
                  3859, 3860, 6037, 12359, 2835, 2836, 2838, 7912, 12365 }) },
    { id = "herbs", name = "Herbs", class = 7, subs = { 9 },
      ids = Set({ 765, 2447, 785, 2449, 2450, 2452, 3820, 2453, 3355, 3369, 3356, 3357, 3818, 3821,
                  3358, 3819, 4625, 8831, 8836, 8838, 8839, 8845, 8846, 13464, 13463, 13465, 13466,
                  13467, 13468 }) },
    { id = "cooking", name = "Cooking ingredients", class = 7, subs = { 8 } },
    { id = "elemental", name = "Elemental", class = 7, subs = { 10 } },
    { id = "enchanting", name = "Enchanting materials", class = 7, subs = { 12 },
      ids = Set({ 10940, 11083, 11137, 11176, 16204, 10938, 10939, 10998, 11082, 11134, 11135,
                  11174, 11175, 16202, 16203, 10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344, 20725 }) },
    { id = "parts", name = "Parts, devices & explosives", class = 7, subs = { 1, 2, 3 } },
    { id = "tradegoods", name = "All trade goods", class = 7 },
    { header = "Consumables" },
    { id = "consumables", name = "All consumables", class = 0 },
    { id = "potions", name = "Potions", class = 0, subs = { 1 } },
    { id = "elixirs", name = "Elixirs & flasks", class = 0, subs = { 2, 3 } },
    { id = "food", name = "Food & drink", class = 0, subs = { 5 } },
    { id = "bandages", name = "Bandages", class = 0, subs = { 7 } },
    { id = "scrolls", name = "Scrolls", class = 0, subs = { 4 } },
    { id = "enhancements", name = "Item enhancements", class = 0, subs = { 6 } },
    { header = "Other" },
    { id = "reagents", name = "Reagents", class = 5 },
    { id = "recipes", name = "Recipes", class = 9 },
    { id = "gems", name = "Gems", class = 3 },
    { id = "containers", name = "Bags", class = 1 },
    { id = "projectiles", name = "Arrows & bullets", class = 6 },
    { id = "weapons", name = "Weapons", class = 2 },
    { id = "armor", name = "Armor", class = 4 },
    { id = "misc", name = "Miscellaneous", class = 15 },
}

local groupsById = {}
for _, g in ipairs(ns.ITEM_GROUPS) do
    if g.id then
        groupsById[g.id] = g
        if g.subs then g.subSet = Set(g.subs) end
    end
end
function ns.ItemGroup(id) return groupsById[id] end

function ns.InGroup(group, itemID, classID, subClassID)
    if not group then return false end
    if group.ids and itemID and group.ids[itemID] then return true end
    if classID ~= group.class then return false end
    return not group.subSet or (subClassID ~= nil and group.subSet[subClassID] == true)
end

-- category data of an item; works for items the client hasn't loaded yet
function ns.ItemCategory(item)
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if instant then
        local itemID, _, _, _, _, classID, subClassID = instant(item)
        if classID then return itemID, classID, subClassID end
    end
    local _, _, _, _, _, _, _, _, _, _, _, classID, subClassID = ns.ItemInfo(item)
    return nil, classID, subClassID
end

function ns.RuleMatches(rule, itemID, name, quality, classID, bindType, subClassID)
    local t = rule.type
    if t == "item" then
        if rule.itemID then return rule.itemID == itemID end
        return rule.name and name and rule.name:lower() == name:lower()
    elseif t == "quality" then
        return quality == rule.quality
    elseif t == "boe" then
        return bindType == BOE
    elseif t == "class" then
        return classID == rule.classID
    elseif t == "group" then
        return ns.InGroup(groupsById[rule.group], itemID, classID, subClassID)
    end
    return false
end

-- How specific a matching rule is: an exact item beats an item group, a
-- group beats an item class, and those beat Bind on Equip or a quality.
local SPECIFIC = { item = 4, group = 3, class = 2, boe = 1, quality = 1 }

-- Does any rule of the role match the item (link or ID)? Second value: the
-- most specific matching rule (SPECIFIC), 0 if none matches.
function ns.RoleWantsItem(roleName, item)
    local role = ns.db.roles[roleName]
    if not role then return false, 0 end
    local itemID = tonumber(tostring(item):match("item:(%d+)") or item)
    local name, _, quality, _, _, _, _, _, _, _, _, classID, subClassID, bindType = ns.ItemInfo(item)
    if not classID then _, classID, subClassID = ns.ItemCategory(item) end
    local best = 0
    for _, rule in ipairs(role.rules) do
        if ns.RuleMatches(rule, itemID, name, quality, classID, bindType, subClassID) then
            best = math.max(best, SPECIFIC[rule.type] or 1)
        end
    end
    return best > 0, best
end

-- Returns "item" if an explicit item rule matches, "rule" if a category/quality/BoE
-- rule matches, or nil. Explicit item rules take priority over generic rules.
function ns.RoleMatchKind(roleName, item)
    local _, best = ns.RoleWantsItem(roleName, item)
    if best == 4 then return "item" elseif best > 0 then return "rule" end
    return nil
end

-- Team members whose roles want the item, plus the matching roles. The
-- members with the most specific rule come first ("Cloth" before "white
-- items"), team order among equals. Roles set to Pass are excluded.
function ns.MembersForItem(item)
    local keys, roles, score, pos = {}, {}, {}, {}
    for i, key in ipairs(ns.SortedMembers()) do
        local best, bestRole, passBest = 0, nil, 0
        for _, role in ipairs(ns.MemberRoleList(key)) do
            local wants, how = ns.RoleWantsItem(role, item)
            if wants then
                if ns.RoleRoll(role) == "PASS" then
                    passBest = math.max(passBest, how)
                elseif how > best then
                    best, bestRole = how, role
                end
            end
        end
        if best > 0 and best > passBest then
            keys[#keys + 1] = key
            roles[key], score[key], pos[key] = bestRole, best, i
        end
    end
    table.sort(keys, function(a, b)
        if score[a] ~= score[b] then return score[a] > score[b] end
        return pos[a] < pos[b]
    end)
    return keys, roles
end
