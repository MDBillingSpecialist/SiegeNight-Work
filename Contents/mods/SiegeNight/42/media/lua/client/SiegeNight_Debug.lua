--[[
    SiegeNight_Debug.lua
    Debug tools for testing Siege Night. CLIENT-SIDE.

    v2.0 - Updated for wave system, kill tracking, no cleanup state

    KEYBINDS (Numpad keys):
    ===============================================================
    Numpad 0    = Toggle debug mode ON/OFF (always active)
    Numpad 1    = Dump full status to console + overhead text
    Numpad 2    = Force next state transition (IDLE→WARNING→ACTIVE→DAWN→IDLE)
    Numpad 3    = Force spawn 10 zombies around player
    Numpad 4    = Force spawn 1 of each special type (sprinter, breaker, tank)
    Numpad 5    = Force trigger a mini-horde
    Numpad 6    = Toggle on-screen debug HUD overlay
    Numpad 7    = Set next siege to TODAY
    Numpad 8    = Fast-forward 1 hour

    Start by pressing Numpad 0 to enable debug mode.
]]

local SN = require("SiegeNight_Shared")

-- ==========================================
-- STATE
-- ==========================================
local debugHUDVisible = false
local debugHUD = nil

-- ==========================================
-- DEBUG HUD OVERLAY
-- ==========================================

SiegeNightDebugHUD = ISPanel:derive("SiegeNightDebugHUD")

function SiegeNightDebugHUD:new(x, y, w, h)
    local o = ISPanel:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.backgroundColor = {r=0, g=0, b=0, a=0.75}
    o.borderColor = {r=0.6, g=0.1, b=0.1, a=0.9}
    return o
end

function SiegeNightDebugHUD:initialise()
    ISPanel.initialise(self)
end

