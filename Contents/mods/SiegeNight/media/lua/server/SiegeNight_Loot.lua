-- ==========================================
-- SiegeNight Loot System
-- ==========================================
-- Ensures siege zombie clothing persists to corpse and
-- provides tiered loot progression control.
--
-- Key API: zombie:addItemToSpawnAtDeath(item)
--   PZ native mechanism that guarantees items appear on corpse.
--
-- Flow:
--   1. addZombiesInOutfit spawns zombie with visual clothing
--   2. registerZombieDeath() copies worn items to death drops
--   3. If LootProgression is on, adds tier-appropriate loot
--
-- ASCII only in this file. No em dashes, smart quotes, etc.

local SN = require("SiegeNight_Shared")

-- ==========================================
-- INSTANCE ITEM HELPER
-- ==========================================
-- B42 uses instanceItem() global. B41 uses InventoryItemFactory.CreateItem.
local function createItem(itemType)
    local ok, item = pcall(function()
        return instanceItem(itemType)
    end)
    if ok and item then return item end
    -- B41 fallback
    local ok2, item2 = pcall(function()
        return InventoryItemFactory.CreateItem(itemType)
    end)
    if ok2 and item2 then return item2 end
    SN.debug("createItem failed for: " .. tostring(itemType))
    return nil
end

-- ==========================================
-- CLOTHING PERSISTENCE
-- ==========================================
--- Read zombie's worn items and register them as death drops.
--- This ensures clothing survives zombie->corpse transition.
--- Called server-side after addZombiesInOutfit spawns the zombie.
local function registerClothingForDeath(zombie)
    local ok, err = pcall(function()
        local wornItems = zombie:getWornItems()
        if not wornItems then return end
        local count = wornItems:size()
        if count == 0 then return end

        -- Log worn count so we know if addZombiesInOutfit populates server-side items
        SN.log("SN Loot: wornItems count = " .. count .. " (0 = visual-only outfit, no real items)")
        if count == 0 then return end

        local registered = 0
        for i = 0, count - 1 do
            local wornItem = wornItems:get(i)
            if wornItem then
                local item = wornItem:getItem()
                if item then
                    local itemType = item:getFullType()
                    if itemType then
                        local deathItem = createItem(itemType)
                        if deathItem then
                            pcall(function()
                                deathItem:setCondition(item:getCondition())
                            end)
                            zombie:addItemToSpawnAtDeath(deathItem)
                            registered = registered + 1
                        end
                    end
                end
            end
        end
        SN.log("SN Loot: registered " .. registered .. " clothing items for death drop")
    end)
    if not ok then
        SN.debug("registerClothingForDeath error: " .. tostring(err))
    end
end

-- ==========================================
-- LOOT TIER DEFINITIONS
-- ==========================================
-- Each tier has a list of possible loot items with weights.
-- Items are {type, weight, minCount, maxCount}
-- Weight is relative within the tier. Higher = more common.

local LOOT_CIVILIAN = {
    {type = "Base.Bandage",            weight = 20, min = 1, max = 2},
    {type = "Base.Pills",              weight = 10, min = 1, max = 1},
    {type = "Base.WaterBottle",        weight = 15, min = 1, max = 1},
    {type = "Base.Can",                weight = 10, min = 1, max = 1},
    {type = "Base.Lighter",            weight = 8,  min = 1, max = 1},
    {type = "Base.Cigarettes",         weight = 8,  min = 1, max = 1},
    {type = "Base.Wallet2",            weight = 5,  min = 1, max = 1},
    {type = "Base.HandTorch",          weight = 6,  min = 1, max = 1},
    {type = "Base.Battery",            weight = 6,  min = 1, max = 1},
    {type = "Base.Screwdriver",        weight = 4,  min = 1, max = 1},
}

