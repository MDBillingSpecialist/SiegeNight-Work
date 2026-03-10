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
local SN_Weather = require("SiegeNight_Weather")

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
local clusterRefreshTickCounter = 0
local CLUSTER_REFRESH_INTERVAL = 300

-- Forward declarations: these functions are defined later but referenced by
-- refreshActiveClusters / calculateDynamicSiegeTarget which appear first.
local pickNearestPlayer
local updateGlobalAggregates
local getPlayerList
local getEstablishmentMultiplier
local pickPrimaryDirection
local getClusteredSafehouseTargets

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
        currentPhase = SN.PHASE_SURGE,
        surgeSpawnedCount = 0,
        surgeTargetCount = 0,
        cooldownTicksRemaining = 0,
        surgeTickCounter = 0,
        surgesComplete = false,  -- true when all surge waves are done (baseline absorbs remaining)
        -- Baseline tide layer (constant pressure, independent of surge phase)
        baselineSpawned = 0,
        baselineBudget = 0,
        baselineTickCounter = 0,
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
        spawnCursor = 1,
        debugBreakOverride = nil,
    }
end

local function getPlayerKey(player)
    if not player then return "nil" end
    local ok, key = pcall(function()
        if player.getOnlineID then
            local onlineID = player:getOnlineID()
            if onlineID ~= nil then return "id:" .. tostring(onlineID) end
        end
        return "name:" .. tostring(player:getUsername() or player:getDisplayName() or "player")
    end)
    return ok and key or tostring(player)
end

local function sanitizeClusterMembers(cs)
    local aliveMembers = {}
    for _, player in ipairs(cs.members or {}) do
        local ok, alive = pcall(function() return player and player:isAlive() end)
        if ok and alive then
            table.insert(aliveMembers, player)
        end
    end
    cs.members = aliveMembers
    cs.playerCount = #aliveMembers
    cs.centroidPlayer = pickCentroidPlayer(aliveMembers)
    return aliveMembers
end

local function buildClusterSignatureFromGroups(groups)
    local parts = {}
    for _, group in ipairs(groups or {}) do
        local memberKeys = {}
        for _, player in ipairs(group) do
            table.insert(memberKeys, getPlayerKey(player))
        end
        table.sort(memberKeys)
        table.insert(parts, table.concat(memberKeys, ","))
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

local function calculateDynamicSiegeTarget(siegeData, playerList)
    local players = playerList or {}
    local playerCount = #players
    if playerCount <= 0 then
        return siegeData.targetZombies or 0
    end
    local estMult = getEstablishmentMultiplier(players)
    local baseTarget = SN.calculateSiegeZombies(siegeData.siegeCount, playerCount)
    local maxZ = SN.getSandboxNumber("MaxZombies", 10, 5000) or 4000
    return math.min(math.floor(baseTarget * estMult), maxZ)
end