function SiegeNightDebugHUD:prerender()
    ISPanel.prerender(self)

    local font = UIFont.Small
    local y = 8
    local lh = 18
    local x = 10

    self:drawText("=== SIEGE NIGHT DEBUG v2 ===", x, y, 1.0, 0.3, 0.3, 1.0, font)
    y = y + lh + 4

    local sbReady = SN.sandboxReady()
    local sbColor = sbReady and {r=0.3, g=1.0, b=0.3} or {r=1.0, g=0.5, b=0.2}
    self:drawText("Sandbox: " .. (sbReady and "LOADED" or "DEFAULTS") .. " | Enabled: " .. tostring(SN.getSandbox("Enabled")), x, y, sbColor.r, sbColor.g, sbColor.b, 1.0, font)
    y = y + lh

    local siegeData = SN.getWorldData()

    if not siegeData then
        self:drawText("World data not loaded yet", x, y, 1.0, 1.0, 0.3, 1.0, font)
        return
    end

    -- State
    local stateColor = {r=1.0, g=1.0, b=1.0}
    if siegeData.siegeState == SN.STATE_WARNING then stateColor = {r=1.0, g=0.8, b=0.0}
    elseif siegeData.siegeState == SN.STATE_ACTIVE then stateColor = {r=1.0, g=0.2, b=0.2}
    elseif siegeData.siegeState == SN.STATE_DAWN then stateColor = {r=0.3, g=1.0, b=0.3}
    end
    self:drawText("State: " .. siegeData.siegeState, x, y, stateColor.r, stateColor.g, stateColor.b, 1.0, font)
    y = y + lh

    -- Time
    local dayFloat = 0
    if getWorld() then dayFloat = SN.getActualDay() end
    self:drawText("Day: " .. string.format("%.1f", dayFloat) .. " | Hour: " .. SN.getCurrentHour(), x, y, 0.8, 0.8, 0.8, 1.0, font)
    y = y + lh

    -- Siege schedule
    local isSiegeDay = SN.isSiegeDay(math.floor(dayFloat))
    local siegeDayColor = isSiegeDay and {r=1.0, g=0.3, b=0.3} or {r=0.6, g=0.6, b=0.6}
    self:drawText("Siege day: " .. tostring(isSiegeDay) .. " | Next: day " .. siegeData.nextSiegeDay, x, y, siegeDayColor.r, siegeDayColor.g, siegeDayColor.b, 1.0, font)
    y = y + lh

    -- Siege details
    self:drawText("Siege #" .. siegeData.siegeCount .. " | Dir: " .. (siegeData.lastDirection >= 0 and SN.DIR_NAMES[siegeData.lastDirection + 1] or "none"), x, y, 0.8, 0.8, 0.8, 1.0, font)
    y = y + lh

    -- Spawn progress
    local spawnPct = 0
    if siegeData.targetZombies > 0 then
        spawnPct = math.floor(siegeData.spawnedThisSiege / siegeData.targetZombies * 100)
    end
    self:drawText("Spawned: " .. siegeData.spawnedThisSiege .. "/" .. siegeData.targetZombies .. " (" .. spawnPct .. "%)", x, y, 0.8, 0.8, 0.8, 1.0, font)
    y = y + lh

    -- Kill tracking
    local kills = siegeData.killsThisSiege or 0
    local specKills = siegeData.specialKillsThisSiege or 0
    self:drawText("Kills: " .. kills .. " | Specials killed: " .. specKills, x, y, 0.9, 0.6, 0.3, 1.0, font)
    y = y + lh

    -- Wave info
    local waveIdx = siegeData.currentWaveIndex or 0
    local phase = siegeData.currentPhase or "?"
    self:drawText("Wave: " .. waveIdx .. " | Phase: " .. phase, x, y, 0.7, 0.7, 1.0, 1.0, font)
    y = y + lh

    -- History
    local totalCompleted = siegeData.totalSiegesCompleted or 0
    local totalKills = siegeData.totalKillsAllTime or 0
    self:drawText("All-time: " .. totalCompleted .. " sieges | " .. totalKills .. " kills", x, y, 0.5, 0.8, 0.5, 1.0, font)
    y = y + lh

    -- Escalation info (during active)
    if siegeData.siegeState == SN.STATE_ACTIVE then
        local hsd = SN.getHoursSinceDusk()
        self:drawText("Hours since dusk: " .. string.format("%.1f", hsd), x, y, 1.0, 0.6, 0.3, 1.0, font)
        y = y + lh
        self:drawText("Tanks: " .. siegeData.tanksSpawned .. "/" .. SN.getSandbox("TankCount"), x, y, 1.0, 0.6, 0.3, 1.0, font)
        y = y + lh
    end

    -- Player position
    local player = getPlayer()
    if player then
        self:drawText("Pos: " .. math.floor(player:getX()) .. ", " .. math.floor(player:getY()), x, y, 0.5, 0.5, 0.5, 1.0, font)
        y = y + lh
    end

    -- Keybind reminder
    y = y + 4
    self:drawText("Num0=debug Num1=dump Num2=nextState Num3=spawn10", x, y, 0.4, 0.4, 0.4, 1.0, font)
    y = y + lh
    self:drawText("Num4=specials Num5=mini Num6=HUD Num7=today Num8=skip1h", x, y, 0.4, 0.4, 0.4, 1.0, font)
end

local function toggleDebugHUD()
    if debugHUDVisible then
        if debugHUD then
            debugHUD:setVisible(false)
            debugHUD:removeFromUIManager()
            debugHUD = nil
        end
        debugHUDVisible = false
        SN.log("Debug HUD hidden")
    else
        debugHUD = SiegeNightDebugHUD:new(10, 100, 420, 380)
        debugHUD:initialise()
        debugHUD:addToUIManager()
        debugHUD:setVisible(true)
        debugHUDVisible = true
        SN.log("Debug HUD shown")
    end
end

-- ==========================================
-- DEBUG ACTIONS
-- ==========================================

