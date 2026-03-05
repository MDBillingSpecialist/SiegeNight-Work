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
    - Running generators = 15 per check
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
    data.heat = math.min(100, data.heat + amount)
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
                table.insert(playerList, players:get(i))
            end
        end
    end
    return playerList
end

-- ==========================================
-- NOISE DETECTION (Event-driven)
-- ==========================================

local function onWeaponSwing(character, handWeapon)
    if not SN or not SN.getSandbox or not SN.getSandbox("MiniHorde_Enabled") then return end
    if not handWeapon then return end
    if not character then return end

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

    -- Don't count kills of mini-horde zombies as heat (prevents feedback loop)
    if zombie and zombie:getModData() and zombie:getModData().SN_MiniHorde then return end

    local px, py = character:getX(), character:getY()
    if type(px) ~= "number" or type(py) ~= "number" then return end

    local cellKey = getCellKey(px, py)
    if cellKey then
        recentKills[cellKey] = (recentKills[cellKey] or 0) + 1
    end
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
                                    addHeat(px, py, 15, nil)
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
    local cooldownMinutes = tonumber(SN.getSandbox("MiniHorde_CooldownMinutes"))
    if not cooldownMinutes or cooldownMinutes <= 0 then cooldownMinutes = 30 end
    if cooldownMinutes < 1 then cooldownMinutes = 1 end
    local cooldownHours = cooldownMinutes / 60

    local threshold = tonumber(SN.getSandbox("MiniHorde_NoiseThreshold")) or 80
    if threshold < 1 then threshold = 1 end

    -- If a mini-horde is currently spawning, don't trigger another one.
    -- This prevents stacked jobs from looking like "nonstop" hordes even with a sane cooldown.
    if activeMiniHordes and #activeMiniHordes > 0 then
        return
    end

    -- Daily hard cap: reset counter at midnight (new day), then enforce limit.
    local currentDay = math.floor(now / 24)
    if (siegeData.miniHordeDay or -1) ~= currentDay then
        siegeData.miniHordeDay = currentDay
        siegeData.miniHordesToday = 0
    end
    local maxPerDay = tonumber(SN.getSandbox("MiniHorde_MaxPerDay")) or 5
    if maxPerDay < 1 then maxPerDay = 1 end
    if (siegeData.miniHordesToday or 0) >= maxPerDay then
        -- Daily limit reached; still decay heat but don't trigger.
        for cellKey, data in pairs(heatGrid) do
            data.heat = math.max(0, data.heat - 8)
            if data.heat <= 0 and (now - data.lastTrigger) > cooldownHours then
                heatGrid[cellKey] = nil
            end
        end
        return
    end

    -- GLOBAL cooldown (MP): prevent large servers from triggering mini-hordes every tick
    -- just because players are spread across many heat cells.
    local globalLast = siegeData.miniHordeLastTrigger or 0
    local inGlobalGrace = (now - globalLast) < cooldownHours

    for cellKey, data in pairs(heatGrid) do
        -- Per-cell grace period
        local inGrace = (now - data.lastTrigger) < cooldownHours

        if (not inGlobalGrace) and (not inGrace) and data.heat >= threshold then
            triggerMiniHorde(cellKey, data, playerList)
            data.heat = 0
            data.lastTrigger = now
            siegeData.miniHordeLastTrigger = now
            siegeData.miniHordesToday = (siegeData.miniHordesToday or 0) + 1
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

