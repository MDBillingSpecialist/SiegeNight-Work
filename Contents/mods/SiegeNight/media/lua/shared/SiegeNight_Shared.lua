--[[
    SiegeNight_Shared.lua
    Shared constants, utility functions, and sandbox reads.
    Loaded by both server and client.
]]

local SN = {}

-- ==========================================
-- VERSION
-- ==========================================
SN.VERSION = "2.7.1"
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
-- Two-layer spawn system (ocean rhythm):
--   Layer 1: BASELINE TIDE — constant 1 zombie every 2 sec, never stops (35% of budget)
--   Layer 2: SURGE WAVES — periodic instant crashes of 50-100 zombies (65% of budget)
-- During cooldown between surges, baseline keeps going → pressure never goes silent.
-- Dynamic — surge sizes vary ±20% so it never feels mechanical.

-- Surge layer (the crashing waves)
SN.SURGE_SPAWN_INTERVAL = 1       -- every tick during SURGE (fastest possible)
SN.SURGE_BATCH_SIZE = 15          -- zombies per tick during SURGE (~450/sec theoretical, capped by MAX_SPAWNS)

-- Baseline layer (the tide that never recedes)
SN.BASELINE_SPAWN_INTERVAL = 60   -- ticks between baseline spawns (1 every 2 seconds)
SN.BASELINE_BATCH_SIZE = 1        -- 1 zombie per baseline spawn tick

-- Budget split (how total zombies are divided between layers)
SN.BASELINE_BUDGET_FRACTION = 0.35 -- 35% of total zombies go to baseline tide

-- Phase names (simplified: just SURGE and COOLDOWN)
SN.PHASE_SURGE    = "SURGE"
SN.PHASE_COOLDOWN = "COOLDOWN"
-- Backward compat aliases
SN.PHASE_BURST    = SN.PHASE_SURGE     -- old name still works
SN.PHASE_BREAK    = SN.PHASE_COOLDOWN  -- old name still works

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
    FirstSiegeDay = 5,
    FrequencyDays = 5,
    FrequencyDaysMax = 0,  -- 0 = use FrequencyDays exactly. If > FrequencyDays, randomize between the two.
    BaseZombieCount = 50,
    ScalingMultiplier = 1.5,
    MaxZombies = 4000,
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
    MiniHorde_Enabled = false,
    MiniHorde_NoiseThreshold = 100,
    MiniHorde_MaxZombies = 35,
    MiniHorde_MinZombies = 8,
    MiniHorde_CooldownMinutes = 60,
    MiniHorde_MaxPerDay = 2,
    MiniHorde_ActivityScaling = true,
    -- Scaling factors
    MiniHorde_PlayerScaling = true,
    MiniHorde_EstablishmentScaling = true,
    -- Per-cluster / safehouse anchor system
    MaxActiveZombies = 400,
    SafehouseSearchRadius = 300,
    SafehouseMergeDistance = 50,
    SpawnAnchor = 1,  -- 1 = player, 2 = safehouse
    -- Weather (optional; purely cosmetic)
    StripSiegeZombieLoot = false,  -- If true, removes non-clothing items from siege/mini-horde zombies so they don't drop loot
    SiegeWeatherEnabled = false,
    SiegeWeatherIntensity = 1.0,
}

-- ==========================================
-- SAFE SANDBOX ACCESS
-- ==========================================
function SN.getSandbox(key)
    local val = nil
    if SandboxVars and SandboxVars.SiegeNight and SandboxVars.SiegeNight[key] ~= nil then
        val = SandboxVars.SiegeNight[key]
    elseif SN.DEFAULTS[key] ~= nil then
        val = SN.DEFAULTS[key]
    else
        SN.log("WARNING: Unknown sandbox key '" .. tostring(key) .. "' with no default")
        return nil
    end
    -- Auto-coerce strings to numbers when the default is numeric.
    -- Some dedicated servers pass SandboxVars as strings ("200" instead of 200).
    if val ~= nil and type(val) ~= "number" and type(SN.DEFAULTS[key]) == "number" then
        val = tonumber(val)
        if val == nil then val = SN.DEFAULTS[key] end  -- fallback if unparseable
    end
    -- Auto-coerce strings to booleans when the default is boolean.
    -- Some dedicated servers pass SandboxVars as strings ("true"/"false" instead of true/false).
    if val ~= nil and type(val) == "string" and type(SN.DEFAULTS[key]) == "boolean" then
        local lowered = string.lower(val)
        if lowered == "true" then val = true
        elseif lowered == "false" then val = false
        end
    end
    return val
