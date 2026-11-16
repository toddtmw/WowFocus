-- WoWFocus: hide world-quest noise, surface the next campaign quest.
-- Every Blizzard API call is wrapped in pcall so an API change silences
-- a feature rather than throwing a Lua error.

local ADDON_NAME = "WoWFocus"

-- ── Saved-variable defaults ────────────────────────────────────────────────
local defaults = {
    enabled       = true,
    hideMapPins   = true,
    hideTracker   = true,
    showNext      = true,
}

-- ── State ──────────────────────────────────────────────────────────────────
local cfg  -- reference to the live saved-variable table, set on ADDON_LOADED
local nextFrame  -- the "Next: <quest>" display frame

-- ── Utility ───────────────────────────────────────────────────────────────
local function applyDefaults(t, d)
    for k, v in pairs(d) do
        if t[k] == nil then t[k] = v end
    end
end

local function safeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        -- Surface errors only during a /focus debug session; silent otherwise.
        -- print(ADDON_NAME .. " error: " .. tostring(err))
    end
    return ok
end

-- ── World-map pin suppression ──────────────────────────────────────────────
-- ShouldShowQuest returns false for any quest we want hidden.
-- We patch every registered data provider after the map has initialised.

local function isWorldQuest(questID)
    local ok, qtype = pcall(C_QuestLog.GetQuestClassification, questID)
    if not ok then return false end
    -- Classification 2 = WorldQuest (Enum.QuestClassification.WorldQuest)
    return qtype == 2
end

local function isBonusObjective(questID)
    local ok, result = pcall(C_QuestLog.IsQuestBounty, questID)
    -- IsQuestBounty doesn't exist in all patches; fall back to false
    if not ok then return false end
    return result == true
end

local function shouldHideQuest(questID)
    if not (cfg and cfg.enabled and cfg.hideMapPins) then return false end
    if isWorldQuest(questID) then return true end
    if isBonusObjective(questID) then return true end
    -- Daily / weekly: classification 7 = Daily, 9 = Weekly
    local ok, qtype = pcall(C_QuestLog.GetQuestClassification, questID)
    if ok and (qtype == 7 or qtype == 9) then return true end
    return false
end

local origShouldShowQuest = {}  -- keyed by provider object

local function patchProvider(provider)
    if origShouldShowQuest[provider] then return end  -- already patched
    local orig = provider.ShouldShowQuest
    if type(orig) ~= "function" then return end
    origShouldShowQuest[provider] = orig
    provider.ShouldShowQuest = function(self, questID)
        if shouldHideQuest(questID) then return false end
        return orig(self, questID)
    end
end

local function patchAllDataProviders()
    -- WorldMapFrame may not exist in all contexts (e.g. loading screen).
    safeCall(function()
        if not WorldMapFrame then return end
        local canvas = WorldMapFrame.ScrollContainer and
                       WorldMapFrame.ScrollContainer.Child
        if not canvas then return end
        for _, child in ipairs({canvas:GetChildren()}) do
            if child.ShouldShowQuest then
                patchProvider(child)
            end
        end
        -- Also iterate registered data providers if the API exists
        if WorldMapFrame.dataProviders then
            for provider in pairs(WorldMapFrame.dataProviders) do
                if provider.ShouldShowQuest then
                    patchProvider(provider)
                end
            end
        end
    end)
end

-- ── Objective-tracker world-quest removal ─────────────────────────────────
local function removeWorldQuestsFromTracker()
    if not (cfg and cfg.enabled and cfg.hideTracker) then return end
    safeCall(function()
        local numEntries = C_QuestLog.GetNumQuestLogEntries()
        for i = 1, numEntries do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader then
                if isWorldQuest(info.questID) then
                    C_QuestLog.RemoveWorldQuestWatch(info.questID)
                end
            end
        end
    end)
end

-- ── "Next campaign quest" frame ────────────────────────────────────────────
local function findNextCampaignQuest()
    local result = nil
    safeCall(function()
        local numEntries = C_QuestLog.GetNumQuestLogEntries()
        for i = 1, numEntries do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and not info.isComplete then
                local ok, cls = pcall(C_QuestLog.GetQuestClassification, info.questID)
                -- Classification 1 = Campaign (Enum.QuestClassification.Campaign)
                if ok and cls == 1 then
                    result = info.title
                    break
                end
            end
        end
    end)
    return result
end

