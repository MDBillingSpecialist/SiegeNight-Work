--[[
    SiegeNight_Server.lua
    Core siege logic: state machine, wave-based spawn engine, directional attacks, special zombies.
    Runs SERVER-SIDE only.

    v2.3 - Wave system: WAVE -> TRICKLE -> BREAK -> repeat
         - Player count scaling
         - Kill tracking (OnZombieDead + proximity fallback)
         - No CLEANUP state (DAWN -> IDLE)
         - Establishment scaling (loot, structures)
         - Special zombie visual distinction
         - Tick-based state checks (no longer depends on EveryHours alone)
         - Capped siege history to 20 entries
         - SafeHouse nil safety
         - Reduced re-path targeting overhead
]]

local SN = require("SiegeNight_Shared")

-- ==========================================
-- LOCAL STATE
-- ==========================================

-- Dawn delay (ticks)
local dawnTicksRemaining = 0
local DAWN_DURATION_TICKS = 300  -- ~10 seconds at 30fps

-- Zombie attraction system
local attractorTickCounter = 0
local ATTRACTOR_INTERVAL = 150  -- ~5 seconds

-- Siege zombie tracking for re-pathing
local siegeZombies = {}
local REPATH_INTERVAL = 150
local repathTickCounter = 0

-- ==========================================
-- WAVE SYSTEM STATE
-- ==========================================
local waveStructure = {}       -- array of wave definitions from SN.calculateWaveStructure()
local currentWaveIndex = 1     -- which wave we're on (1-based)
local currentPhase = SN.PHASE_WAVE  -- WAVE, TRICKLE, or BREAK
local phaseSpawnedCount = 0    -- zombies spawned in current phase
local phaseTargetCount = 0     -- target for current phase
local breakTicksRemaining = 0  -- countdown during BREAK phase
local spawnTickCounter = 0     -- tick counter for spawn intervals

-- ==========================================
-- KILL TRACKING
-- ==========================================
-- Listen for zombie deaths to count siege kills
-- Tracks both tagged siege zombies and untagged "attracted" kills
local function onZombieDead(zombie)
    if not zombie then return end
    local siegeData = SN.getWorldData()
    if not siegeData then return end
    if siegeData.siegeState ~= SN.STATE_ACTIVE then return end

    local md = zombie:getModData()
    if md and md.SN_Siege then
        -- Tagged siege zombie
        siegeData.killsThisSiege = (siegeData.killsThisSiege or 0) + 1
        if md.SN_Type and md.SN_Type ~= "normal" then
            siegeData.specialKillsThisSiege = (siegeData.specialKillsThisSiege or 0) + 1
        end
    else
        -- Untagged zombie killed during siege (attracted by noise, nearby, etc.)
        siegeData.bonusKills = (siegeData.bonusKills or 0) + 1
    end
end

--- Total effective kills = tagged + bonus (used for siege end check)
local function getTotalSiegeKills(siegeData)
    return (siegeData.killsThisSiege or 0) + (siegeData.bonusKills or 0)
end

-- ==========================================
-- PLAYER LIST HELPER
-- ==========================================
local function getPlayerList()
    local playerList = {}
    local isSP = not isServer() and not isClient()
    if isSP then
        local player = getPlayer()
        if player and player:isAlive() then
            table.insert(playerList, player)
        end
    else
        local players = getOnlinePlayers()
        if players then
            for p = 0, players:size() - 1 do
                local player = players:get(p)
                if player and player:isAlive() then
                    table.insert(playerList, player)
                end
            end
        end
    end
    return playerList, isSP
end

-- ==========================================
-- ESTABLISHMENT SCORING
-- ==========================================
--- Estimate how established players are based on nearby structures and inventory.
--- Returns a multiplier (1.0 = fresh spawn, up to 2.0 = well-established).
local function getEstablishmentMultiplier(playerList)
    if not SN.getSandbox("MiniHorde_EstablishmentScaling") then return 1.0 end
    local score = 0
    for _, player in ipairs(playerList) do
        -- Check for generator nearby (major establishment indicator)
        local cell = getWorld():getCell()
        if cell then
            local px, py = math.floor(player:getX()), math.floor(player:getY())
            for gx = -5, 5, 5 do
                for gy = -5, 5, 5 do
                    local sq = cell:getGridSquare(px + gx, py + gy, 0)
                    if sq then
                        local gen = sq:getGenerator()
                        if gen and gen:isRunning() then
                            score = score + 30
                        end
                    end
                end
            end
        end
        -- Inventory weight as loot proxy (heavier = more established)
        local inv = player:getInventory()
        if inv then
            local weight = inv:getCapacityWeight()
            score = score + math.min(20, math.floor(weight))
        end
    end
    -- Normalize: 0-50 -> 1.0-2.0
    local mult = 1.0 + math.min(1.0, score / 50)
    return mult
end

-- ==========================================
-- DIRECTION SYSTEM
-- ==========================================

local function pickPrimaryDirection(lastDirection)
    local dir = ZombRand(8)
    local attempts = 0
    while dir == lastDirection and attempts < 20 do
        dir = ZombRand(8)
        attempts = attempts + 1
    end
    return dir
end