local function dumpStatus()
    local player = getPlayer()
    if not player then return end

    local siegeData = SN.getWorldData()
    if not siegeData then
        player:Say("[SN] World data not loaded yet")
        return
    end
    local dayFloat = SN.getActualDay()
    local hour = SN.getCurrentHour()

    local lines = {
        "--- SIEGE NIGHT STATUS v2 ---",
        "State: " .. siegeData.siegeState,
        "Day: " .. string.format("%.1f", dayFloat) .. " | Hour: " .. hour,
        "Siege #" .. siegeData.siegeCount,
        "Spawned: " .. siegeData.spawnedThisSiege .. "/" .. siegeData.targetZombies,
        "Kills: " .. (siegeData.killsThisSiege or 0) .. " | Specials: " .. (siegeData.specialKillsThisSiege or 0),
        "Wave: " .. (siegeData.currentWaveIndex or 0) .. " | Phase: " .. (siegeData.currentPhase or "?"),
        "Direction: " .. (siegeData.lastDirection >= 0 and SN.DIR_NAMES[siegeData.lastDirection + 1] or "none"),
        "Next siege: day " .. siegeData.nextSiegeDay,
        "All-time: " .. (siegeData.totalSiegesCompleted or 0) .. " sieges, " .. (siegeData.totalKillsAllTime or 0) .. " kills",
    }

    for _, line in ipairs(lines) do
        SN.log(line)
    end

    player:Say("[SN] " .. siegeData.siegeState .. " | Day " .. math.floor(dayFloat) .. " H" .. hour .. " | " .. siegeData.spawnedThisSiege .. "/" .. siegeData.targetZombies .. " | K:" .. (siegeData.killsThisSiege or 0))
end

local function forceNextState()
    local player = getPlayer()
    if not player then return end

    local siegeData = SN.getWorldData()
    if not siegeData then
        player:Say("[SN] World data not loaded yet")
        return
    end
    local oldState = siegeData.siegeState

    if oldState == SN.STATE_IDLE then
        siegeData.siegeState = SN.STATE_WARNING
        siegeData.siegeCount = math.max(0, SN.getSiegeCount(math.floor(SN.getActualDay())))

    elseif oldState == SN.STATE_WARNING then
        siegeData.siegeState = SN.STATE_ACTIVE
        siegeData.siegeCount = math.max(0, siegeData.siegeCount)
        siegeData.targetZombies = SN.calculateSiegeZombies(siegeData.siegeCount, 1)
        siegeData.spawnedThisSiege = 0
        siegeData.tanksSpawned = 0
        siegeData.killsThisSiege = 0
        siegeData.specialKillsThisSiege = 0
        siegeData.siegeStartHour = SN.getCurrentHour()
        local dir = ZombRand(8)
        if dir == siegeData.lastDirection then dir = (dir + 1) % 8 end
        siegeData.lastDirection = dir

    elseif oldState == SN.STATE_ACTIVE then
        siegeData.siegeState = SN.STATE_DAWN

    elseif oldState == SN.STATE_DAWN then
        -- Dawn goes directly to IDLE (no cleanup)
        siegeData.siegeState = SN.STATE_IDLE
        siegeData.nextSiegeDay = math.floor(SN.getActualDay()) + SN.getSandbox("FrequencyDays")
    end

    SN.log("FORCE STATE: " .. oldState .. " -> " .. siegeData.siegeState)
    player:Say("[SN] " .. oldState .. " -> " .. siegeData.siegeState)
end

