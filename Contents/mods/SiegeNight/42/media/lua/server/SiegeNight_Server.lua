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

local okSN, SN = pcall(require, "SiegeNight_Shared")
if not okSN or type(SN) ~= "table" then return end

-- Safety: this file must never run on MP clients.
-- (Singleplayer has isClient()==false, so SP still works.)
if isClient and isClient() then return end

-- ==========================================
-- MP CLUSTER HELPERS (module scope)
-- ==========================================

-- Build clusters of players by distance so one far-away player does not break shared spawning.
local function buildPlayerClusters(players, radius)
    local clusters = {}
    local visited = {}

    local function dist2(a, b)
        local dx = a:getX() - b:getX()
        local dy = a:getY() - b:getY()
        return dx*dx + dy*dy
    end

    local r2 = (radius or 200)
    r2 = r2 * r2

    for i = 1, #players do
        if not visited[i] then
            visited[i] = true
            local queue = { i }
            local idx = 1
            local members = {}
            while idx <= #queue do
                local qi = queue[idx]
                idx = idx + 1
                table.insert(members, players[qi])

                for j = 1, #players do
                    if not visited[j] then
                        if dist2(players[qi], players[j]) <= r2 then
                            visited[j] = true
                            table.insert(queue, j)
                        end
                    end
                end
            end
            table.insert(clusters, members)
        end
    end

    return clusters
end

local function pickCentroidPlayer(players)
    if #players == 0 then return nil end
    if #players == 1 then return players[1] end

    local cx, cy = 0, 0
    for _, p in ipairs(players) do cx = cx + p:getX(); cy = cy + p:getY() end
    cx = cx / #players; cy = cy / #players

    local best = players[1]
    local bestDist = math.huge
    for _, p in ipairs(players) do
        local d = (p:getX()-cx)*(p:getX()-cx) + (p:getY()-cy)*(p:getY()-cy)
        if d < bestDist then bestDist = d; best = p end
    end
    return best
end
-- ==========================================
-- LOCAL STATE
-- ==========================================

-- Dawn delay (ticks)
local dawnTicksRemaining = 0
local DAWN_DURATION_TICKS = 300  -- ~10 seconds at 30fps

-- ==========================================
-- SPECIAL CORPSE SANITY (MP)
-- ==========================================

local function worldAgeSecSafe()
    local w = getWorld()
    if w and w.getWorldAgeDays then
        local ok, d = pcall(function() return w:getWorldAgeDays() end)
        if ok and type(d) == "number" then return d * 86400 end
    end
    return 0
end

local function isZombieOnGround(z)
    if not z then return false end
    -- API varies by build, so guard multiple methods.
    if z.isOnFloor then
        local ok, v = pcall(function() return z:isOnFloor() end)
        if ok and v == true then return true end
    end
    if z.isKnockedDown then
        local ok, v = pcall(function() return z:isKnockedDown() end)
        if ok and v == true then return true end
    end
    if z.isFallOnFront then
        local ok, v = pcall(function() return z:isFallOnFront() end)
        if ok and v == true then return true end
    end
    if z.isFallOnBack then
        local ok, v = pcall(function() return z:isFallOnBack() end)
        if ok and v == true then return true end
    end
    return false
end

local function forceKillZombie(z)
    if not z then return end
    -- Try a few methods, all guarded.
    if z.Kill then pcall(function() z:Kill(nil) end) end
    if z.kill then pcall(function() z:kill(nil) end) end
    if z.setHealth then pcall(function() z:setHealth(0) end) end
end

local function specialCorpseSanityTick(siegeZombies)
    if not siegeZombies then return end
    local now = worldAgeSecSafe()
    for i = #siegeZombies, 1, -1 do
        local entry = siegeZombies[i]
        local z = entry and entry.zombie or nil
        if not z then
            table.remove(siegeZombies, i)
        else
            local md = z:getModData()
            if md and md.SN_SpecialType then
                local okDead, isDead = pcall(function() return z:isDead() end)
                if okDead and isDead then
                    md.SN_DownedAt = nil
                else
                    if isZombieOnGround(z) then
                        if not md.SN_DownedAt then md.SN_DownedAt = now end
                        if (now - md.SN_DownedAt) > 8 then
                            -- If a special has been on the ground for a while, force a clean kill.
                            forceKillZombie(z)
                            md.SN_DownedAt = now
                        end
                    else
                        md.SN_DownedAt = nil
                    end
                end
            end
        end
    end
end

-- Siege trigger types (stored in siegeData.siegeTrigger in ModData for persistence)
--   "scheduled" = normal nighttime siege from tick-based detection (default)
--   "manual"    = admin used !siege start
--   "vote"      = player vote passed
--   "debug"     = state forced via PZ debug panel or external ModData edit
-- Only "scheduled" sieges obey the dawn fallback. All others run until cleared or stopped.

--- Check if the current siege was player-initiated (not a scheduled nighttime siege).
--- Reads from ModData so it survives server restarts.
local function isPlayerTriggered(siegeData)
    local trigger = siegeData and siegeData.siegeTrigger
    return trigger == "manual" or trigger == "vote" or trigger == "debug"
end

-- ModData sync to clients (for UI panel updates)
local syncTickCounter = 0
local SYNC_INTERVAL = 60  -- ~2 seconds between client syncs

-- Zombie attraction system
local attractorTickCounter = 0
local ATTRACTOR_INTERVAL = 150  -- ~5 seconds

