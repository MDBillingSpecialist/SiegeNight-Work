--[[
    SiegeNight_Shared.lua
    Shared constants, utility functions, and sandbox reads.
    Loaded by both server and client.
]]

local SN = {}

-- ==========================================
-- VERSION
-- ==========================================
SN.VERSION = "2.6.19"
SN.MOD_ID = "SiegeNight"
SN.CLIENT_MODULE = "SiegeNightModule"

-- ==========================================
-- STATE CONSTANTS
-- ==========================================
SN.STATE_IDLE     = "IDLE"
SN.STATE_WARNING  = "WARNING"
SN.STATE_ACTIVE   = "ACTIVE"
SN.STATE_DAWN     = "DAWN"
-- No CLEANUP state. Dawn transitions directly to IDLE.
-- Leftover zombies are the player's problem.

-- ==========================================
-- TIME CONSTANTS
-- ==========================================
SN.DUSK_HOUR    = 20   -- legacy default start hour
SN.DAWN_HOUR    = 6    -- legacy default end hour
SN.MIDNIGHT_RELATIVE_HOUR = 4  -- hours after siege start when midnight hits (default: 20+4=24)

-- Sandbox-configurable siege window
function SN.getSiegeStartHour()
    local h = SN.getSandbox("SiegeStartHour")
    if type(h) ~= "number" then return SN.DUSK_HOUR end
    return math.floor(h)
end

function SN.getSiegeEndHour()
    local h = SN.getSandbox("SiegeEndHour")
    if type(h) ~= "number" then return SN.DAWN_HOUR end
    return math.floor(h)
end

--- True if the given hour is inside the active siege window.
--- Handles windows that cross midnight (ex 20 -> 6).
function SN.isSiegeTime(hour)
    local startH = SN.getSiegeStartHour()
    local endH = SN.getSiegeEndHour()
    hour = math.floor(hour or 0)
    if startH == endH then
        -- Degenerate case: treat as "always siege" (admin/testing). Not recommended.
        return true
    end
    if startH < endH then
        return hour >= startH and hour < endH
    end
    return hour >= startH or hour < endH
end

-- ==========================================
-- DIRECTION CONSTANTS
-- ==========================================
SN.DIR_X = {0, 1, 1, 1, 0, -1, -1, -1}
SN.DIR_Y = {-1, -1, 0, 1, 1, 1, 0, -1}
SN.DIR_NAMES = {"North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"}

-- ==========================================
-- WAVE SYSTEM CONSTANTS
-- ==========================================
-- A siege night is structured as repeating cycles:
--   WAVE (intense burst) -> TRICKLE (slow stragglers) -> BREAK (quiet respite)
-- Wave sizes escalate throughout the night.
SN.WAVE_SPAWN_INTERVAL = 6       -- ticks between spawns during a WAVE (~0.2s)
SN.WAVE_BATCH_SIZE = 4            -- zombies per spawn tick during WAVE
SN.TRICKLE_SPAWN_INTERVAL = 60    -- ticks between spawns during TRICKLE (~2s)
SN.TRICKLE_BATCH_SIZE = 1         -- zombies per spawn tick during TRICKLE

-- Wave phase names
SN.PHASE_WAVE    = "WAVE"
SN.PHASE_TRICKLE = "TRICKLE"
SN.PHASE_BREAK   = "BREAK"

-- ==========================================
-- OUTFIT TABLES
-- ==========================================
SN.BREAKER_OUTFITS = {"ConstructionWorker", "MetalWorker", "Mechanic", "Woodcut"}
SN.TANK_OUTFITS = {"ArmyCamoGreen", "ArmyCamoDesert", "ArmyServiceUniform", "PoliceRiot"}

SN.ZOMBIE_OUTFITS = {
    "AirCrew", "AmbulanceDriver", "ArmyCamoDesert", "ArmyCamoGreen",
    "Bandit", "BaseballFan_KY", "Bathrobe", "Bedroom", "Biker",
    "Camper", "Chef", "Classy", "Cook_Generic", "Cyclist",
    "Doctor", "Farmer", "Fireman", "FitnessInstructor",
    "Fossoil", "Generic01", "Generic02", "Generic03", "Generic04", "Generic05",
    "GigaMart_Employee", "Hobbo", "HospitalPatient",
    "Nurse", "OfficeWorkerSkirt", "Pharmacist", "Police",
    "Postal", "Punk", "Ranger", "Redneck", "Rocker",
    "SportsFan", "Student", "Survivalist", "Swimmer", "Teacher",
    "Tourist", "Waiter_Spiffo", "Young",
    "ConstructionWorker", "Fisherman", "Hunter", "Mechanic",
    "OfficeWorker", "Security", "Veteran"
}

