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
local clientBonusKills = 0
local clientSpecialKills = 0
local lastSyncedState = SN.STATE_IDLE

local warningSoundTimer = 0
local warningSoundInterval = 1800
local activeSoundTimer = 0

-- Speech cooldown (tick-based, incremented in onTick)
local speechCooldownTicks = 0
local SPEECH_COOLDOWN = 900  -- ~30 seconds at 30fps

-- Wave tracking (exposed via SN for panel access)
local clientCurrentWave = 0
local clientTotalWaves = 0
-- Sync retry: if ModData never arrives, re-request periodically
local syncRetryTicks = 0
local syncRetryInterval = 300  -- ~10 seconds at 30fps
local syncRetryMax = 6  -- give up after ~60 seconds
local syncRetryCount = 0
-- Redress system removed: server-side dressInNamedOutfit was causing naked zombies.
-- addZombiesInOutfit handles clothing correctly on the client side.
-- Keeping RedressZombie handler as no-op for backward compat with older servers.

-- Client-authoritative real-time data (updated by server commands, read by panel)
-- These are more reliable than ModData on busy servers
SN._clientRealtime = {
    waveIndex = 0,
    totalWaves = 0,
    phase = SN.PHASE_SURGE,
    spawnedThisSiege = 0,
    killsThisSiege = 0,
    bonusKills = 0,
    specialKills = 0,
    targetZombies = 0,
    state = SN.STATE_IDLE,  -- current siege state (updated by StateChange, more reliable than ModData)
    active = false,  -- true when we have command-sourced data
}

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
    "That's all of them -- now kill every last one!",
    "No more coming... finish them off!",
    "The full horde is here. Fight to live!",
    "This is it -- kill or be killed!",
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
-- Custom sounds defined in media/scripts/SiegeNight_sounds.txt
-- Sound names: SN_SiegeHorn, SN_Warning, SN_WaveIncoming, SN_WaveBreak, SN_DawnClear, SN_MiniHordeAlert
-- If custom .ogg files are missing, falls back to vanilla PZ sounds.

local warningEmitter = nil

local function playSound(soundName, fallback)
    -- All custom sounds disabled — no .ogg files shipped yet.
    -- When we add real sound assets, remove this early return.
    return nil
end

local function playSiegeHorn()
    local emitter = playSound("SN_SiegeHorn", "zombierand7")
    if emitter then
        getSoundManager():PlayAsMusic("SN_SiegeHorn", emitter, false, 0)
        emitter:setVolume(0.35)
    end
end

local function playWaveIncoming()
    playSound("SN_WaveIncoming", nil)
end

local function playWaveBreak()
    playSound("SN_WaveBreak", nil)
end

local function playDawnClear()
    playSound("SN_DawnClear", nil)
end

local function playMiniHordeAlert()
    playSound("SN_MiniHordeAlert", nil)
end

local function stopWarningAmbience()
    if warningEmitter then
        local sm = getSoundManager()
        if sm then
            sm:StopSound(warningEmitter)
        end
        warningEmitter = nil
    end
end

local function startWarningAmbience()
    -- Disabled — no custom sound assets shipped yet.
    stopWarningAmbience()
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
    startWarningAmbience()
    local player = getPlayer()
    if player and SN.getSandbox("WarningSignsEnabled") then
        trySpeech(WARNING_SPEECHES, SN.getCurrentHour())
    end
end

local function onEnterActive()
    SN.log("Client: Entering ACTIVE state")
    stopWarningAmbience()
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

local function hasArg(args, key)
    return args ~= nil and args[key] ~= nil
end

local function onEnterDawn()
    SN.log("Client: Siege ended!" .. (clientDawnFallback and " (dawn fallback)" or ""))
    stopWarningAmbience()
    playDawnClear()
    local player = getPlayer()
    if player then
        local kills = 0
        local bonus = 0
        local siegeData = SN.getWorldData()
        if siegeData then
            kills = siegeData.killsThisSiege or 0
            bonus = siegeData.bonusKills or 0
        end
        -- Use client state if available (MP)
        if clientKills > 0 then kills = clientKills end
        if clientBonusKills > 0 then bonus = clientBonusKills end
        local totalKills = kills + bonus
        local bonusStr = bonus > 0 and (" +" .. bonus .. " attracted") or ""
        if clientDawnFallback then
            if totalKills > 0 then
                player:Say("Dawn... " .. kills .. " down" .. bonusStr .. ", but some got away.")
            else
                trySpeech(DAWN_FALLBACK_SPEECHES, nil)
            end
        elseif totalKills > 0 then
            player:Say("It's over... " .. kills .. " of them dead." .. (bonus > 0 and (" Plus " .. bonus .. " that wandered in.") or ""))
        else
            trySpeech(DAWN_SPEECHES, nil)
        end
    end
    clientBonusKills = 0
    clientDawnFallback = false
