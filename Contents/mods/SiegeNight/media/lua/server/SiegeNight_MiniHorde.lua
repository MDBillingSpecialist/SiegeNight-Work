--[[
    SiegeNight_MiniHorde.lua
    Noise heat tracking and triggered mini-hordes between siege nights.
    Runs SERVER-SIDE only.

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

local SN = require("SiegeNight_Shared")

-- ==========================================
-- NOISE HEAT GRID
-- ==========================================
local CELL_SIZE = 100
local heatGrid = {}
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

local function addHeat(worldX, worldY, amount)
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
    if not SN.getSandbox("MiniHorde_Enabled") then return end
    if not handWeapon then return end
    if not character then return end

    local scriptItem = handWeapon:getScriptItem()
    if scriptItem and scriptItem:getAmmoType() then
        local px, py = character:getX(), character:getY()
        if type(px) == "number" and type(py) == "number" then
            addHeat(px, py, 10)
            SN.debug("Gunfire detected from " .. tostring(character:getUsername() or "player"))
        end
    end
end

local function onHitZombie(zombie, character, bodyPartType, handWeapon)
    if not SN.getSandbox("MiniHorde_Enabled") then return end
    if not character then return end
    if not instanceof(character, "IsoPlayer") then return end

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
    if not SN.getSandbox("MiniHorde_Enabled") then return end

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
                addHeat(px, py, 3)

                -- Vehicle noise (more impactful)
                if player:getVehicle() then
                    addHeat(px, py, 8)
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

                -- Generator detection
                local cell = getWorld():getCell()
                if cell then
                    local foundGenerator = false
                    for gx = -3, 3 do
                        if foundGenerator then break end
                        for gy = -3, 3 do
                            local sq = cell:getGridSquare(math.floor(px) + gx * 10, math.floor(py) + gy * 10, 0)
                            if sq then
                                local generator = sq:getGenerator()
                                if generator and generator:isRunning() then
                                    addHeat(px, py, 15)
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
                        addHeat(px, py, 5)
                    end
                end
            end
        end
    end

    -- Decay heat and check triggers
    local gt = getGameTime()
    if not gt then return end
    local now = gt:getWorldAgeHours()
    local cooldownHours = SN.getSandbox("MiniHorde_CooldownMinutes") / 60
    local threshold = SN.getSandbox("MiniHorde_NoiseThreshold")

    for cellKey, data in pairs(heatGrid) do
        if data.heat >= threshold then
            if (now - data.lastTrigger) >= cooldownHours then
                triggerMiniHorde(cellKey, data, playerList)
                data.heat = 0
                data.lastTrigger = now
            end
        end

        -- Slower decay (4 instead of 5) so heat accumulates more
        data.heat = math.max(0, data.heat - 4)

        if data.heat <= 0 and (now - data.lastTrigger) > 1 then
            heatGrid[cellKey] = nil
        end
    end
end

-- ==========================================
-- MINI-HORDE SPAWNER
-- ==========================================

local activeMiniHordes = {}

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
    local minZ = SN.getSandbox("MiniHorde_MinZombies")
    local maxZ = SN.getSandbox("MiniHorde_MaxZombies")

    local count = minZ
    if SN.getSandbox("MiniHorde_ActivityScaling") then
        count = math.floor(minZ + (maxZ - minZ) * heatRatio)
    end

    -- Player count scaling: more players = bigger mini-horde
    if SN.getSandbox("MiniHorde_PlayerScaling") then
        count = math.floor(count * math.max(1, #playerList * 0.75))
    end

    local dir = ZombRand(8)
    SN.log("MINI-HORDE triggered! " .. count .. " zombies at cell " .. cellKey
        .. " (heat: " .. heatData.heat .. ", players: " .. #playerList .. ")")

    -- Notify client(s)
    if isServer() then
        sendServerCommand(SN.CLIENT_MODULE, "MiniHorde", {
            count = count,
            direction = dir,
        })
    end

    -- Fire API callback
    SN.fireCallback("onMiniHorde", count, dir, cellKey)

    -- Create staggered spawn job
    table.insert(activeMiniHordes, {
        player = nearestPlayer,
        remaining = count,
        tickCounter = 0,
        spawnInterval = 8,  -- faster spawn rate than before
        direction = dir,
        -- Notify flag: announce to player on first spawn
        announced = false,
    })
end

local function onMiniHordeTick()
    if #activeMiniHordes == 0 then return end

    for i = #activeMiniHordes, 1, -1 do
        local job = activeMiniHordes[i]
        job.tickCounter = job.tickCounter - 1

        if job.tickCounter <= 0 then
            job.tickCounter = job.spawnInterval

            if job.player and job.player:isAlive() and job.remaining > 0 then
                -- SP: announce via Say() on first spawn
                if not job.announced then
                    -- In SP, sendServerCommand does nothing, so use Say() directly
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
                        if square and square:isFree(false) and square:isOutside() then
                            local outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1]
                            local zombies = addZombiesInOutfit(fx, fy, 0, 1, outfit, 50, false, false, false, false, false, false, 1.5)
                            if zombies and zombies:size() > 0 then
                                local zombie = zombies:get(0)
                                zombie:pathToCharacter(job.player)
                                zombie:setTarget(job.player)
                                zombie:setAttackedBy(job.player)
                                zombie:spottedNew(job.player, true)
                                zombie:addAggro(job.player, 1)
                                zombie:getModData().SN_MiniHorde = true
                            end
                            getWorldSoundManager():addSound(job.player, math.floor(px), math.floor(py), 0, 200, 10)

                            job.remaining = job.remaining - 1
                            break
                        end
                    end
                end
            end

            if job.remaining <= 0 then
                SN.log("Mini-horde spawn complete")
                table.remove(activeMiniHordes, i)
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