local function forceSpawn10()
    local player = getPlayer()
    if not player then return end

    local count = 0
    local failed = 0
    local px, py = player:getX(), player:getY()

    for i = 1, 10 do
        local spawned = false
        for attempt = 0, 50 do
            local fx = math.floor(px + ZombRand(31) - 15)
            local fy = math.floor(py + ZombRand(31) - 15)
            local dist = math.sqrt((fx - px)^2 + (fy - py)^2)
            if dist >= 10 then
                local square = getWorld():getCell():getGridSquare(fx, fy, 0)
                if square and square:isFree(false) then
                    local outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1]
                    local zombies = addZombiesInOutfit(fx, fy, 0, 1, outfit, 50, false, false, false, false, false, false, 1.5)
                    if zombies and zombies:size() > 0 then
                        local z = zombies:get(0)
                        z:pathToCharacter(player)
                        z:setTarget(player)
                        z:setAttackedBy(player)
                        z:spottedNew(player, true)
                        z:addAggro(player, 1)
                        z:getModData().SN_Siege = true
                    end
                    count = count + 1
                    spawned = true
                    break
                end
            end
        end
        if not spawned then failed = failed + 1 end
    end

    SN.log("DEBUG: Force spawned " .. count .. " zombies (" .. failed .. " failed)")
    player:Say("[SN] Spawned " .. count .. " zombies" .. (failed > 0 and (" (" .. failed .. " failed)") or ""))
end

local function forceSpawnSpecials()
    local player = getPlayer()
    if not player then return end

    local px, py = player:getX(), player:getY()
    local types = {"sprinter", "breaker", "tank"}
    local spawned = {}

    for _, specialType in ipairs(types) do
        for attempt = 0, 50 do
            local fx = math.floor(px + ZombRand(41) - 20)
            local fy = math.floor(py + ZombRand(41) - 20)
            local dist = math.sqrt((fx - px)^2 + (fy - py)^2)
            local square = dist >= 10 and getWorld():getCell():getGridSquare(fx, fy, 0) or nil
            if square and square:isFree(false) then
                local healthMult = 1.5
                if specialType == "tank" then
                    healthMult = SN.getSandbox("TankHealthMultiplier")
                end

                local outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1]
                local zombies = addZombiesInOutfit(fx, fy, 0, 1, outfit, 50, false, false, false, false, false, false, healthMult)

                if zombies and zombies:size() > 0 then
                    local zombie = zombies:get(0)

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

                    zombie:getModData().SN_Type = specialType
                    zombie:getModData().SN_Siege = true

                    if specialType == "breaker" then
                        zombie:dressInNamedOutfit("ConstructionWorker")
                    elseif specialType == "tank" then
                        zombie:dressInNamedOutfit("ArmyCamoGreen")
                    end

                    zombie:pathToCharacter(player)
                    zombie:setTarget(player)
                    zombie:setAttackedBy(player)
                    zombie:spottedNew(player, true)
                    zombie:addAggro(player, 1)

                    table.insert(spawned, specialType)
                    SN.log("DEBUG: Spawned " .. specialType .. " at " .. fx .. "," .. fy)
                end
                break
            end
        end
    end

    player:Say("[SN] Spawned: " .. table.concat(spawned, ", "))
end

