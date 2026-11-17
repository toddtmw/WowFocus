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

-- Suppress the talking-head / voice-actor popup that introduces world quests.
-- TWW triggers TalkingHeadFrame from C++ with no Lua event; HookScript("OnShow")
-- is the hook point.  A periodic ticker provides belt-and-suspenders coverage
-- for frames that use alpha-fade rather than a true Show() call.
local talkingHeadHooked = false
local talkingHeadTicker = nil

local function closeTalkingHeadNow()
    safeCall(function()
        if CloseTalkingHead then CloseTalkingHead() end
        if TalkingHeadFrame and TalkingHeadFrame:IsShown() then
            TalkingHeadFrame:Hide()
        end
    end)
end

local function suppressTalkingHead()
    if talkingHeadHooked then return end
    safeCall(function()
        if not TalkingHeadFrame then return end
        talkingHeadHooked = true
        TalkingHeadFrame:HookScript("OnShow", function(self)
            if cfg and cfg.enabled and cfg.hideTracker then
                closeTalkingHeadNow()
            end
        end)
    end)
end

local function setTalkingHeadEnabled(enabled)
    if not enabled then
        -- Immediate close if already visible.
        closeTalkingHeadNow()
        -- Tight ticker (50ms) catches alpha-fade-in frames that bypass OnShow.
        -- Short interval minimises the audio window before we close the frame.
        if not talkingHeadTicker then
            talkingHeadTicker = C_Timer.NewTicker(0.05, function()
                if cfg and cfg.enabled and cfg.hideTracker then
                    if TalkingHeadFrame and TalkingHeadFrame:IsShown() then
                        closeTalkingHeadNow()
                    end
                end
            end)
        end
    else
        if talkingHeadTicker then
            talkingHeadTicker:Cancel()
            talkingHeadTicker = nil
        end
    end
end

-- Suppress the auto-quest-popup announcement banner.
local autoPopupHooked = false
local function suppressAutoQuestPopup()
    if autoPopupHooked then return end
    safeCall(function()
        -- Several possible frame names across patches
        local candidates = {
            _G["AutoQuestPopupTrackerFrame"],
            _G["BonusObjectiveTrackerFrameAlertFrame"],
            _G["QuestTurnInFailedAlertFrame"],
        }
        for _, f in ipairs(candidates) do
            if f and f.HookScript then
                autoPopupHooked = true
                f:HookScript("OnShow", function(self)
                    if cfg and cfg.enabled and cfg.hideTracker then self:Hide() end
                end)
                if f:IsShown() then f:Hide() end
            end
        end
    end)
end

-- Suppress the minimap zone-outline blob drawn around world-quest/task areas.
-- In TWW, Minimap.DrawBlob is nil and there is no named TaskBlobFrame child.
-- Debug shows child[1] is an unnamed always-shown frame — likely the blob overlay.
-- We hook every unnamed Minimap child's OnShow to hide it, and also check named
-- candidates for older patches.
local minimapBlobHooked = false
local minimapBlobChildren = {}  -- unnamed children we are suppressing

