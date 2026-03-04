-- ============================================================
-- SANDBOX VARS - "Fortress Defense" Preset
-- Unprocessable Entities Survival Pack
-- Generated: Feb 14, 2026
--
-- INSTALL: Copy this file to your server's save folder:
--   Zomboid/Server/servertest/SandboxVars.lua
-- (Replace "servertest" with your server name if different)
-- ============================================================

SandboxVars = {
    -- =====================
    -- ZOMBIE POPULATION
    -- =====================
    Zombies = 4,                       -- Population Multiplier: 1.5 (Insane=1, VHigh=2, High=3, Normal=4, Low=5)
    Distribution = 1,                  -- 1=Urban Focused
    DayLength = 3,                     -- 2-hour days (1=15min, 2=30min, 3=1hr, 4=2hr... actually: 1=15, 2=30, 3=1hr, 4=2hr, 5=3hr)
    StartYear = 1,                     -- Year 1
    StartMonth = 7,                    -- July
    StartDay = 1,                      -- Day 1
    StartTime = 2,                     -- 9 AM (1=7am, 2=9am, 3=12pm, 4=2pm, 5=5pm, 6=9pm, 7=12am, 8=2am, 9=5am)

    -- =====================
    -- ZOMBIE BEHAVIOR
    -- =====================
    Speed = 2,                         -- Fast Shamblers (1=Sprinters, 2=Fast Shamblers, 3=Shamblers)
    Strength = 2,                      -- Normal (1=Superhuman, 2=Normal, 3=Weak)
    Toughness = 2,                     -- Normal
    Transmission = 1,                  -- Blood + Saliva (1=Blood+Saliva, 2=Saliva, 3=Everyone Infected)
    Mortality = 5,                     -- 2-3 Days (gives time to find PhunCure)
    Reanimate = 3,                     -- 0-12 Hours
    Cognition = 2,                     -- Navigate + Use Doors (1=Navigate+Doors+Windows, 2=Navigate+Doors, 3=Basic Nav)
    CrawlUnderVehicle = 2,             -- Sometimes
    Memory = 2,                        -- Normal (1=Long, 2=Normal, 3=Short, 4=None)
    Sight = 2,                         -- Normal
    Hearing = 2,                       -- Normal

    -- =====================
    -- ZOMBIE POPULATION RAMPING
    -- =====================
    ZombiePopulationMultiplier = 1.5,  -- 50% more zombies
    ZombiePopulationStartMultiplier = 0.5, -- Start at half, ramp up
    ZombiePopulationPeakMultiplier = 3.0,  -- TRIPLE at peak - horde pressure
    ZombiePopulationPeakDay = 28,      -- Full density by day 28
    ZombieRespawnHours = 72.0,         -- Cleared areas refill in 3 days
    ZombieRespawnUnseenHours = 16.0,   -- Only respawn when away
    ZombieRespawnMultiplier = 0.1,     -- 10% respawn rate

    -- Rally groups (roaming hordes)
    RallyGroupSize = 50,               -- Large roaming groups
    RallyGroupSeparation = 15,         -- Groups merge when close
    RallyGroupRadius = 20,             -- Detection radius
    RallyTravelDistance = 30,          -- How far groups roam

    -- =====================
    -- LOOT & ECONOMY
    -- =====================
    Loot = 4,                          -- Rare (1=Insanely Rare, 2=Extremely Rare, 3=Rare, 4=Normal... we want 3=Rare)
    -- NOTE: Set this to 3 for Rare loot. Check in-game if numbering differs in B42.
    LootRespawn = 1,                   -- None (1=None, 2=Every Day, etc)
    LockedHouses = 4,                  -- Very Rare unlocked
    FoodLoot = 4,                      -- Rare
    WeaponLoot = 4,                    -- Rare
    OtherLoot = 4,                     -- Rare
    GeneratorSpawning = 2,             -- Sometimes
    SurvivorHouseChance = 2,           -- Rare
    AnnotatedMapChance = 2,            -- Sometimes

    -- =====================
    -- WORLD EVENTS
    -- =====================
    WaterShut = 5,                     -- 2-6 months (1=Instant, 2=0-30 days, ..., 5=2-6 months, 6=6-12 months, 7=Never)
    ElecShut = 5,                      -- 2-6 months
    WaterShutModifier = 14,            -- Min days
    ElecShutModifier = 14,             -- Min days
    Temperature = 3,                   -- Normal
    Rain = 3,                          -- Normal
    ErosionSpeed = 3,                  -- Normal (vegetation growth)
    ErosionDays = 0,                   -- Start from day 0
    Farming = 3,                       -- Normal farming speed
    NatureAbundance = 3,               -- Normal foraging

    -- =====================
    -- XP & SKILLS
    -- =====================
    XPMultiplier = 2.5,                -- 2.5x XP for MP progression
    XPMultiplierAffectsQuests = true,
    StatsDecrease = 3,                 -- Normal stat decrease
    Nutrition = true,                  -- Nutrition matters
    ConstructionBonusPoints = 0,       -- No free construction points
    CookingBonusPoints = 0,
    CraftingBonusPoints = 0,
    FarmingBonusPoints = 0,
    FirstAidBonusPoints = 0,
    FishingBonusPoints = 0,
    MetalWeldingBonusPoints = 0,
    MechanicsBonusPoints = 0,
    SurvivalBonusPoints = 0,

    -- =====================
    -- VEHICLES
    -- =====================
    CarSpawnRate = 2,                  -- Low (with KI5's 44 cars, Low still = plenty)
    ChanceHasGas = 2,                 -- Low gas in found cars
    InitialGas = 2,                   -- Low starting gas
    CarGasConsumption = 1.0,          -- Normal consumption
    LockedCar = 3,                    -- Very Rare unlocked
    DamageToPlayerFromHitByACar = 3,  -- Normal
    TrafficJam = true,                -- Road blockages
    CarAlarmChance = 3,               -- Sometimes
    EnableVehicles = true,

    -- =====================
    -- PLAYER SETTINGS
    -- =====================
    PlayerBuildingDamage = true,       -- Player can damage buildings (for base expansion)
    StarterKit = false,                -- No free gear
    FreeTraits = false,
    EnablePoisoning = true,
    MultiHitZombies = true,            -- Swing through crowds
    RearVulnerability = 3,             -- Normal
    AttackBlockMovements = true,
    AllClothesUnlocked = false,
    TimeSinceApo = 1,                  -- 0 months (fresh apocalypse)
    PlantResilience = 3,              -- Normal
    PlantAbundance = 3,               -- Normal
    EndRegen = 3,                      -- Normal endurance regen
    Helicopter = 2,                    -- Sometimes (draws hordes to you!)
    MetaEvent = 2,                     -- Sometimes
    SleepingEvent = 2,                 -- Sometimes
    GeneratorFuelConsumption = 1.0,
    SurvivorsDaysSurvived = 1,
    AllowExteriorGenerator = true,
    MaxFogIntensity = 3,              -- Normal
    MaxRainFXIntensity = 3,           -- Normal

    -- =====================
    -- MAP
    -- =====================
    MapAllKnown = false,               -- Must explore to reveal map
    ZonesStoryChance = 2,              -- Sometimes (random story locations)

    -- =====================
    -- FIRE
    -- =====================
    FireSpread = true,
    DaysForRottenFoodRemoval = -1,     -- Never auto-remove

    -- =====================
    -- HORDE NIGHT MOD SETTINGS
    -- These appear under Advanced Zombie Options > Horde Night
    -- If they don't show in sandbox UI, edit these values directly
    -- =====================
    -- NOTE: Horde Night mod settings may use its own namespace.
    -- If these don't take effect, look for HordeNight01 settings
    -- in the sandbox menu and set:
    --   Starting Zombie Count: 150-200
    --   Zombie Increment: 50
    --   Zombie Limit: 500
    --   Frequency: Every 7 days
    --   Start Hour: 21 (9 PM)
    --   First Day: 7
    --
    -- The mod creates settings under "Horde Night" in sandbox.
    -- Each player gets their OWN horde.
    -- 4 players x 200 zombies = 800 total per event.
}