-- ==========================================
-- SANDBOX DEFAULTS (used when SandboxVars not loaded)
-- ==========================================
SN.DEFAULTS = {
    Enabled = true,
    FirstSiegeDay = 3,
    FrequencyDays = 3,
    FrequencyDaysMax = 0,  -- 0 = use FrequencyDays exactly. If > FrequencyDays, randomize between the two.
    BaseZombieCount = 75,
    ScalingMultiplier = 1.5,
    MaxZombies = 1500,
    WarningSignsEnabled = true,
    DirectionalAttacks = true,
    SpawnDistance = 45,
    SharedSpawnRadius = 200,  -- MP: if players are within this many tiles, spawn near centroid so everyone sees the horde
    SiegeStartHour = 20,
    SiegeEndHour = 6,
    WaveBreakSeconds = 0,  -- 0 = use size-based formula. Any value > 0 caps break duration to that many seconds.
    -- Special zombies
    SpecialZombiesEnabled = true,
    SpecialZombiesStartWeek = 3,
    SprinterPercent = 5,
    BreakerPercent = 10,
    TankCount = 2,
    TankHealthMultiplier = 5.0,
    -- Mini-hordes
    MiniHorde_Enabled = true,
    MiniHorde_NoiseThreshold = 80,
    MiniHorde_MaxZombies = 50,
    MiniHorde_MinZombies = 10,
    MiniHorde_CooldownMinutes = 30,
    MiniHorde_MaxPerDay = 5,
    MiniHorde_ActivityScaling = true,
    -- Scaling factors
    MiniHorde_PlayerScaling = true,
    MiniHorde_EstablishmentScaling = true,
    -- Per-cluster / safehouse anchor system
    MaxActiveZombies = 300,
    SafehouseSearchRadius = 300,
    SafehouseMergeDistance = 50,
    SpawnAnchor = 1,  -- 1 = player, 2 = safehouse
    -- Weather effects
    SiegeWeatherEnabled = true,
    SiegeWeatherIntensity = 1.0,
}

-- ==========================================
-- SAFE SANDBOX ACCESS
-- ==========================================
function SN.getSandbox(key)
    if SandboxVars and SandboxVars.SiegeNight and SandboxVars.SiegeNight[key] ~= nil then
        return SandboxVars.SiegeNight[key]
    end
    if SN.DEFAULTS[key] ~= nil then
        return SN.DEFAULTS[key]
    end
    SN.log("WARNING: Unknown sandbox key '" .. tostring(key) .. "' with no default")
    return nil
end

function SN.sandboxReady()
    return SandboxVars ~= nil and SandboxVars.SiegeNight ~= nil
end

--- Get the next siege frequency (supports random range)
--- If FrequencyDaysMax > FrequencyDays, returns a random value between them.
--- Otherwise returns FrequencyDays exactly (backward compatible).
function SN.getNextFrequency()
    local freqMin = SN.getSandbox("FrequencyDays")
    local freqMax = SN.getSandbox("FrequencyDaysMax") or 0
    if freqMax > freqMin then
        return freqMin + ZombRand(freqMax - freqMin + 1)
    end
    return freqMin
end

-- ==========================================
-- UTILITY FUNCTIONS
-- ==========================================

--- Get the actual in-game day number since the player started.
--- Uses getWorldAgeDays() directly  this is the number of days the world has existed.
--- TimeSinceApo only affects the calendar month/day display, NOT world age.
--- World age day 0 = the first day of the game regardless of apocalypse start date.
function SN.getActualDay()
    if not getWorld() then return 0 end
    -- getWorldAgeDays() returns the number of days since world creation (0-based float).
    -- Day 0 is the first day. We add 1 so "Day 1" = first day of gameplay.
    return getWorld():getWorldAgeDays() + 1
end

function SN.getCurrentHour()
    if not getGameTime() then return 0 end
    return getGameTime():getHour()
end

function SN.getHoursSinceDusk()
    local hour = SN.getCurrentHour()
    local startH = SN.getSiegeStartHour()
    local endH = SN.getSiegeEndHour()

    if not SN.isSiegeTime(hour) then
        return 0
    end

    if startH == endH then
        return 0
    end

    if startH < endH then
        return hour - startH
    end

    if hour >= startH then
        return hour - startH
    end
    return (24 - startH) + hour
end

function SN.getNightDuration()
    local startH = SN.getSiegeStartHour()
    local endH = SN.getSiegeEndHour()
    if startH == endH then return 24 end
    if startH < endH then return endH - startH end
    return (24 - startH) + endH
end

