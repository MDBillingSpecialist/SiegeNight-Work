--[[
    SiegeNight_Server.lua
    Core siege logic: state machine, wave-based spawn engine, directional attacks, special zombies.
    Runs SERVER-SIDE only.

    v2.6.0 - Per-cluster independent sieges
           - Each player group gets own waves, kills, direction, clear condition
           - Safehouse anchor system + multi-safehouse targeting
           - MaxActiveZombies per-cluster cap (replaces MAX_TRACKED_ZOMBIES)
           - Corpse sanity: 2s downed delay, force-kill specials at siege end
           - Wave system: WAVE -> TRICKLE -> BREAK -> repeat
           - Player count scaling, establishment scaling
           - Kill tracking (OnZombieDead + per-cluster routing via SN_ClusterID)
           - No CLEANUP state (DAWN -> IDLE)
           - Special zombie visual distinction
           - Tick-based state checks
           - Capped siege history to 20 entries
]]

local SN = require("SiegeNight_Shared")

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
-- PER-CLUSTER SIEGE STATE
-- ==========================================

local clusterSieges = {}
local nextClusterID = 1

local function createClusterState(id, members, playerCount)
    local centroid = pickCentroidPlayer(members)
    return {
        id = id,
        members = members,
        centroidPlayer = centroid,
        playerCount = playerCount or #members,
        siegeState = SN.STATE_ACTIVE,
        direction = 0,
        targetZombies = 0,
        spawnedThisSiege = 0,
        waveStructure = {},
        currentWaveIndex = 1,
        currentPhase = SN.PHASE_WAVE,
        phaseSpawnedCount = 0,
        phaseTargetCount = 0,
        breakTicksRemaining = 0,
        spawnTickCounter = 0,
        repathTickCounter = 0,
        attractorTickCounter = 0,
        corpseSanityCounter = 0,
        killsThisSiege = 0,
        bonusKills = 0,
        specialKillsThisSiege = 0,
        siegeZombies = {},
        specialQueue = {},
        anchors = {},
        dawnTicksRemaining = 0,
        ending = false,
        tanksSpawned = 0,
        hordeCompleteNotified = false,
    }
end

local function findPlayerCluster(player)
    if not player then return nil end
    for _, cs in pairs(clusterSieges) do
        for _, m in ipairs(cs.members) do
            if m == player then return cs end
        end
    end
    return nil
end

local function findNearestActiveCluster(x, y)
    local bestCS = nil
    local bestDist = math.huge
    for _, cs in pairs(clusterSieges) do
        if cs.siegeState == SN.STATE_ACTIVE then
            local cp = cs.centroidPlayer
            if cp then
                local dx = x - cp:getX()
                local dy = y - cp:getY()
                local d = dx*dx + dy*dy
                if d < bestDist then bestDist = d; bestCS = cs end
            end
        end
    end
    return bestCS
end

local function updateGlobalAggregates(siegeData)
    local totalKills = 0
    local totalBonus = 0
    local totalSpecial = 0
    local totalSpawned = 0
    local totalTarget = 0
    for _, cs in pairs(clusterSieges) do
        totalKills = totalKills + cs.killsThisSiege
        totalBonus = totalBonus + cs.bonusKills
        totalSpecial = totalSpecial + cs.specialKillsThisSiege
        totalSpawned = totalSpawned + cs.spawnedThisSiege
        totalTarget = totalTarget + cs.targetZombies
    end
    siegeData.killsThisSiege = totalKills
    siegeData.bonusKills = totalBonus
    siegeData.specialKillsThisSiege = totalSpecial
    siegeData.spawnedThisSiege = totalSpawned
    siegeData.targetZombies = totalTarget
end

local function notifyClusterPlayers(cs, command, args)
    if not isServer() then return end
    for _, player in ipairs(cs.members) do
        if player and player:isAlive() then
            sendServerCommand(player, SN.CLIENT_MODULE, command, args)
        end
    end
end

-- ==========================================
-- LOCAL STATE (global scope)
-- ==========================================

local dawnTicksRemaining = 0
local DAWN_DURATION_TICKS = 300

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
    if z.Kill then pcall(function() z:Kill(nil) end) end
    if z.kill then pcall(function() z:kill(nil) end) end
    if z.setHealth then pcall(function() z:setHealth(0) end) end
end

local function specialCorpseSanityTick(zombieList)
    if not zombieList then return end
    local now = worldAgeSecSafe()
    for i = #zombieList, 1, -1 do
        local entry = zombieList[i]
        local z = entry and entry.zombie or nil
        if not z then
            table.remove(zombieList, i)
        else
            local md = z:getModData()
            if md and md.SN_SpecialType then
                local okDead, isDead = pcall(function() return z:isDead() end)
                if okDead and isDead then
                    md.SN_DownedAt = nil
                else
                    if isZombieOnGround(z) then
                        if not md.SN_DownedAt then md.SN_DownedAt = now end
                        if (now - md.SN_DownedAt) > 2 then
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

local function isPlayerTriggered(siegeData)
    local trigger = siegeData and siegeData.siegeTrigger
    return trigger == "manual" or trigger == "vote" or trigger == "debug"
end

local syncTickCounter = 0
local SYNC_INTERVAL = 60
local REPATH_INTERVAL = 300
local CORPSE_SANITY_INTERVAL = 30
local ATTRACTOR_INTERVAL = 150

-- ==========================================
-- KILL TRACKING (per-cluster)
-- ==========================================
local function onZombieDead(zombie)
    if not zombie then return end
    local md = zombie:getModData()
    local siegeData = SN.getWorldData()
    if not siegeData then return end
    if siegeData.siegeState ~= SN.STATE_ACTIVE then return end

    local clusterID = md and md.SN_ClusterID
    local cs = clusterID and clusterSieges[clusterID] or nil

    if not cs then
        cs = findNearestActiveCluster(zombie:getX(), zombie:getY())
    end

    if not cs then return end

    if md and md.SN_Siege then
        cs.killsThisSiege = cs.killsThisSiege + 1
        if md.SN_Type and md.SN_Type ~= "normal" then
            cs.specialKillsThisSiege = cs.specialKillsThisSiege + 1
        end
    else
        cs.bonusKills = cs.bonusKills + 1
    end

    updateGlobalAggregates(siegeData)
end

local function getClusterTotalKills(cs)
    return cs.killsThisSiege + cs.bonusKills
end

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
local function getEstablishmentMultiplier(playerList)
    if not SN.getSandbox("MiniHorde_EstablishmentScaling") then return 1.0 end
    local score = 0
    for _, player in ipairs(playerList) do
        local cell = getWorld():getCell()
        if cell then
            local px, py = math.floor(player:getX()), math.floor(player:getY())
            for gx = -5, 5, 5 do
                for gy = -5, 5, 5 do
                    local sq = cell:getGridSquare(px + gx, py + gy, 0)
                    if sq then
                        local gen = sq:getGenerator()
                        if gen and gen:isRunning() then score = score + 30 end
                    end
                end
            end
        end
        local inv = player:getInventory()
        if inv then
            local weight = inv:getCapacityWeight()
            score = score + math.min(20, math.floor(weight))
        end
    end
    return 1.0 + math.min(1.0, score / 50)
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