-- Siege zombie tracking for re-pathing
local siegeZombies = {}
local REPATH_INTERVAL = 300  -- ~5 seconds between re-paths (was 150)
local repathTickCounter = 0

-- Special corpse sanity (MP): periodically force-kill specials that get stuck "downed" forever
local corpseSanityCounter = 0
local CORPSE_SANITY_INTERVAL = 30  -- ~1s

-- Outfit patrol removed: server-side dressInNamedOutfit was causing naked zombies.

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

    -- DO NOT redress on death. Server-side dressInNamedOutfit overwrites client visuals
    -- and is the root cause of naked zombies. addZombiesInOutfit handles clothing correctly.
    local md = zombie:getModData()

    local siegeData = SN.getWorldData()
    if not siegeData then return end
    if siegeData.siegeState ~= SN.STATE_ACTIVE then return end
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
local function getPlayerList(includeOptedOut)
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
                    -- Skip opted-out players unless explicitly including them
                    if includeOptedOut or not player:getModData().SN_OptedOut then
                        table.insert(playerList, player)
                    end
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

local function getSpawnPosition(spawnPlayer, primaryDir, usePrimary)
    if not spawnPlayer then return nil end
    local px = spawnPlayer:getX()
    local py = spawnPlayer:getY()
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

    -- Helper: check if a square is inside an enclosed area
    -- Uses PZ's room system + checks for player-built objects (barricades, crates, walls)
    local function isInsideEnclosure(sq)
        -- If the square has a room assigned by PZ, it's inside a building
        if sq:getRoom() then return true end
        -- Check if the square has player-built floor/wall (IsoThumpable = player-built)
        local objects = sq:getObjects()
        if objects then
            for oi = 0, objects:size() - 1 do
                local obj = objects:get(oi)
                if obj and instanceof(obj, "IsoThumpable") then
                    return true
                end
            end
        end
        return false
    end

    -- Pass 1: ideal spot (must be in a loaded cell so all players can see it)
    for attempt = 0, 30 do
        local tryX = targetX + ZombRand(11) - 5
        local tryY = targetY + ZombRand(11) - 5
        local square = getWorld():getCell():getGridSquare(tryX, tryY, 0)
        if square then
            local isSafe = SafeHouse and SafeHouse.getSafeHouse and SafeHouse.getSafeHouse(square) or nil
            if square:isFree(false) and square:isOutside() and isSafe == nil and not isInsideEnclosure(square) then
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
            if square and square:isFree(false) and square:isOutside() and not isInsideEnclosure(square) then
                return tryX, tryY
            end
        end
    end

    -- Pass 3: random scatter - enforce minimum distance AND outdoor-only
    local pass3MinDist = math.max(40, spawnDist * 0.6)
    for fallback = 0, 30 do
        local range = math.floor(spawnDist * 0.7)
        local fx = math.floor(px + ZombRand(range * 2) - range)
        local fy = math.floor(py + ZombRand(range * 2) - range)
        local dist = math.sqrt((fx - px)^2 + (fy - py)^2)
        if dist >= pass3MinDist then
            local square = getWorld():getCell():getGridSquare(fx, fy, 0)
            if square and square:isFree(false) and square:isOutside() and not isInsideEnclosure(square) then
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

    -- Defensive casts: some servers end up with sandbox/moddata values as strings.
    -- Kahlua will throw "__le not defined for operand" on mixed-type comparisons.
    local siegeCount = tonumber(siegeData and siegeData.siegeCount) or 0
    local startWeek = tonumber(SN.getSandbox("SpecialZombiesStartWeek")) or 0
    if siegeCount < (startWeek - 1) then return "normal" end

    local hoursSinceDusk = tonumber(SN.getHoursSinceDusk()) or 0
    if hoursSinceDusk < (SN.MIDNIGHT_RELATIVE_HOUR or 4) then return "normal" end

    local roll = ZombRand(100)
    local sprinterChance = tonumber(SN.getSandbox("SprinterPercent")) or 0
    local breakerChance = tonumber(SN.getSandbox("BreakerPercent")) or 0

    if roll < sprinterChance then return "sprinter" end
    if roll < sprinterChance + breakerChance then return "breaker" end
    return "normal"
end

local function shouldSpawnTank(siegeData)
    if not SN.getSandbox("SpecialZombiesEnabled") then return false end

    -- Defensive casts: some servers end up with sandbox/moddata values as strings.
    -- Kahlua will throw "__le not defined for operand" on mixed-type comparisons.
    local siegeCount = tonumber(siegeData and siegeData.siegeCount) or 0
    local tanksSpawned = tonumber(siegeData and siegeData.tanksSpawned) or 0
    local startWeek = tonumber(SN.getSandbox("SpecialZombiesStartWeek")) or 0
    local tankCount = tonumber(SN.getSandbox("TankCount")) or 0

    if siegeCount < (startWeek - 1) then return false end
    if tanksSpawned >= tankCount then return false end

    local hoursSinceDusk = tonumber(SN.getHoursSinceDusk()) or 0
    local nightDuration = tonumber(SN.getNightDuration()) or 0
    if nightDuration <= 0 then return false end
    if hoursSinceDusk < (nightDuration * 0.65) then return false end

    local remainingTanks = tankCount - tanksSpawned
    local remainingHours = nightDuration - hoursSinceDusk
    if remainingHours <= 0 then return false end

    local chance = math.min(15, math.floor(remainingTanks / remainingHours * 30))
    return ZombRand(100) < chance
end