--- Calculate total siege zombies for a given siege number.
--- Scales with: base count, multiplier^siegeCount, and player count.
function SN.calculateSiegeZombies(siegeCount, playerCount)
    local base = SN.getSandbox("BaseZombieCount")
    local multiplier = SN.getSandbox("ScalingMultiplier")
    local maxZ = SN.getSandbox("MaxZombies")
    playerCount = playerCount or 1
    local total = math.floor(base * math.pow(multiplier, siegeCount) * playerCount)
    return math.min(total, maxZ)
end

--- Calculate wave structure for a siege.
--- Returns a table of wave definitions for the entire night.
--- Each wave = { waveSize, trickleSize, breakDurationTicks }
--- Waves escalate through the night but every wave is substantial.
--- First wave = ~25% of total. Last wave = ~40% of total.
--- Break duration scales with horde size: bigger horde = longer breaks (5-10 min).
function SN.calculateWaveStructure(totalZombies)
    local waves = {}

    -- Number of waves scales with total zombie count
    -- Small siege (75): 3 waves. Medium (200): 4-5. Large (500+): 6-7.
    local numWaves = math.max(3, math.min(7, math.floor(totalZombies / 60) + 2))

    -- Distribute zombies with escalation but substantial minimums.
    -- Use a shifted weight so wave 1 still gets a meaningful chunk:
    --   weight_i = numWaves + i  (e.g. for 3 waves: weights 4, 5, 6 => 27%, 33%, 40%)
    --   This ensures the first wave always gets ~25%+ of the total.
    local totalWeight = 0
    for i = 1, numWaves do
        totalWeight = totalWeight + (numWaves + i)
    end

    local zombiesAllocated = 0
    for i = 1, numWaves do
        local weight = (numWaves + i) / totalWeight
        local waveZombies

        if i == numWaves then
            -- Last wave gets all remaining
            waveZombies = totalZombies - zombiesAllocated
        else
            waveZombies = math.max(10, math.floor(totalZombies * weight))
        end

        -- Wave portion = 70% of wave's zombies (intense burst), trickle = 30% (slow stragglers)
        local waveSize = math.max(5, math.floor(waveZombies * 0.7))
        local trickleSize = math.max(2, waveZombies - waveSize)

        -- Break duration scales with TOTAL horde size (bigger siege = longer breaks needed)
        -- Also shorter breaks as the night progresses (urgency increases)
        -- Small siege (75): breaks ~3-5 min.  Large siege (500+): breaks ~5-10 min.
        -- Last wave has no break (final push til dawn).
        -- WaveBreakSeconds sandbox option caps break duration if set > 0.
        local breakTicks = 0
        if i < numWaves then
            -- Base break: scales with total zombie count (more zombies = need more prep time)
            local sizeBreakBase = math.min(18000, math.max(5400, totalZombies * 36))  -- 3-10 min range
            -- Decay: later waves get shorter breaks (urgency)
            local decay = 1.0 - (i / numWaves) * 0.6  -- wave 1 = 100%, last-1 = ~40%
            breakTicks = math.floor(sizeBreakBase * decay)
            -- Clamp: min 2 min, max 10 min
            breakTicks = math.max(3600, math.min(18000, breakTicks))
            -- Apply WaveBreakSeconds cap if set
            local maxBreakSec = SN.getSandbox("WaveBreakSeconds")
            if maxBreakSec and maxBreakSec > 0 then
                breakTicks = math.min(breakTicks, maxBreakSec * 30)
            end
        end

        table.insert(waves, {
            waveSize = waveSize,
            trickleSize = trickleSize,
            breakDurationTicks = breakTicks,
        })

        zombiesAllocated = zombiesAllocated + waveSize + trickleSize
    end

    return waves
end

function SN.isSiegeDay(day)
    local firstDay = SN.getSandbox("FirstSiegeDay")
    local freq = SN.getSandbox("FrequencyDays")
    if day < firstDay then return false end
    return ((math.floor(day) - firstDay) % freq) == 0
end

function SN.getSiegeCount(day)
    local firstDay = SN.getSandbox("FirstSiegeDay")
    local freq = SN.getSandbox("FrequencyDays")
    if day < firstDay then return -1 end
    return math.floor((math.floor(day) - firstDay) / freq)
end

-- ==========================================
-- STATE HELPERS
-- ==========================================

function SN.getStateName(state)
    if state == SN.STATE_IDLE then return "Idle"
    elseif state == SN.STATE_WARNING then return "Warning"
    elseif state == SN.STATE_ACTIVE then return "Active"
    elseif state == SN.STATE_DAWN then return "Dawn"
    else return tostring(state)
    end
end

function SN.isInSiege(state)
    return state == SN.STATE_WARNING or state == SN.STATE_ACTIVE or state == SN.STATE_DAWN