local function allocateIntegerShares(total, groups)
    local allocations = {}
    total = math.max(0, math.floor(tonumber(total) or 0))
    if not groups or #groups == 0 then return allocations end
    local totalWeight = 0
    for _, group in ipairs(groups) do
        totalWeight = totalWeight + math.max(0, tonumber(group.weight) or 0)
    end
    if totalWeight <= 0 then
        allocations[1] = total
        for i = 2, #groups do allocations[i] = 0 end
        return allocations
    end

    local assigned = 0
    for i = 1, #groups do
        local share = (groups[i].weight or 0) / totalWeight
        local value = (i == #groups) and (total - assigned) or math.floor(total * share)
        allocations[i] = math.max(0, value)
        assigned = assigned + allocations[i]
    end
    return allocations
end

local function applySpawnProgressToCluster(cs, spawnedCount, cooldownTicksRemaining)
    local waveStructure, baselineBudget = SN.calculateWaveStructure(cs.targetZombies)
    cs.waveStructure = waveStructure
    cs.baselineBudget = baselineBudget
    cs.baselineTickCounter = SN.BASELINE_SPAWN_INTERVAL
    cs.currentWaveIndex = 1
    cs.currentPhase = SN.PHASE_SURGE
    cs.surgeSpawnedCount = 0
    cs.surgeTargetCount = waveStructure[1] and waveStructure[1].surgeSize or cs.targetZombies
    cs.cooldownTicksRemaining = 0

    -- Estimate how spawnedCount distributes across baseline + surges
    local totalSpent = math.max(0, math.min(cs.targetZombies, math.floor(tonumber(spawnedCount) or 0)))
    cs.baselineSpawned = math.min(baselineBudget, math.floor(totalSpent * baselineBudget / math.max(1, cs.targetZombies)))
    local surgeSpent = totalSpent - cs.baselineSpawned

    -- Walk through surge waves to find current position
    for waveIndex, waveDef in ipairs(waveStructure) do
        if surgeSpent < waveDef.surgeSize then
            cs.currentWaveIndex = waveIndex
            cs.currentPhase = SN.PHASE_SURGE
            cs.surgeSpawnedCount = surgeSpent
            cs.surgeTargetCount = waveDef.surgeSize
            return
        end
        surgeSpent = surgeSpent - waveDef.surgeSize

        if waveIndex < #waveStructure and cooldownTicksRemaining and cooldownTicksRemaining > 0 and surgeSpent <= 0 then
            cs.currentWaveIndex = waveIndex
            cs.currentPhase = SN.PHASE_COOLDOWN
            cs.surgeSpawnedCount = 0
            cs.surgeTargetCount = 0
            cs.cooldownTicksRemaining = cooldownTicksRemaining
            return
        end
    end

    -- Past all waves: all surges done
    cs.currentWaveIndex = #waveStructure
    cs.currentPhase = SN.PHASE_SURGE
    cs.surgeTargetCount = waveStructure[#waveStructure] and waveStructure[#waveStructure].surgeSize or 0
    cs.surgeSpawnedCount = cs.surgeTargetCount
end

local function refreshActiveClusters(siegeData, force)
    if not siegeData or siegeData.siegeState ~= SN.STATE_ACTIVE then return false end

    local players = getPlayerList()
    if #players <= 0 then return false end

    local sharedRadius = SN.getSandboxNumber("SharedSpawnRadius", 50, 500) or 200
    local groups = buildPlayerClusters(players, sharedRadius)
    local newSignature = buildClusterSignatureFromGroups(groups)
    if not force and siegeData.clusterSignature == newSignature then
        for _, cs in pairs(clusterSieges) do
            sanitizeClusterMembers(cs)
            if SN.getSandbox("SpawnAnchor") == 2 then
                cs.anchors = getClusteredSafehouseTargets(cs.centroidPlayer)
            end
        end
        return false
    end

    local oldClusters = {}
    for _, cs in pairs(clusterSieges) do
        sanitizeClusterMembers(cs)
        table.insert(oldClusters, cs)
    end

    local oldMembership = {}
    for oldIndex, cs in ipairs(oldClusters) do
        oldMembership[oldIndex] = {}
        for _, player in ipairs(cs.members) do
            oldMembership[oldIndex][getPlayerKey(player)] = true
        end
    end

    local groupData = {}
    for groupIndex, group in ipairs(groups) do
        local membership = {}
        local bestOldIndex = nil
        local bestOverlap = -1
        for _, player in ipairs(group) do
            membership[getPlayerKey(player)] = true
        end
        for oldIndex, members in ipairs(oldMembership) do
            local overlap = 0
            for key in pairs(membership) do
                if members[key] then overlap = overlap + 1 end
            end
            if overlap > bestOverlap then
                bestOverlap = overlap
                bestOldIndex = oldIndex
            end
        end
        groupData[groupIndex] = {
            members = group,
            membership = membership,
            sourceIndex = bestOldIndex,
            overlap = math.max(0, bestOverlap),
            counters = { spawned = 0, kills = 0, bonus = 0, special = 0, tanks = 0 },
            zombies = {},
        }
    end

    local oldClusterDescendants = {}
    for groupIndex, data in ipairs(groupData) do
        local oldIndex = data.sourceIndex
        if oldIndex then
            oldClusterDescendants[oldIndex] = oldClusterDescendants[oldIndex] or {}
            table.insert(oldClusterDescendants[oldIndex], {
                groupIndex = groupIndex,
                weight = math.max(1, data.overlap),
            })
        end
    end

    local metrics = {
        { key = "spawnedThisSiege", counter = "spawned" },
        { key = "killsThisSiege", counter = "kills" },
        { key = "bonusKills", counter = "bonus" },
        { key = "specialKillsThisSiege", counter = "special" },
        { key = "tanksSpawned", counter = "tanks" },
    }

    for oldIndex, cs in ipairs(oldClusters) do
        local descendants = oldClusterDescendants[oldIndex]
        if descendants and #descendants > 0 then
            for _, metric in ipairs(metrics) do
                local allocations = allocateIntegerShares(cs[metric.key] or 0, descendants)
                for allocIndex, value in ipairs(allocations) do
                    local targetGroup = descendants[allocIndex].groupIndex
                    groupData[targetGroup].counters[metric.counter] = groupData[targetGroup].counters[metric.counter] + value
                end
            end

            for _, entry in ipairs(cs.siegeZombies or {}) do
                local assigned = nil
                local entryPlayer = entry and entry.player
                local entryKey = getPlayerKey(entryPlayer)
                for _, desc in ipairs(descendants) do
                    if groupData[desc.groupIndex].membership[entryKey] then
                        assigned = desc.groupIndex
                        break
                    end
                end
                if not assigned and entry and entry.zombie then
                    local zx, zy = entry.zombie:getX(), entry.zombie:getY()
                    local bestDist = math.huge
                    for groupIndex, g in ipairs(groupData) do
                        local nearest = pickNearestPlayer(g.members, zx, zy)
                        if nearest then
                            local dx = nearest:getX() - zx
                            local dy = nearest:getY() - zy
                            local dist = dx * dx + dy * dy
                            if dist < bestDist then
                                bestDist = dist
                                assigned = groupIndex
                            end
                        end
                    end
                end
                if assigned then
                    table.insert(groupData[assigned].zombies, entry)
                end
            end
        end
    end

    local totalTarget = calculateDynamicSiegeTarget(siegeData, players)
    local weightedGroups = {}
    for groupIndex, data in ipairs(groupData) do
        weightedGroups[groupIndex] = { weight = #data.members }
    end
    local targetAllocations = allocateIntegerShares(totalTarget, weightedGroups)

    local newClusterSieges = {}
    local dominantDirection = siegeData.lastDirection or 0
    for groupIndex, data in ipairs(groupData) do
        local source = data.sourceIndex and oldClusters[data.sourceIndex] or nil
        local cs = createClusterState(groupIndex, data.members, #data.members)
        if source then
            cs.direction = source.direction or dominantDirection
            cs.surgeTickCounter = source.surgeTickCounter or 0
            cs.baselineTickCounter = source.baselineTickCounter or SN.BASELINE_SPAWN_INTERVAL
            cs.repathTickCounter = source.repathTickCounter or 0
            cs.attractorTickCounter = source.attractorTickCounter or 0
            cs.corpseSanityCounter = source.corpseSanityCounter or 0
            cs.debugBreakOverride = source.debugBreakOverride
            cs.hordeCompleteNotified = source.hordeCompleteNotified
        else
            cs.direction = pickPrimaryDirection(dominantDirection)
        end

        cs.targetZombies = math.max(10, targetAllocations[groupIndex] or 10)
        cs.spawnedThisSiege = math.min(cs.targetZombies, data.counters.spawned or 0)
        cs.killsThisSiege = data.counters.kills or 0
        cs.bonusKills = data.counters.bonus or 0
        cs.specialKillsThisSiege = data.counters.special or 0
        cs.tanksSpawned = data.counters.tanks or 0
        cs.siegeZombies = data.zombies or {}
        if SN.getSandbox("SpawnAnchor") == 2 then
            cs.anchors = getClusteredSafehouseTargets(cs.centroidPlayer)
        end
        applySpawnProgressToCluster(cs, cs.spawnedThisSiege, source and source.cooldownTicksRemaining or 0)
        if cs.spawnedThisSiege >= cs.targetZombies then
            cs.hordeCompleteNotified = true
        else
            cs.hordeCompleteNotified = false
        end
        newClusterSieges[groupIndex] = cs
    end

    clusterSieges = newClusterSieges
    nextClusterID = #groups + 1
    siegeData.clusterSignature = newSignature
    updateGlobalAggregates(siegeData)
    for _, cs in pairs(clusterSieges) do
        siegeData.currentWaveIndex = cs.currentWaveIndex
        siegeData.currentPhase = cs.currentPhase
        break
    end
    return true
end

pickNearestPlayer = function(players, x, y)
    local bestPlayer = nil
    local bestDist = math.huge
    for _, player in ipairs(players or {}) do
        local ok, px, py = pcall(function()
            if not player or not player:isAlive() then return nil, nil end
            return player:getX(), player:getY()
        end)
        if ok and px and py then
            local dx = x - px
            local dy = y - py
            local dist = dx * dx + dy * dy
            if dist < bestDist then
                bestDist = dist
                bestPlayer = player
            end
        end
    end
    return bestPlayer
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
                -- pcall guards against stale centroidPlayer refs from disconnected players
                local ok, px, py = pcall(function()
                    if not cp:isAlive() then return nil, nil end
                    return cp:getX(), cp:getY()
                end)
                if ok and px and py then
                    local dx = x - px
                    local dy = y - py
                    local d = dx*dx + dy*dy
                    if d < bestDist then bestDist = d; bestCS = cs end
                end
            end
        end
    end
    return bestCS
end

updateGlobalAggregates = function(siegeData)
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
        -- pcall guards against stale player objects from disconnected players
        local ok, alive = pcall(function() return player and player:isAlive() end)
        if ok and alive then
            pcall(sendServerCommand, player, SN.CLIENT_MODULE, command, args)
        end
    end
end

-- ==========================================
-- LOCAL STATE (global scope)
-- ==========================================

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
    local ok, result = pcall(function()
        if z.isOnFloor and z:isOnFloor() then return true end
        if z.isKnockedDown and z:isKnockedDown() then return true end
        if z.isFallOnFront and z:isFallOnFront() then return true end
        if z.isFallOnBack and z:isFallOnBack() then return true end
        return false
    end)
    return ok and result or false
end

local function forceKillZombie(z)
    if not z then return end

    -- Prefer engine kill paths first; fall back to health=0.
    if z.Kill then pcall(function() z:Kill(nil) end) end
    if z.kill then pcall(function() z:kill(nil) end) end
    if z.forceKill then pcall(function() z:forceKill() end) end

    if z.setHealth then pcall(function() z:setHealth(0) end) end

    -- Extra hardening for MP edge cases (downed-but-not-dead / unlootable corpse reports).
    -- These methods may not exist on all builds; guarded accordingly.
    if z.setBecomeCorpse then pcall(function() z:setBecomeCorpse(true) end) end
    if z.setFakeDead then pcall(function() z:setFakeDead(false) end) end
    if z.setReanimate then pcall(function() z:setReanimate(false) end) end
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
            local isSNZombie = md and (md.SN_SpecialType or md.SN_Siege or md.SN_MiniHorde)
            if isSNZombie then
                local okDead, isDead = pcall(function() return z:isDead() end)
                if okDead and isDead then
                    md.SN_DownedAt = nil
                else
                    if isZombieOnGround(z) then
                        if not md.SN_DownedAt then md.SN_DownedAt = now end
                        if (now - md.SN_DownedAt) > 2 then
                            SN.log("CorpseSanity: forceKill (siege) x=" .. tostring(z:getX()) .. " y=" .. tostring(z:getY()) .. " siege=" .. tostring(md.SN_Siege) .. " mini=" .. tostring(md.SN_MiniHorde) .. " special=" .. tostring(md.SN_SpecialType))
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
local REPATH_INTERVAL = 60          -- 2 sec (was 5 sec) — faster unstick for siege zombies
local CORPSE_SANITY_INTERVAL = 30
local ATTRACTOR_INTERVAL = 60       -- 2 sec (was 5 sec) — more frequent sound pulls
local STUCK_REPATH_CYCLES = 3       -- how many repath cycles before zombie is "stuck" (aggressive repath)
local STUCK_CULL_CYCLES = 8         -- how many repath cycles before stuck zombie is killed (no budget return)

-- ==========================================
-- KILL TRACKING (per-cluster)
-- ==========================================
local function onZombieDead(zombie)
    if not zombie then return end
    local md = zombie:getModData()
    local siegeData = SN.getWorldData()
    if not siegeData then return end
    -- Allow kill tracking if global state is ACTIVE or DAWN (clusters may still be ACTIVE
    -- even when global has transitioned to DAWN due to per-cluster independence)
    if siegeData.siegeState ~= SN.STATE_ACTIVE and siegeData.siegeState ~= SN.STATE_DAWN then return end

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
getPlayerList = function(includeOptedOut)
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
getEstablishmentMultiplier = function(playerList)
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

pickPrimaryDirection = function(lastDirection)
    local dir = ZombRand(8)
    local attempts = 0
    while dir == lastDirection and attempts < 20 do
        dir = ZombRand(8)
        attempts = attempts + 1
    end
    return dir
end

local function safeGetSquare(x, y, z)
    local w = getWorld()
    if not w then return nil end
    local cell = w:getCell()
    if not cell then return nil end
    return cell:getGridSquare(x, y, z or 0)
end

-- Strip non-clothing items from a zombie so siege spawns don't drop OP loot.
-- Keeps the visual outfit (Clothing items) but removes weapons, ammo, food, etc.
-- Also clears sub-containers inside clothing (pockets, bags, etc.).
local function stripZombieLoot(zombie)
    if not zombie then return end
    if not SN.getSandbox("StripSiegeZombieLoot") then return end
    pcall(function()
        local inv = zombie:getInventory()
        if not inv then return end
        -- Remove held items (some outfits give zombies weapons in hand)
        zombie:setPrimaryHandItem(nil)
        zombie:setSecondaryHandItem(nil)
        -- Collect non-clothing items to remove, clear clothing sub-containers
        local toRemove = {}
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item then
                if instanceof(item, "Clothing") then
                    -- Keep clothing (visual outfit) but empty its pockets/containers
                    local sub = item:getItemContainer()
                    if sub then sub:removeAllItems() end
                else
                    table.insert(toRemove, item)
                end
            end
        end
        for _, item in ipairs(toRemove) do
            inv:Remove(item)
        end
    end)
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

    local spawnDist = SN.getSandboxNumber("SpawnDistance", 15, 300) or 45
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
        local square = safeGetSquare(tryX, tryY, 0)
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
            local square = safeGetSquare(tryX, tryY, 0)
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
            local square = safeGetSquare(fx, fy, 0)
            if square and square:isFree(false) and square:isOutside() and not isInsideEnclosure(square) then
                return fx, fy
            end
        end
    end

    SN.log("SPAWN DIAG: All 91 position attempts failed near " .. math.floor(px) .. "," .. math.floor(py)
        .. " spawnDist=" .. tostring(spawnDist) .. " dir=" .. tostring(dir))
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

getClusteredSafehouseTargets = function(centroidPlayer)
    if not centroidPlayer then return {} end
    if not SafeHouse or not SafeHouse.getSafehouseList then return {} end
    local searchRadius = SN.getSandboxNumber("SafehouseSearchRadius", 50, 1000) or 300
    local mergeDistance = SN.getSandboxNumber("SafehouseMergeDistance", 10, 200) or 50
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
    local list = cs.siegeZombies
    local writeIdx = 0
    for readIdx = 1, #list do
        local entry = list[readIdx]
        local z = entry and entry.zombie
        if z then
            local ok, dead = pcall(function() return z:isDead() end)
            if ok and not dead then
                writeIdx = writeIdx + 1
                list[writeIdx] = entry
            end
        end
    end
    -- Trim dead entries from end (in-place, no new table allocation)
    for i = writeIdx + 1, #list do list[i] = nil end
    return writeIdx
end

-- ==========================================
-- SPAWN ENGINE (per-cluster)
-- ==========================================

local function spawnOneZombie(spawnPlayer, aggroPlayer, primaryDir, specialType, healthMult, clusterID, zombieList, specQueue, anchorX, anchorY)
    local usePrimary = (ZombRand(100) < 65)
    local spawnX, spawnY = getSpawnPosition(spawnPlayer, primaryDir, usePrimary, anchorX, anchorY)
    if not spawnX then
        -- Diagnostic: log position failure with details (helps debug "no spawns" reports)
        SN.log("SPAWN DIAG: getSpawnPosition FAILED for player=" .. tostring(spawnPlayer)
            .. " dir=" .. tostring(primaryDir) .. " anchorX=" .. tostring(anchorX))
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
    -- sprinters/tanks - the "all zombies dancing" bug).
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
    if not zombies or zombies:size() == 0 then
        SN.log("SPAWN DIAG: addZombiesInOutfit returned empty at " .. spawnX .. "," .. spawnY .. " outfit=" .. tostring(outfit))
        return false
    end
    if zombies:size() > 0 then
        local zombie = zombies:get(0)
        stripZombieLoot(zombie)
        local md = zombie:getModData()
        md.SN_Outfit = outfit
        md.SN_Siege = true
        md.SN_ClusterID = clusterID
        if isSpecial then
            md.SN_Type = specialType
            md.SN_SpecialType = specialType
            -- Apply health directly at spawn time (no deferred queue needed)
            local tankHealthMult = SN.getSandboxNumber("TankHealthMultiplier", 1.0, 20.0) or 5.0
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
        if aggroPlayer then
            -- Consolidated pcall: all targeting calls in one wrapper (lag optimization)
            pcall(function()
                local px = math.floor(aggroPlayer:getX())
                local py = math.floor(aggroPlayer:getY())
                if isServer() then
                    -- MP: server-side pathfinding
                    if anchorX and anchorY then
                        zombie:pathToLocationF(anchorX, anchorY, 0)
                    else
                        zombie:pathToCharacter(aggroPlayer)
                    end
                else
                    -- Solo: pathToCharacter crashes; use pathToLocationF to player coords instead
                    pcall(function() zombie:pathToLocationF(px + 0.5, py + 0.5, 0) end)
                end
                zombie:setTarget(aggroPlayer)
                zombie:setAttackedBy(aggroPlayer)
                zombie:spottedNew(aggroPlayer, true)
                zombie:addAggro(aggroPlayer, 2)
                getWorldSoundManager():addSound(aggroPlayer, px, py, 0, 200, 200)
            end)
        end
        -- Track spawn position for stuck detection
        local spawnPosX, spawnPosY = 0, 0
        pcall(function() spawnPosX = zombie:getX(); spawnPosY = zombie:getY() end)
        table.insert(zombieList, { zombie = zombie, player = aggroPlayer, anchorX = anchorX, anchorY = anchorY, lastX = spawnPosX, lastY = spawnPosY, stuckCount = 0 })
        return true
    end
    return false
end

-- ==========================================
-- WAVE PHASE MANAGEMENT (per-cluster)
-- ==========================================

local function advanceClusterWavePhase(cs, siegeData)
    -- Guard: once all surges are done, don't advance further
    if cs.surgesComplete then return end

    if cs.currentPhase == SN.PHASE_SURGE then
        -- Surge done → cooldown (or next surge if no cooldown)
        local waveDef = cs.waveStructure[cs.currentWaveIndex]
        local cooldownTicks = waveDef and waveDef.cooldownTicks or 0
        local cooldownOverride = cs.debugBreakOverride or siegeData.debugBreakOverride
        if cooldownOverride and cooldownOverride > 0 then
            cooldownTicks = cooldownOverride
        end
        if cooldownTicks > 0 then
            cs.currentPhase = SN.PHASE_COOLDOWN
            cs.cooldownTicksRemaining = cooldownTicks
            cs.surgeSpawnedCount = 0
            cs.surgeTargetCount = 0
            SN.log("Cluster " .. cs.id .. " Wave " .. cs.currentWaveIndex .. " COOLDOWN: " .. math.floor(cooldownTicks / 30) .. "s (baseline continues)")
            notifyClusterPlayers(cs, "WaveCooldown", { waveIndex = cs.currentWaveIndex, totalWaves = #cs.waveStructure, cooldownSeconds = math.floor(cooldownTicks / 30), breakSeconds = math.floor(cooldownTicks / 30), clusterId = cs.id })
            SN.fireCallback("onBreakStart", cs.currentWaveIndex, #cs.waveStructure, cooldownTicks)
        else
            -- No cooldown: advance to next surge immediately
            cs.currentWaveIndex = cs.currentWaveIndex + 1
            if cs.currentWaveIndex <= #cs.waveStructure then
                cs.currentPhase = SN.PHASE_SURGE
                cs.surgeSpawnedCount = 0
                cs.surgeTargetCount = cs.waveStructure[cs.currentWaveIndex].surgeSize
                SN.log("Cluster " .. cs.id .. " Wave " .. cs.currentWaveIndex .. "/" .. #cs.waveStructure .. " SURGE: " .. cs.surgeTargetCount)
                notifyClusterPlayers(cs, "WaveStart", { waveIndex = cs.currentWaveIndex, totalWaves = #cs.waveStructure, clusterId = cs.id })
                SN.fireCallback("onWaveStart", cs.currentWaveIndex, #cs.waveStructure)
                SN_Weather.intensifyForWave(cs.currentWaveIndex, #cs.waveStructure)
            else
                -- ALL SURGES DONE: mark complete, remaining budget becomes baseline-only
                cs.surgesComplete = true
                cs.currentPhase = SN.PHASE_COOLDOWN  -- cosmetic: shows "cooldown" (baseline still running)
                cs.cooldownTicksRemaining = 999999    -- won't expire — siege ends by kill count
                local remaining = cs.targetZombies - cs.spawnedThisSiege
                SN.log("Cluster " .. cs.id .. " All " .. #cs.waveStructure .. " surge waves completed. " .. remaining .. " remaining via baseline")
            end
        end
    elseif cs.currentPhase == SN.PHASE_COOLDOWN then
        -- Cooldown done → next surge
        cs.currentWaveIndex = cs.currentWaveIndex + 1
        if cs.currentWaveIndex <= #cs.waveStructure then
            cs.currentPhase = SN.PHASE_SURGE
            cs.surgeSpawnedCount = 0
            cs.surgeTargetCount = cs.waveStructure[cs.currentWaveIndex].surgeSize
            SN.log("Cluster " .. cs.id .. " Wave " .. cs.currentWaveIndex .. "/" .. #cs.waveStructure .. " SURGE: " .. cs.surgeTargetCount)
            notifyClusterPlayers(cs, "WaveStart", { waveIndex = cs.currentWaveIndex, totalWaves = #cs.waveStructure, clusterId = cs.id })
            SN.fireCallback("onWaveStart", cs.currentWaveIndex, #cs.waveStructure)
            SN_Weather.intensifyForWave(cs.currentWaveIndex, #cs.waveStructure)
        else
            -- ALL SURGES DONE: mark complete, remaining budget becomes baseline-only
            cs.surgesComplete = true
            cs.cooldownTicksRemaining = 999999
            local remaining = cs.targetZombies - cs.spawnedThisSiege
            SN.log("Cluster " .. cs.id .. " All " .. #cs.waveStructure .. " surge waves completed. " .. remaining .. " remaining via baseline")
        end
    end
    siegeData.currentWaveIndex = cs.currentWaveIndex
    siegeData.currentPhase = cs.currentPhase
end

-- ==========================================
-- PER-CLUSTER TICK FUNCTIONS
-- ==========================================

local function getClusterSiegePlayers(cs)
    return sanitizeClusterMembers(cs)
end

local function tickClusterActive(cs, siegeData)
    processSpecialQueue(cs.specialQueue)

    -- CorpseSanity: MP only. In solo, isOnFloor() gives false positives on standing
    -- zombies → force-kills healthy zombies → siege melts away without player action.
    if isServer() then
        cs.corpseSanityCounter = cs.corpseSanityCounter + 1
        if cs.corpseSanityCounter >= CORPSE_SANITY_INTERVAL then
            cs.corpseSanityCounter = 0
            if #cs.siegeZombies > 0 then specialCorpseSanityTick(cs.siegeZombies) end
        end
    end

    local siegePlayers = getClusterSiegePlayers(cs)
    if #siegePlayers <= 0 then
        if not cs.ending then
            cs.ending = true
            cs.siegeState = "DAWN"
            cs.dawnTicksRemaining = DAWN_DURATION_TICKS
            SN.log("Cluster " .. cs.id .. " has no active players; ending cluster")
        end
        return
    end

    cs.attractorTickCounter = cs.attractorTickCounter - 1
    if cs.attractorTickCounter <= 0 then
        cs.attractorTickCounter = ATTRACTOR_INTERVAL
        for _, player in ipairs(siegePlayers) do
            pcall(function() getWorldSoundManager():addSound(player, math.floor(player:getX()), math.floor(player:getY()), 0, 200, 200) end)
        end
    end

    cs.repathTickCounter = cs.repathTickCounter - 1
    if cs.repathTickCounter <= 0 then
        cs.repathTickCounter = REPATH_INTERVAL
        local alive = {}
        local repathed = 0
        local culled = 0
        for _, entry in ipairs(cs.siegeZombies) do
            local zombie = entry.zombie
            local player = entry.player
            local ok, dead = pcall(function() return zombie:isDead() end)
            if ok and not dead then
                local playerActive = false
                for _, sp in ipairs(siegePlayers) do
                    if sp == player then playerActive = true; break end
                end
                if not playerActive then
                    local zx, zy = zombie:getX(), zombie:getY()
                    player = pickNearestPlayer(siegePlayers, zx, zy) or cs.centroidPlayer or siegePlayers[1]
                    entry.player = player
                    playerActive = player ~= nil
                end
                if playerActive then
                    -- In MP, skip repath for downed zombies (CorpseSanity handles them).
                    -- In solo, skip this check — isOnFloor() has false positives in B42.
                    if isServer() and isZombieOnGround(zombie) then
                        pcall(function() zombie:setTarget(nil) end)
                        table.insert(alive, entry)
                    else
                        -- STUCK DETECTION: check if zombie has moved since last repath
                        local curX, curY = 0, 0
                        pcall(function() curX = zombie:getX(); curY = zombie:getY() end)
                        local lastX = entry.lastX or curX
                        local lastY = entry.lastY or curY
                        local movedDist = math.abs(curX - lastX) + math.abs(curY - lastY)
                        entry.lastX = curX
                        entry.lastY = curY

                        if movedDist < 2 then
                            entry.stuckCount = (entry.stuckCount or 0) + 1
                        else
                            entry.stuckCount = 0  -- reset if moved
                        end

                        -- STUCK CULLING: zombie hasn't moved for too many cycles
                        -- Solo: NEVER cull — zombies may not path well, culling causes
                        --   kill counter to race and waves to fly by. Just repath instead.
                        -- MP: cull after STUCK_CULL_CYCLES (server pathfinding should work)
                        local isSoloMode = (#siegePlayers <= 1) and not isServer()
                        if entry.stuckCount >= STUCK_CULL_CYCLES and not isSoloMode then
                            pcall(function()
                                zombie:setHealth(0)
                                zombie:setUseless(true)
                                zombie:makeInactive(true)
                            end)
                            culled = culled + 1
                            -- don't add to alive — zombie is removed
                        elseif entry.stuckCount >= STUCK_REPATH_CYCLES then
                            -- AGGRESSIVE UNSTICK: switch to nearest player
                            local zx, zy = curX, curY
                            local nearestP = pickNearestPlayer(siegePlayers, zx, zy) or player
                            entry.player = nearestP
                            pcall(function()
                                local npx = math.floor(nearestP:getX())
                                local npy = math.floor(nearestP:getY())
                                if isServer() then
                                    zombie:pathToCharacter(nearestP)
                                else
                                    pcall(function() zombie:pathToLocationF(npx + 0.5, npy + 0.5, 0) end)
                                end
                                zombie:setTarget(nearestP)
                                zombie:setAttackedBy(nearestP)
                                zombie:spottedNew(nearestP, true)
                                zombie:addAggro(nearestP, 3)
                                getWorldSoundManager():addSound(nearestP, math.floor(zx), math.floor(zy), 0, 200, 200)
                            end)
                            table.insert(alive, entry)
                            repathed = repathed + 1
                        else
                            -- NORMAL REPATH
                            pcall(function()
                                if isServer() then
                                    if entry.anchorX and entry.anchorY then
                                        zombie:pathToLocationF(entry.anchorX, entry.anchorY, 0)
                                    else
                                        zombie:pathToCharacter(player)
                                    end
                                else
                                    -- Solo: pathToLocationF to player coords (pathToCharacter crashes)
                                    local ppx = math.floor(player:getX())
                                    local ppy = math.floor(player:getY())
                                    pcall(function() zombie:pathToLocationF(ppx + 0.5, ppy + 0.5, 0) end)
                                end
                                if not entry.anchorX then
                                    zombie:setTarget(player)
                                    zombie:setAttackedBy(player)
                                    zombie:spottedNew(player, true)
                                    zombie:addAggro(player, 1)
                                end
                            end)
                            table.insert(alive, entry)
                            repathed = repathed + 1
                        end
                    end
                else
                    pcall(function() zombie:setTarget(nil) end)
                end
            end
        end
        cs.siegeZombies = alive
        if repathed > 0 then SN.debug("Cluster " .. cs.id .. " re-pathed " .. repathed .. " (" .. #cs.siegeZombies .. " tracked)") end
        if culled > 0 then SN.log("Cluster " .. cs.id .. " culled " .. culled .. " stuck zombies (budget returned)") end
    end

    -- Clear check
    local totalKills = getClusterTotalKills(cs)
    if cs.targetZombies > 0 and totalKills >= cs.targetZombies then
        if not cs.ending then
            cs.ending = true
            cs.siegeState = "DAWN"
            cs.dawnTicksRemaining = DAWN_DURATION_TICKS
            SN_Weather.clearWeather()
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

    -- =====================================================================
    -- TWO-LAYER SPAWN SYSTEM
    --   Layer 1: BASELINE TIDE — constant 1 zombie every 2 sec, always runs
    --   Layer 2: SURGE WAVES — periodic burst dumps of 50-100 zombies
    --   Both layers share MaxActive cap, spawnedThisSiege, and spawnCursor
    -- =====================================================================

    -- COOLDOWN countdown (runs regardless of MaxActive — cooldowns are pacing, not spawning)
    -- Note: baseline STILL SPAWNS during cooldown — only surge is paused
    if cs.currentPhase == SN.PHASE_COOLDOWN then
        cs.cooldownTicksRemaining = cs.cooldownTicksRemaining - 1
        if cs.cooldownTicksRemaining <= 0 then advanceClusterWavePhase(cs, siegeData) end
        -- Don't return — fall through to baseline spawning below
    end

    -- MaxActiveZombies cap (gates BOTH layers, but cooldown timer still counts down above)
    local maxActive = SN.getSandboxNumber("MaxActiveZombies", 1, 2000) or 400
    if maxActive < 1 then maxActive = 1 end  -- prevent 0 from freezing spawns forever
    local aliveCount = countAliveSiegeZombies(cs)
    local capRoom = maxActive - aliveCount
    local useAnchors = (SN.getSandbox("SpawnAnchor") == 2) and #cs.anchors > 0
    local spawnedThisTick = 0
    local totalBudgetRemaining = cs.targetZombies - cs.spawnedThisSiege

    -- One-time diagnostic log on first spawn tick of each siege
    if not cs._spawnDiagLogged then
        cs._spawnDiagLogged = true
        local centX = cs.centroidPlayer and math.floor(cs.centroidPlayer:getX()) or "nil"
        local centY = cs.centroidPlayer and math.floor(cs.centroidPlayer:getY()) or "nil"
        SN.log("SPAWN DIAG: cluster=" .. cs.id
            .. " target=" .. cs.targetZombies
            .. " phase=" .. tostring(cs.currentPhase)
            .. " surgeTarget=" .. cs.surgeTargetCount
            .. " baselineBudget=" .. cs.baselineBudget
            .. " siegePlayers=" .. #siegePlayers
            .. " maxActive=" .. maxActive
            .. " alive=" .. aliveCount
            .. " waves=" .. #cs.waveStructure
            .. " useAnchors=" .. tostring(useAnchors)
            .. " centroid=" .. centX .. "," .. centY
            .. " dir=" .. cs.direction)
    end

    -- -------------------------------------------------------
    -- LAYER 1: BASELINE TIDE (runs every tick, spawns slowly)
    -- When surges are complete, baseline absorbs ALL remaining budget
    -- and spawns faster (every tick instead of every 2 sec)
    -- -------------------------------------------------------
    -- Baseline draws from total budget continuously — no separate cap.
    -- This prevents dead periods during long cooldowns where baseline was exhausted.
    -- Surges and baseline share the same pool; total stays the same.
    local baselineRemaining = totalBudgetRemaining
    if baselineRemaining > 0 and capRoom > 0 then
        -- Scale baseline interval by day length (longer days = slower baseline = lasts the night)
        local dayScale = SN.getDayLengthScale()
        local blInterval = cs.surgesComplete and SN.SURGE_SPAWN_INTERVAL or math.max(1, math.floor(SN.BASELINE_SPAWN_INTERVAL * dayScale))
        local blBatchCap = cs.surgesComplete and 8 or 2
        cs.baselineTickCounter = cs.baselineTickCounter - 1
        if cs.baselineTickCounter <= 0 then
            cs.baselineTickCounter = blInterval
            local baselineBatch = math.min(SN.BASELINE_BATCH_SIZE, capRoom, baselineRemaining, totalBudgetRemaining)
            if cs.surgesComplete then baselineBatch = math.min(8, capRoom, baselineRemaining, totalBudgetRemaining) end
            for bi = 1, baselineBatch do
                if spawnedThisTick >= blBatchCap then break end
                local idx = ((cs.spawnCursor - 1) % #siegePlayers) + 1
                local player = siegePlayers[idx]
                -- Baseline spawns are always "normal" — no specials
                local anchorX, anchorY = nil, nil
                if useAnchors then
                    local target = pickWeightedAnchor(cs.anchors)
                    if target then anchorX = target.x; anchorY = target.y end
                end
                local spawnTarget = useAnchors and (cs.centroidPlayer or player) or player
                if spawnOneZombie(spawnTarget, player, cs.direction, "normal", 1.5, cs.id, cs.siegeZombies, cs.specialQueue, anchorX, anchorY) then
                    cs.spawnedThisSiege = cs.spawnedThisSiege + 1
                    cs.baselineSpawned = cs.baselineSpawned + 1
                    spawnedThisTick = spawnedThisTick + 1
                    if #siegePlayers > 0 then
                        cs.spawnCursor = ((cs.spawnCursor) % #siegePlayers) + 1
                    end
                end
            end
            -- Update shared state after baseline spawns
            capRoom = maxActive - aliveCount - spawnedThisTick
            totalBudgetRemaining = cs.targetZombies - cs.spawnedThisSiege
        end
    end

    -- -------------------------------------------------------
    -- LAYER 2: SURGE WAVES (only during PHASE_SURGE)
    -- -------------------------------------------------------
    if cs.currentPhase == SN.PHASE_SURGE and totalBudgetRemaining > 0 and capRoom > 0 then
        -- Check if current surge is exhausted → advance phase
        if cs.surgeSpawnedCount >= cs.surgeTargetCount then
            advanceClusterWavePhase(cs, siegeData)
            -- If we just entered cooldown, skip surge spawning this tick
            if cs.currentPhase ~= SN.PHASE_SURGE then
                updateGlobalAggregates(siegeData)
                return
            end
        end

        -- Solo pacing: spread each wave over ~15 seconds so waves feel distinct.
        -- MP: fast dump (1 tick interval, 15 batch, multi-player loop).
        local isSP = (#siegePlayers <= 1) and not isServer()
        local surgeInterval = SN.SURGE_SPAWN_INTERVAL
        local surgeBatch = SN.SURGE_BATCH_SIZE
        local MAX_SPAWNS_PER_TICK = math.max(12, math.min(20, #siegePlayers * 4))
        if isSP then
            -- Scale solo wave spawn time with day length (longer days = slower waves)
            local dayScale = SN.getDayLengthScale()
            local SOLO_WAVE_TICKS = math.floor(30 * 30 * dayScale)  -- 30s base × scale
            local surgeTarget = math.max(1, cs.surgeTargetCount)
            surgeInterval = math.max(10, math.floor(SOLO_WAVE_TICKS / surgeTarget))
            surgeBatch = 1
            MAX_SPAWNS_PER_TICK = 2
        end

        cs.surgeTickCounter = cs.surgeTickCounter - 1
        if cs.surgeTickCounter <= 0 then
            cs.surgeTickCounter = surgeInterval

            local surgeRemaining = cs.surgeTargetCount - cs.surgeSpawnedCount
            local totalThisTick = math.min(surgeBatch, MAX_SPAWNS_PER_TICK, capRoom, totalBudgetRemaining, surgeRemaining)

            for si = 1, totalThisTick do
                if spawnedThisTick >= (totalThisTick + 2) then break end
                local idx = ((cs.spawnCursor - 1) % #siegePlayers) + 1
                local player = siegePlayers[idx]
                local specialType = "normal"
                local healthMult = 1.5
                -- Specials only appear in surges (not baseline)
                if shouldSpawnTank(siegeData, cs) then
                    specialType = "tank"
                    healthMult = SN.getSandboxNumber("TankHealthMultiplier", 1.0, 20.0) or 5.0
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
                local spawnTarget = useAnchors and (cs.centroidPlayer or player) or player
                if spawnOneZombie(spawnTarget, player, cs.direction, specialType, healthMult, cs.id, cs.siegeZombies, cs.specialQueue, anchorX, anchorY) then
                    cs.spawnedThisSiege = cs.spawnedThisSiege + 1
                    cs.surgeSpawnedCount = cs.surgeSpawnedCount + 1
                    spawnedThisTick = spawnedThisTick + 1
                end
            end
        end
    end

    if #siegePlayers > 0 then
        cs.spawnCursor = ((cs.spawnCursor - 1 + spawnedThisTick) % #siegePlayers) + 1
    end
    -- Diagnostic: log when spawn attempts all fail (throttled to every 5 seconds)
    if spawnedThisTick == 0 and totalBudgetRemaining > 0 and capRoom > 0 then
        cs._spawnFailCount = (cs._spawnFailCount or 0) + 1
        if cs._spawnFailCount <= 3 or cs._spawnFailCount % 150 == 0 then
            SN.log("SPAWN DIAG: 0 spawned (attempt #" .. cs._spawnFailCount .. "). spawned=" .. cs.spawnedThisSiege .. "/" .. cs.targetZombies)
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
                    pcall(function() zombie:setTarget(nil) end)
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
            -- pcall guards against stale player refs from disconnected players
            pcall(function()
                if p and p:isAlive() then
                    p:getModData().SN_SiegeBaseX = nil
                    p:getModData().SN_SiegeBaseY = nil
                end
            end)
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
    local sharedRadius = SN.getSandboxNumber("SharedSpawnRadius", 50, 500) or 200
    local clusters = buildPlayerClusters(playerList, sharedRadius)
    local estMult = getEstablishmentMultiplier(playerList)
    local playerCount = #playerList
    -- debugForceMax: Numpad 9 sets this flag so clusters use MaxZombies directly
    local forceMax = siegeData.debugForceMax
    siegeData.debugForceMax = nil  -- consume the flag

    for _, clusterMembers in ipairs(clusters) do
        local id = nextClusterID
        nextClusterID = nextClusterID + 1
        local cs = createClusterState(id, clusterMembers, #clusterMembers)
        cs.direction = pickPrimaryDirection(siegeData.lastDirection)
        local maxZ = SN.getSandboxNumber("MaxZombies", 10, 5000) or 4000
        if forceMax then
            cs.targetZombies = maxZ
        else
            local clusterFraction = #clusterMembers / math.max(1, playerCount)
            local baseTarget = SN.calculateSiegeZombies(siegeData.siegeCount, playerCount)
            cs.targetZombies = math.min(math.max(10, math.floor(baseTarget * estMult * clusterFraction)), maxZ)
        end
        local waves, baselineBudget = SN.calculateWaveStructure(cs.targetZombies)
        cs.waveStructure = waves
        cs.baselineBudget = baselineBudget
        cs.baselineSpawned = 0
        cs.baselineTickCounter = SN.BASELINE_SPAWN_INTERVAL
        cs.currentWaveIndex = 1
        cs.currentPhase = SN.PHASE_SURGE
        cs.surgeSpawnedCount = 0
        cs.surgeTargetCount = cs.waveStructure[1] and cs.waveStructure[1].surgeSize or cs.targetZombies
        cs.debugBreakOverride = siegeData.debugBreakOverride
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
    siegeData.interruptedByRestart = nil
    siegeData.interruptedByRestartDay = nil
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
    local maxZ = SN.getSandboxNumber("MaxZombies", 10, 5000) or 4000
    siegeData.targetZombies = math.min(math.floor(baseTarget * estMult), maxZ)
    siegeData.spawnedThisSiege = 0
    siegeData.tanksSpawned = 0
    siegeData.killsThisSiege = 0
    siegeData.bonusKills = 0
    siegeData.specialKillsThisSiege = 0
    siegeData.hordeCompleteNotified = false
    siegeData.siegeStartHour = SN.getCurrentHour()
    siegeData.currentWaveIndex = 1
    siegeData.currentPhase = SN.PHASE_SURGE
    clusterRefreshTickCounter = 0

    initializeClusters(playerList or {}, siegeData)
    siegeData.clusterSignature = buildClusterSignatureFromGroups(buildPlayerClusters(playerList or {}, SN.getSandboxNumber("SharedSpawnRadius", 50, 500) or 200))

    SN.log("ACTIVE (" .. reason .. ", trigger=" .. trigger .. "). Siege #" .. siegeData.siegeCount
        .. ", target: " .. siegeData.targetZombies .. ", clusters: " .. (nextClusterID - 1)
        .. " | players=" .. playerCount .. " estMult=" .. string.format("%.2f", estMult))

    if isServer() then
        ModData.transmit("SiegeNight")
        sendServerCommand(SN.CLIENT_MODULE, "StateChange", {
            state = SN.STATE_ACTIVE, siegeCount = siegeData.siegeCount, direction = dir,
            targetZombies = siegeData.targetZombies,
            totalWaves = SN.getWaveCountForTotal(siegeData.targetZombies),
        })
    end
    SN_Weather.startSiegeWeather()
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
    siegeData.debugBreakOverride = nil
    siegeData.clusterSignature = nil
    siegeData.interruptedByRestart = nil
    siegeData.interruptedByRestartDay = nil
    clusterSieges = {}
    clusterRefreshTickCounter = 0
    SN_Weather.disableAllOverrides()
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
    siegeData.dawnToIdleProcessed = false
    siegeData.endSeq = (siegeData.endSeq or 0) + 1
    siegeData.endSeqProcessed = nil
    siegeData.ending = true
    siegeData.debugBreakOverride = nil
    siegeData.clusterSignature = nil
    clusterRefreshTickCounter = 0
    SN_Weather.clearWeather()
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
    elseif command == "CmdSiegeSkipBreak" then
        local siegeData = SN.getWorldData()
        if not siegeData then sendResponseToPlayer(player, "Siege Night not ready yet."); return end
        if siegeData.siegeState ~= SN.STATE_ACTIVE then sendResponseToPlayer(player, "No siege is active."); return end
        local skipped = 0
        for _, cs in pairs(clusterSieges) do
            if cs.currentPhase == SN.PHASE_COOLDOWN then
                cs.cooldownTicksRemaining = 0
                advanceClusterWavePhase(cs, siegeData)
                skipped = skipped + 1
                SN.log("Skip break: cluster " .. cs.id .. " -> wave " .. cs.currentWaveIndex .. " by " .. (player:getUsername() or "player"))
            end
        end
        if skipped > 0 then
            broadcastToAll("CmdResponse", { message = "Break skipped by " .. (player:getUsername() or "player") .. "! Next wave incoming!" })
        else
            -- Tell the player what's actually happening
            local info = "Not on break."
            local cs = findPlayerCluster(player)
            if cs then
                local aliveCount = countAliveSiegeZombies(cs)
                local maxActive = SN.getSandboxNumber("MaxActiveZombies", 1, 2000) or 400
                info = info .. " Phase: " .. (cs.currentPhase or "?") .. ", alive: " .. aliveCount .. "/" .. maxActive
                if aliveCount >= maxActive then
                    info = info .. " (cap hit — kill zombies to resume spawning)"
                end
            end
            sendResponseToPlayer(player, info)
        end

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
            local ok, zombies = pcall(addZombiesInOutfit, sx, sy, 0, 1, outfit, 50, false, false, false, false, false, false, 1.0)
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
            currentWaveIndex = siegeData.currentWaveIndex or 0, currentPhase = siegeData.currentPhase or SN.PHASE_SURGE,
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

    -- ===========================================
    -- DEBUG COMMAND HANDLERS (MP dedicated server)
    -- ===========================================
    elseif command == "CmdDebugForceNextState" then
        if not isPlayerAdmin(player) then return end
        local siegeData2 = SN.getWorldData()
        if not siegeData2 then sendResponseToPlayer(player, "World data not loaded yet."); return end
        local oldState = siegeData2.siegeState
        if oldState == SN.STATE_IDLE then
            siegeData2.siegeState = SN.STATE_WARNING
            -- Use actual completed siege count so debug sieges properly escalate
            siegeData2.siegeCount = (siegeData2.totalSiegesCompleted or 0)
        elseif oldState == SN.STATE_WARNING then
            local playerList = getPlayerList()
            enterGlobalActiveState(siegeData2, "debug force by " .. (player:getUsername() or "admin"), playerList, "manual")
        elseif oldState == SN.STATE_ACTIVE then
            handleSiegeStop(player)
        elseif oldState == SN.STATE_DAWN then
            siegeData2.siegeState = SN.STATE_IDLE
            siegeData2.nextSiegeDay = math.floor(SN.getActualDay()) + SN.getNextFrequency()
            siegeData2.debugBreakOverride = nil
            siegeData2.clusterSignature = nil
            clusterRefreshTickCounter = 0
        end
        if isServer() then ModData.transmit("SiegeNight") end
        local newState = siegeData2.siegeState
        SN.log("DEBUG FORCE STATE: " .. oldState .. " -> " .. newState .. " by " .. (player:getUsername() or "admin"))
        sendResponseToPlayer(player, oldState .. " -> " .. newState)
        if oldState ~= newState then
            broadcastToAll("StateChange", { state = newState, siegeCount = siegeData2.siegeCount })
        end

    elseif command == "CmdDebugSetToday" then
        if not isPlayerAdmin(player) then return end
        local siegeData2 = SN.getWorldData()
        if not siegeData2 then sendResponseToPlayer(player, "World data not loaded yet."); return end
        local today = math.floor(SN.getActualDay())
        siegeData2.nextSiegeDay = today
        if isServer() then ModData.transmit("SiegeNight") end
        SN.log("DEBUG: Set nextSiegeDay to " .. today .. " by " .. (player:getUsername() or "admin"))
        sendResponseToPlayer(player, "Next siege set to TODAY (day " .. today .. ").")

    elseif command == "CmdDebugForceFullSiege" then
        if not isPlayerAdmin(player) then return end
        local siegeData2 = SN.getWorldData()
        if not siegeData2 then sendResponseToPlayer(player, "World data not loaded yet."); return end
        if siegeData2.siegeState == SN.STATE_ACTIVE then sendResponseToPlayer(player, "Siege already active!"); return end
        -- Use actual completed siege count for scaling, not day-based calculation
        -- This way repeated debug sieges properly escalate instead of always being siege #1
        siegeData2.siegeCount = (siegeData2.totalSiegesCompleted or 0)
        -- No debugBreakOverride — use natural wave structure breaks (ocean flow)
        siegeData2.debugForceMax = true  -- tell initializeClusters to use MaxZombies
        local playerList = getPlayerList()
        enterGlobalActiveState(siegeData2, "debug full siege by " .. (player:getUsername() or "admin"), playerList, "manual")
        -- Clusters already got MaxZombies via debugForceMax flag; update global target to match
        local maxZ = SN.getSandboxNumber("MaxZombies", 10, 5000) or 4000
        siegeData2.targetZombies = maxZ
        -- Rebuild wave structures for the full max target
        for _, cs in pairs(clusterSieges) do
            cs.targetZombies = maxZ
            local waves, baselineBudget = SN.calculateWaveStructure(maxZ)
            cs.waveStructure = waves
            cs.baselineBudget = baselineBudget
            cs.baselineSpawned = 0
            cs.baselineTickCounter = SN.BASELINE_SPAWN_INTERVAL
            cs.surgeSpawnedCount = 0
            cs.surgeTargetCount = cs.waveStructure[1] and cs.waveStructure[1].surgeSize or maxZ
        end
        if isServer() then ModData.transmit("SiegeNight") end
        local clusterCount = 0
        for _ in pairs(clusterSieges) do clusterCount = clusterCount + 1 end
        SN.log("DEBUG: Forced FULL SIEGE by " .. (player:getUsername() or "admin") .. " — siege #" .. siegeData2.siegeCount .. ", target=" .. maxZ .. ", clusters=" .. clusterCount .. ", players=" .. #playerList)
        sendResponseToPlayer(player, "MAX SIEGE #" .. siegeData2.siegeCount .. "! " .. maxZ .. " zombies incoming!")

    elseif command == "CmdDebugSpawn10" then
        if not isPlayerAdmin(player) then return end
        local px, py = player:getX(), player:getY()
        local count = 0
        local failed = 0
        for i = 1, 10 do
            local spawned = false
            for attempt = 0, 50 do
                local fx = math.floor(px + ZombRand(31) - 15)
                local fy = math.floor(py + ZombRand(31) - 15)
                local dist = math.sqrt((fx - px)^2 + (fy - py)^2)
                if dist >= 10 then
                    local square = safeGetSquare(fx, fy, 0)
                    if square and square:isFree(false) then
                        local outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1]
                        local ok, zombies = pcall(addZombiesInOutfit, fx, fy, 0, 1, outfit, 50, false, false, false, false, false, false, 1.0)
                        if ok and zombies and zombies:size() > 0 then
                            local z = zombies:get(0)
                            stripZombieLoot(z)
                            z:getModData().SN_Siege = true
                            -- Consolidated pcall: all targeting calls in one wrapper (lag optimization)
                            pcall(function()
                                z:pathToSound(px, py, 0)
                                z:setTarget(player)
                                z:setAttackedBy(player)
                                z:spottedNew(player, true)
                                z:addAggro(player, 1)
                            end)
                        end
                        count = count + 1
                        spawned = true
                        break
                    end
                end
            end
            if not spawned then failed = failed + 1 end
        end
        SN.log("DEBUG: Spawn10 by " .. (player:getUsername() or "admin") .. ": " .. count .. " spawned, " .. failed .. " failed")
        sendResponseToPlayer(player, "Spawned " .. count .. " zombies" .. (failed > 0 and (" (" .. failed .. " failed)") or ""))

    elseif command == "CmdDebugSpawnSpecials" then
        if not isPlayerAdmin(player) then return end
        local px, py = player:getX(), player:getY()
        local types = {"sprinter", "breaker", "tank"}
        local results = {}
        for _, specialType in ipairs(types) do
            for attempt = 0, 50 do
                local fx = math.floor(px + ZombRand(41) - 20)
                local fy = math.floor(py + ZombRand(41) - 20)
                local dist = math.sqrt((fx - px)^2 + (fy - py)^2)
                local square = dist >= 10 and safeGetSquare(fx, fy, 0) or nil
                if square and square:isFree(false) then
                    local outfit
                    if specialType == "breaker" then outfit = SN.BREAKER_OUTFITS[ZombRand(#SN.BREAKER_OUTFITS) + 1]
                    elseif specialType == "tank" then outfit = SN.TANK_OUTFITS[ZombRand(#SN.TANK_OUTFITS) + 1]
                    else outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1] end
                    local healthMult = 1.5
                    if specialType == "breaker" then healthMult = 2.0
                    elseif specialType == "tank" then healthMult = SN.getSandboxNumber("TankHealthMultiplier", 1.0, 20.0) or 5.0 end
                    -- Lore-at-birth: set sandbox BEFORE spawn
                    local origSpeed = getSandboxOptions():getOptionByName("ZombieLore.Speed"):getValue()
                    local origStrength = getSandboxOptions():getOptionByName("ZombieLore.Strength"):getValue()
                    local origToughness = getSandboxOptions():getOptionByName("ZombieLore.Toughness"):getValue()
                    local origCognition = getSandboxOptions():getOptionByName("ZombieLore.Cognition"):getValue()
                    if specialType == "sprinter" then getSandboxOptions():set("ZombieLore.Speed", 1)
                    elseif specialType == "breaker" then getSandboxOptions():set("ZombieLore.Strength", 1); getSandboxOptions():set("ZombieLore.Cognition", 1)
                    elseif specialType == "tank" then getSandboxOptions():set("ZombieLore.Toughness", 1); getSandboxOptions():set("ZombieLore.Speed", 3); getSandboxOptions():set("ZombieLore.Strength", 1) end
                    local ok, zombies = pcall(addZombiesInOutfit, fx, fy, 0, 1, outfit, 50, false, false, false, false, false, false, healthMult)
                    -- ALWAYS restore sandbox lore
                    getSandboxOptions():set("ZombieLore.Speed", origSpeed)
                    getSandboxOptions():set("ZombieLore.Strength", origStrength)
                    getSandboxOptions():set("ZombieLore.Toughness", origToughness)
                    getSandboxOptions():set("ZombieLore.Cognition", origCognition)
                    if ok and zombies and zombies:size() > 0 then
                        local zombie = zombies:get(0)
                        stripZombieLoot(zombie)
                        zombie:getModData().SN_Type = specialType
                        zombie:getModData().SN_SpecialType = specialType
                        zombie:getModData().SN_Siege = true
                        if specialType == "breaker" then zombie:setHealth(2.0)
                        elseif specialType == "tank" then zombie:setHealth(healthMult) end
                        -- Consolidated pcall: all targeting calls in one wrapper (lag optimization)
                        pcall(function()
                            zombie:pathToSound(px, py, 0)
                            zombie:setTarget(player)
                            zombie:setAttackedBy(player)
                            zombie:spottedNew(player, true)
                            zombie:addAggro(player, 1)
                        end)
                        table.insert(results, specialType)
                        SN.log("DEBUG: Spawned " .. specialType .. " at " .. fx .. "," .. fy .. " by " .. (player:getUsername() or "admin"))
                    end
                    break
                end
            end
        end
        sendResponseToPlayer(player, "Spawned: " .. (#results > 0 and table.concat(results, ", ") or "none (all failed)"))

    elseif command == "CmdDebugMiniHorde" then
        if not isPlayerAdmin(player) then return end
        -- Use the real mini-horde system (staggered spawn + repath convergence).
        -- SN.debugForceMiniHorde creates a proper job in activeMiniHordes with
        -- zombie tracking and 5-second repath, so debug behaves identically to
        -- a heat-triggered horde.
        if SN.debugForceMiniHorde then
            local count, dir = SN.debugForceMiniHorde(player)
            local dirName = (dir and SN.DIR_NAMES) and SN.DIR_NAMES[dir + 1] or "?"
            SN.log("DEBUG: Mini-horde by " .. (player:getUsername() or "admin") .. ": " .. (count or 25) .. " from " .. dirName)
            sendResponseToPlayer(player, "Mini-horde! " .. (count or 25) .. " from " .. dirName)
        else
            SN.log("ERROR: SN.debugForceMiniHorde is nil")
            sendResponseToPlayer(player, "ERROR: MiniHorde module not loaded")
        end

    elseif command == "CmdDebugFastForward" then
        if not isPlayerAdmin(player) then return end
        -- Server-side time skip: advance 1 hour
        local gt = getGameTime()
        if gt then
            local currentH = SN.getCurrentHour()
            pcall(function() gt:setMultiplier(100) end)
            -- Schedule restore via a flag; the tick handler will restore after 1 hour passes
            local siegeData2 = SN.getWorldData()
            if siegeData2 then
                siegeData2.debugFFTargetHours = (gt:getWorldAgeHours() or 0) + 1.0
                siegeData2.debugFFActive = true
            end
            SN.log("DEBUG: Fast-forward requested by " .. (player:getUsername() or "admin") .. " from hour " .. currentH)
            sendResponseToPlayer(player, "Fast-forwarding 1 hour from H" .. currentH .. "...")
        else
            sendResponseToPlayer(player, "Cannot fast-forward: getGameTime() unavailable.")
        end
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

    -- Capture state early so lastServerState always gets updated (prevents infinite re-trigger if later code errors)
    local currentTickState = siegeData.siegeState

    checkVoteTimeout()
    SN_Weather.tick()

    -- Debug fast-forward: restore normal speed after 1 hour passes
    if siegeData.debugFFActive then
        local gt = getGameTime()
        if gt and gt:getWorldAgeHours() >= (siegeData.debugFFTargetHours or 0) then
            pcall(function() gt:setMultiplier(1) end)
            siegeData.debugFFActive = nil
            siegeData.debugFFTargetHours = nil
            SN.log("DEBUG: Fast-forward complete at hour " .. SN.getCurrentHour())
        end
    end

    -- Tick all active clusters
    if siegeData.siegeState == SN.STATE_ACTIVE then
        clusterRefreshTickCounter = clusterRefreshTickCounter + 1
        if clusterRefreshTickCounter >= CLUSTER_REFRESH_INTERVAL then
            clusterRefreshTickCounter = 0
            refreshActiveClusters(siegeData, false)
        end
        -- Guard: if no clusters exist (server restart, mod reload, all players left),
        -- do NOT finalize the siege. Wait for players to connect and rebuild clusters.
        local hasAnyClusters = false
        for _ in pairs(clusterSieges) do hasAnyClusters = true; break end

        local allDone = true
        if not hasAnyClusters then
            allDone = false  -- prevent vacuous allDone on empty cluster table
        end
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

        -- Midnight weather intensification (when specials start spawning)
        local hoursSinceDusk = SN.getHoursSinceDusk()
        if hoursSinceDusk >= (SN.MIDNIGHT_RELATIVE_HOUR or 4) then
            SN_Weather.midnightIntensify()
        end

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
            SN_Weather.clearWeather()
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
            local reallyDone = hasAnyClusters  -- can't finalize with zero clusters
            if reallyDone then
                for _, cs in pairs(clusterSieges) do
                    if cs.siegeState ~= "IDLE" then reallyDone = false; break end
                end
            end
            if reallyDone then finalizeGlobalSiegeEnd(siegeData) end
        end
    end

    -- Sync to clients
    syncTickCounter = syncTickCounter + 1
    if syncTickCounter >= SYNC_INTERVAL then
        syncTickCounter = 0
        if isServer() then
            if siegeData.siegeState == SN.STATE_ACTIVE then
                -- Aggregate cluster data BEFORE transmitting so ModData has current values
                updateGlobalAggregates(siegeData)
                -- Per-cluster sync to cluster members (detailed)
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
                -- Global broadcast to ALL clients (ensures every player sees aggregate progress)
                -- This catches players who weren't matched to a cluster or joined mid-siege
                sendServerCommand(SN.CLIENT_MODULE, "SiegeTick", {
                    spawnedThisSiege = siegeData.spawnedThisSiege or 0,
                    killsThisSiege = siegeData.killsThisSiege or 0,
                    bonusKills = siegeData.bonusKills or 0,
                    specialKills = siegeData.specialKillsThisSiege or 0,
                    currentWaveIndex = siegeData.currentWaveIndex or 0,
                    currentPhase = siegeData.currentPhase or SN.PHASE_SURGE,
                    targetZombies = siegeData.targetZombies or 0,
                    clusterId = 0,  -- 0 = global aggregate
                })
            end
            -- Transmit ModData AFTER aggregation so clients get current values
            ModData.transmit("SiegeNight")
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
                SN_Weather.startWarningWeather()
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

    -- Debug-forced state detection (transition to ACTIVE)
    -- Uses currentTickState captured at top of function so lastServerState always gets updated
    -- Note: server restart during ACTIVE is handled by onGameTimeLoaded (graceful end),
    -- so this only fires for debug commands that set state to ACTIVE without calling enterGlobalActiveState.
    if currentTickState == SN.STATE_ACTIVE and lastServerState ~= SN.STATE_ACTIVE then
        local hasAnyCluster = false
        for _ in pairs(clusterSieges) do hasAnyCluster = true; break end
        if not hasAnyCluster and (siegeData.targetZombies or 0) > 0 then
            local pl = getPlayerList()
            if #pl > 0 then
                initializeClusters(pl, siegeData)
                SN.log("Debug cluster init: " .. #pl .. " players, target=" .. (siegeData.targetZombies or 0))
            end
            -- If no players: graceful end in onGameTimeLoaded should have already set IDLE.
            -- If somehow we're here with no players and ACTIVE, the empty cluster guard
            -- in the tick loop prevents instant finalization.
        end
        if not siegeData.siegeTrigger then
            siegeData.siegeTrigger = "debug"
        end
    end
    lastServerState = currentTickState
end

-- ==========================================
-- INITIALIZATION
-- ==========================================

local function onGameTimeLoaded()
    SN.log("Server module loaded. Version " .. SN.VERSION)
    local siegeData = SN.getWorldData()
    if not siegeData then return end

    SN.log("State: " .. siegeData.siegeState .. " | Next: day " .. siegeData.nextSiegeDay .. " | Count: " .. siegeData.siegeCount)
    if type(siegeData.nextSiegeDay) ~= "number" then siegeData.nextSiegeDay = 0 end
    local currentDay = math.floor(SN.getActualDay())

    -- Fix stale nextSiegeDay (server was off for days)
    if siegeData.siegeState == SN.STATE_IDLE and siegeData.nextSiegeDay < currentDay then
        local oldNext = siegeData.nextSiegeDay
        while siegeData.nextSiegeDay < currentDay do siegeData.nextSiegeDay = siegeData.nextSiegeDay + SN.getNextFrequency() end
        SN.log("STALE nextSiegeDay " .. oldNext .. " -> " .. siegeData.nextSiegeDay)
    end

    -- GRACEFUL END ON RESTART: if server restarted during a siege (ACTIVE/DAWN/WARNING),
    -- cleanly finalize it instead of trying to resurrect ephemeral cluster state.
    -- Cluster data (members, per-cluster kills, wave index) is Lua-memory-only and is lost
    -- on restart. Rather than rebuild a half-dead siege, we record what we have and move on.
    if siegeData.siegeState == SN.STATE_ACTIVE or siegeData.siegeState == SN.STATE_DAWN then
        SN.log("Server restarted during " .. siegeData.siegeState .. " — graceful finalize")

        -- Record partial siege history using whatever ModData survived the restart.
        -- DO NOT call updateGlobalAggregates() — it reads from clusterSieges which is empty
        -- after restart and would zero out the kill/spawn counts.
        siegeData.totalSiegesCompleted = (siegeData.totalSiegesCompleted or 0) + 1
        siegeData.totalKillsAllTime = (siegeData.totalKillsAllTime or 0) + getTotalSiegeKills(siegeData)

        local MAX_SIEGE_HISTORY = 20
        local idx = siegeData.totalSiegesCompleted
        siegeData["history_" .. idx .. "_kills"]   = siegeData.killsThisSiege or 0
        siegeData["history_" .. idx .. "_bonus"]    = siegeData.bonusKills or 0
        siegeData["history_" .. idx .. "_specials"] = siegeData.specialKillsThisSiege or 0
        siegeData["history_" .. idx .. "_spawned"]  = siegeData.spawnedThisSiege or 0
        siegeData["history_" .. idx .. "_target"]   = siegeData.targetZombies or 0
        siegeData["history_" .. idx .. "_day"]      = currentDay
        siegeData["history_" .. idx .. "_dir"]      = siegeData.lastDirection or -1
        local pruneIdx = idx - MAX_SIEGE_HISTORY
        if pruneIdx > 0 then
            for _, suffix in ipairs({"kills","bonus","specials","spawned","target","day","dir"}) do
                siegeData["history_" .. pruneIdx .. "_" .. suffix] = nil
            end
        end

        -- Transition to IDLE
        siegeData.siegeState = SN.STATE_IDLE
        siegeData.siegeTrigger = nil
        siegeData.ending = false
        siegeData.stopLockUntil = nil
        siegeData.debugBreakOverride = nil
        siegeData.clusterSignature = nil
        clusterSieges = {}
        clusterRefreshTickCounter = 0
        SN_Weather.disableAllOverrides()

        -- Schedule next siege
        siegeData.nextSiegeDay = currentDay + SN.getNextFrequency()
        if siegeData.nextSiegeDay <= currentDay then siegeData.nextSiegeDay = currentDay + 1 end

        -- Flag so connecting players get notified
        siegeData.interruptedByRestart = true
        siegeData.interruptedByRestartDay = currentDay

        SN.log("IDLE (restart). Kills saved: " .. (siegeData.killsThisSiege or 0)
            .. "+" .. (siegeData.bonusKills or 0)
            .. " | Next: day " .. siegeData.nextSiegeDay
            .. " | History #" .. idx)

    elseif siegeData.siegeState == SN.STATE_WARNING then
        -- Warning is cosmetic — just drop back to IDLE, no history to record
        SN.log("Server restarted during WARNING — dropping to IDLE")
        siegeData.siegeState = SN.STATE_IDLE
        siegeData.clusterSignature = nil
        clusterRefreshTickCounter = 0
        SN_Weather.disableAllOverrides()
    end

    if isServer() then ModData.transmit("SiegeNight") end
end

local function onPlayerConnect(player)
    if not isServer() then return end
    ModData.transmit("SiegeNight")

    local siegeData = SN.getWorldData()
    if not siegeData then return end
    local playerName = player:getUsername() or "?"

    -- Notify player if their siege was interrupted by a server restart
    if siegeData.interruptedByRestart then
        local today = math.floor(SN.getActualDay())
        local messageDay = siegeData.interruptedByRestartDay or today
        if today <= messageDay + 1 then
            sendServerCommand(player, SN.CLIENT_MODULE, "ServerMsg", {
                msg = "The siege was interrupted by a server restart. Progress was saved. Next siege: day " .. (siegeData.nextSiegeDay or "?") .. "."
            })
            SN.log("Notified " .. playerName .. " about restart interruption")
        else
            siegeData.interruptedByRestart = nil
            siegeData.interruptedByRestartDay = nil
        end
    end

    -- Only handle mid-siege joins if state is ACTIVE and clusters exist
    if siegeData.siegeState ~= SN.STATE_ACTIVE then return end
    local hasCluster = false; for _ in pairs(clusterSieges) do hasCluster = true; break end
    if not hasCluster then return end  -- graceful end should have already handled this

    refreshActiveClusters(siegeData, true)

    local bestCS = findNearestActiveCluster(player:getX(), player:getY())
    if bestCS then
        -- Clean stale members first (handles reconnecting players whose old ref is dead)
        local cleanMembers = {}
        for _, m in ipairs(bestCS.members) do
            local ok, alive = pcall(function() return m and m:isAlive() end)
            if ok and alive then
                table.insert(cleanMembers, m)
            end
        end
        bestCS.members = cleanMembers

        -- Add the new player
        local alreadyMember = false
        for _, member in ipairs(bestCS.members) do
            if member == player then alreadyMember = true; break end
        end
        if not alreadyMember then
            table.insert(bestCS.members, player)
        end
        bestCS.centroidPlayer = pickCentroidPlayer(bestCS.members)
        refreshActiveClusters(siegeData, true)
        bestCS = findNearestActiveCluster(player:getX(), player:getY()) or bestCS
        SN.log("Player " .. playerName .. " joined cluster " .. bestCS.id .. " (" .. #bestCS.members .. " members)")

        -- Immediately sync full state so they see wave/kill info
        sendServerCommand(player, SN.CLIENT_MODULE, "StateChange", {
            state = SN.STATE_ACTIVE, siegeCount = siegeData.siegeCount,
            direction = bestCS.direction, targetZombies = bestCS.targetZombies,
            totalWaves = #bestCS.waveStructure, clusterId = bestCS.id,
        })
        local aliveCount = countAliveSiegeZombies(bestCS)
        sendServerCommand(player, SN.CLIENT_MODULE, "SiegeTick", {
            spawnedThisSiege = bestCS.spawnedThisSiege, killsThisSiege = bestCS.killsThisSiege,
            bonusKills = bestCS.bonusKills, specialKills = bestCS.specialKillsThisSiege,
            currentWaveIndex = bestCS.currentWaveIndex, currentPhase = bestCS.currentPhase,
            targetZombies = bestCS.targetZombies, clusterId = bestCS.id, aliveCount = aliveCount,
        })
    else
        -- No nearby active cluster — send global state so UI works
        sendServerCommand(player, SN.CLIENT_MODULE, "StateChange", {
            state = SN.STATE_ACTIVE, siegeCount = siegeData.siegeCount,
            direction = siegeData.lastDirection or 0,
            targetZombies = siegeData.targetZombies or 0,
            totalWaves = SN.getWaveCountForTotal(siegeData.targetZombies or 75),
        })
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