local function getSpawnPosition(spawnPlayer, primaryDir, usePrimary, overrideX, overrideY)
    local px, py
    if overrideX and overrideY then
        px = overrideX
        py = overrideY
    elseif spawnPlayer then
        px = spawnPlayer:getX()
        py = spawnPlayer:getY()
    else
        return nil, nil
    end

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

    local function isInsideEnclosure(sq)
        if sq:getRoom() then return true end
        local objects = sq:getObjects()
        if objects then
            for oi = 0, objects:size() - 1 do
                local obj = objects:get(oi)
                if obj and instanceof(obj, "IsoThumpable") then return true end
            end
        end
        return false
    end

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
-- SAFEHOUSE ANCHOR SYSTEM
-- ==========================================

local function getNearestSafehouseCenter(player)
    if not player then return nil, nil end
    if not SafeHouse or not SafeHouse.getSafehouseList then return nil, nil end
    local px, py = player:getX(), player:getY()
    local bestDist = math.huge
    local bestX, bestY = nil, nil
    local safehouses = SafeHouse.getSafehouseList()
    if not safehouses then return nil, nil end
    for i = 0, safehouses:size() - 1 do
        local sh = safehouses:get(i)
        if sh then
            local sx = sh:getX() + math.floor(sh:getW() / 2)
            local sy = sh:getY() + math.floor(sh:getH() / 2)
            local dx = px - sx
            local dy = py - sy
            local d = dx*dx + dy*dy
            if d < bestDist then bestDist = d; bestX = sx; bestY = sy end
        end
    end
    return bestX, bestY
end

local function getClusteredSafehouseTargets(centroidPlayer)
    if not centroidPlayer then return {} end
    if not SafeHouse or not SafeHouse.getSafehouseList then return {} end
    local searchRadius = SN.getSandbox("SafehouseSearchRadius") or 300
    local mergeDistance = SN.getSandbox("SafehouseMergeDistance") or 50
    local px, py = centroidPlayer:getX(), centroidPlayer:getY()
    local r2 = searchRadius * searchRadius
    local mergeDist2 = mergeDistance * mergeDistance
    local candidates = {}
    local safehouses = SafeHouse.getSafehouseList()
    if not safehouses then return {} end
    for i = 0, safehouses:size() - 1 do
        local sh = safehouses:get(i)
        if sh then
            local w = sh:getW() or 1
            local h = sh:getH() or 1
            local cx = sh:getX() + math.floor(w / 2)
            local cy = sh:getY() + math.floor(h / 2)
            local dx = px - cx
            local dy = py - cy
            if (dx*dx + dy*dy) <= r2 then
                table.insert(candidates, { x = cx, y = cy, area = w * h })
            end
        end
    end
    if #candidates == 0 then return {} end
    local merged = {}
    local used = {}
    for i = 1, #candidates do
        if not used[i] then
            local group = { candidates[i] }
            used[i] = true
            for j = i + 1, #candidates do
                if not used[j] then
                    local dx = candidates[i].x - candidates[j].x
                    local dy = candidates[i].y - candidates[j].y
                    if (dx*dx + dy*dy) <= mergeDist2 then
                        table.insert(group, candidates[j])
                        used[j] = true
                    end
                end
            end
            local totalArea = 0
            local wx, wy = 0, 0
            for _, g in ipairs(group) do
                totalArea = totalArea + g.area
                wx = wx + g.x * g.area
                wy = wy + g.y * g.area
            end
            table.insert(merged, { x = math.floor(wx / totalArea), y = math.floor(wy / totalArea), area = totalArea })
        end
    end
    return merged
end

