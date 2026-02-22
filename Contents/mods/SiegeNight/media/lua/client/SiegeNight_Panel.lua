--[[
    SiegeNight_Panel.lua
    Custom tab added to the character info window (alongside Health, Skills, etc.)
    Shows: current siege status, wave progress, kill tracking, siege history.

    v2.3 - Robust tab registration using ISCharacterInfoWindow hook.
         - Works with or without TchernoLib.
         - Deferred registration via OnGameStart to ensure UI classes are loaded.
]]

local ok, _ = pcall(require, "ISUI/ISPanelJoypad")
if not ok then
    pcall(require, "ISUI/ISPanel")
end

local SN = require("SiegeNight_Shared")

-- ==========================================
-- ADDTAB HELPER (inline, deferred)
-- ==========================================
-- We define addCharacterPageTab ourselves if it doesn't exist.
-- This hooks ISCharacterInfoWindow.createChildren to inject our tab.
local function ensureAddCharacterPageTab()
    if addCharacterPageTab then return end

    -- ISCharacterInfoWindow must be loaded by now (OnGameStart guarantees this)
    if not ISCharacterInfoWindow then
        SN.log("WARNING: ISCharacterInfoWindow not found — panel tab will not register")
        return
    end

    function addCharacterPageTab(tabName, pageType)
        local viewName = tabName .. "View"

        local orig_createChildren = ISCharacterInfoWindow.createChildren
        function ISCharacterInfoWindow:createChildren()
            orig_createChildren(self)
            self[viewName] = pageType:new(0, 8, self.width, self.height - 8, self.playerNum)
            self[viewName]:initialise()
            local panelText = getText("UI_" .. tabName .. "Panel") or "Siege Night status"
            self[viewName].infoText = panelText
            local tabText = getText("UI_" .. tabName) or "Siege"
            self.panel:addView(tabText, self[viewName])
        end

        local orig_onTabTornOff = ISCharacterInfoWindow.onTabTornOff
        if orig_onTabTornOff then
            function ISCharacterInfoWindow:onTabTornOff(view, window)
                if self.playerNum == 0 and view == self[viewName] then
                    if ISLayoutManager then
                        ISLayoutManager.RegisterWindow("charinfowindow." .. tabName, ISCollapsableWindow, window)
                    end
                end
                orig_onTabTornOff(self, view, window)
            end
        end

        local orig_SaveLayout = ISCharacterInfoWindow.SaveLayout
        if orig_SaveLayout then
            function ISCharacterInfoWindow:SaveLayout(name, layout)
                orig_SaveLayout(self, name, layout)
                local hasTab = false
                if self[viewName] and self[viewName].parent == self.panel then
                    hasTab = true
                    if self[viewName] == self.panel:getActiveView() then
                        layout.current = tabName
                    end
                end
                if hasTab then
                    if not layout.tabs then
                        layout.tabs = tabName
                    else
                        layout.tabs = layout.tabs .. "," .. tabName
                    end
                end
            end
        end
    end
end

-- ==========================================
-- PANEL CLASS
-- ==========================================

ISSiegeNightPanel = ISPanelJoypad:derive("ISSiegeNightPanel")

function ISSiegeNightPanel:initialise()
    ISPanelJoypad.initialise(self)
end

function ISSiegeNightPanel:createChildren()
    self:setScrollChildren(true)
    self:addScrollBars()
end

function ISSiegeNightPanel:setVisible(visible)
    self.javaObject:setVisible(visible)
end

function ISSiegeNightPanel:prerender()
    ISPanelJoypad.prerender(self)
    self:setStencilRect(0, 0, self.width, self.height)
end

-- ==========================================
-- COLORS
-- ==========================================
local C_WHITE   = {r=1.0, g=1.0, b=1.0}
local C_GREY    = {r=0.7, g=0.7, b=0.7}
local C_DARK    = {r=0.5, g=0.5, b=0.5}
local C_RED     = {r=1.0, g=0.3, b=0.3}
local C_ORANGE  = {r=1.0, g=0.7, b=0.2}
local C_GREEN   = {r=0.4, g=1.0, b=0.4}
local C_YELLOW  = {r=1.0, g=1.0, b=0.3}
local C_BLUE    = {r=0.5, g=0.7, b=1.0}

-- ==========================================
-- RENDER
-- ==========================================