local function suppressMinimapBlobChildren()
    safeCall(function()
        if not Minimap then return end
        for _, child in ipairs({Minimap:GetChildren()}) do
            if child and not child:GetName() and not child.__wfBlobHooked then
                child.__wfBlobHooked = true
                minimapBlobHooked = true
                minimapBlobChildren[#minimapBlobChildren + 1] = child
                child:HookScript("OnShow", function(self)
                    if cfg and cfg.enabled and cfg.hideMapPins then self:Hide() end
                end)
                if child:IsShown() and cfg and cfg.enabled and cfg.hideMapPins then
                    child:Hide()
                end
            end
        end
    end)
end

local function suppressMinimapTaskBlob()
    -- DrawBlob hook (may become available on some patches).
    safeCall(function()
        local mmFrame = Minimap
        if mmFrame and type(mmFrame.DrawBlob) == "function" then
            minimapBlobHooked = true
            hooksecurefunc(mmFrame, "DrawBlob", function(self, questID, drawIt)
                if drawIt and cfg and cfg.enabled and cfg.hideMapPins then
                    if isWorldQuest(questID) or isBonusObjective(questID) or isRecurring(questID) then
                        C_Timer.After(0, function()
                            safeCall(function() mmFrame:DrawBlob(questID, false) end)
                        end)
                    end
                end
            end)
        end
    end)
    -- Named legacy candidates.
    safeCall(function()
        local candidates = {
            Minimap and rawget(Minimap, "TaskBlobFrame"),
            Minimap and rawget(Minimap, "QuestBlobFrame"),
            MinimapCluster and MinimapCluster.Minimap
                           and rawget(MinimapCluster.Minimap, "TaskBlobFrame"),
            _G["MinimapTaskBlobFrame"],
            _G["TaskPOIFrame"],
        }
        for _, f in ipairs(candidates) do
            if f and f.HookScript and not f.__wfBlobHooked then
                f.__wfBlobHooked = true
                minimapBlobHooked = true
                if f:IsShown() then f:Hide() end
                f:HookScript("OnShow", function(self)
                    if cfg and cfg.enabled and cfg.hideMapPins then self:Hide() end
                end)
            end
        end
    end)
    -- Unnamed children of Minimap (the blob overlay in TWW may be here).
    suppressMinimapBlobChildren()
    -- Also try unnamed children of MinimapCluster (blob may be parented there).
    safeCall(function()
        if not MinimapCluster then return end
        for _, child in ipairs({MinimapCluster:GetChildren()}) do
            if child and not child:GetName() and not child.__wfBlobHooked then
                child.__wfBlobHooked = true
                minimapBlobHooked = true
                minimapBlobChildren[#minimapBlobChildren + 1] = child
                child:HookScript("OnShow", function(self)
                    if cfg and cfg.enabled and cfg.hideMapPins then self:Hide() end
                end)
                if child:IsShown() and cfg and cfg.enabled and cfg.hideMapPins then
                    child:Hide()
                end
            end
        end
    end)
end

-- Apply or remove the hide on the blob children when settings change.
local function applyMinimapBlobVisibility()
    if not (cfg and cfg.enabled and cfg.hideMapPins) then
        -- Restore: show any blob children we hid.
        for _, child in ipairs(minimapBlobChildren) do
            safeCall(function() child:Show() end)
        end
    else
        for _, child in ipairs(minimapBlobChildren) do
            safeCall(function() if child:IsShown() then child:Hide() end end)
        end
    end
end

-- ── Objective-tracker block hiding ────────────────────────────────────────
-- In TWW, ObjectiveTrackerFrame.modules (lowercase) is an array of module
-- objects. Each module has a Header.Text showing its section label.
-- usedBlocks is keyed by TEMPLATE NAME strings (not questIDs), so we match
-- modules by header text and hide the whole module rather than per-questID.

-- Section headers to suppress entirely.
local HIDDEN_TRACKER_HEADERS = {
    ["World Quests"]    = true,
    ["Bonus Objectives"]= true,
}

local function getModuleHeader(module)
    local hdr = ""
    safeCall(function()
        if module.Header and module.Header.Text then
            hdr = module.Header.Text:GetText() or ""
        end
    end)
    return hdr
end

local function hookBlockOnShow(block)
    if type(block) ~= "table" or block.__wfBlockHooked then return end
    if not block.HookScript then return end
    block.__wfBlockHooked = true
    safeCall(function()
        block:HookScript("OnShow", function(self)
            if cfg and cfg.enabled and cfg.hideTracker then
                -- Stop the fly-in animation before it renders a single frame.
                safeCall(function()
                    if self.StopAnimating then self:StopAnimating() end
                    for _, child in ipairs({self:GetChildren()}) do
                        if child.StopAnimating then child:StopAnimating() end
                        child:Hide()
                    end
                end)
                self:Hide()
            end
        end)
    end)
end

local function hideTrackerModule(module)
    safeCall(function()
        if module.Hide then module:Hide() end
        if module.Header and module.Header.Hide then module.Header:Hide() end
        local blocks = module.usedBlocks or module.blocks or module.activeBlocks
        if type(blocks) == "table" then
            for _, block in pairs(blocks) do
                if type(block) == "table" then
                    hookBlockOnShow(block)
                    -- Stop the fly-in animation on the block itself plus children.
                    safeCall(function()
                        if block.StopAnimating then block:StopAnimating() end
                        for _, child in ipairs({block:GetChildren()}) do
                            if child.StopAnimating then child:StopAnimating() end
                            child:Hide()
                        end
                    end)
                    if block.Hide then block:Hide() end
                end
            end
        end
    end)
end

local function hideWorldQuestTrackerBlocks()
    if not (cfg and cfg.enabled and cfg.hideTracker) then return end
    safeCall(function()
        local mods = ObjectiveTrackerFrame and ObjectiveTrackerFrame.modules
        if not mods then return end
        for _, module in pairs(mods) do
            if HIDDEN_TRACKER_HEADERS[getModuleHeader(module)] then
                hideTrackerModule(module)
            end
        end
    end)
end

-- Hook each suppressed module's Update so every redraw is intercepted.
local hookedModuleRefs = {}
local function hookTrackerModulesByHeader()
    local mods = ObjectiveTrackerFrame and ObjectiveTrackerFrame.modules
    if not mods then return end
    for _, module in pairs(mods) do
        if not hookedModuleRefs[module] and HIDDEN_TRACKER_HEADERS[getModuleHeader(module)] then
            hookedModuleRefs[module] = true
            safeCall(function()
                -- hooksecurefunc only works on instance keys; set the method on
                -- the instance first if it lives only in the metatable.
                if not rawget(module, "Update") then
                    local mt = getmetatable(module)
                    local orig = mt and mt.__index and mt.__index.Update
                    if type(orig) == "function" then
                        module.Update = function(self, ...)
                            orig(self, ...)
                            if cfg and cfg.enabled and cfg.hideTracker then
                                hideTrackerModule(self)
                            end
                        end
                        return
                    end
                end
                hooksecurefunc(module, "Update", function(self)
                    if cfg and cfg.enabled and cfg.hideTracker then
                        hideTrackerModule(self)
                    end
                end)
            end)
            -- Hide immediately.
            if cfg and cfg.enabled and cfg.hideTracker then
                hideTrackerModule(module)
            end
        end
    end
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

-- Hook C_QuestLog watch functions so proximity-pushed world quests are
-- removed at the source before the tracker can display them.
local watchHooked = false
local function hookQuestWatching()
    if watchHooked then return end
    watchHooked = true
    -- Any quest added via AddWorldQuestWatch is definitionally a world quest.
    safeCall(function()
        hooksecurefunc(C_QuestLog, "AddWorldQuestWatch", function(questID)
            if cfg and cfg.enabled and cfg.hideTracker then
                C_Timer.After(0, function()
                    pcall(C_QuestLog.RemoveWorldQuestWatch, questID)
                    pcall(C_QuestLog.RemoveQuestWatch, questID)
                end)
            end
        end)
    end)
    -- AddQuestWatch covers bonus objectives and task quests.
    safeCall(function()
        hooksecurefunc(C_QuestLog, "AddQuestWatch", function(questID)
            if cfg and cfg.enabled and cfg.hideTracker and shouldHideFromTracker(questID) then
                C_Timer.After(0, function()
                    pcall(C_QuestLog.RemoveQuestWatch, questID)
                    pcall(C_QuestLog.RemoveWorldQuestWatch, questID)
                end)
            end
        end)
    end)
end

local trackerHooked = false
local function hookObjectiveTracker()
    if trackerHooked then return end
    trackerHooked = true

    -- Hook the tracker frame's own Update as a catch-all.
    safeCall(function()
        hooksecurefunc("ObjectiveTracker_Update", hideWorldQuestTrackerBlocks)
    end)
    safeCall(function()
        if ObjectiveTrackerFrame and ObjectiveTrackerFrame.Update then
            hooksecurefunc(ObjectiveTrackerFrame, "Update", hideWorldQuestTrackerBlocks)
        end
    end)

    -- Hook individual modules by header text (TWW structure).
    hookTrackerModulesByHeader()
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
    hookQuestWatching()
    hookTrackerModulesByHeader()
    removeWorldQuestsFromTracker()
    suppressZonePulse()
    suppressTalkingHead()
    suppressAutoQuestPopup()
    suppressMinimapTaskBlob()
    applyMinimapBlobVisibility()
    setTalkingHeadEnabled(not (cfg and cfg.enabled and cfg.hideTracker))
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
        -- Close talking head immediately on the event that triggers it.
        if cfg and cfg.enabled and cfg.hideTracker then
            C_Timer.After(0, closeTalkingHeadNow)
        end
        -- Re-check blob children (new ones may appear when entering a WQ zone).
        if cfg and cfg.enabled and cfg.hideMapPins then
            suppressMinimapBlobChildren()
            applyMinimapBlobVisibility()
        end
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
        -- Legacy global check (all nil in TWW -- left for reference)
        for _, globalName in ipairs(SUPPRESSED_TRACKER_MODULES) do
            local m = _G[globalName]
            add("  " .. globalName .. ": " .. (m and "exists" or "nil"))
        end
        -- Dump ObjectiveTrackerFrame.modules (lowercase, the TWW structure)
        local otfMods = ObjectiveTrackerFrame and ObjectiveTrackerFrame.modules
        if otfMods then
            local count = 0
            for _ in pairs(otfMods) do count = count + 1 end
            add("  OTF.modules count=" .. count)
            for k, module in pairs(otfMods) do
                local info = "  mod[" .. tostring(k) .. "]"
                local id = module.id or module.moduleType or module.name or module.questType or "?"
                info = info .. " id=" .. tostring(id)
                -- Header text (the section label shown in the tracker UI)
                local hdr = ""
                if module.Header then
                    if module.Header.Text then
                        local ok, t = pcall(function() return module.Header.Text:GetText() end)
                        if ok and t then hdr = t end
                    elseif module.Header.title then
                        local ok, t = pcall(function() return module.Header.title:GetText() end)
                        if ok and t then hdr = t end
                    end
                end
                if hdr ~= "" then info = info .. " hdr=\"" .. hdr .. "\"" end
                -- Block count
                local blocks = module.usedBlocks or module.blocks or module.activeBlocks
                local blockCount, firstKey = 0, nil
                if type(blocks) == "table" then
                    for bk in pairs(blocks) do
                        blockCount = blockCount + 1
                        if not firstKey then firstKey = tostring(bk) end
                    end
                end
                info = info .. " blocks=" .. blockCount
                if firstKey then
                    info = info .. " key0=" .. firstKey
                    local qid = tonumber(firstKey)
                    if qid then
                        local ok, isWQ = pcall(C_QuestLog.IsWorldQuest, qid)
                        local ok2, cls  = pcall(C_QuestLog.GetQuestClassification, qid)
                        info = info .. " isWQ=" .. tostring(ok and isWQ)
                              .. " cls=" .. tostring(ok2 and cls)
                    end
                end
                add(info)
            end
        else
            add("  OTF.modules: nil")
        end
        local total, patched = 0, 0
        if WorldMapFrame and WorldMapFrame.dataProviders then
            for p in pairs(WorldMapFrame.dataProviders) do
                total = total + 1
                if patchedProviders[p] then patched = patched + 1 end
            end
        end
        add("  total providers=" .. total .. "  ShouldShowQuest patched=" .. patched)
        -- Suppression frame status
        local thShown = TalkingHeadFrame and TalkingHeadFrame:IsShown()
        add("  TalkingHeadFrame: " .. tostring(TalkingHeadFrame ~= nil)
            .. "  IsShown=" .. tostring(thShown)
            .. "  hooked=" .. tostring(talkingHeadHooked)
            .. "  ticker=" .. tostring(talkingHeadTicker ~= nil)
            .. "  CloseTalkingHead=" .. type(CloseTalkingHead))
        add("  autoPopupHooked=" .. tostring(autoPopupHooked)
            .. "  minimapBlobHooked=" .. tostring(minimapBlobHooked))
        -- Minimap: DrawBlob, pinPools, then children of both Minimap and MinimapCluster
        local mmGlobal = Minimap
        if mmGlobal then
            add("  Minimap.DrawBlob=" .. type(mmGlobal.DrawBlob)
                .. "  pinPools=" .. type(mmGlobal.pinPools)
                .. "  dataProviders=" .. type(mmGlobal.dataProviders))
            safeCall(function()
                local children = {mmGlobal:GetChildren()}
                for i, child in ipairs(children) do
                    local cname = child:GetName() or "unnamed"
                    local shown = child:IsShown() and "shown" or "hidden"
                    local otype = child:GetObjectType()
                    local w, h = child:GetSize()
                    add("  Minimap child[" .. i .. "]: " .. cname
                        .. " " .. shown .. " " .. otype
                        .. " " .. math.floor(w+0.5) .. "x" .. math.floor(h+0.5))
                end
            end)
        end
        -- MinimapCluster children (blob may live here, not on Minimap)
        safeCall(function()
            if MinimapCluster then
                local children = {MinimapCluster:GetChildren()}
                add("  MinimapCluster childCount=" .. #children)
                for i, child in ipairs(children) do
                    local cname = child:GetName() or "unnamed"
                    local shown = child:IsShown() and "shown" or "hidden"
                    local otype = child:GetObjectType()
                    local w, h = child:GetSize()
                    add("  MC child[" .. i .. "]: " .. cname
                        .. " " .. shown .. " " .. otype
                        .. " " .. math.floor(w+0.5) .. "x" .. math.floor(h+0.5))
                end
            end
        end)
        -- Global scan: any frame/table with Blob or TaskPOI in its name
        safeCall(function()
            local found = {}
            for gname, gval in pairs(_G) do
                if type(gname) == "string" and type(gval) == "table" then
                    local lo = gname:lower()
                    if lo:find("blob") or lo:find("taskpoi") or lo:find("taskblob") then
                        found[#found+1] = gname
                    end
                end
            end
            table.sort(found)
            if #found > 0 then
                add("  blob-globals: " .. table.concat(found, "  "))
            else
                add("  blob-globals: none found")
            end
        end)

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
