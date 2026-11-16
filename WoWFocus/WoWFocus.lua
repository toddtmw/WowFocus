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
local cfg        -- reference to the live saved-variable table, set on ADDON_LOADED
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
        -- Uncomment to debug: print(ADDON_NAME .. " err: " .. tostring(err))
    end
    return ok
end

-- ── Quest-type helpers ────────────────────────────────────────────────────
local function isWorldQuest(questID)
    local ok, result = pcall(C_QuestLog.IsWorldQuest, questID)
    if ok and result then return true end
    local ok2, cls = pcall(C_QuestLog.GetQuestClassification, questID)
    if ok2 and Enum.QuestClassification and cls == Enum.QuestClassification.WorldQuest then
        return true
    end
    return false
end

local function isBonusObjective(questID)
    local ok, result = pcall(C_QuestLog.IsQuestTask, questID)
    if ok and result then return true end
    local ok2, cls = pcall(C_QuestLog.GetQuestClassification, questID)
    if ok2 and Enum.QuestClassification and cls == Enum.QuestClassification.BonusObjective then
        return true
    end
    return false
end

local function isRecurring(questID)
    local ok, cls = pcall(C_QuestLog.GetQuestClassification, questID)
    if not ok or not Enum.QuestClassification then return false end
    return cls == Enum.QuestClassification.Recurring
end

local function shouldHideQuest(questID)
    if not (cfg and cfg.enabled and cfg.hideMapPins) then return false end
    return isWorldQuest(questID) or isBonusObjective(questID) or isRecurring(questID)
end

-- ── ShouldShowQuest patching (covers the 2 providers that use it) ──────────
local patchedProviders = {}

local function patchProvider(provider)
    if not provider or patchedProviders[provider] then return end
    local orig = provider.ShouldShowQuest
    if type(orig) ~= "function" then return end
    patchedProviders[provider] = true
    provider.ShouldShowQuest = function(self, questID)
        if shouldHideQuest(questID) then return false end
        return orig(self, questID)
    end
end

local addDataProviderHooked = false
local function hookAddDataProvider()
    if addDataProviderHooked or not WorldMapFrame then return end
    safeCall(function()
        hooksecurefunc(WorldMapFrame, "AddDataProvider", function(_, provider)
            patchProvider(provider)
        end)
        addDataProviderHooked = true
    end)
end

-- ── Pin-pool hiding (primary approach for providers without ShouldShowQuest) ──
-- After any map refresh, walk every active pin in every pool and hide ones
-- whose questID is a world quest / bonus objective / recurring quest.

local hidePinsPending = false

local function hidePinsOnMap()
    if not (cfg and cfg.enabled and cfg.hideMapPins) then return end
    safeCall(function()
        if not WorldMapFrame then return end

        -- Method 1: iterate the map's pin pools (keyed by template name)
        if WorldMapFrame.pinPools then
            for _, pool in pairs(WorldMapFrame.pinPools) do
                if pool.EnumerateActive then
                    for pin in pool:EnumerateActive() do
                        local qid = pin.questID or (pin.questInfo and pin.questInfo.questId)
                        if qid and shouldHideQuest(qid) then
                            pin:Hide()
                        end
                    end
                end
            end
        end

        -- Method 2: canvas children (catches pools using different structures)
        local canvas = WorldMapFrame.ScrollContainer
                    and WorldMapFrame.ScrollContainer.Child
        if canvas then
            for _, frame in ipairs({canvas:GetChildren()}) do
                local qid = frame.questID or (frame.questInfo and frame.questInfo.questId)
                if qid and shouldHideQuest(qid) then
                    frame:Hide()
                end
            end
        end
    end)
end

local function scheduleHidePins()
    if hidePinsPending then return end
    hidePinsPending = true
    C_Timer.After(0, function()
        hidePinsPending = false
        hidePinsOnMap()
    end)
end

local mapRefreshHooked = false
local function hookMapRefresh()
    if mapRefreshHooked then return end
    safeCall(function()
        -- Fire after every full map refresh.
        hooksecurefunc(WorldMapFrame, "RefreshAllDataProviders", scheduleHidePins)
        -- Also fire after each individual provider refreshes (catches partial refreshes).
        if MapCanvasDataProviderMixin then
            hooksecurefunc(MapCanvasDataProviderMixin, "RefreshAllData", scheduleHidePins)
        end
        mapRefreshHooked = true
    end)
