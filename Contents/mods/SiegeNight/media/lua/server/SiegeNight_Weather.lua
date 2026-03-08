--[[
    SiegeNight_Weather.lua
    Dynamic weather effects during siege nights.
    Server-side: uses ClimateManager's Modded override layer.
    Weather changes propagate to clients automatically via climate sync.

    Timeline:
      WARNING (daytime)  -> light fog ramp 0.0 -> 0.3, slight view reduction
      ACTIVE  (dusk)     -> fog jumps to 0.5, wind starts 0.3
      ACTIVE  (waves)    -> fog/wind intensify per wave progress
      MIDNIGHT (specials)-> heavy fog 0.85, chance of heavy rain
      DAWN               -> everything fades back to clear
      IDLE               -> all modded overrides disabled
]]

local okSN, SN = pcall(require, "SiegeNight_Shared")
if not okSN or type(SN) ~= "table" then return end

-- Safety: server-side only
if isClient and isClient() then return end

local SN_Weather = {}
local weatherActive = false
local midnightApplied = false

-- Cached ClimateFloat references
local fogFloat = nil
local rainFloat = nil
local windFloat = nil
local viewFloat = nil

-- Disable counter for delayed full-disable after fade
local disableCountdown = -1

-- ==========================================
-- CLIMATE FLOAT ACCESS
-- ==========================================

local function getFloats()
    if fogFloat then return true end
    local cm = getClimateManager()
    if not cm then
        SN.log("Weather: ClimateManager not available yet")
        return false
    end
    local ok, err = pcall(function()
        fogFloat  = cm:getClimateFloat(ClimateManager.FLOAT_FOG_INTENSITY)
        rainFloat = cm:getClimateFloat(ClimateManager.FLOAT_PRECIPITATION_INTENSITY)
        windFloat = cm:getClimateFloat(ClimateManager.FLOAT_WIND_INTENSITY)
        viewFloat = cm:getClimateFloat(ClimateManager.FLOAT_VIEW_DISTANCE)
    end)
    if not ok then
        SN.log("Weather: Failed to get ClimateFloats: " .. tostring(err))
        fogFloat = nil
        return false
    end
    return true
end

-- ==========================================
-- INTENSITY HELPER
-- ==========================================
-- Applies the SiegeWeatherIntensity sandbox multiplier to a raw value.
-- Clamps result to 0.0-1.0 range.
local function scaled(rawValue)
    local mult = SN.getSandbox("SiegeWeatherIntensity") or 1.0
    return math.max(0.0, math.min(1.0, rawValue * mult))
end

-- ==========================================
-- WEATHER PHASES
-- ==========================================

--- Called when siege state transitions to WARNING.
--- Starts a slow fog build-up during the daytime hours before the siege.
function SN_Weather.startWarningWeather()
    if not SN.getSandbox("SiegeWeatherEnabled") then return end
    if not getFloats() then return end
    weatherActive = true
    midnightApplied = false
    disableCountdown = -1

    fogFloat:setEnableModded(true)
    fogFloat:setModdedValue(scaled(0.3))
    fogFloat:setModdedInterpolate(0.005)  -- very slow build over hours

    viewFloat:setEnableModded(true)
    viewFloat:setModdedValue(math.max(0.0, 1.0 - scaled(0.15)))  -- 0.85 at default intensity
    viewFloat:setModdedInterpolate(0.005)

    SN.log("Weather: Warning phase started (slow fog ramp)")
end

--- Called when siege transitions from WARNING/IDLE to ACTIVE.
--- Fog jumps up, wind starts, view distance drops.
function SN_Weather.startSiegeWeather()
    if not SN.getSandbox("SiegeWeatherEnabled") then return end
    if not getFloats() then return end
    weatherActive = true
    midnightApplied = false
    disableCountdown = -1

    fogFloat:setEnableModded(true)
    fogFloat:setModdedValue(scaled(0.5))
    fogFloat:setModdedInterpolate(0.02)

    windFloat:setEnableModded(true)
    windFloat:setModdedValue(scaled(0.3))
    windFloat:setModdedInterpolate(0.02)

    viewFloat:setEnableModded(true)
    viewFloat:setModdedValue(math.max(0.0, 1.0 - scaled(0.3)))  -- 0.7 at default
    viewFloat:setModdedInterpolate(0.02)

    SN.log("Weather: Siege weather activated (fog 0.5, wind 0.3)")