local function forceMiniHorde()
    local player = getPlayer()
    if not player then return end

    local px, py = player:getX(), player:getY()
    local count = 25  -- Bigger test mini-horde
    local dir = ZombRand(8)
    local spawnDist = SN.getSandbox("SpawnDistance")
    local spawned = 0

    for i = 1, count do
        local baseX = px + SN.DIR_X[dir + 1] * spawnDist
        local baseY = py + SN.DIR_Y[dir + 1] * spawnDist
        local spread = ZombRand(41) - 20
        local perpX = -SN.DIR_Y[dir + 1]
        local perpY = SN.DIR_X[dir + 1]
        local fx = math.floor(baseX + perpX * spread)
        local fy = math.floor(baseY + perpY * spread)

        local square = getWorld():getCell():getGridSquare(fx, fy, 0)
        if square and square:isFree(false) then
            local outfit = SN.ZOMBIE_OUTFITS[ZombRand(#SN.ZOMBIE_OUTFITS) + 1]
            local zombies = addZombiesInOutfit(fx, fy, 0, 1, outfit, 50, false, false, false, false, false, false, 1.5)
            if zombies and zombies:size() > 0 then
                local z = zombies:get(0)
                z:pathToCharacter(player)
                z:setTarget(player)
                z:setAttackedBy(player)
                z:spottedNew(player, true)
                z:addAggro(player, 1)
                z:getModData().SN_MiniHorde = true
            end
            spawned = spawned + 1
        end
    end

    getWorldSoundManager():addSound(player, math.floor(px), math.floor(py), 0, 200, 10)

    SN.log("DEBUG: Mini-horde forced. " .. spawned .. " zombies from " .. SN.DIR_NAMES[dir + 1])
    player:Say("[SN] Mini-horde! " .. spawned .. " from " .. SN.DIR_NAMES[dir + 1])
end

local function setSiegeToday()
    local player = getPlayer()
    if not player then return end

    local siegeData = SN.getWorldData()
    if not siegeData then
        player:Say("[SN] World data not loaded yet")
        return
    end

    local today = math.floor(SN.getActualDay())
    siegeData.nextSiegeDay = today
    SN.log("DEBUG: Set nextSiegeDay to " .. today .. " (today)")
    player:Say("[SN] Next siege set to TODAY (day " .. today .. "). Wait for hour 6 or use Num2 to force.")
end

-- Fast-forward state
local ffActive = false
local ffTargetWorldHours = -1

local function fastForwardOneHour()
    local player = getPlayer()
    if not player then return end

    if ffActive then
        player:Say("[SN] Already fast-forwarding...")
        return
    end

    local gt = getGameTime()
    if gt then
        local currentWorldHours = gt:getWorldAgeHours()
        ffTargetWorldHours = currentWorldHours + 1.0
        ffActive = true
        gt:setMultiplier(100)
        SN.log("DEBUG: Fast-forwarding 1 hour (worldAgeHours " .. string.format("%.1f", currentWorldHours) .. " -> " .. string.format("%.1f", ffTargetWorldHours) .. ")...")
        player:Say("[SN] Fast-forwarding 1 hour...")
    end
end

local function onFFTick()
    if not ffActive then return end

    local gt = getGameTime()
    if not gt then return end

    local currentWorldHours = gt:getWorldAgeHours()
    if currentWorldHours >= ffTargetWorldHours then
        gt:setMultiplier(1)
        ffActive = false
        ffTargetWorldHours = -1
        local player = getPlayer()
        if player then
            player:Say("[SN] Time restored. Hour: " .. SN.getCurrentHour())
        end
        SN.log("DEBUG: Fast-forward complete at hour " .. SN.getCurrentHour())
    end
end

-- ==========================================
-- KEYBIND HANDLER
-- ==========================================

local function onKeyPressed(keynum)
    local player = getPlayer()
    if not player then return end
    if isClient() and not player:isAccessLevel("admin") then return end

    if keynum == Keyboard.KEY_NUMPAD0 then
        SN.setDebug(not SN.debugEnabled)
        player:Say("[SN] Debug: " .. (SN.debugEnabled and "ON" or "OFF"))
        if SN.debugEnabled and not debugHUDVisible then
            toggleDebugHUD()
        end
        if not SN.debugEnabled and debugHUDVisible then
            toggleDebugHUD()
        end
        return
    end

    if not SN.debugEnabled then return end

    if keynum == Keyboard.KEY_NUMPAD1 then
        dumpStatus()
    elseif keynum == Keyboard.KEY_NUMPAD2 then
        forceNextState()
    elseif keynum == Keyboard.KEY_NUMPAD3 then
        forceSpawn10()
    elseif keynum == Keyboard.KEY_NUMPAD4 then
        forceSpawnSpecials()
    elseif keynum == Keyboard.KEY_NUMPAD5 then
        forceMiniHorde()
    elseif keynum == Keyboard.KEY_NUMPAD6 then
        toggleDebugHUD()
    elseif keynum == Keyboard.KEY_NUMPAD7 then
        setSiegeToday()
    elseif keynum == Keyboard.KEY_NUMPAD8 then
        fastForwardOneHour()
    end
end

-- ==========================================
-- EVENT HOOKS
-- ==========================================
Events.OnKeyPressed.Add(onKeyPressed)
Events.OnTick.Add(onFFTick)

SN.log("Debug module loaded. Press Numpad 0 to enable debug mode.")
