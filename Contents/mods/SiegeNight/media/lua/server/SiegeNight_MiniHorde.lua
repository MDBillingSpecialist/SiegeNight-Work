--[[
    SiegeNight_MiniHorde.lua
    Noise heat tracking and triggered mini-hordes between siege nights.
    Runs SERVER-SIDE only.

    v2.1 - Fixed infinite horde feedback loop, increased heat decay, added grace period
    v2.0 - Expanded heat sources
         - Player count scaling
         - Establishment-aware sizing
         - Better player notifications via Say()
         - Larger default hordes
         - Wave-like staggered spawning
         - API hook for other mods

    Heat sources:
    - Gunfire (OnWeaponSwing with firearm) = 10 heat
    - Zombie kills (OnHitZombie) = 3 per kill (capped at 20 per check)
    - Vehicle use = 8 per check
    - Running generators = 8 per check
    - Base player presence = 3 per check
    - Construction activity (high inventory weight) = 5 per check

    Heat decays by 4 every 10 minutes. When heat >= threshold, a mini-horde triggers.
]]

local okSN, SN = pcall(require, "SiegeNight_Shared")
if not okSN or type(SN) ~= "table" then return end

-- Safety: this file must never run on MP clients.
-- (Singleplayer has isClient()==false, so SP still works.)
if isClient and isClient() then return end

-- ==========================================
-- NOISE HEAT GRID
-- ==========================================
local CELL_SIZE = 100
local heatGrid = {}

-- Active mini-horde spawn jobs (staggered spawning). Must be declared before onEveryTenMinutes
-- so cooldown checks can see it.
local activeMiniHordes = {}

-- ==========================================
-- CORPSE SANITY (MP)
-- ==========================================
-- Some MP reports describe SiegeNight-spawned zombies getting "stuck" in a downed-but-not-dead state
-- that results in dead-but-moving visuals and unlootable corpses. We apply a lightweight sanity tick
-- to mini-horde zombies while a mini-horde job is active.