end

local function onHordeComplete(targetZombies)
    SN.log("Client: Full horde has arrived -- " .. (targetZombies or "?") .. " zombies")
    playSiegeHorn()
    local player = getPlayer()
    if player then
        speechCooldownTicks = 0  -- Force this speech through
        trySpeech(HORDE_COMPLETE_SPEECHES, nil)
    end
end

local function onEnterIdle()
    SN.log("Client: Entering IDLE state")
    stopWarningAmbience()
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
        if hasArg(args, "siegeCount") then clientSiegeCount = args["siegeCount"] end
        if hasArg(args, "direction") then clientDirection = args["direction"] end
        if hasArg(args, "killsThisSiege") then clientKills = args["killsThisSiege"] end
        if hasArg(args, "bonusKills") then clientBonusKills = args["bonusKills"] end
        if hasArg(args, "specialKills") then clientSpecialKills = args["specialKills"] end
        if hasArg(args, "totalWaves") then clientTotalWaves = args["totalWaves"] end
        if hasArg(args, "dawnFallback") then clientDawnFallback = args["dawnFallback"] end
        -- Update realtime tracker (always track state so panel doesn't depend on ModData for state)
        local rt = SN._clientRealtime
        rt.state = newState
        if newState == SN.STATE_ACTIVE then
            if hasArg(args, "totalWaves") then rt.totalWaves = args["totalWaves"] end
            if hasArg(args, "targetZombies") then rt.targetZombies = args["targetZombies"] end
            -- Only reset counters on fresh siege start (not on duplicate StateChange from reconnect)
            if not rt.active then
                rt.waveIndex = 1
                rt.phase = SN.PHASE_SURGE
                rt.spawnedThisSiege = 0
                rt.killsThisSiege = 0
                rt.bonusKills = 0
                rt.specialKills = 0
            end
            rt.active = true
        elseif newState == SN.STATE_DAWN or newState == SN.STATE_IDLE then
            if hasArg(args, "killsThisSiege") then rt.killsThisSiege = args["killsThisSiege"] end
            if hasArg(args, "bonusKills") then rt.bonusKills = args["bonusKills"] end
            if hasArg(args, "specialKills") then rt.specialKills = args["specialKills"] end
            -- Keep active until IDLE so dawn summary panel still shows data
            if newState == SN.STATE_IDLE then rt.active = false end
        end
        syncClientState(newState)

    elseif command == "WaveStart" then
        local waveIdx = args["waveIndex"] or 0
        local totalW = args["totalWaves"] or 0
        clientCurrentWave = waveIdx
        clientTotalWaves = totalW
        -- Update realtime tracker (authoritative over ModData)
        local rt = SN._clientRealtime
        rt.waveIndex = waveIdx
        rt.totalWaves = totalW
        rt.phase = SN.PHASE_SURGE
        local player = getPlayer()
        if player then
            player:Say("Wave " .. waveIdx .. " of " .. totalW .. "!")
        end
        playWaveIncoming()
        playSiegeHorn()

    elseif command == "WaveBreak" or command == "WaveCooldown" then
        local waveIdx = args["waveIndex"] or 0
        local breakSeconds = args["breakSeconds"] or 0
        clientCurrentWave = waveIdx
        -- Update realtime tracker (authoritative over ModData)
        local rt = SN._clientRealtime
        rt.waveIndex = waveIdx
        rt.phase = SN.PHASE_COOLDOWN
        playWaveBreak()
        local player = getPlayer()
        if player then
            trySpeech(BREAK_SPEECHES, nil)
        end

    elseif command == "HordeComplete" then
        local targetZombies = args["targetZombies"] or 0
        SN._clientRealtime.spawnedThisSiege = targetZombies  -- all spawned
        onHordeComplete(targetZombies)

    elseif command == "RedressZombie" then
        -- No-op: kept for backward compat. Server-side dressInNamedOutfit was causing
        -- naked zombies by overwriting client visuals. addZombiesInOutfit handles it.

    elseif command == "SyncSpecial" then
        -- Server syncs special zombie stats to all clients (replaces makeInactive hack)
        local onlineID = args["id"]
        local health = args["health"]
        local speedMod = args["speedMod"]
        if onlineID then
            local zombies = getCell():getZombieList()
            if zombies then
                for i = 0, zombies:size() - 1 do
                    local z = zombies:get(i)
                    if z and z:getOnlineID() == onlineID then
                        -- NOTE: Do NOT set health client-side in MP.
                        -- Doing so can desync client perception vs server authority ("killed but still moving" / unlootable).
                        -- Server already owns health via spawn params; clients only need speed/visual tuning.
                        if speedMod then z:setSpeedMod(speedMod) end
                        break
                    end
                end
            end
        end


    elseif command == "SyncAllStats" then
        -- Server pushed full stats -- write directly into ModData so panel reads them
        local siegeData = SN.getWorldData()
        if not siegeData then
            -- Force create if ModData wasn't received yet
            siegeData = ModData.getOrCreate("SiegeNight")
            SN._worldData = siegeData
        end
        if hasArg(args, "siegeState") then siegeData.siegeState = args["siegeState"] end
        if hasArg(args, "siegeCount") then siegeData.siegeCount = args["siegeCount"] end
        if hasArg(args, "nextSiegeDay") then siegeData.nextSiegeDay = args["nextSiegeDay"] end
        if hasArg(args, "totalSiegesCompleted") then siegeData.totalSiegesCompleted = args["totalSiegesCompleted"] end
        if hasArg(args, "totalKillsAllTime") then siegeData.totalKillsAllTime = args["totalKillsAllTime"] end
        if hasArg(args, "killsThisSiege") then siegeData.killsThisSiege = args["killsThisSiege"] end
        if hasArg(args, "bonusKills") then siegeData.bonusKills = args["bonusKills"] end
        if hasArg(args, "specialKillsThisSiege") then siegeData.specialKillsThisSiege = args["specialKillsThisSiege"] end
        if hasArg(args, "spawnedThisSiege") then siegeData.spawnedThisSiege = args["spawnedThisSiege"] end
        if hasArg(args, "targetZombies") then siegeData.targetZombies = args["targetZombies"] end
        if hasArg(args, "lastDirection") then siegeData.lastDirection = args["lastDirection"] end
        if hasArg(args, "currentWaveIndex") then siegeData.currentWaveIndex = args["currentWaveIndex"] end
        if hasArg(args, "currentPhase") then siegeData.currentPhase = args["currentPhase"] end
        -- Sync history entries
        local totalCompleted = args["totalSiegesCompleted"] or 0
        for idx = 1, totalCompleted do
            local prefix = "history_" .. idx .. "_"
            if hasArg(args, prefix .. "kills") then siegeData[prefix .. "kills"] = args[prefix .. "kills"] end
            if hasArg(args, prefix .. "bonus") then siegeData[prefix .. "bonus"] = args[prefix .. "bonus"] end
            if hasArg(args, prefix .. "specials") then siegeData[prefix .. "specials"] = args[prefix .. "specials"] end
            if hasArg(args, prefix .. "spawned") then siegeData[prefix .. "spawned"] = args[prefix .. "spawned"] end
            if hasArg(args, prefix .. "target") then siegeData[prefix .. "target"] = args[prefix .. "target"] end
            if hasArg(args, prefix .. "day") then siegeData[prefix .. "day"] = args[prefix .. "day"] end
            if hasArg(args, prefix .. "dir") then siegeData[prefix .. "dir"] = args[prefix .. "dir"] end
        end
        SN.log("Received full stats sync from server: siegeCount=" .. (args["siegeCount"] or "?")
            .. " totalCompleted=" .. (args["totalSiegesCompleted"] or "?")
            .. " totalKills=" .. (args["totalKillsAllTime"] or "?")
            .. " nextSiegeDay=" .. (args["nextSiegeDay"] or "?"))
        -- Update realtime tracker from full sync
        local rt = SN._clientRealtime
        if hasArg(args, "currentWaveIndex") then rt.waveIndex = args["currentWaveIndex"] end
        if hasArg(args, "currentPhase") then rt.phase = args["currentPhase"] end
        if hasArg(args, "spawnedThisSiege") then rt.spawnedThisSiege = args["spawnedThisSiege"] end
        if hasArg(args, "killsThisSiege") then rt.killsThisSiege = args["killsThisSiege"] end
        if hasArg(args, "bonusKills") then rt.bonusKills = args["bonusKills"] end
        if hasArg(args, "specialKillsThisSiege") then rt.specialKills = args["specialKillsThisSiege"] end
        if hasArg(args, "targetZombies") then rt.targetZombies = args["targetZombies"] end
        if hasArg(args, "siegeState") then
            rt.state = args["siegeState"]
            if args["siegeState"] == SN.STATE_ACTIVE then rt.active = true end
            syncClientState(args["siegeState"])
        end

    elseif command == "SiegeTick" then
        -- Periodic real-time update from server (more reliable than ModData.transmit)
        local rt = SN._clientRealtime
        rt.active = true
        if hasArg(args, "spawnedThisSiege") then rt.spawnedThisSiege = args["spawnedThisSiege"] end
        if hasArg(args, "killsThisSiege") then rt.killsThisSiege = args["killsThisSiege"] end
        if hasArg(args, "bonusKills") then rt.bonusKills = args["bonusKills"] end
        if hasArg(args, "specialKills") then rt.specialKills = args["specialKills"] end
        if hasArg(args, "currentWaveIndex") then rt.waveIndex = args["currentWaveIndex"] end
        if hasArg(args, "currentPhase") then rt.phase = args["currentPhase"] end
        if hasArg(args, "targetZombies") then rt.targetZombies = args["targetZombies"] end

    elseif command == "MiniHorde" then
        local count = args["count"] or 0
        local dir = args["direction"] or 0
        playMiniHordeAlert()
        local player = getPlayer()
        if player and count > 0 then
            local dirName = SN.getDirName(dir)
            player:Say("Something's attracted their attention from the " .. dirName .. "...")
        end

    elseif command == "ServerMsg" then
        -- Generic server response message (used by debug commands, etc.)
        local msg = args["msg"]
        if msg then
            local player = getPlayer()
            if player then player:Say("[SN] " .. msg) end
            SN.log("Server: " .. msg)
        end

    -- CmdResponse is handled by SiegeNight_Commands.lua (avoids duplicate display)
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

    -- Redress queue removed: was causing naked zombies, not fixing them.

    -- Sync retry: if panel is still "Loading..." (no ModData), keep requesting
    if isClient() and syncRetryCount < syncRetryMax then
        local siegeData = SN.getWorldData()
        if not siegeData or not siegeData.siegeState then
            syncRetryTicks = syncRetryTicks + 1
            if syncRetryTicks >= syncRetryInterval then
                syncRetryTicks = 0
                syncRetryCount = syncRetryCount + 1
                sendClientCommand(player, SN.CLIENT_MODULE, "CmdRequestSync", {})
                SN.log("Sync retry " .. syncRetryCount .. "/" .. syncRetryMax .. " (ModData not received yet)")
            end
        else
            syncRetryCount = syncRetryMax  -- got data, stop retrying
        end
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
                    local totalW = SN.getWaveCountForTotal(siegeData.targetZombies or 75)

                    if clientCurrentWave > 0 then
                        player:Say("Wave " .. newWave .. " of " .. totalW .. "!")
                        playWaveIncoming()
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
    if siegeData and siegeData.siegeState ~= SN.STATE_IDLE then
        clientSiegeCount = siegeData.siegeCount
        syncClientState(siegeData.siegeState)
        SN.log("Loaded into active siege state: " .. siegeData.siegeState)
    end

    -- Request full stats sync from server (belt-and-suspenders for ModData sync issues)
    local player = getPlayer()
    if player and isClient() then
        sendClientCommand(player, SN.CLIENT_MODULE, "CmdRequestSync", {})
        SN.log("Requested stats sync from server")
    end
end

-- Note: No client-side OnZombieDead handler needed. addZombiesInOutfit handles
-- clothing, corpses inherit visuals, and kill tracking is server-side.

-- ==========================================
-- EVENT HOOKS
-- ==========================================
Events.OnGameStart.Add(onGameStart)
Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(onTick)
Events.EveryHours.Add(onEveryHour)