local LOOT_PROFESSIONAL = {
    {type = "Base.Bandage",            weight = 15, min = 1, max = 3},
    {type = "Base.SutureNeedle",       weight = 5,  min = 1, max = 1},
    {type = "Base.AlcoholBandage",     weight = 8,  min = 1, max = 1},
    {type = "Base.WaterBottle",        weight = 10, min = 1, max = 1},
    {type = "Base.CannedFood",         weight = 8,  min = 1, max = 2},
    {type = "Base.Hammer",             weight = 6,  min = 1, max = 1},
    {type = "Base.Screwdriver",        weight = 6,  min = 1, max = 1},
    {type = "Base.Wrench",             weight = 4,  min = 1, max = 1},
    {type = "Base.NailsBox",           weight = 5,  min = 1, max = 1},
    {type = "Base.HandTorch",          weight = 6,  min = 1, max = 1},
    {type = "Base.Rope",              weight = 4,  min = 1, max = 1},
}

local LOOT_ARMED = {
    {type = "Base.Bandage",            weight = 10, min = 1, max = 3},
    {type = "Base.AlcoholBandage",     weight = 8,  min = 1, max = 2},
    {type = "Base.WaterBottle",        weight = 8,  min = 1, max = 1},
    {type = "Base.CannedFood",         weight = 6,  min = 1, max = 2},
    {type = "Base.KnifeButter",        weight = 5,  min = 1, max = 1},
    {type = "Base.HuntingKnife",       weight = 4,  min = 1, max = 1},
    {type = "Base.Axe",                weight = 3,  min = 1, max = 1},
    {type = "Base.Pistol",             weight = 2,  min = 1, max = 1},
    {type = "Base.Bullets9mm",         weight = 3,  min = 1, max = 2},
    {type = "Base.ShotgunShells",      weight = 2,  min = 1, max = 1},
    {type = "Base.Vest_BulletArmy",    weight = 2,  min = 1, max = 1},
}

local LOOT_MILITARY = {
    {type = "Base.AlcoholBandage",     weight = 10, min = 1, max = 3},
    {type = "Base.SutureNeedle",       weight = 6,  min = 1, max = 2},
    {type = "Base.WaterBottle",        weight = 6,  min = 1, max = 1},
    {type = "Base.MRE",               weight = 5,  min = 1, max = 2},
    {type = "Base.HuntingKnife",       weight = 5,  min = 1, max = 1},
    {type = "Base.Pistol",             weight = 4,  min = 1, max = 1},
    {type = "Base.Shotgun",            weight = 2,  min = 1, max = 1},
    {type = "Base.AssaultRifle",       weight = 1,  min = 1, max = 1},
    {type = "Base.Bullets9mm",         weight = 5,  min = 1, max = 3},
    {type = "Base.ShotgunShells",      weight = 3,  min = 2, max = 4},
    {type = "Base.223Bullets",         weight = 2,  min = 1, max = 2},
    {type = "Base.Vest_BulletArmy",    weight = 4,  min = 1, max = 1},
    {type = "Base.Hat_ArmyHelmet",     weight = 3,  min = 1, max = 1},
}

local TIER_TABLES = {
    civilian     = LOOT_CIVILIAN,
    professional = LOOT_PROFESSIONAL,
    armed        = LOOT_ARMED,
    military     = LOOT_MILITARY,
}

-- ==========================================
-- TIER SELECTION
-- ==========================================
--- Determine loot tier based on siege count and sandbox settings.
--- Returns "civilian", "professional", "armed", or "military".
local function getTier(siegeCount)
    local civUntil  = SN.getSandbox("CivilianUntilSiege") or 5
    local armUntil  = SN.getSandbox("ArmedUntilSiege") or 15
    local milUntil  = SN.getSandbox("MilitaryUntilSiege") or 30

    if siegeCount < civUntil then
        return "civilian"
    elseif siegeCount < armUntil then
        return "professional"
    elseif siegeCount < milUntil then
        return "armed"
    else
        return "military"
    end
end