end

function SN.sandboxReady()
    return SandboxVars ~= nil and SandboxVars.SiegeNight ~= nil
end

local function clampNumber(value, minValue, maxValue)
    if type(value) ~= "number" then return value end
    if minValue ~= nil and value < minValue then value = minValue end
    if maxValue ~= nil and value > maxValue then value = maxValue end
    return value
end

function SN.getSandboxNumber(key, minValue, maxValue)
    local value = tonumber(SN.getSandbox(key))
    if value == nil then
        local defaultValue = SN.DEFAULTS[key]
        if type(defaultValue) == "number" then
            value = defaultValue
        end
    end
    return clampNumber(value, minValue, maxValue)
end

--- Day-length scale factor.  1.0 = default 1-hour days.  2.0 = 2-hour days.
--- Reads PZ's minutes-per-day setting so siege pacing automatically matches.
function SN.getDayLengthScale()
    local ok, mpd = pcall(function() return getGameTime():getMinutesPerDay() end)
    if ok and mpd and mpd > 0 then return mpd / 60 end
    return 1.0  -- fallback: assume 1-hour days
end

--- Night window real-time duration in seconds.
--- Default: 20:00→06:00 = 10 game-hours.  Scales with day length.
function SN.getNightDurationSeconds()
    local startH = SN.getSandbox("SiegeStartHour") or 20
    local endH = SN.getSandbox("SiegeEndHour") or 6
    local nightHours
    if endH > startH then nightHours = endH - startH
    else nightHours = (24 - startH) + endH end
    local scale = SN.getDayLengthScale()
    -- 1 game-hour = (minutesPerDay / 24) real minutes = scale * 2.5 real minutes
    return nightHours * scale * 150
end

function SN.getWaveCountForTotal(totalZombies)
    totalZombies = clampNumber(tonumber(totalZombies) or 1, 1, nil)
    -- Fewer, bigger waves = each one hits harder (ocean-style)
    -- Small siege (50): 5 waves. Medium (200): 6. Large (800+): 10.
    return math.max(5, math.min(10, math.floor(totalZombies / 100) + 4))
end

function SN.getSiegePlayerScale(playerCount)
    local count = clampNumber(math.floor(tonumber(playerCount) or 1), 1, nil)
    return 1.0 + math.max(0, count - 1) * 0.75
end

function SN.getMiniHordePlayerScale(playerCount)
    local count = clampNumber(math.floor(tonumber(playerCount) or 1), 1, nil)
    return 1.0 + math.max(0, count - 1) * 0.50
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
    local base = SN.getSandboxNumber("BaseZombieCount", 1, 5000) or 50
    local multiplier = SN.getSandboxNumber("ScalingMultiplier", 1.0, 10.0) or 1.5
    local maxZ = SN.getSandboxNumber("MaxZombies", 1, 5000) or 4000
    siegeCount = clampNumber(math.floor(tonumber(siegeCount) or 0), 0, nil)
    local playerScale = SN.getSiegePlayerScale(playerCount)
    local total = math.floor(base * math.pow(multiplier, siegeCount) * playerScale)
    return math.min(total, maxZ)
end