--- Queue for special zombie sandbox swaps -  processed ONE per tick to avoid race conditions.
--- In MP, swapping global sandbox options affects ALL zombies on the server for that instant.
--- By queuing and processing one per tick, we minimize the window of wrong values.
local specialQueue = {}

--- Apply special zombie VISUAL DISTINCTION immediately (safe, no sandbox swap).
--- Actual stat changes are queued and applied one-per-tick.
local function applySpecialStats(zombie, specialType)

    -- DEFENSIVE SPECIAL TAG: ensure sprinters/breakers/tanks are tagged for MP corpse sanity
    if specialType and specialType ~= "normal" then
        zombie:getModData().SN_SpecialType = specialType
    end
    if specialType == "normal" then return end

    -- Tag the zombie for identification immediately
    zombie:getModData().SN_Type = specialType
    zombie:getModData().SN_Siege = true

    -- Visual identification via outfit (safe to do immediately)
    -- Store in moddata so processSpecialQueue can re-apply after makeInactive
    if specialType == "breaker" then
        local outfit = SN.BREAKER_OUTFITS[ZombRand(#SN.BREAKER_OUTFITS) + 1]
        zombie:getModData().SN_Outfit = outfit
        if isServer() then
            local zid = zombie:getOnlineID()
            if zid and zid > 0 then
                sendServerCommand(SN.CLIENT_MODULE, "DressZombie", { id = zid, outfit = outfit })
            end
        else
            zombie:dressInNamedOutfit(outfit)
        end
    elseif specialType == "tank" then
        local outfit = SN.TANK_OUTFITS[ZombRand(#SN.TANK_OUTFITS) + 1]
        zombie:getModData().SN_Outfit = outfit
        if isServer() then
            local zid = zombie:getOnlineID()
            if zid and zid > 0 then
                sendServerCommand(SN.CLIENT_MODULE, "DressZombie", { id = zid, outfit = outfit })
            end
        else
            zombie:dressInNamedOutfit(outfit)
        end
    end
    -- Sprinters keep random outfit (SN_Outfit already set from spawnOneZombie)

    -- Queue the stat swap for next tick (one at a time)
    table.insert(specialQueue, { zombie = zombie, specialType = specialType })
end

--- Process ONE queued special zombie per tick.
--- Uses direct zombie API calls (setHealth, setSpeedMod) instead of the
--- makeInactive sandbox-swap hack, which caused invisible zombies in MP
--- because makeInactive(true)->makeInactive(false) desyncs the zombie
--- from remote clients' network streams.
local function processSpecialQueue()
    if #specialQueue == 0 then return end

    local entry = table.remove(specialQueue, 1)
    local zombie = entry.zombie
    local specialType = entry.specialType

    -- Verify zombie is still valid
    local ok, dead = pcall(function() return zombie:isDead() end)
    if not ok or dead then return end

    -- Direct stat manipulation (Bandits-style) -- no makeInactive needed
    local healthMult = SN.getSandbox("TankHealthMultiplier") or 5.0

    if specialType == "sprinter" then
        -- Fast zombie: boost speed
        zombie:setSpeedMod(1)  -- 1 = sprinter speed
    elseif specialType == "breaker" then
        -- Strong zombie: boost health moderately
        zombie:setHealth(2.0)
    elseif specialType == "tank" then
        -- Tough zombie: massive health, slightly slower
        zombie:setHealth(healthMult)
        zombie:setSpeedMod(0.7)  -- tanks are slower but beefy
    end

    -- Sync health to all clients via server command
    if isServer() then
        local zid = zombie:getOnlineID()
        if zid and zid > 0 then
            sendServerCommand(SN.CLIENT_MODULE, "SyncSpecial", {
                id = zid,
                specialType = specialType,
                health = zombie:getHealth(),
                speedMod = specialType == "sprinter" and 1 or (specialType == "tank" and 0.7 or nil)
            })
        end
    end

    -- DO NOT re-dress here. dressInNamedOutfit on server overwrites client visuals.
    -- setHealth/setSpeedMod do not strip clothing (verified by outfit test).
    SN.debug("Applied " .. specialType .. " stats directly (no makeInactive)")
end

-- ==========================================
-- SPAWN ENGINE
-- ==========================================

local function spawnOneZombie(spawnPlayer, aggroPlayer, primaryDir, specialType, healthMult)
    local usePrimary = (ZombRand(100) < 65)

    local spawnX, spawnY = getSpawnPosition(spawnPlayer, primaryDir, usePrimary)
    if not spawnX then
        SN.debug("Failed to find spawn position for zombie")
        return false
    end

    healthMult = healthMult or 1.5
    local outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1]

    local zombies = addZombiesInOutfit(spawnX, spawnY, 0, 1, outfit, 50, false, false, false, false, false, false, healthMult)
    if zombies and zombies:size() > 0 then
        local zombie = zombies:get(0)
        -- Store outfit in moddata (for kill tracking, future loot tier system)
        zombie:getModData().SN_Outfit = outfit
        -- DO NOT call dressInNamedOutfit or send RedressZombie here!
        -- addZombiesInOutfit already handles clothing on the client side.
        -- Server-side dressInNamedOutfit overwrites client visuals and causes naked zombies.
        applySpecialStats(zombie, specialType)

        -- DEFENSIVE SPECIAL TAG: ensure sprinters/breakers/tanks are tagged for MP corpse sanity
        if specialType and specialType ~= "normal" then
            zombie:getModData().SN_SpecialType = specialType
        end

        -- Soft targeting: sound-based pathing instead of GPS lock
        -- Zombies head toward the player's area but can lose track, wander, get stuck on walls
        if aggroPlayer then zombie:pathToSound(aggroPlayer:getX(), aggroPlayer:getY(), 0) end

        -- Tag as siege zombie
        zombie:getModData().SN_Siege = true

        -- Sound attractor (draws them toward player area naturally)
        if aggroPlayer then getWorldSoundManager():addSound(aggroPlayer, math.floor(aggroPlayer:getX()), math.floor(aggroPlayer:getY()), 0, 50, 5) end

        -- Track for re-pathing
        table.insert(siegeZombies, { zombie = zombie, player = aggroPlayer })
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

local function enterActiveState(siegeData, reason, playerList, trigger)
    trigger = trigger or "scheduled"
    local dir = pickPrimaryDirection(siegeData.lastDirection)
    siegeData.lastDirection = dir
    siegeData.siegeState = SN.STATE_ACTIVE
    siegeData.siegeTrigger = trigger
    siegeData.siegeCount = math.max(0, siegeData.siegeCount)

    -- Cap siege count to actual sieges completed + 1
    -- Prevents existing saves from getting hit with a massive first siege
    -- (e.g. adding mod on day 100 shouldn't mean siege #14 difficulty)
    local actualCompleted = siegeData.totalSiegesCompleted or 0
    if siegeData.siegeCount > actualCompleted + 1 then
        SN.log("SCALING CAP: siegeCount " .. siegeData.siegeCount .. " capped to " .. (actualCompleted + 1)
            .. " (only " .. actualCompleted .. " sieges actually completed)")
        siegeData.siegeCount = actualCompleted + 1
    end

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

    SN.log("ACTIVE state entered (" .. reason .. ", trigger=" .. trigger .. "). Siege #" .. siegeData.siegeCount
        .. ", target: " .. siegeData.targetZombies .. " zombies"
        .. " (" .. #waveStructure .. " waves)"
        .. " from " .. SN.DIR_NAMES[dir + 1]
        .. " | players=" .. playerCount .. " estMult=" .. string.format("%.2f", estMult))

    if isServer() then
        ModData.transmit("SiegeNight")
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
        sendResponseToPlayer(player, "Only admins can force-start a siege. Use !siege vote instead.")
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
    enterActiveState(siegeData, "manual trigger by " .. (player:getUsername() or "player"), playerList, "manual")
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
    siegeData.dawnToIdleProcessed = false
    siegeData.endSeq = (siegeData.endSeq or 0) + 1
    siegeData.endSeqProcessed = nil
    siegeData.ending = true
    -- Stop lock: prevents tick loop from re-triggering end logic / duplicate state changes right after manual stop
    local w = getWorld()
    local nowAge = 0
    if w and w.getWorldAgeDays then
        local ok, d = pcall(function() return w:getWorldAgeDays() end)
        if ok and type(d) == "number" then
            nowAge = d * 24
        end
    end
    siegeData.stopLockUntil = nowAge + (10.0 / 3600.0)
    if isServer() then ModData.transmit("SiegeNight") end
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
    if siegeData.siegeState ~= SN.STATE_IDLE then
        sendResponseToPlayer(player, "A siege is already in progress!")
        return
    end
    if voteState.active then
        sendResponseToPlayer(player, "A vote is already in progress. Type !siege yes to vote.")
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
        sendResponseToPlayer(player, "No vote in progress. Use !siege vote to start one.")
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
            enterActiveState(siegeData, "vote passed", playerList, "vote")
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
    elseif command == "CmdSiegeOptOut" then
        player:getModData().SN_OptedOut = true
        sendServerCommand(player, SN.CLIENT_MODULE, "ServerMsg", { msg = "You have opted out of sieges. Zombies will not spawn near you. Type !siege optin to rejoin." })
        SN.log("Player " .. (player:getUsername() or "?") .. " opted out of sieges")
    elseif command == "CmdSiegeOptIn" then
        player:getModData().SN_OptedOut = nil
        sendServerCommand(player, SN.CLIENT_MODULE, "ServerMsg", { msg = "You have opted back into sieges. Welcome back!" })
        SN.log("Player " .. (player:getUsername() or "?") .. " opted back into sieges")
    elseif command == "CmdTestOutfits" then
        -- Debug: spawn one zombie per outfit, check if clothed, report results
        if not isPlayerAdmin(player) then return end
        SN.log("=== OUTFIT VALIDATION TEST ===")
        local px, py = player:getX(), player:getY()
        local results = {}
        local outfits = SN.ZOMBIE_OUTFITS
        for idx, outfit in ipairs(outfits) do
            local sx = px + ((idx % 10) * 3) - 15
            local sy = py + (math.floor(idx / 10) * 3) - 6
            local ok, zombies = pcall(function()
                return addZombiesInOutfit(sx, sy, 0, 1, outfit, 50, false, false, false, false, false, false, 1.0)
            end)
            if ok and zombies and zombies:size() > 0 then
                local z = zombies:get(0)
                z:getModData().SN_TestOutfit = outfit
                -- Check if zombie has any worn items (dressed = has items)
                local wornCount = 0
                pcall(function()
                    local worn = z:getWornItems()
                    if worn then wornCount = worn:size() end
                end)
                local status = wornCount > 0 and "DRESSED(" .. wornCount .. ")" or "NAKED"
                table.insert(results, outfit .. "=" .. status)
                SN.log("  " .. outfit .. ": " .. status .. " (wornItems=" .. wornCount .. ")")
            else
                table.insert(results, outfit .. "=SPAWN_FAILED")
                SN.log("  " .. outfit .. ": SPAWN FAILED")
            end
        end
        -- Send summary to player
        local naked = 0
        local dressed = 0
        for _, r in ipairs(results) do
            if r:find("NAKED") then naked = naked + 1
            elseif r:find("DRESSED") then dressed = dressed + 1 end
        end
        local summary = "Outfit test: " .. dressed .. " dressed, " .. naked .. " naked, " .. #results .. " total"
        SN.log(summary)
        sendServerCommand(player, SN.CLIENT_MODULE, "CmdResponse", { message = summary })
        SN.log("=== END OUTFIT TEST ===")

    elseif command == "CmdRequestSync" then
        -- Client requesting full stats sync (on connect/game start)
        local siegeData = SN.getWorldData()
        if not siegeData then return end
        local syncArgs = {
            siegeState = siegeData.siegeState,
            siegeCount = siegeData.siegeCount,
            nextSiegeDay = siegeData.nextSiegeDay,
            totalSiegesCompleted = siegeData.totalSiegesCompleted or 0,
            totalKillsAllTime = siegeData.totalKillsAllTime or 0,
            killsThisSiege = siegeData.killsThisSiege or 0,
            bonusKills = siegeData.bonusKills or 0,
            specialKillsThisSiege = siegeData.specialKillsThisSiege or 0,
            spawnedThisSiege = siegeData.spawnedThisSiege or 0,
            targetZombies = siegeData.targetZombies or 0,
            lastDirection = siegeData.lastDirection or -1,
            currentWaveIndex = siegeData.currentWaveIndex or 0,
            currentPhase = siegeData.currentPhase or SN.PHASE_WAVE,
        }
        -- Include history entries
        local totalCompleted = siegeData.totalSiegesCompleted or 0
        for idx = 1, totalCompleted do
            local prefix = "history_" .. idx .. "_"
            syncArgs[prefix .. "kills"] = siegeData[prefix .. "kills"] or 0
            syncArgs[prefix .. "bonus"] = siegeData[prefix .. "bonus"] or 0
            syncArgs[prefix .. "specials"] = siegeData[prefix .. "specials"] or 0
            syncArgs[prefix .. "spawned"] = siegeData[prefix .. "spawned"] or 0
            syncArgs[prefix .. "target"] = siegeData[prefix .. "target"] or 0
            syncArgs[prefix .. "day"] = siegeData[prefix .. "day"] or 0
            syncArgs[prefix .. "dir"] = siegeData[prefix .. "dir"] or -1
        end
        sendServerCommand(player, SN.CLIENT_MODULE, "SyncAllStats", syncArgs)
        SN.log("Sent full stats sync to " .. (player:getUsername() or "player")
            .. ": siegeCount=" .. siegeData.siegeCount
            .. " totalCompleted=" .. (siegeData.totalSiegesCompleted or 0)
            .. " nextSiegeDay=" .. siegeData.nextSiegeDay)
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

    -- Periodic MP sanity: specials sometimes get stuck downed and never die,
    -- leaving "immortal" corpses. Clean them up server-side.
    corpseSanityCounter = corpseSanityCounter + 1
    if corpseSanityCounter >= CORPSE_SANITY_INTERVAL then
        corpseSanityCounter = 0
        if siegeData.siegeState == SN.STATE_ACTIVE and #siegeZombies > 0 then
            specialCorpseSanityTick(siegeZombies)
        end
    end

    -- ==========================================
    -- SYNC MODDATA TO CLIENTS (periodic)
    -- ==========================================
    syncTickCounter = syncTickCounter + 1
    if syncTickCounter >= SYNC_INTERVAL then
        syncTickCounter = 0
        if isServer() then
            ModData.transmit("SiegeNight")
            -- Push real-time siege data via command (more reliable than ModData on busy servers)
            -- Reuse outer siegeData (avoid shadowing)
            if siegeData and siegeData.siegeState == SN.STATE_ACTIVE then
                sendServerCommand(SN.CLIENT_MODULE, "SiegeTick", {
                    spawnedThisSiege = siegeData.spawnedThisSiege or 0,
                    killsThisSiege = siegeData.killsThisSiege or 0,
                    bonusKills = siegeData.bonusKills or 0,
                    specialKills = siegeData.specialKillsThisSiege or 0,
                    currentWaveIndex = currentWaveIndex,
                    currentPhase = currentPhase,
                    targetZombies = siegeData.targetZombies or 0,
                })
            end
        end
    end

    -- ==========================================
    -- TICK-BASED STATE CHECKS (every ~1 second)
    -- Replaces EveryHours for reliability -  EveryHours can miss if server lags
    -- ==========================================
    stateCheckCounter = stateCheckCounter - 1
    if stateCheckCounter <= 0 then
        stateCheckCounter = STATE_CHECK_INTERVAL
        local currentDay = math.floor(SN.getActualDay())
        local currentHour = SN.getCurrentHour()

        if siegeData.siegeState == SN.STATE_IDLE then
            -- Use nextSiegeDay as the sole authority for when sieges trigger.
            -- isSiegeDay (modular arithmetic) is only used as a fallback if nextSiegeDay
            -- was never properly initialized (e.g. migrating from older save).
            -- This prevents the "siege every day" bug where nextSiegeDay gets stuck at a
            -- low value due to missed DAWN->IDLE transitions.
            local isSiegeToday = (currentDay >= siegeData.nextSiegeDay)
            if not isSiegeToday and SN.isSiegeDay(currentDay) and siegeData.nextSiegeDay <= 0 then
                -- Fallback: nextSiegeDay was never set (old save migration)
                isSiegeToday = true
                SN.log("FALLBACK: nextSiegeDay was " .. siegeData.nextSiegeDay .. ", using isSiegeDay() for day " .. currentDay)
            end
            local startHour = SN.getSiegeStartHour()
            -- Warn on the siege day before the start hour (day-of warning)
            if isSiegeToday and SN.getSandbox("WarningSignsEnabled") and (not SN.isSiegeTime(currentHour)) and currentHour < startHour then
                siegeData.siegeState = SN.STATE_WARNING
                siegeData.siegeCount = math.max(0, SN.getSiegeCount(currentDay))
                SN.log("WARNING state entered (tick). Siege #" .. siegeData.siegeCount
                    .. " on day " .. currentDay
                    .. " | nextSiegeDay=" .. siegeData.nextSiegeDay
                    .. " | isSiegeDay()=" .. tostring(SN.isSiegeDay(currentDay)))
                if isServer() then
                    sendServerCommand(SN.CLIENT_MODULE, "StateChange", {
                        state = SN.STATE_WARNING,
                        siegeCount = siegeData.siegeCount,
                        day = currentDay,
                    })
                end
            end
            if isSiegeToday and SN.isSiegeTime(currentHour) then
                siegeData.siegeCount = math.max(0, SN.getSiegeCount(currentDay))
                local playerList = getPlayerList()
                enterActiveState(siegeData, "tick-based siege window detection", playerList, "scheduled")
            end

        elseif siegeData.siegeState == SN.STATE_WARNING then
            local startHour = SN.getSiegeStartHour()
            if SN.isSiegeTime(currentHour) and currentHour >= startHour then
                local playerList = getPlayerList()
                enterActiveState(siegeData, "tick-based siege window transition", playerList, "scheduled")
            end

        elseif siegeData.siegeState == SN.STATE_ACTIVE then
            local kills = siegeData.killsThisSiege or 0
            local bonus = siegeData.bonusKills or 0
            local totalKills = getTotalSiegeKills(siegeData)
            local target = siegeData.targetZombies or 0
            local siegeCleared = target > 0 and totalKills >= target

            -- Dawn safety fallback: force end if it's daytime and this was a scheduled siege.
            -- Player-triggered sieges (manual/vote/debug) ignore time-of-day entirely --
            -- they run until cleared, stopped, or hard timeout.
            local playerTriggered = isPlayerTriggered(siegeData)
            local dawnFallback = false

            -- stopLockUntil is stored in "world-age hours" (days*24). Guarded for dedi safety.
            local nowAge = 0
            do
                local w = getWorld()
                if w and w.getWorldAgeDays then
                    local ok, d = pcall(function() return w:getWorldAgeDays() end)
                    if ok and type(d) == "number" then
                        nowAge = d * 24
                    end
                end
            end

            local stopLocked = siegeData.stopLockUntil and nowAge < siegeData.stopLockUntil
            if not playerTriggered and not siegeCleared and (not SN.isSiegeTime(currentHour)) and not stopLocked then
                dawnFallback = true
                SN.log("DAWN FALLBACK: Forcing scheduled siege end at hour " .. currentHour
                    .. " | Kills: " .. kills .. " + " .. bonus .. " bonus/" .. target
                    .. " | Spawned: " .. (siegeData.spawnedThisSiege or 0))
            end

            -- Hard safety timeout: prevents any siege from running forever.
            -- Scheduled sieges: 12h. Player-triggered sieges: 23h.
            -- Use !siege stop to end a player-triggered siege early.
            if not dawnFallback and not siegeCleared and siegeData.siegeStartHour then
                local elapsed = currentHour - siegeData.siegeStartHour
                if elapsed < 0 then elapsed = elapsed + 24 end
                local maxHours = playerTriggered and 23 or 12
                if elapsed > maxHours then
                    dawnFallback = true
                    SN.log("HARD TIMEOUT: Siege exceeded " .. maxHours .. "h (elapsed=" .. elapsed
                        .. "h, trigger=" .. (siegeData.siegeTrigger or "?") .. "). Forcing end.")
                end
            end

            if siegeCleared or dawnFallback then
                if siegeData.ending then return end

                siegeData.ending = true
                siegeData.endSeq = (siegeData.endSeq or 0) + 1
                siegeData.endSeqProcessed = nil
                siegeData.dawnToIdleProcessed = false

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
    -- DAWN -> IDLE TRANSITION (tick-based delay)
    -- ==========================================
    if siegeData.siegeState == SN.STATE_DAWN then
        if dawnTicksRemaining <= 0 then
            dawnTicksRemaining = DAWN_DURATION_TICKS
            SN.debug("Dawn timer was not set - initializing to " .. DAWN_DURATION_TICKS)
            return
        end

        dawnTicksRemaining = dawnTicksRemaining - 1
        if dawnTicksRemaining > 0 then return end

        -- Guard: DAWN->IDLE should only run once per siege end
        if siegeData.dawnToIdleProcessed then return end
        if siegeData.endSeqProcessed == siegeData.endSeq then return end

        siegeData.dawnToIdleProcessed = true
        siegeData.endSeqProcessed = siegeData.endSeq

        -- Record siege history
        siegeData.totalSiegesCompleted = (siegeData.totalSiegesCompleted or 0) + 1
        siegeData.totalKillsAllTime = (siegeData.totalKillsAllTime or 0) + getTotalSiegeKills(siegeData)

        local prevNextSiegeDay = siegeData.nextSiegeDay
        local nextFreq = SN.getNextFrequency()
        siegeData.nextSiegeDay = math.floor(SN.getActualDay()) + nextFreq
        SN.log("DAWN->IDLE: nextSiegeDay " .. prevNextSiegeDay .. " -> " .. siegeData.nextSiegeDay
            .. " (currentDay=" .. math.floor(SN.getActualDay()) .. ", freq=" .. nextFreq .. ")")

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
        siegeData.siegeTrigger = nil
        siegeData.ending = false
        siegeData.stopLockUntil = nil

        -- Keep this true for the rest of this tick cycle so we don't re-run the transition.
        -- It will be reset on the next siege start.
        SN.log("Returned to IDLE. Next siege day: " .. siegeData.nextSiegeDay
            .. " | History recorded: siege #" .. idx)

        if isServer() then
            ModData.transmit("SiegeNight")
            sendServerCommand(SN.CLIENT_MODULE, "StateChange", {
                state = SN.STATE_IDLE,
                nextSiegeDay = siegeData.nextSiegeDay,
                killsThisSiege = siegeData.killsThisSiege or 0,
                specialKills = siegeData.specialKillsThisSiege or 0,
            })
        end
    end

    -- ==========================================
    -- ZOMBIE ATTRACTION + RE-PATHING (during ACTIVE only)
    -- ==========================================
    if siegeData.siegeState == SN.STATE_ACTIVE then
        -- Build list of "active siege players" (alive and not recently respawned)
        -- Players who died during siege get a grace period so the horde doesn't chase them to respawn
        local siegePlayers = {}
        local allPlayers = getPlayerList()
        for _, player in ipairs(allPlayers) do
            if player and player:isAlive() then
                local pmd = player:getModData()
                -- Track siege base position (where player was when siege started or first seen)
                if not pmd.SN_SiegeBaseX then
                    pmd.SN_SiegeBaseX = player:getX()
                    pmd.SN_SiegeBaseY = player:getY()
                end
                -- If player moved more than 200 tiles from their siege base position,
                -- they probably respawned  don't attract zombies to their new position
                local dx = player:getX() - pmd.SN_SiegeBaseX
                local dy = player:getY() - pmd.SN_SiegeBaseY
                local distFromBase = math.sqrt(dx*dx + dy*dy)
                if distFromBase < 200 then
                    table.insert(siegePlayers, player)
                else
                    SN.debug("Player respawned far from base (" .. math.floor(distFromBase) .. " tiles) - skipping attraction")
                end
            end
        end

        -- Sound attractor (only for players still near their siege base)
        attractorTickCounter = attractorTickCounter - 1
        if attractorTickCounter <= 0 then
            attractorTickCounter = ATTRACTOR_INTERVAL
            for _, player in ipairs(siegePlayers) do
                getWorldSoundManager():addSound(player, math.floor(player:getX()), math.floor(player:getY()), 0, 50, 5)
            end
            SN.debug("Sound attractor fired for " .. #siegePlayers .. "/" .. #allPlayers .. " players")
        end

        -- Re-pathing (only toward players still at base)
        repathTickCounter = repathTickCounter - 1
        if repathTickCounter <= 0 then
            repathTickCounter = REPATH_INTERVAL
            local alive = {}
            local repathed = 0

            for _, entry in ipairs(siegeZombies) do
                local zombie = entry.zombie
                local player = entry.player

                local ok, dead = pcall(function() return zombie:isDead() end)
                if ok and not dead then
                    -- Only re-path if the assigned player is still in siegePlayers list
                    local playerActive = false
                    for _, sp in ipairs(siegePlayers) do
                        if sp == player then playerActive = true; break end
                    end

                    if playerActive then
                        -- downed zombies should not be re-pathed/aggroed (prevents unlootable panting bodies)
                        if isZombieOnGround(zombie) then
                            zombie:setTarget(nil)
                            table.insert(alive, entry)
                        else
                            if player then
                                zombie:pathToSound(player:getX(), player:getY(), 0)
                            end
                            table.insert(alive, entry)
                            repathed = repathed + 1
                        end
                    else
                        -- Zombie's player died/respawned -- stop tracking, let zombie wander
                        zombie:setTarget(nil)
                    end
                end
            end

            siegeZombies = alive
            if repathed > 0 then
                SN.debug("Re-pathed " .. repathed .. " siege zombies (" .. #siegeZombies .. " tracked)")
            end
        end

        -- Outfit patrol removed: server-side dressInNamedOutfit was CAUSING naked zombies
        -- by overwriting client-side visuals. addZombiesInOutfit handles clothing correctly.
    else
        if #siegeZombies > 0 then
            -- Clear siege base positions on all players
            local endPlayers = getPlayerList()
            for _, p in ipairs(endPlayers) do
                if p then
                    p:getModData().SN_SiegeBaseX = nil
                    p:getModData().SN_SiegeBaseY = nil
                end
            end
            -- Clear targeting on all surviving siege zombies so they revert to vanilla behavior
            for _, entry in ipairs(siegeZombies) do
                local zombie = entry.zombie
                local ok, dead = pcall(function() return zombie:isDead() end)
                if ok and not dead then
                    zombie:setTarget(nil)
                    zombie:getModData().SN_Siege = nil
                end
            end
            siegeZombies = {}
            SN.debug("Siege ended - cleared zombie tracking and targeting")
        end
    end

    -- ==========================================
    -- WAVE-BASED SPAWN ENGINE (during ACTIVE only)
    -- ==========================================
    -- Detect debug-forced state transitions (e.g. sandbox editor, external ModData change)
    if siegeData.siegeState == SN.STATE_ACTIVE and lastServerState ~= SN.STATE_ACTIVE then
        if siegeData.spawnedThisSiege == 0 and spawnTickCounter > 1 then
            SN.debug("Detected ACTIVE state entry - resetting spawn counter")
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
        -- Debug-forced entries bypass enterActiveState, so siegeTrigger is never set.
        -- Tag it as "debug" so dawn fallback doesn't immediately kill it.
        if not siegeData.siegeTrigger then
            siegeData.siegeTrigger = "debug"
            SN.log("Debug-forced siege detected -- tagged as trigger=debug")
        end
    end
    lastServerState = siegeData.siegeState

    if siegeData.siegeState ~= SN.STATE_ACTIVE then return end
    if siegeData.spawnedThisSiege >= siegeData.targetZombies then
        -- All zombies spawned -  notify clients once
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

    -- MP visibility fix:
    -- Build clusters of nearby players so one far-away player doesn't force per-player spawning.
    -- Pick the largest cluster as the "anchor" group for the siege/mini-horde.
    local useSharedSpawn = false
    local centroidPlayer = playerList[1]
    local sharedRadius = SN.getSandbox("SharedSpawnRadius") or 200

    local clusters = buildPlayerClusters(playerList, sharedRadius)
    local largest = clusters[1] or playerList
    for _, c in ipairs(clusters) do
        if #c > #largest then largest = c end
    end

    centroidPlayer = pickCentroidPlayer(largest) or playerList[1]
    useSharedSpawn = true

    -- Only spawn/aggro around the anchor cluster. Other players can travel to the fight and will see it when close.
    playerList = largest

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

            if spawnOneZombie(spawnTarget, player, siegeData.lastDirection, specialType, healthMult) then
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
        -- Only advance if it is truly in the past.
        -- If nextSiegeDay == currentDay and we are IDLE, that is a valid "siege today" schedule.
        if type(siegeData.nextSiegeDay) ~= "number" then siegeData.nextSiegeDay = 0 end
        local currentDay = math.floor(SN.getActualDay())
        local stale = false
        if siegeData.siegeState == SN.STATE_IDLE then
            stale = (siegeData.nextSiegeDay < currentDay)
        elseif siegeData.siegeState == SN.STATE_DAWN then
            stale = (siegeData.nextSiegeDay <= currentDay)
        end

        if stale then
            local oldNext = siegeData.nextSiegeDay
            -- Push forward to the next valid siege day from today.
            -- If frequency is randomized, re-roll each step.
            while siegeData.nextSiegeDay < currentDay do
                siegeData.nextSiegeDay = siegeData.nextSiegeDay + SN.getNextFrequency()
            end
            if siegeData.siegeState == SN.STATE_DAWN and siegeData.nextSiegeDay <= currentDay then
                siegeData.nextSiegeDay = currentDay + SN.getNextFrequency()
            end
            SN.log("STALE nextSiegeDay detected (was " .. oldNext .. ") - advanced to day " .. siegeData.nextSiegeDay)
        end

        -- If server restarted mid-siege during daytime, check the trigger type:
        -- Scheduled sieges: reset to IDLE (shouldn't be active during day)
        -- Player-triggered sieges: keep alive (they chose to start during day)
        if siegeData.siegeState == SN.STATE_ACTIVE or siegeData.siegeState == SN.STATE_WARNING or siegeData.siegeState == SN.STATE_DAWN then
            local currentHour = SN.getCurrentHour()
            if not SN.isSiegeTime(currentHour) then
                if isPlayerTriggered(siegeData) then
                    SN.log("Server restarted mid-siege during daytime (trigger="
                        .. (siegeData.siegeTrigger or "?") .. ") -- keeping active")
                else
                    SN.log("Server restarted mid-scheduled-siege during daytime -- resetting to IDLE")
                    siegeData.siegeState = SN.STATE_IDLE
                    siegeData.siegeTrigger = nil
                    siegeData.dawnToIdleProcessed = false
                    siegeData.ending = false
                    siegeData.stopLockUntil = nil
                    if siegeData.nextSiegeDay <= currentDay then
                        siegeData.nextSiegeDay = currentDay + SN.getNextFrequency()
                    end
                    SN.log("Next siege day: " .. siegeData.nextSiegeDay)
                end
            end
        end
        -- Immediately transmit to all connected clients so they get persisted stats
        if isServer() then
            ModData.transmit("SiegeNight")
            SN.log("Transmitted ModData to clients on load")
        end
    else
        SN.log("World data not available yet")
    end
end

-- ==========================================
-- Transmit ModData to newly connected players
-- ==========================================
local function onPlayerConnect(player)
    if isServer() then
        ModData.transmit("SiegeNight")
        SN.log("Transmitted ModData to client on connect: " .. tostring(player:getUsername()))
    end
end

-- ==========================================
-- EVENT HOOKS
-- ==========================================
Events.OnGameTimeLoaded.Add(onGameTimeLoaded)
Events.OnTick.Add(onServerTick)
Events.OnZombieDead.Add(onZombieDead)
Events.OnClientCommand.Add(onClientCommand)
-- OnConnected is CLIENT-SIDE only. Use OnConnectedPlayer for server-side player join detection.
if Events.OnConnectedPlayer then
    Events.OnConnectedPlayer.Add(onPlayerConnect)
end




