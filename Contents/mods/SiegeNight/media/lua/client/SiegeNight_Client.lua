--[[
    SiegeNight_Client.lua
    Client-side warning signs, atmosphere sounds, wave notifications.
    Runs CLIENT-SIDE only.

    v2.3 - Removed warning groan sounds entirely
    v2.2 - NO vignette, NO ISPanel, NO UIManager.DrawRect
         - Pure Say() + sounds for all feedback
         - Wave/break notifications
         - Direction announced at siege start
         - Kill tracking
         - Mini-horde direction announcement
]]

local SN = require("SiegeNight_Shared")

-- ==========================================
-- LOCAL STATE
-- ==========================================
local clientSiegeState = SN.STATE_IDLE
local clientSiegeCount = 0
local clientDirection = 0
local clientKills = 0
local clientSpecialKills = 0
local lastSyncedState = SN.STATE_IDLE

local warningSoundTimer = 0
local warningSoundInterval = 1800
local activeSoundTimer = 0

-- Speech cooldown (tick-based, incremented in onTick)
local speechCooldownTicks = 0
local SPEECH_COOLDOWN = 900  -- ~30 seconds at 30fps

-- Wave tracking
local clientCurrentWave = 0
local clientTotalWaves = 0

-- ==========================================
-- SPEECH LINES
-- ==========================================

local WARNING_SPEECHES = {
    [6]  = "Something feels wrong today...",
    [8]  = "I've got a bad feeling about this...",
    [10] = "The air feels heavy...",
    [12] = "Why is it so quiet?",
    [14] = "I keep hearing things in the distance...",
    [16] = "It's too quiet... way too quiet.",
    [18] = "They're coming. I can feel it.",
    [19] = "Oh god... not again...",
}

local ACTIVE_SPEECHES = {
    "Here they come!",
    "There's so many!",
    "Keep fighting!",
    "Don't stop!",
    "They're everywhere!",
    "Hold the line!",
    "Just gotta kill them all...",
    "How many more?!",
}

local DAWN_SPEECHES = {
    "We did it... they're all dead.",
    "Is it over? I think it's over.",
    "We survived. We actually survived.",
    "That's the last of them.",
}

local HORDE_COMPLETE_SPEECHES = {
    "That's all of them — now kill every last one!",
    "No more coming... finish them off!",
    "The full horde is here. Fight to live!",
    "This is it — kill or be killed!",
}

local BREAK_SPEECHES = {
    "Quick, reload!",
    "Catch your breath...",
    "More will come...",
    "This isn't over yet.",
    "Use this time, they'll be back.",
}

-- ==========================================
-- SOUND SYSTEM
-- ==========================================

local function playSiegeHorn()
    local emitter = getSoundManager():PlaySound("zombierand7", false, 0)
    if emitter then
        getSoundManager():PlayAsMusic("zombierand7", emitter, false, 0)
        emitter:setVolume(0.20)
    end
end

-- ==========================================
-- CHARACTER SPEECH
-- ==========================================

