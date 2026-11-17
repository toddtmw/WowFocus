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
-- The world quest data provider re-shows its pins after every refresh, so a
-- one-shot Hide() loses the race. Instead we hook each pin's OnShow so it
-- hides itself the moment the data provider tries to show it.

local hidePinsPending = false

-- Template names whose pins should always be hidden when the addon is active.
local HIDDEN_PIN_TEMPLATES = {
    ["WorldMap_WorldQuestPinTemplate"] = true,
}

-- Track which pools we have already hooked so we only hook once.
local hookedPinPools = {}

local function hookPinPool(templateName, pool)
    if hookedPinPools[pool] then return end
    if not HIDDEN_PIN_TEMPLATES[templateName] then return end
    hookedPinPools[pool] = true
    safeCall(function()
        local origAcquire = pool.Acquire
        pool.Acquire = function(self)
            local frame, isNew = origAcquire(self)
            if frame and not frame.__wfOnShowHooked then
                frame.__wfOnShowHooked = true
                frame:HookScript("OnShow", function(pin)
                    if cfg and cfg.enabled and cfg.hideMapPins then
                        pin:Hide()
                    end
                end)
            end
            return frame, isNew
        end
    end)
end

local function hookAllPinPools()
    if not WorldMapFrame or not WorldMapFrame.pinPools then return end
    for templateName, pool in pairs(WorldMapFrame.pinPools) do
        hookPinPool(templateName, pool)
    end
end