local function getSpawnPosition(player, primaryDir, usePrimary)
    local px = player:getX()
    local py = player:getY()
    local spawnDist = SN.getSandbox("SpawnDistance")

    local dir
    if SN.getSandbox("DirectionalAttacks") and usePrimary then
        dir = primaryDir
    else
        dir = ZombRand(8)
    end

    local baseX = px + SN.DIR_X[dir + 1] * spawnDist
    local baseY = py + SN.DIR_Y[dir + 1] * spawnDist

    local spread = ZombRand(41) - 20
    local perpX = -SN.DIR_Y[dir + 1]
    local perpY = SN.DIR_X[dir + 1]

    local targetX = math.floor(baseX + perpX * spread)
    local targetY = math.floor(baseY + perpY * spread)

    -- Pass 1: ideal spot (must be in a loaded cell so all players can see it)
    for attempt = 0, 30 do
        local tryX = targetX + ZombRand(11) - 5
        local tryY = targetY + ZombRand(11) - 5
        local square = getWorld():getCell():getGridSquare(tryX, tryY, 0)
        if square then
            local isSafe = SafeHouse and SafeHouse.getSafeHouse and SafeHouse.getSafeHouse(square) or nil
            if square:isFree(false) and square:isOutside() and isSafe == nil then
                -- In MP, verify the chunk is loaded (getGridSquare returns nil for unloaded)
                -- square existing means the cell IS loaded for the server
                return tryX, tryY
            end
        end
    end

    -- Pass 2: closer but still respects minimum distance
    local minDist = math.max(25, math.floor(spawnDist * 0.5))
    local closerDist = math.floor(spawnDist * 0.65)
    for attempt = 0, 30 do
        local cBaseX = px + SN.DIR_X[dir + 1] * closerDist
        local cBaseY = py + SN.DIR_Y[dir + 1] * closerDist
        local cSpread = ZombRand(21) - 10
        local tryX = math.floor(cBaseX + perpX * cSpread) + ZombRand(7) - 3
        local tryY = math.floor(cBaseY + perpY * cSpread) + ZombRand(7) - 3
        local dist = math.sqrt((tryX - px)^2 + (tryY - py)^2)
        if dist >= minDist then
            local square = getWorld():getCell():getGridSquare(tryX, tryY, 0)
            if square and square:isFree(false) and square:isOutside() then
                return tryX, tryY
            end
        end
    end

    -- Pass 3: random scatter — still enforce minimum distance
    for fallback = 0, 30 do
        local range = math.floor(spawnDist * 0.7)
        local fx = math.floor(px + ZombRand(range * 2) - range)
        local fy = math.floor(py + ZombRand(range * 2) - range)
        local dist = math.sqrt((fx - px)^2 + (fy - py)^2)
        if dist >= minDist then
            local square = getWorld():getCell():getGridSquare(fx, fy, 0)
            if square and square:isFree(false) then
                return fx, fy
            end
        end
    end

    SN.debug("All spawn position attempts failed near " .. math.floor(px) .. "," .. math.floor(py))
    return nil, nil
end

-- ==========================================
-- SPECIAL ZOMBIE SYSTEM
-- ==========================================

local function rollSpecialType(siegeData)
    if not SN.getSandbox("SpecialZombiesEnabled") then return "normal" end
    if siegeData.siegeCount < (SN.getSandbox("SpecialZombiesStartWeek") - 1) then return "normal" end

    local hoursSinceDusk = SN.getHoursSinceDusk()
    if hoursSinceDusk < SN.MIDNIGHT_RELATIVE_HOUR then return "normal" end

    local roll = ZombRand(100)
    local sprinterChance = SN.getSandbox("SprinterPercent")
    local breakerChance = SN.getSandbox("BreakerPercent")

    if roll < sprinterChance then return "sprinter" end
    if roll < sprinterChance + breakerChance then return "breaker" end
    return "normal"
end

local function shouldSpawnTank(siegeData)
    if not SN.getSandbox("SpecialZombiesEnabled") then return false end
    if siegeData.siegeCount < (SN.getSandbox("SpecialZombiesStartWeek") - 1) then return false end
    if siegeData.tanksSpawned >= SN.getSandbox("TankCount") then return false end

    local hoursSinceDusk = SN.getHoursSinceDusk()
    local nightDuration = SN.getNightDuration()
    if hoursSinceDusk < (nightDuration * 0.65) then return false end

    local remainingTanks = SN.getSandbox("TankCount") - siegeData.tanksSpawned
    local remainingHours = nightDuration - hoursSinceDusk
    if remainingHours <= 0 then return false end

    local chance = math.min(15, math.floor(remainingTanks / remainingHours * 30))
    return ZombRand(100) < chance
end

--- Queue for special zombie sandbox swaps — processed ONE per tick to avoid race conditions.
--- In MP, swapping global sandbox options affects ALL zombies on the server for that instant.
--- By queuing and processing one per tick, we minimize the window of wrong values.
local specialQueue = {}