local function trySpeech(speechTable, indexOrRandom)
    local player = getPlayer()
    if not player then return end

    if speechCooldownTicks > 0 then return end

    local text
    if type(speechTable) == "table" and type(indexOrRandom) == "number" then
        text = speechTable[indexOrRandom]
    elseif type(speechTable) == "table" then
        text = speechTable[ZombRand(#speechTable) + 1]
    end

    if text then
        player:Say(text)
        speechCooldownTicks = SPEECH_COOLDOWN
    end
end

-- ==========================================
-- STATE TRANSITION HANDLERS
-- ==========================================

local function onEnterWarning()
    SN.log("Client: Entering WARNING state")
    local player = getPlayer()
    if player and SN.getSandbox("WarningSignsEnabled") then
        trySpeech(WARNING_SPEECHES, SN.getCurrentHour())
    end
end

local function onEnterActive()
    SN.log("Client: Entering ACTIVE state")
    playSiegeHorn()
    local player = getPlayer()
    if player then
        local siegeData = SN.getWorldData()
        local dirName = "unknown"
        if siegeData and siegeData.lastDirection and siegeData.lastDirection >= 0 then
            dirName = SN.getDirName(siegeData.lastDirection)
        end
        if SN.getSandbox("DirectionalAttacks") then
            player:Say("They're coming from the " .. dirName .. "!")
        else
            player:Say("They're coming! Siege has begun!")
        end
    end
end

local DAWN_FALLBACK_SPEECHES = {
    "Dawn... the rest scattered.",
    "Sunrise. Some of them are still out there...",
    "It's morning. They're pulling back.",
    "We made it to dawn... barely.",
}

local clientDawnFallback = false

local function onEnterDawn()
    SN.log("Client: Siege ended!" .. (clientDawnFallback and " (dawn fallback)" or ""))
    local player = getPlayer()
    if player then
        local kills = 0
        local siegeData = SN.getWorldData()
        if siegeData then kills = siegeData.killsThisSiege or 0 end
        if clientDawnFallback then
            -- Dawn forced the siege to end — player didn't clear the horde
            if kills > 0 then
                player:Say("Dawn... " .. kills .. " down, but some got away.")
            else
                trySpeech(DAWN_FALLBACK_SPEECHES, nil)
            end
        elseif kills > 0 then
            player:Say("It's over... " .. kills .. " of them dead.")
        else
            trySpeech(DAWN_SPEECHES, nil)
        end
    end
    clientDawnFallback = false
end

local function onHordeComplete(targetZombies)
    SN.log("Client: Full horde has arrived — " .. (targetZombies or "?") .. " zombies")
    playSiegeHorn()
    local player = getPlayer()
    if player then
        speechCooldownTicks = 0  -- Force this speech through
        trySpeech(HORDE_COMPLETE_SPEECHES, nil)
    end
end

local function onEnterIdle()
    SN.log("Client: Entering IDLE state")
end

-- ==========================================
-- STATE SYNC
-- ==========================================

local function syncClientState(newState)
    if newState == lastSyncedState then return end

    lastSyncedState = newState
    clientSiegeState = newState

    if newState == SN.STATE_WARNING then
        onEnterWarning()
    elseif newState == SN.STATE_ACTIVE then
        onEnterActive()
    elseif newState == SN.STATE_DAWN then
        onEnterDawn()
    elseif newState == SN.STATE_IDLE then
        onEnterIdle()
    end
end

-- ==========================================
-- SERVER COMMAND HANDLER (MP)
-- ==========================================

local function onServerCommand(module, command, args)
    if module ~= SN.CLIENT_MODULE then return end

    if command == "StateChange" then
        local newState = args["state"]
        if args["siegeCount"] then clientSiegeCount = args["siegeCount"] end
        if args["direction"] then clientDirection = args["direction"] end
        if args["killsThisSiege"] then clientKills = args["killsThisSiege"] end
        if args["specialKills"] then clientSpecialKills = args["specialKills"] end
        if args["totalWaves"] then clientTotalWaves = args["totalWaves"] end
        if args["dawnFallback"] then clientDawnFallback = args["dawnFallback"] end
        syncClientState(newState)

    elseif command == "WaveStart" then
        local waveIdx = args["waveIndex"] or 0
        local totalW = args["totalWaves"] or 0
        clientCurrentWave = waveIdx
        clientTotalWaves = totalW
        local player = getPlayer()
        if player then
            player:Say("Wave " .. waveIdx .. " of " .. totalW .. "!")
        end
        playSiegeHorn()

    elseif command == "WaveBreak" then
        local waveIdx = args["waveIndex"] or 0
        clientCurrentWave = waveIdx
        local player = getPlayer()
        if player then
            trySpeech(BREAK_SPEECHES, nil)
        end

    elseif command == "HordeComplete" then
        local targetZombies = args["targetZombies"] or 0
        onHordeComplete(targetZombies)

    elseif command == "MiniHorde" then
        local count = args["count"] or 0
        local dir = args["direction"] or 0
        local player = getPlayer()
        if player and count > 0 then
            local dirName = SN.getDirName(dir)
            player:Say("Something's attracted their attention from the " .. dirName .. "...")
        end
    end
end

-- ==========================================
-- TICK HANDLERS
-- ==========================================

local function onTick()
    local player = getPlayer()
    if not player then return end

    -- Decrement speech cooldown
    if speechCooldownTicks > 0 then
        speechCooldownTicks = speechCooldownTicks - 1
    end

    -- SP: mirror server world data state directly
    if not isClient() then
        local siegeData = SN.getWorldData()
        if siegeData then
            syncClientState(siegeData.siegeState)

            -- SP: mirror wave info for Say() messages
            if siegeData.siegeState == SN.STATE_ACTIVE then
                local newWave = siegeData.currentWaveIndex or 0
                if newWave ~= clientCurrentWave and newWave > 0 then
                    local totalW = math.max(3, math.min(7, math.floor((siegeData.targetZombies or 75) / 60) + 2))

                    if clientCurrentWave > 0 then
                        player:Say("Wave " .. newWave .. " of " .. totalW .. "!")
                        playSiegeHorn()
                    end
                    clientCurrentWave = newWave
                    clientTotalWaves = totalW
                end
            end
        end
    end

    -- ACTIVE: occasional combat speech
    if clientSiegeState == SN.STATE_ACTIVE then
        -- Occasional combat speech
        if ZombRand(3000) == 0 then
            trySpeech(ACTIVE_SPEECHES, nil)
        end
    end
end

local function onEveryHour()
    if not SN.getSandbox("Enabled") then return end

    local hour = SN.getCurrentHour()

    if clientSiegeState == SN.STATE_WARNING then
        if SN.getSandbox("WarningSignsEnabled") then
            trySpeech(WARNING_SPEECHES, hour)
        end
    end
end

-- ==========================================
-- INITIALIZATION
-- ==========================================

local function onGameStart()
    SN.log("Client module loaded. Version " .. SN.VERSION)

    local siegeData = SN.getWorldData()
    if not siegeData then return end
    if siegeData.siegeState ~= SN.STATE_IDLE then
        clientSiegeCount = siegeData.siegeCount
        syncClientState(siegeData.siegeState)
        SN.log("Loaded into active siege state: " .. siegeData.siegeState)
    end
end

-- ==========================================
-- EVENT HOOKS
-- ==========================================
Events.OnGameStart.Add(onGameStart)
Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(onTick)
Events.EveryHours.Add(onEveryHour)