end

--- Called at each wave start to progressively intensify weather.
--- @param waveIndex number Current wave number (1-based)
--- @param totalWaves number Total waves in this siege
function SN_Weather.intensifyForWave(waveIndex, totalWaves)
    if not weatherActive then return end
    if not SN.getSandbox("SiegeWeatherEnabled") then return end
    if not fogFloat then return end

    local progress = (waveIndex - 1) / math.max(1, totalWaves - 1)  -- 0.0 to 1.0

    fogFloat:setModdedValue(scaled(0.5 + progress * 0.3))          -- 0.5 -> 0.8
    fogFloat:setModdedInterpolate(0.015)

    windFloat:setModdedValue(scaled(0.3 + progress * 0.3))         -- 0.3 -> 0.6
    windFloat:setModdedInterpolate(0.015)

    viewFloat:setModdedValue(math.max(0.0, 1.0 - scaled(0.3 + progress * 0.3)))  -- 0.7 -> 0.4
    viewFloat:setModdedInterpolate(0.015)

    -- Random rain chance on later waves (30% chance after wave 2)
    if progress > 0.3 and ZombRand(100) < 30 then
        rainFloat:setEnableModded(true)
        rainFloat:setModdedValue(scaled(0.2 + progress * 0.3))
        rainFloat:setModdedInterpolate(0.03)
        SN.log("Weather: Rain triggered on wave " .. waveIndex)
    end
end

--- Called when specials start spawning (midnight relative hour).
--- Maximum intensity: heavy fog, chance of heavy rain, strong wind.
function SN_Weather.midnightIntensify()
    if not weatherActive then return end
    if midnightApplied then return end
    if not SN.getSandbox("SiegeWeatherEnabled") then return end
    if not fogFloat then return end
    midnightApplied = true

    fogFloat:setModdedValue(scaled(0.85))
    fogFloat:setModdedInterpolate(0.01)

    windFloat:setModdedValue(scaled(0.6))
    windFloat:setModdedInterpolate(0.01)

    viewFloat:setModdedValue(math.max(0.0, 1.0 - scaled(0.65)))  -- 0.35 at default
    viewFloat:setModdedInterpolate(0.01)

    -- 50% chance of heavy rain at midnight
    if ZombRand(100) < 50 then
        rainFloat:setEnableModded(true)
        rainFloat:setModdedValue(scaled(0.6))
        rainFloat:setModdedInterpolate(0.02)
        SN.log("Weather: Heavy rain at midnight")
    end

    SN.log("Weather: Midnight intensity (fog 0.85, wind 0.6)")
end

--- Called when siege enters DAWN state.
--- Gradually fades all weather effects back to zero.
function SN_Weather.clearWeather()
    if not weatherActive then return end
    if not fogFloat then return end

    fogFloat:setModdedValue(0.0)
    fogFloat:setModdedInterpolate(0.01)

    if rainFloat then
        rainFloat:setModdedValue(0.0)
        rainFloat:setModdedInterpolate(0.02)
    end

    if windFloat then
        windFloat:setModdedValue(0.0)
        windFloat:setModdedInterpolate(0.02)
    end

    viewFloat:setModdedValue(1.0)
    viewFloat:setModdedInterpolate(0.01)

    -- Schedule full disable after fade (~60 seconds)
    disableCountdown = 1800  -- 60 seconds at 30fps

    SN.log("Weather: Clearing (fade to normal)")
end

--- Immediately disables all modded overrides. Called on IDLE transition.
function SN_Weather.disableAllOverrides()
    if not getFloats() then return end

    if fogFloat then fogFloat:setEnableModded(false) end
    if rainFloat then rainFloat:setEnableModded(false) end
    if windFloat then windFloat:setEnableModded(false) end
    if viewFloat then viewFloat:setEnableModded(false) end

    weatherActive = false
    midnightApplied = false
    disableCountdown = -1

    SN.log("Weather: All overrides disabled")
end

--- Tick handler for delayed disable after fade.
--- Should be called from the main server tick.
function SN_Weather.tick()
    if disableCountdown > 0 then
        disableCountdown = disableCountdown - 1
        if disableCountdown <= 0 then
            SN_Weather.disableAllOverrides()
        end
    end
end

--- Returns whether weather effects are currently active.
function SN_Weather.isActive()
    return weatherActive
end

return SN_Weather