local function hidePinsOnMap()
    if not (cfg and cfg.enabled and cfg.hideMapPins) then return end
    safeCall(function()
        if not WorldMapFrame then return end

        -- Walk all pin pools; use template name to catch pools whose pins
        -- lack a questID (e.g. older-era world quests in Legion zones).
        if WorldMapFrame.pinPools then
            for templateName, pool in pairs(WorldMapFrame.pinPools) do
                if pool.EnumerateActive then
                    local isWQPool = HIDDEN_PIN_TEMPLATES[templateName]
                    for pin in pool:EnumerateActive() do
                        local qid = pin.questID or (pin.questInfo and pin.questInfo.questId)
                        if isWQPool or (qid and shouldHideQuest(qid)) then
                            pin:Hide()
                        end
                    end
                end
            end
        end

        -- Canvas children fallback.
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
        hookAllPinPools()
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

-- ── Objective-tracker removal ─────────────────────────────────────────────
local function shouldHideFromTracker(questID)
    return isWorldQuest(questID) or isBonusObjective(questID) or isRecurring(questID)
end

local function removeWorldQuestsFromTracker()
    if not (cfg and cfg.enabled and cfg.hideTracker) then return end
    safeCall(function()
        local numEntries = C_QuestLog.GetNumQuestLogEntries()
        for i = 1, numEntries do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and shouldHideFromTracker(info.questID) then
                -- World/recurring quests use RemoveWorldQuestWatch;
                -- bonus objectives (task quests) use RemoveQuestWatch.
                pcall(C_QuestLog.RemoveWorldQuestWatch, info.questID)
                pcall(C_QuestLog.RemoveQuestWatch, info.questID)
            end
        end
    end)
end

local function suppressZonePulse()
    safeCall(function()
        if BonusObjectivePulse then
            if BonusObjectivePulse:IsShown() then BonusObjectivePulse:Hide() end
            BonusObjectivePulse:HookScript("OnShow", function(self) self:Hide() end)
        end
    end)
end

-- ── Objective-tracker block hiding ────────────────────────────────────────
-- World quests in Legion+ zones are proximity-pushed into the tracker without
-- going through the normal watch system, so RemoveQuestWatch doesn't prevent
-- them. We hook ObjectiveTracker_Update and hide any block whose ID is a
-- world quest / bonus objective / recurring quest right after it's drawn.

local function hideWorldQuestTrackerBlocks()
    if not (cfg and cfg.enabled and cfg.hideTracker) then return end
    safeCall(function()
        if not ObjectiveTrackerFrame or not ObjectiveTrackerFrame.MODULES then return end
        for _, module in ipairs(ObjectiveTrackerFrame.MODULES) do
            if module.usedBlocks then
                -- If the module IS the world-quest or bonus-objective module, hide
                -- every block in it unconditionally (questID check can miss older-era quests).
                local isWQModule = (WORLD_QUEST_TRACKER_MODULE and module == WORLD_QUEST_TRACKER_MODULE)
                                or (BONUS_OBJECTIVE_TRACKER_MODULE and module == BONUS_OBJECTIVE_TRACKER_MODULE)
                for key, block in pairs(module.usedBlocks) do
                    local qid = tonumber(key)
                              or (type(block) == "table" and (block.id or block.questID))
                    local hide = isWQModule or (qid and shouldHideFromTracker(qid))
                    if hide and type(block) == "table" and block.Hide then
                        block:Hide()
                    end
                end
            end
        end
    end)
end

-- Modules whose every block we suppress entirely when the addon is active.
-- AUTO_QUEST_POPUP_TRACKER_MODULE is the banner popup that appears on-screen.
local SUPPRESSED_TRACKER_MODULES = {
    "WORLD_QUEST_TRACKER_MODULE",
    "BONUS_OBJECTIVE_TRACKER_MODULE",
    "AUTO_QUEST_POPUP_TRACKER_MODULE",
}

local function hideModuleCompletely(module)
    if not module then return end
    safeCall(function()
        if module.Header then module.Header:Hide() end
        if module.usedBlocks then
            for _, block in pairs(module.usedBlocks) do
                if type(block) == "table" and block.Hide then block:Hide() end
            end
        end
        -- Some modules expose a container frame directly.
        if module.ContentsFrame and module.ContentsFrame.Hide then
            module.ContentsFrame:Hide()
        end
    end)
end

local trackerHooked = false
local function hookObjectiveTracker()
    if trackerHooked then return end
    trackerHooked = true

    -- Hook the specific world-quest/bonus-objective/popup modules by name.
    -- Doing this inside their own Update ensures we re-hide after every redraw.
    for _, globalName in ipairs(SUPPRESSED_TRACKER_MODULES) do
        local module = _G[globalName]
        if module and module.Update then
            safeCall(function()
                hooksecurefunc(module, "Update", function(self)
                    if cfg and cfg.enabled and cfg.hideTracker then
                        hideModuleCompletely(self)
                    end
                end)
            end)
        end
    end

    -- Fallback: hook the global ObjectiveTracker_Update and frame Update
    -- to catch any module we may have missed by name.
    safeCall(function()
        hooksecurefunc("ObjectiveTracker_Update", hideWorldQuestTrackerBlocks)
    end)
    safeCall(function()
        if ObjectiveTrackerFrame and ObjectiveTrackerFrame.Update then
            hooksecurefunc(ObjectiveTrackerFrame, "Update", hideWorldQuestTrackerBlocks)
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
local function refreshMap()
    safeCall(function()
        if WorldMapFrame and WorldMapFrame:IsShown() then
            WorldMapFrame:RefreshAllDataProviders()
        end
    end)
end

local function applyAll()
    patchAllDataProviders()
    hookObjectiveTracker()
    removeWorldQuestsFromTracker()
    suppressZonePulse()
    createNextFrame()
    updateNextFrame()
    scheduleHidePins()
    -- Refresh the map so pins are restored or re-hidden to match current settings.
    refreshMap()
end

-- ── Event handling ────────────────────────────────────────────────────────
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("QUEST_LOG_UPDATE")
eventFrame:RegisterEvent("QUEST_ACCEPTED")
eventFrame:RegisterEvent("TASK_PROGRESS_UPDATE")
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

    elseif event == "TASK_PROGRESS_UPDATE" then
        scheduleHidePins()
        -- Defer: tracker draws the block after the event fires, so check on next frames.
        C_Timer.After(0,   hideWorldQuestTrackerBlocks)
        C_Timer.After(0.2, hideWorldQuestTrackerBlocks)
        C_Timer.After(0.5, hideWorldQuestTrackerBlocks)

    elseif event == "QUEST_ACCEPTED" then
        if cfg and cfg.enabled and cfg.hideTracker and arg1 and shouldHideFromTracker(arg1) then
            safeCall(C_QuestLog.RemoveWorldQuestWatch, arg1)
            safeCall(C_QuestLog.RemoveQuestWatch, arg1)
        end
        C_Timer.After(0,   hideWorldQuestTrackerBlocks)
        C_Timer.After(0.2, hideWorldQuestTrackerBlocks)

    elseif event == "WORLD_MAP_OPEN" then
        patchAllDataProviders()
        hookAllPinPools()
        scheduleHidePins()
        -- World quest data loads from the server asynchronously on first open;
        -- retry a few times to catch pins that appear after our initial pass.
        C_Timer.After(1, hidePinsOnMap)
        C_Timer.After(3, hidePinsOnMap)
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
        -- Collect all debug lines into a table so we can both print and show in a box.
        local lines = {}
        local function add(s) lines[#lines+1] = s ; print(s) end

        add("=== WoWFocus debug ===")
        if Enum and Enum.QuestClassification then
            local vals = {}
            for k, v in pairs(Enum.QuestClassification) do
                vals[#vals+1] = k .. "=" .. tostring(v)
            end
            add("  QuestClassification: " .. table.concat(vals, "  "))
        else
            add("  Enum.QuestClassification: missing")
        end
        add("  IsWorldQuest API: " .. type(C_QuestLog.IsWorldQuest))
        add("  IsQuestTask  API: " .. type(C_QuestLog.IsQuestTask))
        add("  mapRefreshHooked: " .. tostring(mapRefreshHooked))
        add("  AddDataProvider hooked: " .. tostring(addDataProviderHooked))
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
                        add("  pool[" .. tpl .. "] active=" .. n)
                    end
                end
            end
        end
        add("  pools with pins=" .. poolCount .. "  would-hide=" .. hiddenPins)
        for _, globalName in ipairs(SUPPRESSED_TRACKER_MODULES) do
            local m = _G[globalName]
            local blockCount = 0
            if m and m.usedBlocks then
                for _ in pairs(m.usedBlocks) do blockCount = blockCount + 1 end
            end
            add("  " .. globalName .. ": " .. (m and "exists" or "nil")
                .. "  blocks=" .. blockCount
                .. "  Update=" .. tostring(m and m.Update ~= nil))
        end
        local total, patched = 0, 0
        if WorldMapFrame and WorldMapFrame.dataProviders then
            for p in pairs(WorldMapFrame.dataProviders) do
                total = total + 1
                if patchedProviders[p] then patched = patched + 1 end
            end
        end
        add("  total providers=" .. total .. "  ShouldShowQuest patched=" .. patched)

        -- Show a copyable popup box with the same text.
        local text = table.concat(lines, "\n")
        if not _G["WoWFocusDebugBox"] then
            local f = CreateFrame("Frame", "WoWFocusDebugBox", UIParent, "BasicFrameTemplate")
            f:SetSize(560, 300)
            f:SetPoint("CENTER")
            f:SetMovable(true)
            f:EnableMouse(true)
            f:RegisterForDrag("LeftButton")
            f:SetScript("OnDragStart", f.StartMoving)
            f:SetScript("OnDragStop",  f.StopMovingOrSizing)
            f:SetFrameStrata("DIALOG")
            f.TitleText:SetText("WoWFocus Debug — Ctrl+A then Ctrl+C to copy")

            local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
            sf:SetPoint("TOPLEFT",     f, "TOPLEFT",     8, -28)
            sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -26, 8)

            local eb = CreateFrame("EditBox", nil, sf)
            eb:SetMultiLine(true)
            eb:SetMaxLetters(0)
            eb:SetFontObject(ChatFontNormal)
            eb:SetWidth(510)
            eb:SetAutoFocus(false)
            eb:SetScript("OnEscapePressed", function() f:Hide() end)
            sf:SetScrollChild(eb)
            f.eb = eb
        end
        local box = _G["WoWFocusDebugBox"]
        box.eb:SetText(text)
        box.eb:SetFocus()
        box.eb:HighlightText()
        box:Show()
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