end

function SN.getDirName(dirIndex)
    if dirIndex == nil or dirIndex < 0 or dirIndex > 7 then return "none" end
    return SN.DIR_NAMES[dirIndex + 1]
end

-- ==========================================
-- WORLD DATA
-- ==========================================

SN._worldData = nil

function SN.initWorldData()
    -- Only the server (or SP host) should create and initialize ModData.
    -- Clients receive it via ModData.transmit() from the server.
    -- If clients call getOrCreate, it shadows the server's persisted data with defaults.
    local isSP = not isServer() and not isClient()
    if isClient() and not isServer() then
        -- Client: just try to read what the server sent
        local data = ModData.get("SiegeNight")
        if data then
            SN._worldData = data
            SN.log("Client received global ModData from server")
        else
            SN.log("Client: ModData not yet received from server (will sync shortly)")
        end
        return data
    end

    -- Server or SP: create and initialize
    local data = ModData.getOrCreate("SiegeNight")
    if data.siegeState == nil then data.siegeState = SN.STATE_IDLE end
    if data.siegeCount == nil then data.siegeCount = 0 end
    if data.nextSiegeDay == nil then data.nextSiegeDay = SN.getSandbox("FirstSiegeDay") end
    if data.lastDirection == nil then data.lastDirection = -1 end
    if data.spawnedThisSiege == nil then data.spawnedThisSiege = 0 end
    if data.targetZombies == nil then data.targetZombies = 0 end
    if data.siegeStartHour == nil then data.siegeStartHour = 0 end
    if data.tanksSpawned == nil then data.tanksSpawned = 0 end
    -- Kill tracking
    if data.killsThisSiege == nil then data.killsThisSiege = 0 end
    if data.specialKillsThisSiege == nil then data.specialKillsThisSiege = 0 end
    -- Siege history (array of past siege summaries, stored as flat keys)
    if data.totalSiegesCompleted == nil then data.totalSiegesCompleted = 0 end
    if data.totalKillsAllTime == nil then data.totalKillsAllTime = 0 end
    -- Wave tracking
    if data.currentWaveIndex == nil then data.currentWaveIndex = 0 end
    if data.currentPhase == nil then data.currentPhase = SN.PHASE_WAVE end
    -- Migrate: if save has old CLEANUP state, move to IDLE
    if data.siegeState == "CLEANUP" then data.siegeState = SN.STATE_IDLE end
    SN._worldData = data
    SN.log("SiegeNight loaded (v" .. tostring(SN.VERSION) .. ")")
    SN.log("Global ModData initialized (server/SP)")
    return data
end

function SN.getWorldData()
    -- Always fetch fresh from ModData (no cache) so client gets server transmits
    local data = ModData.get("SiegeNight")
    if data then
        SN._worldData = data
        return data
    end
    return SN._worldData
end

Events.OnInitGlobalModData.Add(SN.initWorldData)

function SN.log(message)
    print("[SiegeNight] " .. tostring(message))
end

-- ==========================================
-- DEBUG SYSTEM
-- ==========================================
SN.debugEnabled = false

function SN.debug(message)
    if SN.debugEnabled then
        print("[SiegeNight:DEBUG] " .. tostring(message))
    end
end

function SN.setDebug(enabled)
    SN.debugEnabled = enabled
    SN.log("Debug mode: " .. (enabled and "ON" or "OFF"))
end

-- ==========================================
-- MOD API HOOKS
-- ==========================================
-- Other mods can register callbacks to react to siege events.
-- Usage: SN.onSiegeStart(function(siegeCount, direction, targetZombies) ... end)
SN._callbacks = {
    onSiegeStart = {},
    onSiegeEnd = {},
    onWaveStart = {},
    onBreakStart = {},
    onMiniHorde = {},
}

function SN.onSiegeStart(callback)
    table.insert(SN._callbacks.onSiegeStart, callback)
end

function SN.onSiegeEnd(callback)
    table.insert(SN._callbacks.onSiegeEnd, callback)
end

function SN.onWaveStart(callback)
    table.insert(SN._callbacks.onWaveStart, callback)
end

function SN.onBreakStart(callback)
    table.insert(SN._callbacks.onBreakStart, callback)
end

function SN.onMiniHorde(callback)
    table.insert(SN._callbacks.onMiniHorde, callback)
end

function SN.fireCallback(name, ...)
    if SN._callbacks[name] then
        for _, cb in ipairs(SN._callbacks[name]) do
            local ok, err = pcall(cb, ...)
            if not ok then
                SN.log("API callback error (" .. name .. "): " .. tostring(err))
            end
        end
    end
end

return SN