-- Strip non-clothing items from a zombie so mini-horde spawns don't drop OP loot.
local function stripZombieLoot(zombie)
    if not zombie then return end
    if not SN.getSandbox("StripSiegeZombieLoot") then return end
    pcall(function()
        local inv = zombie:getInventory()
        if not inv then return end
        zombie:setPrimaryHandItem(nil)
        zombie:setSecondaryHandItem(nil)
        local toRemove = {}
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item then
                if instanceof(item, "Clothing") then
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

    if z.Kill then pcall(function() z:Kill(nil) end) end
    if z.kill then pcall(function() z:kill(nil) end) end
    if z.forceKill then pcall(function() z:forceKill() end) end

    if z.setHealth then pcall(function() z:setHealth(0) end) end

    -- Extra hardening for MP edge cases.
    if z.setBecomeCorpse then pcall(function() z:setBecomeCorpse(true) end) end
    if z.setFakeDead then pcall(function() z:setFakeDead(false) end) end
    if z.setReanimate then pcall(function() z:setReanimate(false) end) end
end

local function miniHordeCorpseSanityTick(zombieList)
    if not zombieList then return end
    local now = worldAgeSecSafe()
    for i = #zombieList, 1, -1 do
        local z = zombieList[i]
        if not z then
            table.remove(zombieList, i)
        else
            local md = z:getModData()
            local isSNZombie = md and md.SN_MiniHorde
            if isSNZombie then
                local okDead, isDead = pcall(function() return z:isDead() end)
                if okDead and isDead then
                    md.SN_DownedAt = nil
                else
                    if isZombieOnGround(z) then
                        if not md.SN_DownedAt then md.SN_DownedAt = now end
                        if (now - md.SN_DownedAt) > 2 then
                            SN.log("CorpseSanity: forceKill (mini) x=" .. tostring(z:getX()) .. " y=" .. tostring(z:getY()) .. " mini=" .. tostring(md.SN_MiniHorde))
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

-- Per-10-minute heat caps (prevents gunfire from chain-triggering mini-hordes constantly)
local SN_MH_LastTenMinTick = -1
local SN_MH_GunfireHeatThisTick = 0
local SN_MH_MaxGunfireHeatPerTick = 60

local recentKills = {}

local function getCellKey(worldX, worldY)
    if type(worldX) ~= "number" or type(worldY) ~= "number" then
        return nil
    end
    local cellX = math.floor(worldX / CELL_SIZE)
    local cellY = math.floor(worldY / CELL_SIZE)
    return cellX .. "_" .. cellY
end

local function getHeatData(cellKey)
    if not cellKey then return nil end
    if not heatGrid[cellKey] then
        heatGrid[cellKey] = {
            heat = 0,
            lastTrigger = 0,
            kills = 0,
        }
    end
    return heatGrid[cellKey]
end

-- ==========================================
-- SPAWN SAFETY HELPERS
-- ==========================================

--- Treat rooms, safehouses, and player-built thumpables as "player areas".
--- Prevents mini-hordes from spawning inside bases/pens.
local function isInsidePlayerArea(sq)
    if not sq then return true end
    if sq:getRoom() then return true end
    local isSafe = SafeHouse and SafeHouse.getSafeHouse and SafeHouse.getSafeHouse(sq) or nil
    if isSafe ~= nil then return true end

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
local function addHeat(worldX, worldY, amount, source)
    if source == 'gunfire' then
        local add = amount or 0
        if SN_MH_GunfireHeatThisTick >= SN_MH_MaxGunfireHeatPerTick then return end
        if SN_MH_GunfireHeatThisTick + add > SN_MH_MaxGunfireHeatPerTick then
            add = SN_MH_MaxGunfireHeatPerTick - SN_MH_GunfireHeatThisTick
        end
        if add <= 0 then return end
        SN_MH_GunfireHeatThisTick = SN_MH_GunfireHeatThisTick + add
        amount = add
    end
    local cellKey = getCellKey(worldX, worldY)
    if not cellKey then return end
    local data = getHeatData(cellKey)
    if not data then return end
    -- Cap heat at threshold + 50 to prevent runaway accumulation
    -- while still allowing any sandbox threshold setting to be reachable
    local threshold = SN.getSandboxNumber("MiniHorde_NoiseThreshold", 1, 200) or 80
    local heatCap = math.max(100, threshold + 50)
    data.heat = math.min(heatCap, data.heat + amount)
    SN.debug("Heat +" .. amount .. " at " .. cellKey .. " = " .. data.heat)
end

-- ==========================================
-- PLAYER LIST HELPER
-- ==========================================
local function getPlayerList()
    local playerList = {}
    local isSP = not isServer() and not isClient()
    if isSP then
        local sp = getPlayer()
        if sp then table.insert(playerList, sp) end
    else
        local players = getOnlinePlayers()
        if players then
            for i = 0, players:size() - 1 do
                local p = players:get(i)
                if p and p:isAlive() then
                    table.insert(playerList, p)
                end
            end
        end
    end
    return playerList
end

local function getAlivePlayers(players)
    local alivePlayers = {}
    for _, player in ipairs(players or {}) do
        local ok, alive = pcall(function() return player and player:isAlive() end)
        if ok and alive then
            table.insert(alivePlayers, player)
        end
    end
    return alivePlayers
end

local function pickNearestPlayer(players, x, y)
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

local function getPlayersNearPoint(players, x, y, radius)
    local nearby = {}
    local maxDist2 = (radius or 200) * (radius or 200)
    for _, player in ipairs(getAlivePlayers(players)) do
        local px, py = player:getX(), player:getY()
        local dx = x - px
        local dy = y - py
        if (dx * dx + dy * dy) <= maxDist2 then
            table.insert(nearby, player)
        end
    end
    return nearby
end

local function getActiveJobPlayers(job)
    job.players = getAlivePlayers(job.players or {})
    if #job.players == 0 and job.player then
        job.players = getAlivePlayers({ job.player })
    end
    job.player = job.players[1]
    if not job.playerCursor or job.playerCursor < 1 then
        job.playerCursor = 1
    end
    if #job.players > 0 and job.playerCursor > #job.players then
        job.playerCursor = ((job.playerCursor - 1) % #job.players) + 1
    end
    return job.players
end

-- ==========================================
-- NOISE DETECTION (Event-driven)
-- ==========================================

local function onWeaponSwing(character, handWeapon)
    if not SN or not SN.getSandbox or not SN.getSandbox("MiniHorde_Enabled") then return end
    if not handWeapon then return end
    if not character then return end

    -- Skip ALL heat while a mini-horde is actively spawning (prevents feedback loop:
    -- shooting mini-horde zombies should not generate heat for the next mini-horde)
    if activeMiniHordes and #activeMiniHordes > 0 then return end

    local scriptItem = handWeapon:getScriptItem()
    if scriptItem and scriptItem:getAmmoType() then
        local px, py = character:getX(), character:getY()
        if type(px) == "number" and type(py) == "number" then
            -- Gunfire heat is capped per 10-minute tick inside addHeat(source='gunfire')
            addHeat(px, py, 10, "gunfire")
            SN.debug("Gunfire detected from " .. tostring(character:getUsername() or "player"))
        end
    end
end

local function onHitZombie(zombie, character, bodyPartType, handWeapon)
    if not SN or not SN.getSandbox or not SN.getSandbox("MiniHorde_Enabled") then return end
    if not character then return end
    if not instanceof(character, "IsoPlayer") then return end

    -- Skip ALL heat while a mini-horde is active (prevents feedback loop)
    if activeMiniHordes and #activeMiniHordes > 0 then return end

    -- Hits are not kills. Keep this hook only as a guardrail entry point.
    -- Real kill heat is counted in onMiniHordeZombieDead.
end

local triggerMiniHorde

-- ==========================================
-- PERIODIC HEAT UPDATE (Every 10 minutes)
-- ==========================================

local function onEveryTenMinutes()
    -- MINIHORDE SAFETY: SN not initialized (prevents crash loops if shared module failed to load)
    if not SN or not SN.getSandbox then return end
    if not SN or not SN.getSandbox or not SN.getSandbox("MiniHorde_Enabled") then return end

    -- Reset per-10-minute gunfire cap
    SN_MH_GunfireHeatThisTick = 0

    local siegeData = SN.getWorldData()
    if not siegeData then return end
    if siegeData.siegeState == SN.STATE_ACTIVE or siegeData.siegeState == SN.STATE_WARNING then
        return
    end

    local playerList = getPlayerList()

    -- INFINITE HORDE FIX: Suppress heat accumulation while a mini-horde is actively
    -- spawning/fighting. Without this, generators (+15), vehicles (+8), presence (+3)
    -- etc. keep building heat DURING the fight, so by the time the horde ends the
    -- heat is already above threshold again — causing an immediate re-trigger loop.
    if activeMiniHordes and #activeMiniHordes > 0 then
        -- Still decay heat so it doesn't freeze at threshold
        for cellKey, data in pairs(heatGrid) do
            data.heat = math.max(0, data.heat - 8)
        end
        return  -- skip all heat accumulation while fighting
    end

    -- Add heat from player activity
    for _, player in ipairs(playerList) do
        if player and player:isAlive() then
            local px, py = player:getX(), player:getY()
            if type(px) == "number" and type(py) == "number" then
                local cellKey = getCellKey(px, py)

                -- Base presence heat (slightly more than before)
                addHeat(px, py, 3, nil)

                -- Vehicle noise (more impactful)
                if player:getVehicle() then
                    addHeat(px, py, 8, nil)
                end

                -- Kill activity (higher impact)
                if cellKey then
                    local kills = recentKills[cellKey] or 0
                    if kills > 0 then
                        local killHeat = math.min(20, kills * 3)
                        addHeat(px, py, killHeat)
                        recentKills[cellKey] = 0
                    end
                end

                -- Generator detection (pcall-guarded: getGenerator may not exist in all PZ versions)
                local cell = getWorld():getCell()
                if cell then
                    local foundGenerator = false
                    for gx = -3, 3 do
                        if foundGenerator then break end
                        for gy = -3, 3 do
                            local sq = cell:getGridSquare(math.floor(px) + gx * 10, math.floor(py) + gy * 10, 0)
                            if sq and sq.getGenerator then
                                local okG, generator = pcall(sq.getGenerator, sq)
                                if okG and generator and generator.isRunning and generator:isRunning() then
                                    addHeat(px, py, 8, nil)  -- was 15, reduced to prevent generator spam
                                    foundGenerator = true
                                    break
                                end
                            end
                        end
                    end
                end

                -- Construction/establishment indicator: heavy inventory = building/looting
                local inv = player:getInventory()
                if inv then
                    local weight = inv:getCapacityWeight()
                    if weight > 15 then
                        addHeat(px, py, 5, nil)
                    end
                end
            end
        end
    end

    -- Decay heat and check triggers
    local gt = getGameTime()
    if not gt then return end
    local now = gt:getWorldAgeHours()

    -- SandboxVars can arrive as strings on some dedi setups; normalize to numbers.
    local cooldownMinutes = SN.getSandboxNumber("MiniHorde_CooldownMinutes", 1, 180) or 30
    if not cooldownMinutes or cooldownMinutes <= 0 then cooldownMinutes = 30 end
    if cooldownMinutes < 1 then cooldownMinutes = 1 end
    local cooldownHours = cooldownMinutes / 60

    local threshold = SN.getSandboxNumber("MiniHorde_NoiseThreshold", 1, 200) or 80
    if threshold < 1 then threshold = 1 end

    -- Per-day cap: prevents servers from getting stuck in a mini-horde loop.
    local today = math.floor(SN.getActualDay())
    if siegeData.miniHordeDay ~= today then
        siegeData.miniHordeDay = today
        siegeData.miniHordeTriggersToday = 0
    end
    local maxPerDay = SN.getSandboxNumber("MiniHorde_MaxPerDay", 0, 50) or 2
    if maxPerDay < 0 then maxPerDay = 0 end
    -- MaxPerDay=0 means ZERO hordes per day (disabled), NOT unlimited.
    -- Previously `maxPerDay > 0 and ...` made 0 = no cap, which was confusing.
    local dailyCapReached = (maxPerDay == 0) or ((siegeData.miniHordeTriggersToday or 0) >= maxPerDay)

    -- If a mini-horde is currently spawning, don't trigger another one.
    -- This prevents stacked jobs from looking like "nonstop" hordes even with a sane cooldown.
    local activeJobRunning = activeMiniHordes and #activeMiniHordes > 0

    -- GLOBAL cooldown (MP): prevent large servers from triggering mini-hordes every tick
    -- just because players are spread across many heat cells.
    local globalLast = siegeData.miniHordeLastTrigger or 0
    local inGlobalGrace = (now - globalLast) < cooldownHours

    for cellKey, data in pairs(heatGrid) do
        -- Per-cell grace period
        local inGrace = (now - data.lastTrigger) < cooldownHours

        if (not dailyCapReached) and (not activeJobRunning) and (not inGlobalGrace) and (not inGrace) and data.heat >= threshold then
            triggerMiniHorde(cellKey, data, playerList)
            siegeData.miniHordeTriggersToday = (siegeData.miniHordeTriggersToday or 0) + 1
            data.heat = 0
            data.lastTrigger = now
            siegeData.miniHordeLastTrigger = now
            globalLast = now
            inGlobalGrace = true
        end

        -- Decay heat (8 per tick - faster decay to prevent runaway accumulation)
        data.heat = math.max(0, data.heat - 8)

        -- Keep cell entries around at least through the cooldown window
        if data.heat <= 0 and (now - data.lastTrigger) > cooldownHours then
            heatGrid[cellKey] = nil
        end
    end
end

-- ==========================================
-- MINI-HORDE SPAWNER
-- ==========================================

-- Repath interval: 150 ticks = 5 seconds (same as siege).
-- Attractor sound (radius 80) handles zombie hearing AI activation.
-- Repath re-drives pathToSound + targeting to keep zombies converging.
local MH_REPATH_INTERVAL = 150

triggerMiniHorde = function(cellKey, heatData, playerList)
    local parts = {}
    for part in cellKey:gmatch("([^_]+)") do
        table.insert(parts, tonumber(part))
    end
    if #parts < 2 or not parts[1] or not parts[2] then
        SN.log("WARNING: Invalid cell key for mini-horde: " .. tostring(cellKey))
        return
    end

    local cellCenterX = parts[1] * CELL_SIZE + CELL_SIZE / 2
    local cellCenterY = parts[2] * CELL_SIZE + CELL_SIZE / 2

    local nearestPlayer = pickNearestPlayer(playerList, cellCenterX, cellCenterY)

    if not nearestPlayer then return end

    local groupRadius = math.max(CELL_SIZE, SN.getSandboxNumber("SharedSpawnRadius", 50, 500) or 200)
    local targetPlayers = getPlayersNearPoint(playerList, nearestPlayer:getX(), nearestPlayer:getY(), groupRadius)
    if #targetPlayers <= 0 then
        targetPlayers = { nearestPlayer }
    end

    -- Calculate horde size with player scaling
    local heatRatio = math.min(1.0, heatData.heat / 100)
    local minZ = SN.getSandboxNumber("MiniHorde_MinZombies", 1, 200) or 10
    local maxZ = SN.getSandboxNumber("MiniHorde_MaxZombies", 1, 200) or 60
    if maxZ < minZ then maxZ = minZ end

    local count = minZ
    if SN.getSandbox("MiniHorde_ActivityScaling") then
        count = math.floor(minZ + (maxZ - minZ) * heatRatio)
    end

    -- Player count scaling: more players = bigger mini-horde
    if SN.getSandbox("MiniHorde_PlayerScaling") then
        count = math.floor(count * SN.getMiniHordePlayerScale(#targetPlayers))
    end

    -- IMPORTANT: MiniHorde_MaxZombies is treated as an absolute cap.
    -- (Some servers set MaxZombies low intentionally; player scaling should never exceed it.)
    count = math.min(count, maxZ)

    local dir = ZombRand(8)
    SN.log("MINI-HORDE triggered! " .. count .. " zombies at cell " .. cellKey
        .. " (heat: " .. heatData.heat .. ", localPlayers: " .. #targetPlayers
        .. ", cap: " .. tostring(maxZ)
        .. ", cooldownMin: " .. tostring(SN.getSandboxNumber("MiniHorde_CooldownMinutes", 1, 180) or 30)
        .. ")")

    -- Notify client(s)
    if isServer() then
        sendServerCommand(SN.CLIENT_MODULE, "MiniHorde", {
            count = count,
            direction = dir,
        })
    end

    -- Fire API callback
    SN.fireCallback("onMiniHorde", count, dir, cellKey)

    -- Create staggered spawn job with zombie tracking for repath convergence
    table.insert(activeMiniHordes, {
        player = nearestPlayer,
        players = targetPlayers,
        playerCursor = 1,
        cellKey = cellKey,  -- track origin cell for scoped heat reset on completion
        remaining = count,
        tickCounter = 0,
        spawnInterval = 8,  -- faster spawn rate than before
        direction = dir,
        -- Notify flag: announce to player on first spawn
        announced = false,
        -- Convergence tracking (matches siege repath system)
        zombieList = {},    -- tracked zombie refs for repath
        repathTick = 0,     -- counts up to MH_REPATH_INTERVAL
        -- Kill counter: attractor stops when player kills ANY zombies equal to spawn count
        totalToSpawn = count,
        killCount = 0,
    })
end

local function onMiniHordeTick()
    if #activeMiniHordes == 0 then return end

    for i = #activeMiniHordes, 1, -1 do
        local job = activeMiniHordes[i]
        job.tickCounter = job.tickCounter - 1
        job.repathTick = (job.repathTick or 0) + 1

        -- Corpse sanity tick (about once per ~2 seconds at 30fps)
        job.corpseSanityTick = (job.corpseSanityTick or 0) + 1
        if job.corpseSanityTick >= 60 then
            job.corpseSanityTick = 0
            if job.zombieList and #job.zombieList > 0 then
                miniHordeCorpseSanityTick(job.zombieList)
            end
        end

        -- ========== SPAWN PHASE (batch of 3 per tick) ==========
        if job.tickCounter <= 0 and job.remaining > 0 then
            job.tickCounter = job.spawnInterval
            local activePlayers = getActiveJobPlayers(job)

            if #activePlayers > 0 then
                -- SP: announce via Say() on first spawn
                if not job.announced then
                    local isSP = not isServer() and not isClient()
                    if isSP then
                        local dirName = SN.getDirName(job.direction)
                        job.player:Say("Something's attracted their attention from the " .. dirName .. "...")
                    end
                    job.announced = true
                end

                local targetPlayer = activePlayers[job.playerCursor] or activePlayers[1]
                job.player = targetPlayer
                local px = targetPlayer:getX()
                local py = targetPlayer:getY()
                if type(px) ~= "number" or type(py) ~= "number" then
                    job.remaining = 0
                else
                    local spawnDist = SN.getSandboxNumber("SpawnDistance", 15, 300) or 45
                    local batchSize = math.min(math.max(2, #activePlayers), job.remaining, 4)

                    local batchSpawned = 0
                    for b = 1, batchSize do
                        if job.remaining <= 0 then break end
                        targetPlayer = activePlayers[job.playerCursor] or activePlayers[1]
                        job.player = targetPlayer
                        px = targetPlayer:getX()
                        py = targetPlayer:getY()
                        for attempt = 0, 30 do
                            local dir = job.direction
                            local baseX = px + SN.DIR_X[dir + 1] * spawnDist
                            local baseY = py + SN.DIR_Y[dir + 1] * spawnDist
                            local spread = ZombRand(41) - 20
                            local perpX = -SN.DIR_Y[dir + 1]
                            local perpY = SN.DIR_X[dir + 1]
                            local fx = math.floor(baseX + perpX * spread)
                            local fy = math.floor(baseY + perpY * spread)

                            local w = getWorld()
                            local cell = w and w:getCell() or nil
                            local square = cell and cell:getGridSquare(fx, fy, 0) or nil
                            if square and square:isFree(false) and square:isOutside() and not isInsidePlayerArea(square) then
                                local outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1]
                                local ok, zombies = pcall(addZombiesInOutfit, fx, fy, 0, 1, outfit, 50, false, false, false, false, false, false, 1.0)
                                if not ok then
                                    SN.log("WARNING: mini-horde addZombiesInOutfit failed: " .. tostring(zombies))
                                end
                                if ok and zombies and zombies:size() > 0 then
                                    local zombie = zombies:get(0)
                                    stripZombieLoot(zombie)
                                    local p = targetPlayer
                                    pcall(function()
                                        if isServer() then zombie:pathToCharacter(p) end
                                        zombie:setTarget(p)
                                        zombie:setAttackedBy(p)
                                        zombie:spottedNew(p, true)
                                        zombie:addAggro(p, 2)
                                    end)
                                    zombie:getModData().SN_MiniHorde = true
                                    table.insert(job.zombieList, zombie)
                                    batchSpawned = batchSpawned + 1
                                end
                                job.remaining = job.remaining - 1
                                if #activePlayers > 0 then
                                    job.playerCursor = (job.playerCursor % #activePlayers) + 1
                                end
                                break
                            end
                        end
                    end
                    -- One attractor sound per batch (not per zombie)
                    if batchSpawned > 0 then
                        for _, player in ipairs(activePlayers) do
                            pcall(function()
                                getWorldSoundManager():addSound(player, math.floor(player:getX()), math.floor(player:getY()), 0, 80, 80)
                            end)
                        end
                    end
                end
            else
                -- Group gone, cancel remaining spawns
                job.remaining = 0
            end

            if job.remaining <= 0 then
                SN.log("Mini-horde spawn complete (" .. #job.zombieList .. " tracked)")
            end
        end

        -- ========== REPATH PHASE (every 5 seconds, same as siege) ==========
        if job.repathTick >= MH_REPATH_INTERVAL then
            job.repathTick = 0
            local activePlayers = getActiveJobPlayers(job)
            if #activePlayers > 0 then
                -- Step 1: Prune dead spawned zombies first
                local alive = {}
                for _, zombie in ipairs(job.zombieList) do
                    local okD, dead = pcall(function() return zombie:isDead() end)
                    if okD and not dead then
                        table.insert(alive, zombie)
                    end
                end
                job.zombieList = alive

                -- Step 2: Only attract + repath if kill counter hasn't been reached.
                if (job.killCount or 0) < (job.totalToSpawn or 0) then
                    for _, player in ipairs(activePlayers) do
                        pcall(function()
                            getWorldSoundManager():addSound(player, math.floor(player:getX()), math.floor(player:getY()), 0, 80, 80)
                        end)
                    end
                    for _, zombie in ipairs(alive) do
                        local targetPlayer = pickNearestPlayer(activePlayers, zombie:getX(), zombie:getY()) or activePlayers[1]
                        if targetPlayer then
                            pcall(function()
                                if isServer() then zombie:pathToCharacter(targetPlayer) end
                                zombie:setTarget(targetPlayer)
                                zombie:setAttackedBy(targetPlayer)
                                zombie:spottedNew(targetPlayer, true)
                                zombie:addAggro(targetPlayer, 1)
                            end)
                        end
                    end
                end
            end
        end

        -- ========== CLEANUP ==========
        -- Job is done when spawning is finished AND (kill counter reached OR all tracked dead OR no players left)
        local noPlayersLeft = #getActiveJobPlayers(job) == 0
        if job.remaining <= 0 and ((job.killCount or 0) >= (job.totalToSpawn or 0) or #job.zombieList == 0 or noPlayersLeft) then
            SN.log("Mini-horde complete (kills: " .. (job.killCount or 0) .. "/" .. (job.totalToSpawn or 0) .. (noPlayersLeft and ", no players left" or "") .. ")")
            -- Reset heat AND kill counter in the horde's origin cell to prevent
            -- the fight itself from feeding the next mini-horde trigger.
            if job.cellKey then
                if heatGrid[job.cellKey] then
                    heatGrid[job.cellKey].heat = 0
                end
                recentKills[job.cellKey] = 0
            end
            -- INFINITE HORDE FIX: Update global cooldown to start from horde END,
            -- not horde START. Previously cooldown was set at trigger time, so by the
            -- time a 5-minute fight ended, the 30-minute cooldown was already 5 min in.
            -- Now the full cooldown runs AFTER the fight finishes.
            local siegeData = SN.getWorldData()
            if siegeData then
                local gt = getGameTime()
                if gt then
                    siegeData.miniHordeLastTrigger = gt:getWorldAgeHours()
                end
                -- Also reset per-cell cooldown to start from fight end
                if job.cellKey and heatGrid[job.cellKey] then
                    heatGrid[job.cellKey].lastTrigger = siegeData.miniHordeLastTrigger or 0
                end
            end
            table.remove(activeMiniHordes, i)
        end
    end
end

-- ==========================================
-- DEBUG API: force a mini-horde through the real spawn + repath system
-- ==========================================

--- Debug helper: forces a mini-horde on the given player using the real
--- staggered spawn + repath convergence system (same code path as a
--- heat-triggered horde). Called from Debug.lua (SP) and Server.lua
--- CmdDebugMiniHorde (MP).
function SN.debugForceMiniHorde(player)
    if not player then return 0 end
    local count = 25
    local dir = ZombRand(8)

    -- Notify client(s) in MP
    if isServer() then
        sendServerCommand(SN.CLIENT_MODULE, "MiniHorde", {
            count = count,
            direction = dir,
        })
    end

    -- Create a proper staggered spawn job with repath tracking
    table.insert(activeMiniHordes, {
        player = player,
        players = { player },
        playerCursor = 1,
        remaining = count,
        tickCounter = 0,
        spawnInterval = 8,
        direction = dir,
        announced = false,
        zombieList = {},
        repathTick = 0,
        totalToSpawn = count,
        killCount = 0,
    })

    local dirName = SN.getDirName and SN.getDirName(dir) or tostring(dir)
    SN.log("DEBUG: Mini-horde forced. " .. count .. " zombies from " .. dirName)
    return count, dir
end

-- ==========================================
-- MINI-HORDE KILL COUNTER
-- ==========================================
-- Any zombie killed near an active mini-horde player counts toward the
-- kill target. Player doesn't have to hunt down specific tagged zombies -
-- kill ANY 22 zombies (spawned or attracted roamers) and the attractor stops.

local function onMiniHordeZombieDead(zombie)
    local zx, zy
    local okZ = pcall(function() zx = zombie:getX(); zy = zombie:getY() end)
    if not okZ or not zx then return end

    local zmd = zombie and zombie:getModData()
    if not (zmd and zmd.SN_MiniHorde) and not (activeMiniHordes and #activeMiniHordes > 0) then
        local closestPlayer = nil
        local closestDist = math.huge
        local players = getPlayerList()
        for _, player in ipairs(players) do
            local px, py = player:getX(), player:getY()
            local dx = zx - px
            local dy = zy - py
            local dist = dx * dx + dy * dy
            if dist < closestDist then
                closestDist = dist
                closestPlayer = player
            end
        end
        if closestPlayer and closestDist <= (CELL_SIZE * CELL_SIZE) then
            local cellKey = getCellKey(closestPlayer:getX(), closestPlayer:getY())
            if cellKey then
                recentKills[cellKey] = (recentKills[cellKey] or 0) + 1
            end
        end
    end

    if #activeMiniHordes == 0 then return end

    for _, job in ipairs(activeMiniHordes) do
        if job.totalToSpawn and (job.killCount or 0) < job.totalToSpawn then
            for _, player in ipairs(getActiveJobPlayers(job)) do
                local px, py = player:getX(), player:getY()
                if px and py then
                    local dist = math.abs(zx - px) + math.abs(zy - py)
                    if dist < 100 then
                        job.killCount = (job.killCount or 0) + 1
                        if job.killCount >= job.totalToSpawn then
                            SN.log("Mini-horde kill target reached (" .. job.killCount .. "/" .. job.totalToSpawn .. ") - attractor stopped")
                        end
                        return  -- credit to first matching job only
                    end
                end
            end
        end
    end
end

-- ==========================================
-- EVENT HOOKS
-- ==========================================
Events.EveryTenMinutes.Add(onEveryTenMinutes)
Events.OnTick.Add(onMiniHordeTick)
Events.OnWeaponSwing.Add(onWeaponSwing)
Events.OnHitZombie.Add(onHitZombie)
Events.OnZombieDead.Add(onMiniHordeZombieDead)