local function updateNextFrame()
    if not nextFrame then return end
    if not (cfg and cfg.enabled and cfg.showNext) then
        nextFrame:Hide()
        return
    end
    local title = findNextCampaignQuest()
    if title then
        nextFrame.text:SetText("Next: " .. title)
        nextFrame:Show()
    else
        nextFrame:Hide()
    end
end

local function createNextFrame()
    if nextFrame then return end
    local f = CreateFrame("Frame", "WoWFocusNextFrame", UIParent)
    f:SetSize(300, 28)
    f:SetPoint("TOP", UIParent, "TOP", 0, -60)
    f:SetFrameStrata("MEDIUM")

    -- Background
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0, 0, 0, 0.55)

    -- Text
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.text:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.text:SetTextColor(1, 0.82, 0)  -- quest-gold

    -- Make it draggable
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)

    -- Tooltip hint
    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("WoWFocus – next campaign quest\nDrag to reposition.", nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    nextFrame = f
end

-- ── Apply / unapply all features ──────────────────────────────────────────
local function applyAll()
    patchAllDataProviders()
    removeWorldQuestsFromTracker()
    createNextFrame()
    updateNextFrame()
    -- Refresh the map if it is open
    safeCall(function()
        if WorldMapFrame and WorldMapFrame:IsShown() then
            WorldMapFrame:RefreshAllDataProviders()
        end
    end)
end

-- ── Event handling ────────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("WORLD_MAP_OPEN")

eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        WoWFocusDB = WoWFocusDB or {}
        applyDefaults(WoWFocusDB, defaults)
        cfg = WoWFocusDB
        print("|cff00ff00WoWFocus|r loaded. /wf for options.")

    elseif event == "PLAYER_ENTERING_WORLD" then
        applyAll()

    elseif event == "QUEST_LOG_UPDATE" then
        removeWorldQuestsFromTracker()
        updateNextFrame()

    elseif event == "WORLD_MAP_OPEN" then
        patchAllDataProviders()
        safeCall(function()
            if WorldMapFrame then
                WorldMapFrame:RefreshAllDataProviders()
            end
        end)
    end
end)

-- ── Slash commands ────────────────────────────────────────────────────────
local function printStatus()
    local function yn(b) return b and "|cff00ff00on|r" or "|cffff4444off|r" end
    print("|cff00ff00WoWFocus|r  enabled=" .. yn(cfg.enabled)
        .. "  map="     .. yn(cfg.hideMapPins)
        .. "  tracker=" .. yn(cfg.hideTracker)
        .. "  next="    .. yn(cfg.showNext))
end

local subcommands = {
    -- toggle the whole addon
    [""]        = function() cfg.enabled = not cfg.enabled ; applyAll() ; printStatus() end,
    ["on"]      = function() cfg.enabled = true  ; applyAll() ; printStatus() end,
    ["off"]     = function() cfg.enabled = false ; applyAll() ; printStatus() end,
    -- per-feature toggles
    ["map"]     = function() cfg.hideMapPins = not cfg.hideMapPins ; applyAll() ; printStatus() end,
    ["tracker"] = function() cfg.hideTracker = not cfg.hideTracker ; removeWorldQuestsFromTracker() ; printStatus() end,
    ["next"]    = function() cfg.showNext    = not cfg.showNext    ; updateNextFrame() ; printStatus() end,
    -- misc
    ["status"]  = printStatus,
    ["reset"]   = function()
        WoWFocusDB = {}
        applyDefaults(WoWFocusDB, defaults)
        cfg = WoWFocusDB
        applyAll()
        print("|cff00ff00WoWFocus|r settings reset.")
    end,
    ["help"]    = function()
        print("|cff00ff00WoWFocus commands:|r  (/wf or /wowfocus)")
        print("  /wf           – toggle addon on/off")
        print("  /wf on|off    – explicit on/off")
        print("  /wf map       – toggle world-map pin hiding")
        print("  /wf tracker   – toggle tracker world-quest removal")
        print("  /wf next      – toggle 'Next campaign quest' frame")
        print("  /wf status    – show current settings")
        print("  /wf reset     – restore defaults")
    end,
}

SLASH_WOWFOCUS1 = "/wf"
SLASH_WOWFOCUS2 = "/wowfocus"
SlashCmdList["WOWFOCUS"] = function(msg)
    if not cfg then
        print("|cff00ff00WoWFocus|r is still loading.")
        return
    end
    local cmd = msg:match("^%s*(%S*)") or ""
    cmd = cmd:lower()
    local fn = subcommands[cmd]
    if fn then
        fn()
    else
        print("|cff00ff00WoWFocus|r: unknown command '" .. cmd .. "'. Try /focus help")
    end
end