end

-- ── Sweep registered data providers for ShouldShowQuest ───────────────────
local function patchAllDataProviders()
    safeCall(function()
        hookAddDataProvider()
        hookMapRefresh()
        if not WorldMapFrame then return end
        if WorldMapFrame.dataProviders then
            for provider in pairs(WorldMapFrame.dataProviders) do
                patchProvider(provider)
            end
        end
        local canvas = WorldMapFrame.ScrollContainer
                    and WorldMapFrame.ScrollContainer.Child
        if canvas then
            for _, child in ipairs({canvas:GetChildren()}) do
                patchProvider(child)
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
            if info and not info.isHeader and isWorldQuest(info.questID) then
                C_QuestLog.RemoveWorldQuestWatch(info.questID)
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
                if ok and Enum.QuestClassification
                   and cls == Enum.QuestClassification.Campaign then
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

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0, 0, 0, 0.55)

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.text:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.text:SetTextColor(1, 0.82, 0)

    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)

    f:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("WoWFocus – next campaign quest\nDrag to reposition.",
                            nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)

    nextFrame = f
end

-- ── Apply all features ────────────────────────────────────────────────────
local function applyAll()
    patchAllDataProviders()
    removeWorldQuestsFromTracker()
    createNextFrame()
    updateNextFrame()
    scheduleHidePins()
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
        scheduleHidePins()
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
    [""]        = function() cfg.enabled = not cfg.enabled ; applyAll() ; printStatus() end,
    ["on"]      = function() cfg.enabled = true  ; applyAll() ; printStatus() end,
    ["off"]     = function() cfg.enabled = false ; applyAll() ; printStatus() end,
    ["map"]     = function() cfg.hideMapPins = not cfg.hideMapPins ; applyAll() ; printStatus() end,
    ["tracker"] = function() cfg.hideTracker = not cfg.hideTracker ; removeWorldQuestsFromTracker() ; printStatus() end,
    ["next"]    = function() cfg.showNext = not cfg.showNext ; updateNextFrame() ; printStatus() end,
    ["status"]  = printStatus,
    ["debug"]   = function()
        print("=== WoWFocus debug ===")
        if Enum and Enum.QuestClassification then
            local vals = {}
            for k, v in pairs(Enum.QuestClassification) do
                vals[#vals+1] = k .. "=" .. tostring(v)
            end
            print("  QuestClassification: " .. table.concat(vals, "  "))
        else
            print("  Enum.QuestClassification: missing")
        end
        print("  IsWorldQuest API: " .. type(C_QuestLog.IsWorldQuest))
        print("  IsQuestTask  API: " .. type(C_QuestLog.IsQuestTask))
        print("  mapRefreshHooked: " .. tostring(mapRefreshHooked))
        print("  AddDataProvider hooked: " .. tostring(addDataProviderHooked))
        -- Pin pool sizes
        local poolCount, hiddenPins = 0, 0
        if WorldMapFrame and WorldMapFrame.pinPools then
            for tpl, pool in pairs(WorldMapFrame.pinPools) do
                if pool.EnumerateActive then
                    local n = 0
                    for pin in pool:EnumerateActive() do
                        n = n + 1
                        local qid = pin.questID or (pin.questInfo and pin.questInfo.questId)
                        if qid and shouldHideQuest(qid) then hiddenPins = hiddenPins + 1 end
                    end
                    if n > 0 then
                        poolCount = poolCount + 1
                        print("  pool[" .. tpl .. "] active=" .. n)
                    end
                end
            end
        end
        print("  pools with pins=" .. poolCount .. "  would-hide=" .. hiddenPins)
        -- Provider summary
        local total, patched = 0, 0
        if WorldMapFrame and WorldMapFrame.dataProviders then
            for p in pairs(WorldMapFrame.dataProviders) do
                total = total + 1
                if patchedProviders[p] then patched = patched + 1 end
            end
        end
        print("  total providers=" .. total .. "  ShouldShowQuest patched=" .. patched)
    end,
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
        print("  /wf debug     – dump diagnostic info")
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
        print("|cff00ff00WoWFocus|r: unknown command '" .. cmd .. "'. Try /wf help")
    end
end