-- ==========================================
-- WEIGHTED RANDOM SELECTION
-- ==========================================
local function weightedPick(lootTable)
    local totalWeight = 0
    for _, entry in ipairs(lootTable) do
        totalWeight = totalWeight + entry.weight
    end
    if totalWeight <= 0 then return nil end

    local roll = ZombRand(totalWeight)
    local cumulative = 0
    for _, entry in ipairs(lootTable) do
        cumulative = cumulative + entry.weight
        if roll < cumulative then
            return entry
        end
    end
    return lootTable[#lootTable]
end

-- ==========================================
-- LOOT REGISTRATION
-- ==========================================
--- Add tier-appropriate loot items directly to zombie inventory.
--- Items in zombie inventory transfer to corpse container on death.
--- Called server-side after spawn. Only active when LootProgression is on.
local function registerLootForDeath(zombie, siegeCount)
    local ok, err = pcall(function()
        local progression = SN.getSandbox("LootProgression")
        -- Default off.
        if not progression or progression == false or progression == 1 then
            SN.debug("LootProgression off, skipping loot (value=" .. tostring(progression) .. ")")
            return
        end

        local tier = getTier(siegeCount or 0)
        local lootTable = TIER_TABLES[tier]
        if not lootTable then
            SN.debug("No loot table for tier: " .. tostring(tier))
            return
        end

        -- Roll 1-3 items per zombie
        local numItems = 1 + ZombRand(3)
        local added = 0

        for _ = 1, numItems do
            local entry = weightedPick(lootTable)
            if entry then
                local count = entry.min
                if entry.max > entry.min then
                    count = entry.min + ZombRand(entry.max - entry.min + 1)
                end
                for _ = 1, count do
                    local item = createItem(entry.type)
                    if item then
                        -- Randomize condition for weapons (30-80%)
                        pcall(function()
                            if item:IsWeapon() then
                                local cond = math.floor(item:getConditionMax() * (0.3 + ZombRandFloat(0, 0.5)))
                                item:setCondition(math.max(1, cond))
                            end
                        end)
                        -- Register as death drop only (don't add to live inventory)
                        -- addItemToSpawnAtDeath is safer for freshly spawned zombies
                        zombie:addItemToSpawnAtDeath(item)
                        added = added + 1
                    else
                        SN.debug("Failed to create item: " .. tostring(entry.type))
                    end
                end
            end
        end

        SN.log("SN Loot: added " .. added .. " items (tier=" .. tier .. ", siege=" .. tostring(siegeCount) .. ")")
    end)
    if not ok then
        SN.log("registerLootForDeath ERROR: " .. tostring(err))
    end
end

-- ==========================================
-- LOOT STRIPPING (optional)
-- ==========================================
--- If StripLoot sandbox option is on, remove all vanilla loot
--- that PZ's distribution system added to the zombie.
--- Called BEFORE registering our controlled loot.
local function stripVanillaLoot(zombie)
    local ok, _ = pcall(function()
        local strip = SN.getSandbox("StripLoot")
        if not strip or strip == false or strip == 1 then
            return
        end
        local inv = zombie:getInventory()
        if inv then
            inv:removeAllItems()
        end
    end)
end

-- ==========================================
-- PUBLIC API
-- ==========================================

--- Main entry point: register all death drops for a siege zombie.
--- Call this server-side immediately after addZombiesInOutfit returns.
---
--- @param zombie IsoZombie  The spawned zombie
--- @param siegeCount number  Current total siege count (for tier calc)
function SN.registerZombieLoot(zombie, siegeCount)
    if not zombie then return end
    -- Step 1: Ensure clothing persists to corpse
    registerClothingForDeath(zombie)
    -- Step 2: Strip vanilla loot if configured
    stripVanillaLoot(zombie)
    -- Step 3: Add tier-appropriate loot (if LootProgression is on)
    registerLootForDeath(zombie, siegeCount)
end

SN.debug("SiegeNight_Loot loaded")