-- Repath interval: same as siege (150 ticks = 5 seconds).
-- Continuously re-drives all tracked mini-horde zombies toward the player.
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

    local nearestPlayer = nil
    local nearestDist = math.huge

    for _, player in ipairs(playerList) do
        if player and player:isAlive() then
            local px, py = player:getX(), player:getY()
            if type(px) == "number" and type(py) == "number" then
                local dist = math.sqrt((px - cellCenterX)^2 + (py - cellCenterY)^2)
                if dist < nearestDist then
                    nearestDist = dist
                    nearestPlayer = player
                end
            end
        end
    end

    if not nearestPlayer then return end

    -- Calculate horde size with player scaling
    local heatRatio = math.min(1.0, heatData.heat / 100)
    local minZ = tonumber(SN.getSandbox("MiniHorde_MinZombies")) or 10
    local maxZ = tonumber(SN.getSandbox("MiniHorde_MaxZombies")) or 60
    if maxZ < minZ then maxZ = minZ end

    local count = minZ
    if SN.getSandbox("MiniHorde_ActivityScaling") then
        count = math.floor(minZ + (maxZ - minZ) * heatRatio)
    end

    -- Player count scaling: more players = bigger mini-horde
    if SN.getSandbox("MiniHorde_PlayerScaling") then
        count = math.floor(count * math.max(1, #playerList * 0.75))
    end

    -- IMPORTANT: MiniHorde_MaxZombies is treated as an absolute cap.
    -- (Some servers set MaxZombies low intentionally; player scaling should never exceed it.)
    count = math.min(count, maxZ)

    local dir = ZombRand(8)
    SN.log("MINI-HORDE triggered! " .. count .. " zombies at cell " .. cellKey
        .. " (heat: " .. heatData.heat .. ", players: " .. #playerList
        .. ", cap: " .. tostring(maxZ)
        .. ", cooldownMin: " .. tostring(tonumber(SN.getSandbox("MiniHorde_CooldownMinutes")) or 30)
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
        remaining = count,
        tickCounter = 0,
        spawnInterval = 8,  -- faster spawn rate than before
        direction = dir,
        -- Notify flag: announce to player on first spawn
        announced = false,
        -- Convergence tracking (matches siege repath system)
        zombieList = {},    -- tracked zombie refs for repath
        repathTick = 0,     -- counts up to MH_REPATH_INTERVAL
    })
end

local function onMiniHordeTick()
    if #activeMiniHordes == 0 then return end

    for i = #activeMiniHordes, 1, -1 do
        local job = activeMiniHordes[i]
        job.tickCounter = job.tickCounter - 1
        job.repathTick = (job.repathTick or 0) + 1

        -- ========== SPAWN PHASE (batch of 3 per tick) ==========
        if job.tickCounter <= 0 and job.remaining > 0 then
            job.tickCounter = job.spawnInterval

            if job.player and job.player:isAlive() then
                -- SP: announce via Say() on first spawn
                if not job.announced then
                    local isSP = not isServer() and not isClient()
                    if isSP then
                        local dirName = SN.getDirName(job.direction)
                        job.player:Say("Something's attracted their attention from the " .. dirName .. "...")
                    end
                    job.announced = true
                end

                local px = job.player:getX()
                local py = job.player:getY()
                if type(px) ~= "number" or type(py) ~= "number" then
                    job.remaining = 0
                else
                    local spawnDist = SN.getSandbox("SpawnDistance")
                    local batchSize = math.min(3, job.remaining)

                    for b = 1, batchSize do
                        if job.remaining <= 0 then break end
                        local spawned = false
                        for attempt = 0, 30 do
                            local dir = job.direction
                            local baseX = px + SN.DIR_X[dir + 1] * spawnDist
                            local baseY = py + SN.DIR_Y[dir + 1] * spawnDist
                            local spread = ZombRand(41) - 20
                            local perpX = -SN.DIR_Y[dir + 1]
                            local perpY = SN.DIR_X[dir + 1]
                            local fx = math.floor(baseX + perpX * spread)
                            local fy = math.floor(baseY + perpY * spread)

                            local square = getWorld():getCell():getGridSquare(fx, fy, 0)
                            if square and square:isFree(false) and square:isOutside() and not isInsidePlayerArea(square) then
                                local outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1]
                                local ok, zombies = pcall(addZombiesInOutfit, fx, fy, 0, 1, outfit, 50, false, false, false, false, false, false, 1.0)
                                if not ok then
                                    SN.log("WARNING: mini-horde addZombiesInOutfit failed: " .. tostring(zombies))
                                end
                                if ok and zombies and zombies:size() > 0 then
                                    local zombie = zombies:get(0)
                                    local p = job.player
                                    -- Single pcall for all targeting (reduces overhead vs 5 separate pcalls)
                                    pcall(function()
                                        zombie:pathToSound(px, py, 0)
                                        zombie:setTarget(p)
                                        zombie:setAttackedBy(p)
                                        zombie:spottedNew(p, true)
                                        zombie:addAggro(p, 1)
                                    end)
                                    zombie:getModData().SN_MiniHorde = true
                                    table.insert(job.zombieList, zombie)
                                end
                                job.remaining = job.remaining - 1
                                spawned = true
                                break
                            end
                        end
                    end
                end
            else
                -- Player dead/gone, cancel remaining spawns
                job.remaining = 0
            end

            if job.remaining <= 0 then
                SN.log("Mini-horde spawn complete (" .. #job.zombieList .. " tracked)")
            end
        end

        -- ========== REPATH PHASE (every 5 seconds, same as siege) ==========
        if job.repathTick >= MH_REPATH_INTERVAL then
            job.repathTick = 0
            local p = job.player
            if p and p:isAlive() then
                local okP, pX = pcall(function() return p:getX() end)
                local okPY, pY = pcall(function() return p:getY() end)
                if okP and okPY and type(pX) == "number" and type(pY) == "number" then
                    -- Prune dead zombies, repath living ones toward the player.
                    -- Single pcall per zombie (reduces overhead from 6 pcalls to 2).
                    local alive = {}
                    for _, zombie in ipairs(job.zombieList) do
                        local okD, dead = pcall(function() return zombie:isDead() end)
                        if okD and not dead then
                            pcall(function()
                                zombie:pathToSound(pX, pY, 0)
                                zombie:setTarget(p)
                                zombie:setAttackedBy(p)
                                zombie:spottedNew(p, true)
                                zombie:addAggro(p, 1)
                            end)
                            table.insert(alive, zombie)
                        end
                    end
                    job.zombieList = alive
                end
            end
        end

        -- ========== CLEANUP ==========
        -- Job is done when spawning is finished AND all tracked zombies are dead/gone
        if job.remaining <= 0 and #job.zombieList == 0 then
            SN.log("Mini-horde complete (all zombies dead or despawned)")
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
        remaining = count,
        tickCounter = 0,
        spawnInterval = 8,
        direction = dir,
        announced = false,
        zombieList = {},
        repathTick = 0,
    })

    local dirName = SN.getDirName and SN.getDirName(dir) or tostring(dir)
    SN.log("DEBUG: Mini-horde forced. " .. count .. " zombies from " .. dirName)
    return count, dir
end

-- ==========================================
-- EVENT HOOKS
-- ==========================================
Events.EveryTenMinutes.Add(onEveryTenMinutes)
Events.OnTick.Add(onMiniHordeTick)
Events.OnWeaponSwing.Add(onWeaponSwing)
Events.OnHitZombie.Add(onHitZombie)