--- Calculate wave structure for a siege (two-layer system).
--- Returns TWO values:
---   1. waves table: array of { surgeSize, cooldownTicks } per wave
---   2. baselineBudget: number of zombies for the baseline tide layer
--- The surge layer gets the remaining zombies (65% by default).
--- Baseline runs independently — 1 zombie every 2 sec throughout the siege.
--- Surges are periodic instant crashes. Cooldowns between surges are short
--- (5-12 sec) because baseline fills the silence.
function SN.calculateWaveStructure(totalZombies)
    local waves = {}

    -- Guard: ensure non-negative total
    if not totalZombies or totalZombies < 1 then totalZombies = 1 end

    -- Budget split: baseline tide vs surge waves
    local baselineBudget = math.floor(totalZombies * SN.BASELINE_BUDGET_FRACTION)
    local surgeBudget = totalZombies - baselineBudget

    -- Wave count based on surge budget (not total — baseline is independent)
    local numWaves = SN.getWaveCountForTotal(surgeBudget)

    -- Distribute surge zombies with escalation.
    -- Shifted weight: wave 1 still gets a meaningful chunk, later waves grow.
    --   weight_i = numWaves + i  (e.g. for 5 waves: weights 6..10 => ~13%..~22%)
    local totalWeight = 0
    for i = 1, numWaves do
        totalWeight = totalWeight + (numWaves + i)
    end

    -- Dynamic variation seed — uses totalZombies as a cheap deterministic seed
    -- so the same siege replays consistently but different sieges feel different.
    local seed = totalZombies * 7 + numWaves * 13

    local zombiesAllocated = 0
    for i = 1, numWaves do
        local weight = (numWaves + i) / totalWeight
        local surgeSize

        if i == numWaves then
            -- Last wave gets all remaining surge budget
            surgeSize = math.max(1, surgeBudget - zombiesAllocated)
        else
            surgeSize = math.max(1, math.floor(surgeBudget * weight))
            -- Prevent over-allocation: don't exceed remaining budget
            if zombiesAllocated + surgeSize > surgeBudget then
                surgeSize = math.max(1, surgeBudget - zombiesAllocated)
            end
        end

        -- Dynamic variation: ±20% jitter per wave (ocean waves aren't uniform)
        seed = (seed * 31 + i * 17) % 1000
        local jitter = 0.8 + (seed % 400) / 1000  -- range 0.80 .. 1.19
        surgeSize = math.max(1, math.floor(surgeSize * jitter))
        -- Re-clamp to remaining budget
        if zombiesAllocated + surgeSize > surgeBudget then
            surgeSize = math.max(1, surgeBudget - zombiesAllocated)
        end

        -- Cooldowns scale with BOTH day length and zombie count.
        -- Small sieges (50 zombies) get short cooldowns; huge sieges (800) fill the night.
        -- Last wave has no cooldown (final push til dawn).
        -- WaveBreakSeconds sandbox option caps cooldown if set > 0.
        local cooldownTicks = 0
        if i < numWaves then
            local dayScale = SN.getDayLengthScale()
            local nightSec = SN.getNightDurationSeconds()
            -- Target scales with both night length AND zombie count (3 sec per zombie × dayScale)
            local targetByNight = nightSec * 0.40
            local targetByCount = totalZombies * dayScale * 3
            local targetSiegeSec = math.min(targetByNight, targetByCount)
            targetSiegeSec = math.max(180, math.min(2400, targetSiegeSec))  -- clamp 3-40 min
            -- Subtract estimated active spawn time
            local estSpawnSec = numWaves * 20
            local cooldownBudgetSec = math.max((numWaves - 1) * 10, targetSiegeSec - estSpawnSec)
            -- Distribute with decay: earlier waves get longer cooldowns
            local gapIndex = i
            local numGaps = numWaves - 1
            local weight = (numGaps - gapIndex + 1)
            local totalW = numGaps * (numGaps + 1) / 2
            local thisCooldownSec = math.max(10, math.floor(cooldownBudgetSec * weight / totalW))
            -- Cap individual cooldown at 3 min
            thisCooldownSec = math.min(180, thisCooldownSec)
            cooldownTicks = thisCooldownSec * 30
            local maxBreakSec = SN.getSandbox("WaveBreakSeconds")
            if maxBreakSec and maxBreakSec > 0 then
                cooldownTicks = math.min(cooldownTicks, maxBreakSec * 30)
            end
        end

        table.insert(waves, {
            surgeSize = surgeSize,
            cooldownTicks = cooldownTicks,
        })

        zombiesAllocated = zombiesAllocated + surgeSize
    end

    return waves, baselineBudget
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
    if data.currentPhase == nil then data.currentPhase = SN.PHASE_BURST end
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