function ISSiegeNightPanel:render()
    local siegeData = SN.getWorldData()
    local textManager = getTextManager()
    local font = UIFont.Small
    local fontMed = UIFont.Medium
    local fh = textManager:getFontHeight(font)
    local fhMed = textManager:getFontHeight(fontMed)
    local x = 15
    local y = 8
    local col2 = 140  -- second column for values

    -- ---- HEADER ----
    self:drawText("Siege Night", x, y, C_WHITE.r, C_WHITE.g, C_WHITE.b, 1.0, fontMed)
    y = y + fhMed + 6

    if not siegeData then
        self:drawText("Loading...", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
        y = y + fh * 3
        self:setScrollHeight(y)
        self:clearStencilRect()
        return
    end

    -- ---- CURRENT STATUS ----
    local state = siegeData.siegeState or SN.STATE_IDLE
    local stateColor = C_GREY
    local stateLabel = "Idle"
    if state == SN.STATE_WARNING then
        stateColor = C_ORANGE
        stateLabel = "Warning"
    elseif state == SN.STATE_ACTIVE then
        stateColor = C_RED
        stateLabel = "SIEGE ACTIVE"
    elseif state == SN.STATE_DAWN then
        stateColor = C_GREEN
        stateLabel = "Dawn"
    end

    self:drawText("Status:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
    self:drawText(stateLabel, col2, y, stateColor.r, stateColor.g, stateColor.b, 1.0, font)
    y = y + fh

    -- Day info
    local dayFloat = SN.getActualDay()
    local currentDay = math.floor(dayFloat)
    self:drawText("Day:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
    self:drawText(tostring(currentDay) .. "  (Hour " .. SN.getCurrentHour() .. ")", col2, y, C_WHITE.r, C_WHITE.g, C_WHITE.b, 1.0, font)
    y = y + fh

    -- Next siege
    local nextDay = siegeData.nextSiegeDay or 0
    local daysUntil = nextDay - currentDay
    local nextColor = C_GREY
    local nextText = "Day " .. nextDay
    if daysUntil <= 0 then
        nextColor = C_RED
        nextText = "TODAY"
    elseif daysUntil == 1 then
        nextColor = C_ORANGE
        nextText = "TOMORROW (Day " .. nextDay .. ")"
    else
        nextText = "Day " .. nextDay .. " (" .. daysUntil .. " days)"
    end
    self:drawText("Next Siege:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
    self:drawText(nextText, col2, y, nextColor.r, nextColor.g, nextColor.b, 1.0, font)
    y = y + fh

    -- Siege number
    self:drawText("Siege #:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
    self:drawText(tostring(siegeData.siegeCount or 0), col2, y, C_WHITE.r, C_WHITE.g, C_WHITE.b, 1.0, font)
    y = y + fh + 4

    -- ---- ACTIVE SIEGE DETAILS ----
    if state == SN.STATE_ACTIVE or state == SN.STATE_DAWN then
        -- Separator
        self:drawRect(x, y, self.width - x * 2, 1, 0.4, 0.6, 0.1, 0.1)
        y = y + 6

        self:drawText("Current Siege", x, y, C_RED.r, C_RED.g, C_RED.b, 1.0, fontMed)
        y = y + fhMed + 4

        -- Direction
        local dirName = "All directions"
        if siegeData.lastDirection and siegeData.lastDirection >= 0 then
            dirName = SN.getDirName(siegeData.lastDirection)
        end
        self:drawText("Direction:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
        self:drawText(dirName, col2, y, C_ORANGE.r, C_ORANGE.g, C_ORANGE.b, 1.0, font)
        y = y + fh

        -- Spawn progress
        local spawned = siegeData.spawnedThisSiege or 0
        local target = siegeData.targetZombies or 0
        local pct = target > 0 and math.floor(spawned / target * 100) or 0
        self:drawText("Spawned:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
        self:drawText(spawned .. " / " .. target .. "  (" .. pct .. "%)", col2, y, C_WHITE.r, C_WHITE.g, C_WHITE.b, 1.0, font)
        y = y + fh

        -- Spawn progress bar
        if target > 0 then
            local barX = col2
            local barW = self.width - col2 - x - 10
            local barH = 6
            self:drawRect(barX, y, barW, barH, 0.5, 0.2, 0.2, 0.2)
            local fillW = math.floor(barW * math.min(1.0, spawned / target))
            if fillW > 0 then
                self:drawRect(barX, y, fillW, barH, 0.8, 0.8, 0.2, 0.2)
            end
            y = y + barH + 4
        end

        -- Wave info
        local waveIdx = siegeData.currentWaveIndex or 0
        local phase = siegeData.currentPhase or "?"
        local phaseColor = C_WHITE
        if phase == SN.PHASE_WAVE then phaseColor = C_RED
        elseif phase == SN.PHASE_TRICKLE then phaseColor = C_ORANGE
        elseif phase == SN.PHASE_BREAK then phaseColor = C_GREEN
        end
        self:drawText("Wave:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
        self:drawText(tostring(waveIdx), col2, y, C_WHITE.r, C_WHITE.g, C_WHITE.b, 1.0, font)
        y = y + fh

        self:drawText("Phase:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
        self:drawText(tostring(phase), col2, y, phaseColor.r, phaseColor.g, phaseColor.b, 1.0, font)
        y = y + fh + 4

        -- Separator
        self:drawRect(x, y, self.width - x * 2, 1, 0.4, 0.6, 0.1, 0.1)
        y = y + 6
    end

    -- ---- KILL TRACKING ----
    self:drawText("Kill Tracker", x, y, C_ORANGE.r, C_ORANGE.g, C_ORANGE.b, 1.0, fontMed)
    y = y + fhMed + 4

    local kills = siegeData.killsThisSiege or 0
    local specKills = siegeData.specialKillsThisSiege or 0
    self:drawText("This Siege:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
    self:drawText(tostring(kills) .. " killed", col2, y, C_WHITE.r, C_WHITE.g, C_WHITE.b, 1.0, font)
    y = y + fh

    if specKills > 0 then
        self:drawText("Specials:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
        self:drawText(tostring(specKills) .. " killed", col2, y, C_YELLOW.r, C_YELLOW.g, C_YELLOW.b, 1.0, font)
        y = y + fh
    end

    -- Tanks
    if state == SN.STATE_ACTIVE and (siegeData.tanksSpawned or 0) > 0 then
        self:drawText("Tanks:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
        self:drawText(siegeData.tanksSpawned .. " / " .. SN.getSandbox("TankCount"), col2, y, C_RED.r, C_RED.g, C_RED.b, 1.0, font)
        y = y + fh
    end

    y = y + 4

    -- ---- ALL-TIME STATS ----
    self:drawRect(x, y, self.width - x * 2, 1, 0.4, 0.6, 0.1, 0.1)
    y = y + 6

    self:drawText("All-Time", x, y, C_BLUE.r, C_BLUE.g, C_BLUE.b, 1.0, fontMed)
    y = y + fhMed + 4

    local totalSieges = siegeData.totalSiegesCompleted or 0
    local totalKills = siegeData.totalKillsAllTime or 0

    self:drawText("Sieges Survived:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
    self:drawText(tostring(totalSieges), col2, y, C_WHITE.r, C_WHITE.g, C_WHITE.b, 1.0, font)
    y = y + fh

    self:drawText("Total Kills:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
    self:drawText(tostring(totalKills), col2, y, C_WHITE.r, C_WHITE.g, C_WHITE.b, 1.0, font)
    y = y + fh

    if totalSieges > 0 then
        local avg = math.floor(totalKills / totalSieges)
        self:drawText("Avg Kills/Siege:", x, y, C_GREY.r, C_GREY.g, C_GREY.b, 1.0, font)
        self:drawText(tostring(avg), col2, y, C_WHITE.r, C_WHITE.g, C_WHITE.b, 1.0, font)
        y = y + fh
    end

    y = y + 4

    -- ---- SIEGE HISTORY ----
    if totalSieges > 0 then
        self:drawRect(x, y, self.width - x * 2, 1, 0.4, 0.6, 0.1, 0.1)
        y = y + 6

        self:drawText("Siege History", x, y, C_BLUE.r, C_BLUE.g, C_BLUE.b, 1.0, fontMed)
        y = y + fhMed + 4

        -- Show last 10 sieges (most recent first)
        local startIdx = math.max(1, totalSieges - 9)
        for idx = totalSieges, startIdx, -1 do
            local hKills = siegeData["history_" .. idx .. "_kills"] or 0
            local hSpecials = siegeData["history_" .. idx .. "_specials"] or 0
            local hSpawned = siegeData["history_" .. idx .. "_spawned"] or 0
            local hTarget = siegeData["history_" .. idx .. "_target"] or 0
            local hDay = siegeData["history_" .. idx .. "_day"] or "?"
            local hDir = siegeData["history_" .. idx .. "_dir"]
            local dirStr = ""
            if hDir and hDir >= 0 and hDir <= 7 then
                dirStr = " " .. SN.DIR_NAMES[hDir + 1]
            end

            -- Header line: "Siege #3 - Day 9  North"
            local headerText = "Siege #" .. idx .. " - Day " .. tostring(hDay) .. dirStr
            self:drawText(headerText, x, y, C_WHITE.r, C_WHITE.g, C_WHITE.b, 1.0, font)
            y = y + fh

            -- Detail line: "  Killed 45/75  (3 specials)"
            local detailText = "  Killed " .. hKills .. "/" .. hTarget
            if hSpecials > 0 then
                detailText = detailText .. "  (" .. hSpecials .. " specials)"
            end
            self:drawText(detailText, x, y, C_DARK.r, C_DARK.g, C_DARK.b, 1.0, font)
            y = y + fh + 2
        end
    end

    y = y + fh

    -- Set scroll height for content
    self:setScrollHeight(y)
    self:clearStencilRect()
end

function ISSiegeNightPanel:onMouseWheel(del)
    self:setYScroll(self:getYScroll() - del * 30)
    return true
end

function ISSiegeNightPanel:new(x, y, width, height, playerNum)
    local o = ISPanelJoypad:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self
    o.playerNum = playerNum
    o.char = getSpecificPlayer(playerNum)
    o:noBackground()
    ISSiegeNightPanel.instance = o
    return o
end

-- Joypad support (minimal)
function ISSiegeNightPanel:onGainJoypadFocus(joypadData)
    ISPanelJoypad.onGainJoypadFocus(self, joypadData)
end

function ISSiegeNightPanel:onLoseJoypadFocus(joypadData)
    ISPanelJoypad.onLoseJoypadFocus(self, joypadData)
end

function ISSiegeNightPanel:onJoypadDown(button)
    if button == Joypad.LBumper or button == Joypad.RBumper then
        getPlayerInfoPanel(self.playerNum):onJoypadDown(button)
    end
end

-- ==========================================
-- REGISTER TAB
-- ==========================================
-- Two-pronged approach:
-- 1. Hook createChildren so any FUTURE character info windows get our tab.
-- 2. On OnGameStart, inject the tab into the EXISTING window instance
--    (because B42 creates the window before OnGameStart, so the hook alone misses it).

local tabInjected = false

local function injectTabIntoExistingWindow()
    if tabInjected then return end
    -- Find the existing character info window for player 0
    local playerNum = 0
    local infoWindow = getPlayerInfoPanel(playerNum)
    if not infoWindow then
        SN.log("WARNING: getPlayerInfoPanel returned nil — will retry")
        return false
    end
    if not infoWindow.panel then
        SN.log("WARNING: Character info window has no panel — will retry")
        return false
    end

    -- Check if our tab already exists
    local viewName = "SiegeNightView"
    if infoWindow[viewName] then
        SN.log("Siege tab already exists on window")
        tabInjected = true
        return true
    end

    -- Create and inject our panel
    local panel = ISSiegeNightPanel:new(0, 8, infoWindow.width, infoWindow.height - 8, playerNum)
    panel:initialise()
    local tabText = getText("UI_SiegeNight") or "Siege"
    panel.infoText = getText("UI_SiegeNightPanel") or "Siege Night status"
    infoWindow.panel:addView(tabText, panel)
    infoWindow[viewName] = panel

    tabInjected = true
    SN.log("Panel module loaded - Siege tab injected into existing window.")
    return true
end

local function registerSiegeTab()
    -- Hook for future windows
    ensureAddCharacterPageTab()
    if addCharacterPageTab then
        addCharacterPageTab("SiegeNight", ISSiegeNightPanel)
        SN.log("Panel createChildren hook registered.")
    end

    -- Inject into existing window
    if not injectTabIntoExistingWindow() then
        -- If it failed (window not ready yet), retry on next few ticks
        local retryCount = 0
        local function retryInject()
            retryCount = retryCount + 1
            if injectTabIntoExistingWindow() or retryCount > 300 then
                Events.OnTick.Remove(retryInject)
                if retryCount > 300 then
                    SN.log("WARNING: Failed to inject Siege tab after 300 retries")
                end
            end
        end
        Events.OnTick.Add(retryInject)
    end
end

Events.OnGameStart.Add(registerSiegeTab)