local function pickWeightedAnchor(targets)
    if not targets or #targets == 0 then return nil end
    if #targets == 1 then return targets[1] end
    local totalArea = 0
    for _, t in ipairs(targets) do totalArea = totalArea + t.area end
    if totalArea <= 0 then return targets[1] end
    local roll = ZombRand(totalArea)
    local cumulative = 0
    for _, t in ipairs(targets) do
        cumulative = cumulative + t.area
        if roll < cumulative then return t end
    end
    return targets[#targets]
end

-- ==========================================
-- SPECIAL ZOMBIE SYSTEM
-- ==========================================

local function rollSpecialType(siegeData)
    if not SN.getSandbox("SpecialZombiesEnabled") then return "normal" end
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

local function shouldSpawnTank(siegeData, cs)
    if not SN.getSandbox("SpecialZombiesEnabled") then return false end
    local siegeCount = tonumber(siegeData and siegeData.siegeCount) or 0
    local tanksSpawned = tonumber(cs and cs.tanksSpawned) or 0
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

-- Special zombie stats are now applied at spawn time in spawnOneZombie:
-- Sandbox lore is temporarily set BEFORE addZombiesInOutfit so the zombie
-- inherits correct speed/strength/toughness from birth. Health is set
-- immediately after spawn. No makeInactive needed (which caused lying down).
-- processSpecialQueue is kept as a no-op for backward compatibility.

local function processSpecialQueue(specQueue)
    -- No longer needed: specials now get their stats at spawn time via sandbox
    -- lore manipulation BEFORE addZombiesInOutfit. This avoids makeInactive()
    -- which caused zombies to visually collapse ("lying down" bug).
    -- Keeping function signature for backward compatibility; just drain any
    -- stale entries that may exist from a mid-siege code reload.
    if #specQueue > 0 then
        table.remove(specQueue, 1)
    end
end

-- ==========================================
-- ALIVE COUNT + ACTIVE CAP
-- ==========================================

local function countAliveSiegeZombies(cs)
    local alive = {}
    local count = 0
    for _, entry in ipairs(cs.siegeZombies) do
        local z = entry.zombie
        if z then
            local ok, dead = pcall(function() return z:isDead() end)
            if ok and not dead then
                table.insert(alive, entry)
                count = count + 1
            end
        end
    end
    cs.siegeZombies = alive
    return count
end

-- ==========================================
-- SPAWN ENGINE (per-cluster)
-- ==========================================

local function spawnOneZombie(spawnPlayer, aggroPlayer, primaryDir, specialType, healthMult, clusterID, zombieList, specQueue, anchorX, anchorY)
    local usePrimary = (ZombRand(100) < 65)
    local spawnX, spawnY = getSpawnPosition(spawnPlayer, primaryDir, usePrimary, anchorX, anchorY)
    if not spawnX then
        SN.debug("Failed to find spawn position for zombie")
        return false
    end
    healthMult = healthMult or 1.5
    -- Pick outfit BEFORE spawn so addZombiesInOutfit dresses the zombie correctly.
    -- This avoids post-spawn dressInNamedOutfit which causes naked zombies in MP.
    local outfit
    if specialType == "breaker" then
        outfit = SN.BREAKER_OUTFITS[ZombRand(#SN.BREAKER_OUTFITS) + 1]
    elseif specialType == "tank" then
        outfit = SN.TANK_OUTFITS[ZombRand(#SN.TANK_OUTFITS) + 1]
    else
        outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1]
    end
    -- For specials: temporarily set sandbox lore BEFORE spawn so the zombie
    -- inherits correct speed/strength/toughness from addZombiesInOutfit.
    -- This avoids makeInactive() which caused the "lying down" visual bug.
    local isSpecial = specialType and specialType ~= "normal"
    local origSpeed, origStrength, origToughness, origCognition
    if isSpecial then
        origSpeed = getSandboxOptions():getOptionByName("ZombieLore.Speed"):getValue()
        origStrength = getSandboxOptions():getOptionByName("ZombieLore.Strength"):getValue()
        origToughness = getSandboxOptions():getOptionByName("ZombieLore.Toughness"):getValue()
        origCognition = getSandboxOptions():getOptionByName("ZombieLore.Cognition"):getValue()
        if specialType == "sprinter" then
            getSandboxOptions():set("ZombieLore.Speed", 1)       -- Sprinter
        elseif specialType == "breaker" then
            getSandboxOptions():set("ZombieLore.Strength", 1)    -- Superhuman
            getSandboxOptions():set("ZombieLore.Cognition", 1)   -- Navigate + Use Doors
        elseif specialType == "tank" then
            getSandboxOptions():set("ZombieLore.Toughness", 1)   -- Tough
            getSandboxOptions():set("ZombieLore.Speed", 3)       -- Shambler (slow tank)
            getSandboxOptions():set("ZombieLore.Strength", 1)    -- Superhuman
        end
    end
    -- pcall-protect the spawn so sandbox lore is ALWAYS restored even if
    -- addZombiesInOutfit throws an error. Without this, a crash between set
    -- and restore would leave sandbox lore stuck (making ALL future zombies
    -- sprinters/tanks — the "all zombies dancing" bug).
    local ok, zombies = pcall(addZombiesInOutfit, spawnX, spawnY, 0, 1, outfit, 50, false, false, false, false, false, false, healthMult)
    -- ALWAYS restore sandbox lore, even on error
    if isSpecial then
        getSandboxOptions():set("ZombieLore.Speed", origSpeed)
        getSandboxOptions():set("ZombieLore.Strength", origStrength)
        getSandboxOptions():set("ZombieLore.Toughness", origToughness)
        getSandboxOptions():set("ZombieLore.Cognition", origCognition)
    end
    if not ok then
        SN.log("WARNING: addZombiesInOutfit failed: " .. tostring(zombies))
        return false
    end
    if zombies and zombies:size() > 0 then
        local zombie = zombies:get(0)
        local md = zombie:getModData()
        md.SN_Outfit = outfit
        md.SN_Siege = true
        md.SN_ClusterID = clusterID
        if isSpecial then
            md.SN_Type = specialType
            md.SN_SpecialType = specialType
            -- Apply health directly at spawn time (no deferred queue needed)
            local tankHealthMult = SN.getSandbox("TankHealthMultiplier") or 5.0
            if specialType == "breaker" then
                zombie:setHealth(2.0)
            elseif specialType == "tank" then
                zombie:setHealth(tankHealthMult)
            end
            -- Sync to clients so health bars and special indicators are correct
            if isServer() then
                local zid = zombie:getOnlineID()
                if zid and zid > 0 then
                    sendServerCommand(SN.CLIENT_MODULE, "SyncSpecial", {
                        id = zid, specialType = specialType,
                        health = zombie:getHealth(),
                    })
                end
            end
            SN.debug("Spawned " .. specialType .. " with lore-at-birth (outfit=" .. tostring(outfit) .. ")")
        end
        if aggroPlayer then zombie:pathToSound(aggroPlayer:getX(), aggroPlayer:getY(), 0) end
        if aggroPlayer then getWorldSoundManager():addSound(aggroPlayer, math.floor(aggroPlayer:getX()), math.floor(aggroPlayer:getY()), 0, 50, 5) end
        table.insert(zombieList, { zombie = zombie, player = aggroPlayer, anchorX = anchorX, anchorY = anchorY })
        return true
    end
    return false
end

-- ==========================================
-- WAVE PHASE MANAGEMENT (per-cluster)
-- ==========================================

local function advanceClusterWavePhase(cs, siegeData)
    if cs.currentPhase == SN.PHASE_WAVE then
        cs.currentPhase = SN.PHASE_TRICKLE
        cs.phaseSpawnedCount = 0
        local waveDef = cs.waveStructure[cs.currentWaveIndex]
        cs.phaseTargetCount = waveDef and waveDef.trickleSize or 0
        SN.log("Cluster " .. cs.id .. " Wave " .. cs.currentWaveIndex .. " TRICKLE: " .. cs.phaseTargetCount)
    elseif cs.currentPhase == SN.PHASE_TRICKLE then
        local waveDef = cs.waveStructure[cs.currentWaveIndex]
        local breakTicks = waveDef and waveDef.breakDurationTicks or 0
        if siegeData.debugBreakOverride and siegeData.debugBreakOverride > 0 then
            breakTicks = siegeData.debugBreakOverride
        end
        if breakTicks > 0 then
            cs.currentPhase = SN.PHASE_BREAK
            cs.breakTicksRemaining = breakTicks
            cs.phaseSpawnedCount = 0
            cs.phaseTargetCount = 0
            SN.log("Cluster " .. cs.id .. " Wave " .. cs.currentWaveIndex .. " BREAK: " .. string.format("%.1f", breakTicks / 1800) .. " min")
            notifyClusterPlayers(cs, "WaveBreak", { waveIndex = cs.currentWaveIndex, totalWaves = #cs.waveStructure, breakSeconds = math.floor(breakTicks / 30), clusterId = cs.id })
            SN.fireCallback("onBreakStart", cs.currentWaveIndex, #cs.waveStructure, breakTicks)
        else
            cs.currentWaveIndex = cs.currentWaveIndex + 1
            if cs.currentWaveIndex <= #cs.waveStructure then
                cs.currentPhase = SN.PHASE_WAVE
                cs.phaseSpawnedCount = 0
                cs.phaseTargetCount = cs.waveStructure[cs.currentWaveIndex].waveSize
                SN.log("Cluster " .. cs.id .. " Wave " .. cs.currentWaveIndex .. "/" .. #cs.waveStructure .. " WAVE: " .. cs.phaseTargetCount)
                notifyClusterPlayers(cs, "WaveStart", { waveIndex = cs.currentWaveIndex, totalWaves = #cs.waveStructure, clusterId = cs.id })
                SN.fireCallback("onWaveStart", cs.currentWaveIndex, #cs.waveStructure)
            end
        end
    elseif cs.currentPhase == SN.PHASE_BREAK then
        cs.currentWaveIndex = cs.currentWaveIndex + 1
        if cs.currentWaveIndex <= #cs.waveStructure then
            cs.currentPhase = SN.PHASE_WAVE
            cs.phaseSpawnedCount = 0
            cs.phaseTargetCount = cs.waveStructure[cs.currentWaveIndex].waveSize
            SN.log("Cluster " .. cs.id .. " Wave " .. cs.currentWaveIndex .. "/" .. #cs.waveStructure .. " WAVE: " .. cs.phaseTargetCount)
            notifyClusterPlayers(cs, "WaveStart", { waveIndex = cs.currentWaveIndex, totalWaves = #cs.waveStructure, clusterId = cs.id })
            SN.fireCallback("onWaveStart", cs.currentWaveIndex, #cs.waveStructure)
        else
            SN.log("Cluster " .. cs.id .. " All waves completed")
        end
    end
    siegeData.currentWaveIndex = cs.currentWaveIndex
    siegeData.currentPhase = cs.currentPhase
end

-- ==========================================
-- PER-CLUSTER TICK FUNCTIONS
-- ==========================================

local function getClusterSiegePlayers(cs)
    local siegePlayers = {}
    for _, player in ipairs(cs.members) do
        if player and player:isAlive() then
            local pmd = player:getModData()
            if not pmd.SN_SiegeBaseX then
                pmd.SN_SiegeBaseX = player:getX()
                pmd.SN_SiegeBaseY = player:getY()
            end
            local dx = player:getX() - pmd.SN_SiegeBaseX
            local dy = player:getY() - pmd.SN_SiegeBaseY
            if math.sqrt(dx*dx + dy*dy) < 200 then
                table.insert(siegePlayers, player)
            end
        end
    end
    return siegePlayers
end

local function tickClusterActive(cs, siegeData)
    processSpecialQueue(cs.specialQueue)

    cs.corpseSanityCounter = cs.corpseSanityCounter + 1
    if cs.corpseSanityCounter >= CORPSE_SANITY_INTERVAL then
        cs.corpseSanityCounter = 0
        if #cs.siegeZombies > 0 then specialCorpseSanityTick(cs.siegeZombies) end
    end

    local siegePlayers = getClusterSiegePlayers(cs)

    cs.attractorTickCounter = cs.attractorTickCounter - 1
    if cs.attractorTickCounter <= 0 then
        cs.attractorTickCounter = ATTRACTOR_INTERVAL
        for _, player in ipairs(siegePlayers) do
            getWorldSoundManager():addSound(player, math.floor(player:getX()), math.floor(player:getY()), 0, 50, 5)
        end
    end

    cs.repathTickCounter = cs.repathTickCounter - 1
    if cs.repathTickCounter <= 0 then
        cs.repathTickCounter = REPATH_INTERVAL
        local alive = {}
        local repathed = 0
        for _, entry in ipairs(cs.siegeZombies) do
            local zombie = entry.zombie
            local player = entry.player
            local ok, dead = pcall(function() return zombie:isDead() end)
            if ok and not dead then
                local playerActive = false
                for _, sp in ipairs(siegePlayers) do
                    if sp == player then playerActive = true; break end
                end
                if playerActive then
                    if isZombieOnGround(zombie) then
                        zombie:setTarget(nil)
                        table.insert(alive, entry)
                    else
                        local pathX = entry.anchorX or (player and player:getX()) or nil
                        local pathY = entry.anchorY or (player and player:getY()) or nil
                        if pathX and pathY then zombie:pathToSound(pathX, pathY, 0) end
                        table.insert(alive, entry)
                        repathed = repathed + 1
                    end
                else
                    zombie:setTarget(nil)
                end
            end
        end
        cs.siegeZombies = alive
        if repathed > 0 then SN.debug("Cluster " .. cs.id .. " re-pathed " .. repathed .. " (" .. #cs.siegeZombies .. " tracked)") end
    end

    -- Clear check
    local totalKills = getClusterTotalKills(cs)
    if cs.targetZombies > 0 and totalKills >= cs.targetZombies then
        if not cs.ending then
            cs.ending = true
            cs.siegeState = "DAWN"
            cs.dawnTicksRemaining = DAWN_DURATION_TICKS
            SN.log("Cluster " .. cs.id .. " CLEARED! " .. cs.killsThisSiege .. "+" .. cs.bonusKills .. "/" .. cs.targetZombies)
            notifyClusterPlayers(cs, "StateChange", { state = SN.STATE_DAWN, killsThisSiege = cs.killsThisSiege, bonusKills = cs.bonusKills, specialKills = cs.specialKillsThisSiege, clusterId = cs.id })
            for _, entry in ipairs(cs.siegeZombies) do
                local z = entry.zombie
                if z then local zmd = z:getModData(); if zmd then zmd.SN_BonusHP = nil end end
            end
            SN.fireCallback("onSiegeEnd", siegeData.siegeCount, totalKills, cs.spawnedThisSiege)
        end
        return
    end

    -- Horde complete notification
    if cs.spawnedThisSiege >= cs.targetZombies then
        if not cs.hordeCompleteNotified then
            cs.hordeCompleteNotified = true
            SN.log("Cluster " .. cs.id .. " all " .. cs.targetZombies .. " spawned")
            notifyClusterPlayers(cs, "HordeComplete", { targetZombies = cs.targetZombies, killsSoFar = cs.killsThisSiege, clusterId = cs.id })
        end
        return
    end

    -- MaxActiveZombies cap
    local maxActive = SN.getSandbox("MaxActiveZombies") or 300
    local aliveCount = countAliveSiegeZombies(cs)
    if aliveCount >= maxActive then return end

    -- BREAK countdown
    if cs.currentPhase == SN.PHASE_BREAK then
        cs.breakTicksRemaining = cs.breakTicksRemaining - 1
        if cs.breakTicksRemaining <= 0 then advanceClusterWavePhase(cs, siegeData) end
        return
    end

    if cs.phaseSpawnedCount >= cs.phaseTargetCount then
        advanceClusterWavePhase(cs, siegeData)
        if cs.currentPhase == SN.PHASE_BREAK then return end
    end

    local interval = cs.currentPhase == SN.PHASE_WAVE and SN.WAVE_SPAWN_INTERVAL or SN.TRICKLE_SPAWN_INTERVAL
    cs.spawnTickCounter = cs.spawnTickCounter - 1
    if cs.spawnTickCounter > 0 then return end
    cs.spawnTickCounter = interval

    local batchSize = cs.currentPhase == SN.PHASE_WAVE and SN.WAVE_BATCH_SIZE or SN.TRICKLE_BATCH_SIZE
    local capRoom = maxActive - aliveCount
    if capRoom <= 0 then return end
    batchSize = math.min(batchSize, capRoom)

    local zombiesPerPlayer = math.max(1, math.floor(batchSize / math.max(1, #siegePlayers)))
    local useAnchors = (SN.getSandbox("SpawnAnchor") == 2) and #cs.anchors > 0
    local spawnTarget = cs.centroidPlayer

    for _, player in ipairs(siegePlayers) do
        for i = 1, zombiesPerPlayer do
            if cs.spawnedThisSiege >= cs.targetZombies then break end
            if cs.phaseSpawnedCount >= cs.phaseTargetCount then break end
            local specialType = "normal"
            local healthMult = 1.5
            if shouldSpawnTank(siegeData, cs) then
                specialType = "tank"
                healthMult = SN.getSandbox("TankHealthMultiplier")
                cs.tanksSpawned = cs.tanksSpawned + 1
            else
                specialType = rollSpecialType(siegeData)
                if specialType == "breaker" then healthMult = 2.0 end
            end
            local anchorX, anchorY = nil, nil
            if useAnchors then
                local target = pickWeightedAnchor(cs.anchors)
                if target then anchorX = target.x; anchorY = target.y end
            end
            if spawnOneZombie(spawnTarget, player, cs.direction, specialType, healthMult, cs.id, cs.siegeZombies, cs.specialQueue, anchorX, anchorY) then
                cs.spawnedThisSiege = cs.spawnedThisSiege + 1
                cs.phaseSpawnedCount = cs.phaseSpawnedCount + 1
            end
        end
    end
    updateGlobalAggregates(siegeData)
end

local function tickClusterDawn(cs)
    cs.dawnTicksRemaining = cs.dawnTicksRemaining - 1
    if cs.dawnTicksRemaining <= 0 then
        cs.siegeState = "IDLE"
        local forceKilled = 0
        for _, entry in ipairs(cs.siegeZombies) do
            local zombie = entry.zombie
            local ok, dead = pcall(function() return zombie:isDead() end)
            if ok and not dead then
                local zmd = zombie:getModData()
                -- Force-kill specials so no super-powered zombies roam post-siege
                if zmd and zmd.SN_SpecialType and zmd.SN_SpecialType ~= "normal" then
                    forceKillZombie(zombie)
                    forceKilled = forceKilled + 1
                else
                    -- Normal siege zombies: untag and release
                    zombie:setTarget(nil)
                end
                if zmd then
                    zmd.SN_Siege = nil
                    zmd.SN_BonusHP = nil
                    zmd.SN_SpecialType = nil
                    zmd.SN_Type = nil
                end
            end
        end
        cs.siegeZombies = {}
        cs.specialQueue = {}
        for _, p in ipairs(cs.members) do
            if p then p:getModData().SN_SiegeBaseX = nil; p:getModData().SN_SiegeBaseY = nil end
        end
        SN.log("Cluster " .. cs.id .. " IDLE (force-killed " .. forceKilled .. " specials)")
    end
end

-- ==========================================
-- INITIALIZE CLUSTERS
-- ==========================================

local function initializeClusters(playerList, siegeData)
    clusterSieges = {}
    nextClusterID = 1
    local sharedRadius = SN.getSandbox("SharedSpawnRadius") or 200
    local clusters = buildPlayerClusters(playerList, sharedRadius)
    local estMult = getEstablishmentMultiplier(playerList)
    local playerCount = #playerList
    -- debugForceMax: Numpad 9 sets this flag so clusters use MaxZombies directly
    local forceMax = siegeData.debugForceMax
    siegeData.debugForceMax = nil  -- consume the flag

    for _, clusterMembers in ipairs(clusters) do
        local id = nextClusterID
        nextClusterID = nextClusterID + 1
        local cs = createClusterState(id, clusterMembers, playerCount)
        cs.direction = pickPrimaryDirection(siegeData.lastDirection)
        local maxZ = SN.getSandbox("MaxZombies")
        if forceMax then
            cs.targetZombies = maxZ
        else
            local clusterFraction = #clusterMembers / math.max(1, playerCount)
            local baseTarget = SN.calculateSiegeZombies(siegeData.siegeCount, playerCount)
            cs.targetZombies = math.min(math.max(10, math.floor(baseTarget * estMult * clusterFraction)), maxZ)
        end
        cs.waveStructure = SN.calculateWaveStructure(cs.targetZombies)
        cs.currentWaveIndex = 1
        cs.currentPhase = SN.PHASE_WAVE
        cs.phaseSpawnedCount = 0
        cs.phaseTargetCount = cs.waveStructure[1] and cs.waveStructure[1].waveSize or cs.targetZombies
        if SN.getSandbox("SpawnAnchor") == 2 then
            cs.anchors = getClusteredSafehouseTargets(cs.centroidPlayer)
            if #cs.anchors > 0 then SN.log("Cluster " .. id .. " found " .. #cs.anchors .. " safehouse targets") end
        end
        clusterSieges[id] = cs
        SN.log("Cluster " .. id .. ": " .. #clusterMembers .. " players, " .. cs.targetZombies .. " target, " .. #cs.waveStructure .. " waves, dir=" .. SN.getDirName(cs.direction))
        notifyClusterPlayers(cs, "StateChange", { state = SN.STATE_ACTIVE, siegeCount = siegeData.siegeCount, direction = cs.direction, targetZombies = cs.targetZombies, totalWaves = #cs.waveStructure, clusterId = cs.id })
    end
end

-- ==========================================
-- STATE MACHINE (global)
-- ==========================================

local function enterGlobalActiveState(siegeData, reason, playerList, trigger)
    trigger = trigger or "scheduled"
    siegeData.siegeState = SN.STATE_ACTIVE
    siegeData.siegeTrigger = trigger
    siegeData.siegeCount = math.max(0, siegeData.siegeCount)
    local actualCompleted = siegeData.totalSiegesCompleted or 0
    if siegeData.siegeCount > actualCompleted + 1 then
        SN.log("SCALING CAP: siegeCount " .. siegeData.siegeCount .. " -> " .. (actualCompleted + 1))
        siegeData.siegeCount = actualCompleted + 1
    end
    local dir = pickPrimaryDirection(siegeData.lastDirection)
    siegeData.lastDirection = dir
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
    siegeData.currentWaveIndex = 1
    siegeData.currentPhase = SN.PHASE_WAVE

    initializeClusters(playerList or {}, siegeData)

    SN.log("ACTIVE (" .. reason .. ", trigger=" .. trigger .. "). Siege #" .. siegeData.siegeCount
        .. ", target: " .. siegeData.targetZombies .. ", clusters: " .. (nextClusterID - 1)
        .. " | players=" .. playerCount .. " estMult=" .. string.format("%.2f", estMult))

    if isServer() then
        ModData.transmit("SiegeNight")
        sendServerCommand(SN.CLIENT_MODULE, "StateChange", {
            state = SN.STATE_ACTIVE, siegeCount = siegeData.siegeCount, direction = dir,
            targetZombies = siegeData.targetZombies,
            totalWaves = math.max(3, math.min(7, math.floor(siegeData.targetZombies / 60) + 2)),
        })
    end
    SN.fireCallback("onSiegeStart", siegeData.siegeCount, dir, siegeData.targetZombies)
end

local function finalizeGlobalSiegeEnd(siegeData)
    for _, cs in pairs(clusterSieges) do
        if cs.siegeState ~= "IDLE" then return false end
    end
    siegeData.totalSiegesCompleted = (siegeData.totalSiegesCompleted or 0) + 1
    updateGlobalAggregates(siegeData)
    siegeData.totalKillsAllTime = (siegeData.totalKillsAllTime or 0) + getTotalSiegeKills(siegeData)
    local prevNext = siegeData.nextSiegeDay
    local nextFreq = SN.getNextFrequency()
    siegeData.nextSiegeDay = math.floor(SN.getActualDay()) + nextFreq
    SN.log("DAWN->IDLE: nextSiegeDay " .. prevNext .. " -> " .. siegeData.nextSiegeDay)
    local MAX_SIEGE_HISTORY = 20
    local idx = siegeData.totalSiegesCompleted
    siegeData["history_" .. idx .. "_kills"] = siegeData.killsThisSiege or 0
    siegeData["history_" .. idx .. "_bonus"] = siegeData.bonusKills or 0
    siegeData["history_" .. idx .. "_specials"] = siegeData.specialKillsThisSiege or 0
    siegeData["history_" .. idx .. "_spawned"] = siegeData.spawnedThisSiege or 0
    siegeData["history_" .. idx .. "_target"] = siegeData.targetZombies or 0
    siegeData["history_" .. idx .. "_day"] = math.floor(SN.getActualDay())
    siegeData["history_" .. idx .. "_dir"] = siegeData.lastDirection or -1
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
    clusterSieges = {}
    SN.log("IDLE. Next siege day: " .. siegeData.nextSiegeDay .. " | History #" .. idx)
    if isServer() then
        ModData.transmit("SiegeNight")
        sendServerCommand(SN.CLIENT_MODULE, "StateChange", { state = SN.STATE_IDLE, nextSiegeDay = siegeData.nextSiegeDay, killsThisSiege = siegeData.killsThisSiege or 0, specialKills = siegeData.specialKillsThisSiege or 0 })
    end
    return true
end

-- ==========================================
-- PLAYER COMMANDS
-- ==========================================

local voteState = { active = false, voters = {}, needed = 0, startTick = 0 }
local VOTE_TIMEOUT_TICKS = 30 * 60

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
    if not siegeData then sendResponseToPlayer(player, "Siege Night not ready yet."); return end
    if siegeData.siegeState == SN.STATE_ACTIVE then sendResponseToPlayer(player, "A siege is already active!"); return end
    local playerList = getPlayerList()
    enterGlobalActiveState(siegeData, "manual trigger by " .. (player:getUsername() or "player"), playerList, "manual")
    broadcastToAll("CmdResponse", { message = "Siege started by " .. (player:getUsername() or "player") .. "!" })
end

local function handleSiegeStop(player)
    if isServer() and not isPlayerAdmin(player) then
        sendResponseToPlayer(player, "Only admins can force-end a siege.")
        return
    end
    local siegeData = SN.getWorldData()
    if not siegeData then sendResponseToPlayer(player, "Siege Night not ready yet."); return end
    if siegeData.siegeState ~= SN.STATE_ACTIVE then sendResponseToPlayer(player, "No siege is active."); return end
    for _, cs in pairs(clusterSieges) do
        if cs.siegeState == SN.STATE_ACTIVE then
            cs.ending = true
            cs.siegeState = "DAWN"
            cs.dawnTicksRemaining = DAWN_DURATION_TICKS
            for _, entry in ipairs(cs.siegeZombies) do
                local z = entry.zombie
                if z then local zmd = z:getModData(); if zmd then zmd.SN_BonusHP = nil end end
            end
        end
    end
    siegeData.siegeState = SN.STATE_DAWN
    dawnTicksRemaining = DAWN_DURATION_TICKS
    siegeData.dawnToIdleProcessed = false
    siegeData.endSeq = (siegeData.endSeq or 0) + 1
    siegeData.endSeqProcessed = nil
    siegeData.ending = true
    local w = getWorld()
    local nowAge = 0
    if w and w.getWorldAgeDays then
        local ok, d = pcall(function() return w:getWorldAgeDays() end)
        if ok and type(d) == "number" then nowAge = d * 24 end
    end
    siegeData.stopLockUntil = nowAge + (10.0 / 3600.0)
    if isServer() then ModData.transmit("SiegeNight") end
    updateGlobalAggregates(siegeData)
    broadcastToAll("StateChange", { state = SN.STATE_DAWN, spawnedTotal = siegeData.spawnedThisSiege or 0, killsThisSiege = siegeData.killsThisSiege or 0, specialKills = siegeData.specialKillsThisSiege or 0, dawnFallback = true })
    broadcastToAll("CmdResponse", { message = "Siege ended by " .. (player:getUsername() or "player") .. "." })
    SN.log("MANUAL SIEGE END by " .. (player:getUsername() or "player"))
    SN.fireCallback("onSiegeEnd", siegeData.siegeCount, siegeData.killsThisSiege or 0, siegeData.spawnedThisSiege or 0)
end

local function handleSiegeVote(player)
    local siegeData = SN.getWorldData()
    if not siegeData then return end
    if siegeData.siegeState ~= SN.STATE_IDLE then sendResponseToPlayer(player, "A siege is already in progress!"); return end
    if voteState.active then sendResponseToPlayer(player, "A vote is already in progress."); return end
    local playerList = getPlayerList()
    local needed = math.max(1, math.ceil(#playerList / 2))
    if #playerList <= 1 then handleSiegeStart(player); return end
    voteState.active = true
    voteState.voters = {}
    voteState.voters[player:getUsername() or "player"] = true
    voteState.needed = needed
    voteState.startTick = 0
    broadcastToAll("VoteStarted", { needed = tostring(needed) })
    broadcastToAll("VoteUpdate", { current = 1, needed = needed })
end

local function handleSiegeVoteYes(player)
    if not voteState.active then sendResponseToPlayer(player, "No vote in progress."); return end
    local name = player:getUsername() or "player"
    if voteState.voters[name] then sendResponseToPlayer(player, "You already voted!"); return end
    voteState.voters[name] = true
    local count = 0
    for _ in pairs(voteState.voters) do count = count + 1 end
    broadcastToAll("VoteUpdate", { current = count, needed = voteState.needed })
    if count >= voteState.needed then
        voteState.active = false
        broadcastToAll("VotePassed", {})
        local siegeData = SN.getWorldData()
        if siegeData then
            local playerList = getPlayerList()
            enterGlobalActiveState(siegeData, "vote passed", playerList, "vote")
        end
    end
end

local function checkVoteTimeout()
    if not voteState.active then return end
    voteState.startTick = (voteState.startTick or 0) + 1
    if voteState.startTick >= VOTE_TIMEOUT_TICKS then
        voteState.active = false
        broadcastToAll("VoteFailed", {})
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= SN.CLIENT_MODULE then return end
    if command == "CmdSiegeStart" then handleSiegeStart(player)
    elseif command == "CmdSiegeStop" then handleSiegeStop(player)
    elseif command == "CmdSiegeVote" then handleSiegeVote(player)
    elseif command == "CmdSiegeVoteYes" then handleSiegeVoteYes(player)
    elseif command == "CmdSiegeOptOut" then
        player:getModData().SN_OptedOut = true
        sendServerCommand(player, SN.CLIENT_MODULE, "ServerMsg", { msg = "Opted out of sieges." })
    elseif command == "CmdSiegeOptIn" then
        player:getModData().SN_OptedOut = nil
        sendServerCommand(player, SN.CLIENT_MODULE, "ServerMsg", { msg = "Opted back into sieges." })
    elseif command == "CmdTestOutfits" then
        if not isPlayerAdmin(player) then return end
        SN.log("=== OUTFIT VALIDATION TEST ===")
        local px, py = player:getX(), player:getY()
        local results = {}
        for idx, outfit in ipairs(SN.ZOMBIE_OUTFITS) do
            local sx = px + ((idx % 10) * 3) - 15
            local sy = py + (math.floor(idx / 10) * 3) - 6
            local ok, zombies = pcall(function() return addZombiesInOutfit(sx, sy, 0, 1, outfit, 50, false, false, false, false, false, false, 1.0) end)
            if ok and zombies and zombies:size() > 0 then
                local z = zombies:get(0)
                z:getModData().SN_TestOutfit = outfit
                local wornCount = 0
                pcall(function() local worn = z:getWornItems(); if worn then wornCount = worn:size() end end)
                table.insert(results, outfit .. "=" .. (wornCount > 0 and "DRESSED(" .. wornCount .. ")" or "NAKED"))
            else
                table.insert(results, outfit .. "=SPAWN_FAILED")
            end
        end
        local naked, dressed = 0, 0
        for _, r in ipairs(results) do
            if r:find("NAKED") then naked = naked + 1 elseif r:find("DRESSED") then dressed = dressed + 1 end
        end
        sendServerCommand(player, SN.CLIENT_MODULE, "CmdResponse", { message = "Outfit test: " .. dressed .. " dressed, " .. naked .. " naked" })
        SN.log("=== END OUTFIT TEST ===")
    elseif command == "CmdRequestSync" then
        local siegeData = SN.getWorldData()
        if not siegeData then return end
        local syncArgs = {
            siegeState = siegeData.siegeState, siegeCount = siegeData.siegeCount, nextSiegeDay = siegeData.nextSiegeDay,
            totalSiegesCompleted = siegeData.totalSiegesCompleted or 0, totalKillsAllTime = siegeData.totalKillsAllTime or 0,
            killsThisSiege = siegeData.killsThisSiege or 0, bonusKills = siegeData.bonusKills or 0,
            specialKillsThisSiege = siegeData.specialKillsThisSiege or 0, spawnedThisSiege = siegeData.spawnedThisSiege or 0,
            targetZombies = siegeData.targetZombies or 0, lastDirection = siegeData.lastDirection or -1,
            currentWaveIndex = siegeData.currentWaveIndex or 0, currentPhase = siegeData.currentPhase or SN.PHASE_WAVE,
        }
        for idx = 1, (siegeData.totalSiegesCompleted or 0) do
            local p = "history_" .. idx .. "_"
            syncArgs[p.."kills"] = siegeData[p.."kills"] or 0
            syncArgs[p.."bonus"] = siegeData[p.."bonus"] or 0
            syncArgs[p.."specials"] = siegeData[p.."specials"] or 0
            syncArgs[p.."spawned"] = siegeData[p.."spawned"] or 0
            syncArgs[p.."target"] = siegeData[p.."target"] or 0
            syncArgs[p.."day"] = siegeData[p.."day"] or 0
            syncArgs[p.."dir"] = siegeData[p.."dir"] or -1
        end
        local pcs = findPlayerCluster(player)
        if pcs then syncArgs.clusterId = pcs.id; syncArgs.aliveCount = countAliveSiegeZombies(pcs) end
        sendServerCommand(player, SN.CLIENT_MODULE, "SyncAllStats", syncArgs)
    end
end

-- ==========================================
-- MAIN SERVER TICK
-- ==========================================

local lastServerState = SN.STATE_IDLE
local stateCheckCounter = 0
local STATE_CHECK_INTERVAL = 30

local function onServerTick()
    if not SN.getSandbox("Enabled") then return end
    local siegeData = SN.getWorldData()
    if not siegeData then return end

    checkVoteTimeout()

    -- Tick all active clusters
    if siegeData.siegeState == SN.STATE_ACTIVE then
        local allDone = true
        for _, cs in pairs(clusterSieges) do
            if cs.siegeState == SN.STATE_ACTIVE then
                tickClusterActive(cs, siegeData)
                if cs.siegeState == SN.STATE_ACTIVE then allDone = false end
            elseif cs.siegeState == "DAWN" then
                tickClusterDawn(cs)
                if cs.siegeState ~= "IDLE" then allDone = false end
            end
        end
        updateGlobalAggregates(siegeData)

        -- Dawn fallback for scheduled sieges
        local currentHour = SN.getCurrentHour()
        local playerTriggered = isPlayerTriggered(siegeData)
        local nowAge = 0
        do
            local w = getWorld()
            if w and w.getWorldAgeDays then
                local ok, d = pcall(function() return w:getWorldAgeDays() end)
                if ok and type(d) == "number" then nowAge = d * 24 end
            end
        end
        local stopLocked = siegeData.stopLockUntil and nowAge < siegeData.stopLockUntil
        local dawnFallback = false

        if not playerTriggered and (not SN.isSiegeTime(currentHour)) and not stopLocked then
            dawnFallback = true
            SN.log("DAWN FALLBACK at hour " .. currentHour)
        end

        if not dawnFallback and siegeData.siegeStartHour then
            local elapsed = currentHour - siegeData.siegeStartHour
            if elapsed < 0 then elapsed = elapsed + 24 end
            if elapsed > (playerTriggered and 23 or 12) then
                dawnFallback = true
                SN.log("HARD TIMEOUT after " .. elapsed .. "h")
            end
        end

        if dawnFallback then
            for _, cs in pairs(clusterSieges) do
                if cs.siegeState == SN.STATE_ACTIVE then
                    cs.ending = true
                    cs.siegeState = "DAWN"
                    cs.dawnTicksRemaining = DAWN_DURATION_TICKS
                    for _, entry in ipairs(cs.siegeZombies) do
                        local z = entry.zombie
                        if z then local zmd = z:getModData(); if zmd then zmd.SN_BonusHP = nil end end
                    end
                end
            end
            if isServer() then
                sendServerCommand(SN.CLIENT_MODULE, "StateChange", { state = SN.STATE_DAWN, killsThisSiege = siegeData.killsThisSiege or 0, specialKills = siegeData.specialKillsThisSiege or 0, dawnFallback = true })
            end
            SN.fireCallback("onSiegeEnd", siegeData.siegeCount, getTotalSiegeKills(siegeData), siegeData.spawnedThisSiege or 0)
        end

        -- Finalize when all clusters done
        if allDone or dawnFallback then
            local reallyDone = true
            for _, cs in pairs(clusterSieges) do
                if cs.siegeState ~= "IDLE" then reallyDone = false; break end
            end
            if reallyDone then finalizeGlobalSiegeEnd(siegeData) end
        end
    end

    -- Sync to clients
    syncTickCounter = syncTickCounter + 1
    if syncTickCounter >= SYNC_INTERVAL then
        syncTickCounter = 0
        if isServer() then
            ModData.transmit("SiegeNight")
            if siegeData.siegeState == SN.STATE_ACTIVE then
                for _, cs in pairs(clusterSieges) do
                    if cs.siegeState == SN.STATE_ACTIVE then
                        local aliveCount = countAliveSiegeZombies(cs)
                        notifyClusterPlayers(cs, "SiegeTick", {
                            spawnedThisSiege = cs.spawnedThisSiege, killsThisSiege = cs.killsThisSiege,
                            bonusKills = cs.bonusKills, specialKills = cs.specialKillsThisSiege,
                            currentWaveIndex = cs.currentWaveIndex, currentPhase = cs.currentPhase,
                            targetZombies = cs.targetZombies, clusterId = cs.id, aliveCount = aliveCount,
                        })
                    end
                end
            end
        end
    end

    -- State checks
    stateCheckCounter = stateCheckCounter - 1
    if stateCheckCounter <= 0 then
        stateCheckCounter = STATE_CHECK_INTERVAL
        local currentDay = math.floor(SN.getActualDay())
        local currentHour = SN.getCurrentHour()

        if siegeData.siegeState == SN.STATE_IDLE then
            local isSiegeToday = (currentDay >= siegeData.nextSiegeDay)
            if not isSiegeToday and SN.isSiegeDay(currentDay) and siegeData.nextSiegeDay <= 0 then
                isSiegeToday = true
            end
            local startHour = SN.getSiegeStartHour()
            if isSiegeToday and SN.getSandbox("WarningSignsEnabled") and (not SN.isSiegeTime(currentHour)) and currentHour < startHour then
                siegeData.siegeState = SN.STATE_WARNING
                siegeData.siegeCount = math.max(0, SN.getSiegeCount(currentDay))
                SN.log("WARNING on day " .. currentDay)
                if isServer() then sendServerCommand(SN.CLIENT_MODULE, "StateChange", { state = SN.STATE_WARNING, siegeCount = siegeData.siegeCount, day = currentDay }) end
            end
            if isSiegeToday and SN.isSiegeTime(currentHour) then
                siegeData.siegeCount = math.max(0, SN.getSiegeCount(currentDay))
                enterGlobalActiveState(siegeData, "tick-based detection", getPlayerList(), "scheduled")
            end
        elseif siegeData.siegeState == SN.STATE_WARNING then
            if SN.isSiegeTime(SN.getCurrentHour()) then
                enterGlobalActiveState(siegeData, "warning->active transition", getPlayerList(), "scheduled")
            end
        end
    end

    -- Debug-forced state detection
    if siegeData.siegeState == SN.STATE_ACTIVE and lastServerState ~= SN.STATE_ACTIVE then
        if next(clusterSieges) == nil and siegeData.targetZombies > 0 then
            initializeClusters(getPlayerList(), siegeData)
        end
        if not siegeData.siegeTrigger then
            siegeData.siegeTrigger = "debug"
        end
    end
    lastServerState = siegeData.siegeState
end

-- ==========================================
-- INITIALIZATION
-- ==========================================

local function onGameTimeLoaded()
    SN.log("Server module loaded. Version " .. SN.VERSION)
    local siegeData = SN.getWorldData()
    if siegeData then
        SN.log("State: " .. siegeData.siegeState .. " | Next: day " .. siegeData.nextSiegeDay .. " | Count: " .. siegeData.siegeCount)
        if type(siegeData.nextSiegeDay) ~= "number" then siegeData.nextSiegeDay = 0 end
        local currentDay = math.floor(SN.getActualDay())
        local stale = false
        if siegeData.siegeState == SN.STATE_IDLE then stale = (siegeData.nextSiegeDay < currentDay)
        elseif siegeData.siegeState == SN.STATE_DAWN then stale = (siegeData.nextSiegeDay <= currentDay) end
        if stale then
            local oldNext = siegeData.nextSiegeDay
            while siegeData.nextSiegeDay < currentDay do siegeData.nextSiegeDay = siegeData.nextSiegeDay + SN.getNextFrequency() end
            if siegeData.siegeState == SN.STATE_DAWN and siegeData.nextSiegeDay <= currentDay then
                siegeData.nextSiegeDay = currentDay + SN.getNextFrequency()
            end
            SN.log("STALE nextSiegeDay " .. oldNext .. " -> " .. siegeData.nextSiegeDay)
        end
        if siegeData.siegeState == SN.STATE_ACTIVE or siegeData.siegeState == SN.STATE_WARNING or siegeData.siegeState == SN.STATE_DAWN then
            local currentHour = SN.getCurrentHour()
            if not SN.isSiegeTime(currentHour) then
                if isPlayerTriggered(siegeData) then
                    SN.log("Restarted mid-siege (trigger=" .. (siegeData.siegeTrigger or "?") .. ") -- keeping")
                    if siegeData.siegeState == SN.STATE_ACTIVE then
                        local pl = getPlayerList()
                        if #pl > 0 then initializeClusters(pl, siegeData) end
                    end
                else
                    SN.log("Restarted mid-scheduled-siege during day -- IDLE")
                    siegeData.siegeState = SN.STATE_IDLE
                    siegeData.siegeTrigger = nil
                    siegeData.ending = false
                    siegeData.stopLockUntil = nil
                    clusterSieges = {}
                    if siegeData.nextSiegeDay <= currentDay then siegeData.nextSiegeDay = currentDay + SN.getNextFrequency() end
                end
            else
                if siegeData.siegeState == SN.STATE_ACTIVE then
                    local pl = getPlayerList()
                    if #pl > 0 then initializeClusters(pl, siegeData) end
                end
            end
        end
        if isServer() then ModData.transmit("SiegeNight") end
    end
end

local function onPlayerConnect(player)
    if isServer() then
        ModData.transmit("SiegeNight")
        local siegeData = SN.getWorldData()
        if siegeData and siegeData.siegeState == SN.STATE_ACTIVE and next(clusterSieges) then
            local bestCS = findNearestActiveCluster(player:getX(), player:getY())
            if bestCS then
                table.insert(bestCS.members, player)
                bestCS.centroidPlayer = pickCentroidPlayer(bestCS.members)
                SN.log("Player " .. (player:getUsername() or "?") .. " joined cluster " .. bestCS.id)
            end
        end
    end
end

-- ==========================================
-- EVENT HOOKS
-- ==========================================
Events.OnGameTimeLoaded.Add(onGameTimeLoaded)
Events.OnTick.Add(onServerTick)
Events.OnZombieDead.Add(onZombieDead)
Events.OnClientCommand.Add(onClientCommand)
if Events.OnConnectedPlayer then Events.OnConnectedPlayer.Add(onPlayerConnect) end