--- Apply special zombie VISUAL DISTINCTION immediately (safe, no sandbox swap).
--- Actual stat changes are queued and applied one-per-tick.
local function applySpecialStats(zombie, specialType)
    if specialType == "normal" then return end

    -- Tag the zombie for identification immediately
    zombie:getModData().SN_Type = specialType
    zombie:getModData().SN_Siege = true

    -- Visual identification via outfit (safe to do immediately)
    -- Store in moddata so processSpecialQueue can re-apply after makeInactive
    if specialType == "breaker" then
        local outfit = SN.BREAKER_OUTFITS[ZombRand(#SN.BREAKER_OUTFITS) + 1]
        zombie:getModData().SN_Outfit = outfit
        zombie:dressInNamedOutfit(outfit)
    elseif specialType == "tank" then
        local outfit = SN.TANK_OUTFITS[ZombRand(#SN.TANK_OUTFITS) + 1]
        zombie:getModData().SN_Outfit = outfit
        zombie:dressInNamedOutfit(outfit)
    end
    -- Sprinters keep random outfit (SN_Outfit already set from spawnOneZombie)

    -- Queue the stat swap for next tick (one at a time)
    table.insert(specialQueue, { zombie = zombie, specialType = specialType })
end

--- Process ONE queued special zombie per tick. This keeps the sandbox-swap window
--- as short as possible and prevents race conditions with other mods.
local function processSpecialQueue()
    if #specialQueue == 0 then return end

    local entry = table.remove(specialQueue, 1)
    local zombie = entry.zombie
    local specialType = entry.specialType

    -- Verify zombie is still valid
    local ok, dead = pcall(function() return zombie:isDead() end)
    if not ok or dead then return end

    local origSpeed = getSandboxOptions():getOptionByName("ZombieLore.Speed"):getValue()
    local origStrength = getSandboxOptions():getOptionByName("ZombieLore.Strength"):getValue()
    local origToughness = getSandboxOptions():getOptionByName("ZombieLore.Toughness"):getValue()
    local origCognition = getSandboxOptions():getOptionByName("ZombieLore.Cognition"):getValue()

    if specialType == "sprinter" then
        getSandboxOptions():set("ZombieLore.Speed", 1)
    elseif specialType == "breaker" then
        getSandboxOptions():set("ZombieLore.Strength", 1)
        getSandboxOptions():set("ZombieLore.Cognition", 1)
    elseif specialType == "tank" then
        getSandboxOptions():set("ZombieLore.Toughness", 1)
        getSandboxOptions():set("ZombieLore.Speed", 3)
        getSandboxOptions():set("ZombieLore.Strength", 1)
    end

    zombie:makeInactive(true)
    zombie:makeInactive(false)

    getSandboxOptions():set("ZombieLore.Speed", origSpeed)
    getSandboxOptions():set("ZombieLore.Strength", origStrength)
    getSandboxOptions():set("ZombieLore.Toughness", origToughness)
    getSandboxOptions():set("ZombieLore.Cognition", origCognition)

    -- Re-apply outfit AFTER makeInactive cycle (makeInactive resets visual state)
    -- This is the fix for naked zombies in MP — the outfit must be applied last
    local outfitName = zombie:getModData().SN_Outfit
    if outfitName then
        zombie:dressInNamedOutfit(outfitName)
    end
end

-- ==========================================
-- SPAWN ENGINE
-- ==========================================

local function spawnOneZombie(player, primaryDir, specialType, healthMult)
    local usePrimary = (ZombRand(100) < 65)

    local spawnX, spawnY = getSpawnPosition(player, primaryDir, usePrimary)
    if not spawnX then
        SN.debug("Failed to find spawn position for zombie")
        return false
    end

    healthMult = healthMult or 1.5
    local outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1]

    local zombies = addZombiesInOutfit(spawnX, spawnY, 0, 1, outfit, 50, false, false, false, false, false, false, healthMult)
    if zombies and zombies:size() > 0 then
        local zombie = zombies:get(0)
        -- Store outfit in moddata for re-application after makeInactive
        zombie:getModData().SN_Outfit = outfit
        -- Dress server-side immediately
        if isServer() then
            zombie:dressInNamedOutfit(outfit)
        end
        applySpecialStats(zombie, specialType)

        -- Full Bandits-style targeting combo
        zombie:pathToCharacter(player)
        zombie:setTarget(player)
        zombie:setAttackedBy(player)
        zombie:spottedNew(player, true)
        zombie:addAggro(player, 1)

        -- Tag as siege zombie
        zombie:getModData().SN_Siege = true

        -- Sound attractor
        getWorldSoundManager():addSound(player, math.floor(player:getX()), math.floor(player:getY()), 0, 200, 10)

        -- Track for re-pathing
        table.insert(siegeZombies, { zombie = zombie, player = player })
        local MAX_TRACKED_ZOMBIES = 200
        if #siegeZombies > MAX_TRACKED_ZOMBIES then
            local overflow = #siegeZombies - MAX_TRACKED_ZOMBIES
            for ci = 1, overflow do
                table.remove(siegeZombies, 1)
            end
        end

        return true
    end
    return false
end

-- ==========================================
-- WAVE PHASE MANAGEMENT
-- ==========================================

--- Advance to the next phase within the current wave, or next wave entirely.
local function advanceWavePhase(siegeData)
    if currentPhase == SN.PHASE_WAVE then
        -- Wave done -> start Trickle
        currentPhase = SN.PHASE_TRICKLE
        phaseSpawnedCount = 0
        local waveDef = waveStructure[currentWaveIndex]
        phaseTargetCount = waveDef and waveDef.trickleSize or 0
        SN.log("Wave " .. currentWaveIndex .. " TRICKLE phase: " .. phaseTargetCount .. " zombies")

    elseif currentPhase == SN.PHASE_TRICKLE then
        -- Trickle done -> start Break
        local waveDef = waveStructure[currentWaveIndex]
        local breakTicks = waveDef and waveDef.breakDurationTicks or 0
        -- Debug override for break duration
        if siegeData.debugBreakOverride and siegeData.debugBreakOverride > 0 then
            breakTicks = siegeData.debugBreakOverride
        end
        if breakTicks > 0 then
            currentPhase = SN.PHASE_BREAK
            breakTicksRemaining = breakTicks
            phaseSpawnedCount = 0
            phaseTargetCount = 0
            local breakMinutes = string.format("%.1f", breakTicks / 1800)
            SN.log("Wave " .. currentWaveIndex .. " BREAK: " .. breakMinutes .. " minutes")
            -- Notify clients of break
            if isServer() then
                sendServerCommand(SN.CLIENT_MODULE, "WaveBreak", {
                    waveIndex = currentWaveIndex,
                    totalWaves = #waveStructure,
                    breakSeconds = math.floor(breakTicks / 30),
                })
            end
            SN.fireCallback("onBreakStart", currentWaveIndex, #waveStructure, breakTicks)
        else
            -- No break (last wave) -> stay in spawn mode until target reached
            currentWaveIndex = currentWaveIndex + 1
            if currentWaveIndex <= #waveStructure then
                currentPhase = SN.PHASE_WAVE
                phaseSpawnedCount = 0
                phaseTargetCount = waveStructure[currentWaveIndex].waveSize
                SN.log("Wave " .. currentWaveIndex .. "/" .. #waveStructure .. " WAVE phase: " .. phaseTargetCount .. " zombies")
                if isServer() then
                    sendServerCommand(SN.CLIENT_MODULE, "WaveStart", {
                        waveIndex = currentWaveIndex,
                        totalWaves = #waveStructure,
                    })
                end
                SN.fireCallback("onWaveStart", currentWaveIndex, #waveStructure)
            end
        end

    elseif currentPhase == SN.PHASE_BREAK then
        -- Break done -> advance to next wave
        currentWaveIndex = currentWaveIndex + 1
        if currentWaveIndex <= #waveStructure then
            currentPhase = SN.PHASE_WAVE
            phaseSpawnedCount = 0
            phaseTargetCount = waveStructure[currentWaveIndex].waveSize
            SN.log("Wave " .. currentWaveIndex .. "/" .. #waveStructure .. " WAVE phase: " .. phaseTargetCount .. " zombies")
            if isServer() then
                sendServerCommand(SN.CLIENT_MODULE, "WaveStart", {
                    waveIndex = currentWaveIndex,
                    totalWaves = #waveStructure,
                })
            end
            SN.fireCallback("onWaveStart", currentWaveIndex, #waveStructure)
        else
            SN.log("All waves completed")
        end
    end

    -- Update ModData for debug HUD
    siegeData.currentWaveIndex = currentWaveIndex
    siegeData.currentPhase = currentPhase
end

-- ==========================================
-- STATE MACHINE
-- ==========================================

local function enterActiveState(siegeData, reason, playerList)
    local dir = pickPrimaryDirection(siegeData.lastDirection)
    siegeData.lastDirection = dir
    siegeData.siegeState = SN.STATE_ACTIVE
    siegeData.siegeCount = math.max(0, siegeData.siegeCount)

    -- Calculate zombie count with player scaling and establishment
    local playerCount = playerList and #playerList or 1
    local estMult = getEstablishmentMultiplier(playerList or {})
    local baseTarget = SN.calculateSiegeZombies(siegeData.siegeCount, playerCount)
    local maxZ = SN.getSandbox("MaxZombies")
    siegeData.targetZombies = math.min(math.floor(baseTarget * estMult), maxZ)
    siegeData.spawnedThisSiege = 0
    siegeData.tanksSpawned = 0
    siegeData.killsThisSiege = 0
    siegeData.bonusKills = 0
    siegeData.specialKillsThisSiege = 0
    siegeData.hordeCompleteNotified = false
    siegeData.siegeStartHour = SN.getCurrentHour()

    -- Build wave structure
    waveStructure = SN.calculateWaveStructure(siegeData.targetZombies)
    currentWaveIndex = 1
    currentPhase = SN.PHASE_WAVE
    phaseSpawnedCount = 0
    phaseTargetCount = waveStructure[1] and waveStructure[1].waveSize or siegeData.targetZombies
    breakTicksRemaining = 0
    spawnTickCounter = 0

    siegeData.currentWaveIndex = currentWaveIndex
    siegeData.currentPhase = currentPhase

    SN.log("ACTIVE state entered (" .. reason .. "). Siege #" .. siegeData.siegeCount
        .. ", target: " .. siegeData.targetZombies .. " zombies"
        .. " (" .. #waveStructure .. " waves)"
        .. " from " .. SN.DIR_NAMES[dir + 1]
        .. " | players=" .. playerCount .. " estMult=" .. string.format("%.2f", estMult))

    if isServer() then
        sendServerCommand(SN.CLIENT_MODULE, "StateChange", {
            state = SN.STATE_ACTIVE,
            siegeCount = siegeData.siegeCount,
            direction = dir,
            targetZombies = siegeData.targetZombies,
            totalWaves = #waveStructure,
        })
    end

    SN.fireCallback("onSiegeStart", siegeData.siegeCount, dir, siegeData.targetZombies)
end

-- ==========================================
-- PLAYER COMMANDS (chat-triggered via sendClientCommand)
-- Must be defined before onServerTick (Lua requires functions exist before call)
-- ==========================================

local voteState = {
    active = false,
    voters = {},
    needed = 0,
    startTick = 0,
}
local VOTE_TIMEOUT_TICKS = 30 * 60  -- 60 seconds at 30fps

local function sendResponseToPlayer(player, message)
    sendServerCommand(player, SN.CLIENT_MODULE, "CmdResponse", { message = message })
end

local function broadcastToAll(command, args)
    sendServerCommand(SN.CLIENT_MODULE, command, args)
end

local function isPlayerAdmin(player)
    if not isServer() then return true end
    return player:isAccessLevel("admin") or player:isAccessLevel("moderator")
end

local function handleSiegeStart(player)
    if isServer() and not isPlayerAdmin(player) then
        sendResponseToPlayer(player, "Only admins can force-start a siege. Use /siege vote instead.")
        return
    end
    local siegeData = SN.getWorldData()
    if not siegeData then
        sendResponseToPlayer(player, "Siege Night not ready yet.")
        return
    end
    if siegeData.siegeState == SN.STATE_ACTIVE then
        sendResponseToPlayer(player, "A siege is already active!")
        return
    end
    local playerList = getPlayerList()
    enterActiveState(siegeData, "manual trigger by " .. (player:getUsername() or "player"), playerList)
    broadcastToAll("CmdResponse", { message = "Siege started by " .. (player:getUsername() or "player") .. "!" })
    SN.log("MANUAL SIEGE triggered by " .. (player:getUsername() or "player"))
end

local function handleSiegeStop(player)
    if isServer() and not isPlayerAdmin(player) then
        sendResponseToPlayer(player, "Only admins can force-end a siege.")
        return
    end
    local siegeData = SN.getWorldData()
    if not siegeData then
        sendResponseToPlayer(player, "Siege Night not ready yet.")
        return
    end
    if siegeData.siegeState ~= SN.STATE_ACTIVE then
        sendResponseToPlayer(player, "No siege is active.")
        return
    end
    siegeData.siegeState = SN.STATE_DAWN
    dawnTicksRemaining = DAWN_DURATION_TICKS
    broadcastToAll("StateChange", {
        state = SN.STATE_DAWN,
        spawnedTotal = siegeData.spawnedThisSiege or 0,
        killsThisSiege = siegeData.killsThisSiege or 0,
        specialKills = siegeData.specialKillsThisSiege or 0,
        dawnFallback = true,
    })
    broadcastToAll("CmdResponse", { message = "Siege ended by " .. (player:getUsername() or "player") .. "." })
    SN.log("MANUAL SIEGE END by " .. (player:getUsername() or "player"))
    SN.fireCallback("onSiegeEnd", siegeData.siegeCount, siegeData.killsThisSiege or 0, siegeData.spawnedThisSiege or 0)
end

local function handleSiegeVote(player)
    local siegeData = SN.getWorldData()
    if not siegeData then return end
    if siegeData.siegeState == SN.STATE_ACTIVE then
        sendResponseToPlayer(player, "A siege is already active!")
        return
    end
    if voteState.active then
        sendResponseToPlayer(player, "A vote is already in progress. Type /siege yes to vote.")
        return
    end
    local playerList = getPlayerList()
    local needed = math.max(1, math.ceil(#playerList / 2))
    if #playerList <= 1 then
        handleSiegeStart(player)
        return
    end
    voteState.active = true
    voteState.voters = {}
    voteState.voters[player:getUsername() or "player"] = true
    voteState.needed = needed
    voteState.startTick = 0
    broadcastToAll("VoteStarted", { needed = tostring(needed) })
    broadcastToAll("VoteUpdate", { current = 1, needed = needed })
    SN.log("SIEGE VOTE started by " .. (player:getUsername() or "player") .. ". Need " .. needed .. " votes.")
end

local function handleSiegeVoteYes(player)
    if not voteState.active then
        sendResponseToPlayer(player, "No vote in progress. Use /siege vote to start one.")
        return
    end
    local name = player:getUsername() or "player"
    if voteState.voters[name] then
        sendResponseToPlayer(player, "You already voted!")
        return
    end
    voteState.voters[name] = true
    local count = 0
    for _ in pairs(voteState.voters) do count = count + 1 end
    broadcastToAll("VoteUpdate", { current = count, needed = voteState.needed })
    if count >= voteState.needed then
        voteState.active = false
        broadcastToAll("VotePassed", {})
        SN.log("SIEGE VOTE PASSED (" .. count .. "/" .. voteState.needed .. ")")
        local siegeData = SN.getWorldData()
        if siegeData then
            local playerList = getPlayerList()
            enterActiveState(siegeData, "vote passed", playerList)
        end
    end
end

local function checkVoteTimeout()
    if not voteState.active then return end
    voteState.startTick = (voteState.startTick or 0) + 1
    if voteState.startTick >= VOTE_TIMEOUT_TICKS then
        voteState.active = false
        broadcastToAll("VoteFailed", {})
        SN.log("SIEGE VOTE timed out.")
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= SN.CLIENT_MODULE then return end
    if command == "CmdSiegeStart" then
        handleSiegeStart(player)
    elseif command == "CmdSiegeStop" then
        handleSiegeStop(player)
    elseif command == "CmdSiegeVote" then
        handleSiegeVote(player)
    elseif command == "CmdSiegeVoteYes" then
        handleSiegeVoteYes(player)
    end
end

-- State machine is now fully tick-based (inside onServerTick).
-- EveryHours is no longer used for state transitions.

-- Track last known state for debug-forced transitions
local lastServerState = SN.STATE_IDLE

-- Tick-based state check (runs every ~1 second instead of relying on EveryHours)
local stateCheckCounter = 0
local STATE_CHECK_INTERVAL = 30  -- ~1 second at 30fps

local MAX_SIEGE_HISTORY = 20  -- Cap history to prevent ModData bloat

local function onServerTick()
    if not SN.getSandbox("Enabled") then return end

    local siegeData = SN.getWorldData()
    if not siegeData then return end

    -- ==========================================
    -- PROCESS SPECIAL ZOMBIE QUEUE (one per tick)
    -- ==========================================
    processSpecialQueue()
    checkVoteTimeout()

    -- ==========================================
    -- TICK-BASED STATE CHECKS (every ~1 second)
    -- Replaces EveryHours for reliability — EveryHours can miss if server lags
    -- ==========================================
    stateCheckCounter = stateCheckCounter - 1
    if stateCheckCounter <= 0 then
        stateCheckCounter = STATE_CHECK_INTERVAL
        local currentDay = math.floor(SN.getActualDay())
        local currentHour = SN.getCurrentHour()

        if siegeData.siegeState == SN.STATE_IDLE then
            local isSiegeToday = SN.isSiegeDay(currentDay) or (currentDay >= siegeData.nextSiegeDay)
            if isSiegeToday and currentHour >= SN.WARNING_HOUR and currentHour < SN.DUSK_HOUR then
                siegeData.siegeState = SN.STATE_WARNING
                siegeData.siegeCount = math.max(0, SN.getSiegeCount(currentDay))
                SN.log("WARNING state entered (tick). Siege #" .. siegeData.siegeCount .. " on day " .. currentDay)
                if isServer() then
                    sendServerCommand(SN.CLIENT_MODULE, "StateChange", {
                        state = SN.STATE_WARNING,
                        siegeCount = siegeData.siegeCount,
                        day = currentDay,
                    })
                end
            end
            if isSiegeToday and (currentHour >= SN.DUSK_HOUR or currentHour < SN.DAWN_HOUR) then
                siegeData.siegeCount = math.max(0, SN.getSiegeCount(currentDay))
                local playerList = getPlayerList()
                enterActiveState(siegeData, "tick-based dusk detection", playerList)
            end

        elseif siegeData.siegeState == SN.STATE_WARNING then
            if currentHour >= SN.DUSK_HOUR then
                local playerList = getPlayerList()
                enterActiveState(siegeData, "tick-based dusk transition", playerList)
            end

        elseif siegeData.siegeState == SN.STATE_ACTIVE then
            local kills = siegeData.killsThisSiege or 0
            local bonus = siegeData.bonusKills or 0
            local totalKills = getTotalSiegeKills(siegeData)
            local target = siegeData.targetZombies or 0
            local siegeCleared = target > 0 and totalKills >= target

            -- Dawn safety fallback: force end if it's past dawn hour
            -- Prevents permanently stuck ACTIVE state after server restart
            local dawnFallback = false
            if not siegeCleared and currentHour >= SN.DAWN_HOUR and currentHour < SN.DUSK_HOUR then
                dawnFallback = true
                SN.log("DAWN FALLBACK: Forcing siege end at hour " .. currentHour
                    .. " | Kills: " .. kills .. " + " .. bonus .. " bonus/" .. target
                    .. " | Spawned: " .. (siegeData.spawnedThisSiege or 0))
            end

            if siegeCleared or dawnFallback then
                siegeData.siegeState = SN.STATE_DAWN
                dawnTicksRemaining = DAWN_DURATION_TICKS
                if siegeCleared then
                    SN.log("SIEGE CLEARED! Kills: " .. kills .. " + " .. bonus .. " bonus/" .. target
                        .. " | Spawned: " .. siegeData.spawnedThisSiege)
                end
                if isServer() then
                    sendServerCommand(SN.CLIENT_MODULE, "StateChange", {
                        state = SN.STATE_DAWN,
                        spawnedTotal = siegeData.spawnedThisSiege or 0,
                        killsThisSiege = kills,
                        bonusKills = bonus,
                        specialKills = siegeData.specialKillsThisSiege or 0,
                        dawnFallback = dawnFallback,
                    })
                end
                SN.fireCallback("onSiegeEnd", siegeData.siegeCount, totalKills, siegeData.spawnedThisSiege or 0)
            end
        end
    end

    -- ==========================================
    -- DAWN → IDLE TRANSITION (tick-based delay)
    -- ==========================================
    if siegeData.siegeState == SN.STATE_DAWN then
        if dawnTicksRemaining <= 0 then
            dawnTicksRemaining = DAWN_DURATION_TICKS
            SN.debug("Dawn timer was not set — initializing to " .. DAWN_DURATION_TICKS)
        else
            dawnTicksRemaining = dawnTicksRemaining - 1
            if dawnTicksRemaining <= 0 then
                -- Record siege history
                siegeData.totalSiegesCompleted = (siegeData.totalSiegesCompleted or 0) + 1
                siegeData.totalKillsAllTime = (siegeData.totalKillsAllTime or 0) + getTotalSiegeKills(siegeData)
                siegeData.nextSiegeDay = math.floor(SN.getActualDay()) + SN.getSandbox("FrequencyDays")

                -- Store this siege's stats (capped to MAX_SIEGE_HISTORY)
                local idx = siegeData.totalSiegesCompleted
                siegeData["history_" .. idx .. "_kills"] = siegeData.killsThisSiege or 0
                siegeData["history_" .. idx .. "_bonus"] = siegeData.bonusKills or 0
                siegeData["history_" .. idx .. "_specials"] = siegeData.specialKillsThisSiege or 0
                siegeData["history_" .. idx .. "_spawned"] = siegeData.spawnedThisSiege or 0
                siegeData["history_" .. idx .. "_target"] = siegeData.targetZombies or 0
                siegeData["history_" .. idx .. "_day"] = math.floor(SN.getActualDay())
                siegeData["history_" .. idx .. "_dir"] = siegeData.lastDirection or -1

                -- Prune old history beyond cap
                local pruneIdx = idx - MAX_SIEGE_HISTORY
                if pruneIdx > 0 then
                    siegeData["history_" .. pruneIdx .. "_kills"] = nil
                    siegeData["history_" .. pruneIdx .. "_bonus"] = nil
                    siegeData["history_" .. pruneIdx .. "_specials"] = nil
                    siegeData["history_" .. pruneIdx .. "_spawned"] = nil
                    siegeData["history_" .. pruneIdx .. "_target"] = nil
                    siegeData["history_" .. pruneIdx .. "_day"] = nil
                    siegeData["history_" .. pruneIdx .. "_dir"] = nil
                end

                siegeData.siegeState = SN.STATE_IDLE
                SN.log("Returned to IDLE. Next siege day: " .. siegeData.nextSiegeDay
                    .. " | History recorded: siege #" .. idx)

                if isServer() then
                    sendServerCommand(SN.CLIENT_MODULE, "StateChange", {
                        state = SN.STATE_IDLE,
                        nextSiegeDay = siegeData.nextSiegeDay,
                        killsThisSiege = siegeData.killsThisSiege or 0,
                        specialKills = siegeData.specialKillsThisSiege or 0,
                    })
                end
            end
        end
    end

    -- ==========================================
    -- ZOMBIE ATTRACTION + RE-PATHING (during ACTIVE only)
    -- ==========================================
    if siegeData.siegeState == SN.STATE_ACTIVE then
        -- Sound attractor
        attractorTickCounter = attractorTickCounter - 1
        if attractorTickCounter <= 0 then
            attractorTickCounter = ATTRACTOR_INTERVAL
            local attractPlayers = getPlayerList()
            for _, player in ipairs(attractPlayers) do
                getWorldSoundManager():addSound(player, math.floor(player:getX()), math.floor(player:getY()), 0, 200, 10)
            end
            SN.debug("Sound attractor fired")
        end

        -- Re-pathing (lightweight — just path + target, no setAttackedBy)
        repathTickCounter = repathTickCounter - 1
        if repathTickCounter <= 0 then
            repathTickCounter = REPATH_INTERVAL
            local alive = {}
            local repathed = 0
            for _, entry in ipairs(siegeZombies) do
                local zombie = entry.zombie
                local player = entry.player
                local ok, dead = pcall(function() return zombie:isDead() end)
                if ok and not dead and player and player:isAlive() then
                    zombie:pathToCharacter(player)
                    zombie:setTarget(player)
                    table.insert(alive, entry)
                    repathed = repathed + 1
                end
            end
            siegeZombies = alive
            if repathed > 0 then
                SN.debug("Re-pathed " .. repathed .. " siege zombies (" .. #siegeZombies .. " tracked)")
            end
        end
    else
        if #siegeZombies > 0 then
            siegeZombies = {}
            SN.debug("Siege ended — cleared zombie tracking list")
        end
    end

    -- ==========================================
    -- WAVE-BASED SPAWN ENGINE (during ACTIVE only)
    -- ==========================================
    -- Detect debug-forced state transitions
    if siegeData.siegeState == SN.STATE_ACTIVE and lastServerState ~= SN.STATE_ACTIVE then
        if siegeData.spawnedThisSiege == 0 and spawnTickCounter > 1 then
            SN.debug("Detected ACTIVE state entry — resetting spawn counter")
            spawnTickCounter = 0
        end
        -- If wave structure wasn't built (debug-forced), build it now
        if #waveStructure == 0 and siegeData.targetZombies > 0 then
            waveStructure = SN.calculateWaveStructure(siegeData.targetZombies)
            currentWaveIndex = 1
            currentPhase = SN.PHASE_WAVE
            phaseSpawnedCount = 0
            phaseTargetCount = waveStructure[1] and waveStructure[1].waveSize or siegeData.targetZombies
            SN.log("Wave structure built (debug-forced): " .. #waveStructure .. " waves")
        end
    end
    lastServerState = siegeData.siegeState

    if siegeData.siegeState ~= SN.STATE_ACTIVE then return end
    if siegeData.spawnedThisSiege >= siegeData.targetZombies then
        -- All zombies spawned — notify clients once
        if not siegeData.hordeCompleteNotified then
            siegeData.hordeCompleteNotified = true
            SN.log("All " .. siegeData.targetZombies .. " zombies spawned. Fight to clear!")
            if isServer() then
                sendServerCommand(SN.CLIENT_MODULE, "HordeComplete", {
                    targetZombies = siegeData.targetZombies,
                    killsSoFar = siegeData.killsThisSiege or 0,
                })
            end
        end
        return
    end

    -- BREAK phase: count down, no spawning
    if currentPhase == SN.PHASE_BREAK then
        breakTicksRemaining = breakTicksRemaining - 1
        if breakTicksRemaining <= 0 then
            advanceWavePhase(siegeData)
        end
        return
    end

    -- Check if current phase target is reached
    if phaseSpawnedCount >= phaseTargetCount then
        advanceWavePhase(siegeData)
        -- If we just entered a break, return
        if currentPhase == SN.PHASE_BREAK then return end
    end

    -- Determine spawn interval based on current phase
    local interval
    if currentPhase == SN.PHASE_WAVE then
        interval = SN.WAVE_SPAWN_INTERVAL
    else
        interval = SN.TRICKLE_SPAWN_INTERVAL
    end

    spawnTickCounter = spawnTickCounter - 1
    if spawnTickCounter > 0 then return end
    spawnTickCounter = interval

    -- Determine batch size
    local batchSize
    if currentPhase == SN.PHASE_WAVE then
        batchSize = SN.WAVE_BATCH_SIZE
    else
        batchSize = SN.TRICKLE_BATCH_SIZE
    end

    SN.debug("Spawn tick: phase=" .. currentPhase .. " wave=" .. currentWaveIndex
        .. "/" .. #waveStructure .. " phaseSpawned=" .. phaseSpawnedCount
        .. "/" .. phaseTargetCount .. " total=" .. siegeData.spawnedThisSiege
        .. "/" .. siegeData.targetZombies)

    -- Build player list
    local playerList = getPlayerList()
    if #playerList == 0 then
        SN.debug("No players found for spawning")
        return
    end

    local zombiesPerPlayer = math.max(1, math.floor(batchSize / #playerList))

    -- MP visibility fix: if all players are within 100 tiles of each other,
    -- spawn all zombies relative to the centroid so both clients have them loaded.
    -- Otherwise fall back to per-player spawning.
    local useSharedSpawn = false
    local centroidPlayer = playerList[1]
    if #playerList > 1 then
        local allClose = true
        for i = 1, #playerList do
            for j = i + 1, #playerList do
                local dx = playerList[i]:getX() - playerList[j]:getX()
                local dy = playerList[i]:getY() - playerList[j]:getY()
                if math.sqrt(dx*dx + dy*dy) > 100 then
                    allClose = false
                    break
                end
            end
            if not allClose then break end
        end
        useSharedSpawn = allClose
        if useSharedSpawn then
            -- Pick the player closest to the centroid
            local cx, cy = 0, 0
            for _, p in ipairs(playerList) do cx = cx + p:getX(); cy = cy + p:getY() end
            cx = cx / #playerList; cy = cy / #playerList
            local bestDist = math.huge
            for _, p in ipairs(playerList) do
                local d = math.sqrt((p:getX()-cx)^2 + (p:getY()-cy)^2)
                if d < bestDist then bestDist = d; centroidPlayer = p end
            end
        end
    end

    for _, player in ipairs(playerList) do
        local spawnTarget = useSharedSpawn and centroidPlayer or player
        for i = 1, zombiesPerPlayer do
            if siegeData.spawnedThisSiege >= siegeData.targetZombies then break end
            if phaseSpawnedCount >= phaseTargetCount then break end

            local specialType = "normal"
            local healthMult = 1.5

            if shouldSpawnTank(siegeData) then
                specialType = "tank"
                healthMult = SN.getSandbox("TankHealthMultiplier")
                siegeData.tanksSpawned = siegeData.tanksSpawned + 1
                SN.log("TANK spawned! (" .. siegeData.tanksSpawned .. "/" .. SN.getSandbox("TankCount") .. ")")
            else
                specialType = rollSpecialType(siegeData)
            end

            if spawnOneZombie(spawnTarget, siegeData.lastDirection, specialType, healthMult) then
                siegeData.spawnedThisSiege = siegeData.spawnedThisSiege + 1
                phaseSpawnedCount = phaseSpawnedCount + 1
            end
        end
    end
end

-- ==========================================
-- INITIALIZATION
-- ==========================================

local function onGameTimeLoaded()
    SN.log("Server module loaded. Version " .. SN.VERSION)
    local siegeData = SN.getWorldData()
    if siegeData then
        SN.log("Current state: " .. siegeData.siegeState)
        SN.log("Next siege day: " .. siegeData.nextSiegeDay)
        SN.log("Siege count: " .. siegeData.siegeCount)
        SN.log("Total completed: " .. (siegeData.totalSiegesCompleted or 0))
        SN.log("All-time kills: " .. (siegeData.totalKillsAllTime or 0))

        -- Safety: validate nextSiegeDay isn't stale after server restart
        -- If nextSiegeDay is in the past AND state is IDLE, push it forward
        -- Prevents the "siege reset to today" bug after server restart
        local currentDay = math.floor(SN.getActualDay())
        if siegeData.siegeState == SN.STATE_IDLE and siegeData.nextSiegeDay <= currentDay then
            local freq = SN.getSandbox("FrequencyDays")
            -- Push forward to the next valid siege day from today
            while siegeData.nextSiegeDay <= currentDay do
                siegeData.nextSiegeDay = siegeData.nextSiegeDay + freq
            end
            SN.log("STALE nextSiegeDay detected — advanced to day " .. siegeData.nextSiegeDay)
        end

        -- If server restarted mid-siege (state is ACTIVE/WARNING but it's daytime), reset to IDLE
        if siegeData.siegeState == SN.STATE_ACTIVE or siegeData.siegeState == SN.STATE_WARNING then
            local currentHour = SN.getCurrentHour()
            if currentHour >= SN.DAWN_HOUR and currentHour < SN.WARNING_HOUR then
                SN.log("Server restarted mid-siege during daytime — resetting to IDLE")
                siegeData.siegeState = SN.STATE_IDLE
                siegeData.nextSiegeDay = currentDay + SN.getSandbox("FrequencyDays")
                SN.log("Next siege pushed to day " .. siegeData.nextSiegeDay)
            end
        end
    else
        SN.log("World data not available yet")
    end
end

-- ==========================================
-- EVENT HOOKS
-- ==========================================
Events.OnGameTimeLoaded.Add(onGameTimeLoaded)
Events.OnTick.Add(onServerTick)
Events.OnZombieDead.Add(onZombieDead)
Events.OnClientCommand.Add(onClientCommand)
