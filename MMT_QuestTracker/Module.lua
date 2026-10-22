-- MMT module: Quest Tracker.
--
-- * Replaces the Blizzard quest tracker with a team tracker:
--     Zone > [Level] Quest > Objective > progress of every team member.
--   Every level can be collapsed. Team progress comes over the core's
--   team communication (Data.lua).
-- * Quest automation (moved here from Core > Automations): accept, turn in,
--   announce "ready for turn-in", share new quests, announce quests that
--   can't be shared, abandon a quest on the whole team (Automation.lua).

local _, mod = ...
local MMT = MMT

local function Font(size, r, g, b)
    return { font = "Friz Quadrata", size = size, color = { r = r, g = g, b = b } }
end

local M = MMT.NewModule({
    name = "QuestTracker",
    title = "Quest Tracker",
    description = "Team quest tracker (zone, quest, objective, progress per team member) and quest automation.",
    sync = true,   -- /mmt sync <module> and the Sync button share M.db with the team
    syncExclude = { "movedFromCore" },   -- internal migration flag stays on each client
    defaults = {
        -- automation (the first five were in Core > Automations > Quests)
        acceptNPC       = true,
        acceptShared    = true,
        turnIn          = true,
        skipTrivial     = true,
        announce        = true,   -- "[Quest] is ready for turn-in." in party chat
        autoShare       = true,   -- share newly accepted quests with the group
        announceNoShare = true,   -- "[Quest] can't be shared." in party chat
        abortTeam       = true,   -- abandoning asks to abandon on the whole team
        announceStarter = true,   -- "Looted [Item] - it starts a quest!" in party chat
        markRewards     = true,   -- coin on the best-selling reward, arrow on upgrades

        -- tracker
        show          = true,
        hideBlizzard  = true,
        locked        = false,
        clickThrough  = false,
        showHeader    = true,
        onlyWatched   = false,    -- only quests you track in the quest log
        teamQuests    = true,     -- also quests only teammates have
        showMissing   = true,     -- members who don't have the quest
        showOffline   = false,    -- members who are offline (last known progress)
        classColors   = true,     -- member names in class colour
        levelColors   = true,     -- [level] in quest difficulty colour
        width         = 260,
        maxHeight     = 450,
        scale         = 1,
        indent        = 10,
        align         = "LEFT",
        outline       = "OUTLINE",
        bg            = { r = 0, g = 0, b = 0 },
        bgAlpha       = 0.35,
        point         = { "TOPRIGHT", "TOPRIGHT", -90, -240 },
        fonts = {
            zone      = Font(13, 1, 0.82, 0),
            quest     = Font(12, 1, 1, 1),
            objective = Font(11, 0.85, 0.85, 0.85),
            member    = Font(10, 0.7, 0.7, 0.7),
        },
    },
})
mod.M = M

mod.LEVELS = {
    { key = "zone", title = "Zone" },
    { key = "quest", title = "Quest" },
    { key = "objective", title = "Objective" },
    { key = "member", title = "Team member" },
}

-- The quest settings of older profiles (Core > Automations) are copied once.
local MOVED = { "acceptNPC", "acceptShared", "turnIn", "skipTrivial", "announce" }

local function MigrateCoreSettings()
    local old = MMT.db and MMT.db.quests
    if M.db.movedFromCore then return end
    if type(old) == "table" then
        for _, k in ipairs(MOVED) do
            if type(old[k]) == "boolean" then M.db[k] = old[k] end
        end
        MMT.db.quests = nil
        M:Debug("quest settings copied from Core > Automations")
    end
    M.db.movedFromCore = true
end

function M.OnEnable()
    MigrateCoreSettings()
    if mod.OnEnableData then mod.OnEnableData() end
    if mod.OnEnableTracker then mod.OnEnableTracker() end
end

function M.OnDisable()
    if mod.OnDisableTracker then mod.OnDisableTracker() end
end

function M.OnProfileChanged()
    MigrateCoreSettings()
    if mod.Layout then mod.Layout() end
    if mod.UpdateBlizzardTracker then mod.UpdateBlizzardTracker() end
end

---------------------------------------------------------------------------
-- Shared helpers
---------------------------------------------------------------------------
function mod.GroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and not IsInGroup(LE_PARTY_CATEGORY_HOME) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

function mod.SayGroup(msg)
    local channel = mod.GroupChannel()
    if not channel then return false end
    local ok, err = pcall(SendChatMessage, msg, channel)
    if not ok then M:Debug("SendChatMessage failed: %s", tostring(err)) end
    return ok
end

function mod.QuestLink(questID, title)
    if type(questID) == "number" and GetQuestLink then
        local ok, link = pcall(GetQuestLink, questID)
        if ok and type(link) == "string" and not MMT.IsSecret(link) and link:find("|Hquest:", 1, true) then return link end
    end
    return "[" .. tostring(title or questID) .. "]"
end
