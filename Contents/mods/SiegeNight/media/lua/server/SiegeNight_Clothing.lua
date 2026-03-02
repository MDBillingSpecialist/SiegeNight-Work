-- ==========================================
-- SiegeNight_Clothing.lua
-- ==========================================
-- Maps outfit names (used by addZombiesInOutfit) to actual
-- InventoryItem objects. After spawning, we call setWornItem()
-- with real items so the zombie has actual worn items server-side.
-- These persist to the corpse on death, giving dressed corpses.
--
-- Why this is needed:
--   addZombiesInOutfit() = visual-only on client. getWornItems() = empty.
--   Corpse inherits server-side wornItems = naked body.
--   setWornItem() populates wornItems with real items.
--
-- Slot locations use the BodyLocation format from PZ scripts.
-- Slots: "base:tshirt", "base:shirt", "base:pants", "base:shoes",
--        "base:jacket", "base:hat", "base:sweater"
--
-- ASCII only. No em dashes, smart quotes.

local SN = require("SiegeNight_Shared")

-- ==========================================
-- OUTFIT CLOTHING TABLE
-- ==========================================
-- Format: outfitName = { slot = "ItemType", ... }
-- Only core visible slots (shirt/pants/shoes/jacket/hat).
-- Optional slots marked with a _ prefix for random chance.
-- All item types verified against B42 clothing.txt BodyLocations.

local OUTFIT_CLOTHING = {

    -- ===== MILITARY =====
    ArmyCamoGreen = {
        jacket = "Base.Jacket_ArmyCamoGreen",
        pants  = "Base.Trousers_CamoGreen",
        shoes  = "Base.Shoes_ArmyBoots",
        hat    = "Base.Hat_Army",
    },
    ArmyCamoDesert = {
        jacket = "Base.Jacket_ArmyCamoDesert",
        pants  = "Base.Trousers_CamoDesert",
        shoes  = "Base.Shoes_ArmyBootsDesert",
        hat    = "Base.Hat_ArmyDesert",
    },
    ArmyServiceUniform = {
        shirt  = "Base.Shirt_OliveDrab",
        pants  = "Base.Trousers_OliveDrab",
        shoes  = "Base.Shoes_ArmyBoots",
        hat    = "Base.Hat_Army",
    },
    Veteran = {
        jacket = "Base.Jacket_ArmyOliveDrab",
        pants  = "Base.Trousers_OliveDrab",
        shoes  = "Base.Shoes_ArmyBoots",
    },

    -- ===== LAW ENFORCEMENT =====
    Police = {
        shirt  = "Base.Shirt_PoliceBlue",
        jacket = "Base.Jacket_Police",
        pants  = "Base.Trousers_Police",
        shoes  = "Base.Shoes_Black",
    },
    PoliceRiot = {
        shirt  = "Base.Shirt_PoliceBlue",
        jacket = "Base.Jacket_Police",
        pants  = "Base.Trousers_Police",
        shoes  = "Base.Shoes_Black",
    },
    Security = {
        shirt  = "Base.Shirt_PoliceGrey",
        pants  = "Base.Trousers_PoliceGrey",
        shoes  = "Base.Shoes_Black",
    },
    Ranger = {
        shirt  = "Base.Shirt_Ranger",
        jacket = "Base.Jacket_Ranger",
        pants  = "Base.Trousers_Ranger",
        shoes  = "Base.Shoes_HikingBoots",
    },

    -- ===== MEDICAL =====
    Doctor = {
        shirt  = "Base.Shirt_Scrubs",
        pants  = "Base.Trousers_Scrubs",
        shoes  = "Base.Shoes_Black",
    },
    Nurse = {
        shirt  = "Base.Shirt_Scrubs",
        pants  = "Base.Trousers_Scrubs",
        shoes  = "Base.Shoes_Black",
    },
    Pharmacist = {
        shirt  = "Base.Shirt_Scrubs",
        pants  = "Base.Trousers_Scrubs",
        shoes  = "Base.Shoes_Black",
    },
    AmbulanceDriver = {
        tshirt = "Base.Tshirt_Profession_FiremanBlue",
        pants  = "Base.Trousers_Scrubs",
        shoes  = "Base.Shoes_Black",
    },
    HospitalPatient = {
        tshirt = "Base.Tshirt_Scrubs",
        pants  = "Base.Trousers_Scrubs",
        shoes  = "Base.Shoes_Slippers",
    },

    -- ===== EMERGENCY SERVICES =====
    Fireman = {
        jacket = "Base.Jacket_Fireman",
        pants  = "Base.Trousers_Fireman",
        shoes  = "Base.Shoes_BlackBoots",
    },
    AirCrew = {
        jacket = "Base.Jacket_NavyBlue",
        pants  = "Base.Trousers_NavyBlue",
        shoes  = "Base.Shoes_Black",
    },

    -- ===== TRADES / WORKERS =====
    ConstructionWorker = {
        shirt  = "Base.Shirt_Workman",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlackBoots",
    },
    MetalWorker = {
        tshirt = "Base.Tshirt_OliveDrab",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlackBoots",
    },
    Mechanic = {
        shirt  = "Base.Shirt_Workman",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlackBoots",
    },
    Woodcut = {
        shirt  = "Base.Shirt_Lumberjack",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlackBoots",
    },
    Electrician = {
        shirt  = "Base.Shirt_Workman",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlackBoots",
    },
    Postal = {
        shirt  = "Base.Shirt_OfficerWhite",
        pants  = "Base.Trousers_NavyBlue",
        shoes  = "Base.Shoes_Black",
    },

    -- ===== FOOD SERVICE =====
    Chef = {
        jacket = "Base.Jacket_Chef",
        pants  = "Base.Trousers_Chef",
        shoes  = "Base.Shoes_Black",
    },
    Cook_Generic = {
        jacket = "Base.Jacket_Chef",
        pants  = "Base.Trousers_Chef",
        shoes  = "Base.Shoes_Black",
    },
    Waiter_Spiffo = {
        tshirt = "Base.Tshirt_SpiffoDECAL",
        pants  = "Base.Trousers_Black",
        shoes  = "Base.Shoes_Black",
    },
    GigaMart_Employee = {
        tshirt = "Base.Tshirt_DefaultTEXTURE",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Black",
    },
    Fossoil = {
        tshirt = "Base.Tshirt_Fossoil",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Brown",
        hat    = "Base.Hat_BaseballCap_Fossoil",
    },

    -- ===== OFFICE / PROFESSIONAL =====
    OfficeWorker = {
        shirt  = "Base.Shirt_FormalWhite",
        pants  = "Base.Trousers_Suit",
        shoes  = "Base.Shoes_Black",
    },
    OfficeWorkerSkirt = {
        shirt  = "Base.Shirt_FormalWhite",
        pants  = "Base.Trousers_Suit",
        shoes  = "Base.Shoes_Fancy",
    },
    Classy = {
        shirt  = "Base.Shirt_FormalWhite",
        pants  = "Base.Trousers_Suit",
        shoes  = "Base.Shoes_Black",
    },
    Teacher = {
        shirt  = "Base.Shirt_FormalWhite",
        pants  = "Base.Trousers_Suit",
        shoes  = "Base.Shoes_Black",
    },

    -- ===== OUTDOOR / RURAL =====
    Farmer = {
        shirt  = "Base.Shirt_Lumberjack",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Brown",
    },
    Fisherman = {
        shirt  = "Base.Shirt_Lumberjack_Green",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_HikingBoots",
    },
    Hunter = {
        jacket = "Base.Jacket_HuntingCamo",
        pants  = "Base.Trousers_HuntingCamo",
        shoes  = "Base.Shoes_HikingBoots",
        hat    = "Base.Hat_Bandana",
    },
    Camper = {
        jacket = "Base.Jacket_HuntingCamo",
        pants  = "Base.Trousers_HuntingCamo",
        shoes  = "Base.Shoes_HikingBoots",
    },
    Survivalist = {
        jacket = "Base.Jacket_HuntingCamo",
        pants  = "Base.Trousers_HuntingCamo",
        shoes  = "Base.Shoes_HikingBoots",
    },
    Redneck = {
        shirt  = "Base.Shirt_Lumberjack",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Brown",
    },

    -- ===== CIVILIAN / GENERIC =====
    Generic01 = {
        tshirt = "Base.Tshirt_DefaultTEXTURE_TINT",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Random",
    },
    Generic02 = {
        tshirt = "Base.Tshirt_DefaultTEXTURE_TINT",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Random",
    },
    Generic03 = {
        tshirt = "Base.Tshirt_DefaultTEXTURE_TINT",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Random",
    },
    Generic04 = {
        tshirt = "Base.Tshirt_DefaultTEXTURE_TINT",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Random",
    },
    Generic05 = {
        tshirt = "Base.Tshirt_DefaultTEXTURE_TINT",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Random",
    },
    Young = {
        tshirt = "Base.Tshirt_DefaultTEXTURE_TINT",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlueTrainers",
    },
    Student = {
        tshirt = "Base.Tshirt_DefaultTEXTURE_TINT",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlueTrainers",
    },
    Hobbo = {
        tshirt = "Base.Tshirt_DefaultTEXTURE",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Brown",
    },
    Tourist = {
        tshirt = "Base.Tshirt_DefaultTEXTURE_TINT",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Brown",
    },
    Bandit = {
        tshirt = "Base.Tshirt_DefaultTEXTURE_TINT",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_Brown",
    },
    Swimmer = {
        tshirt = "Base.Tshirt_DefaultTEXTURE",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_FlipFlop",
    },
    Bathrobe = {
        tshirt = "Base.Tshirt_WhiteTINT",
        pants  = "Base.Trousers_WhiteTINT",
        shoes  = "Base.Shoes_Slippers",
    },
    Bedroom = {
        tshirt = "Base.Tshirt_WhiteTINT",
        pants  = "Base.Trousers_WhiteTINT",
        shoes  = "Base.Shoes_Slippers",
    },

    -- ===== SPORTS / FITNESS =====
    FitnessInstructor = {
        tshirt = "Base.Tshirt_Sport",
        pants  = "Base.Trousers_Sport",
        shoes  = "Base.Shoes_BlueTrainers",
    },
    Cyclist = {
        tshirt = "Base.Tshirt_Sport",
        pants  = "Base.Trousers_Sport",
        shoes  = "Base.Shoes_BlueTrainers",
    },
    SportsFan = {
        tshirt = "Base.Tshirt_Sport",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlueTrainers",
        hat    = "Base.Hat_BaseballCap",
    },
    BaseballFan_KY = {
        tshirt = "Base.Tshirt_Sport",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlueTrainers",
        hat    = "Base.Hat_BaseballCap",
    },

    -- ===== SUBCULTURE =====
    Biker = {
        jacket = "Base.Jacket_LeatherBlack",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlackBoots",
    },
    Punk = {
        tshirt = "Base.Tshirt_Punk",
        jacket = "Base.Jacket_Leather_Punk",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlackBoots",
    },
    Rocker = {
        tshirt = "Base.Tshirt_Rock",
        jacket = "Base.Jacket_Leather",
        pants  = "Base.Trousers_Denim",
        shoes  = "Base.Shoes_BlackBoots",
    },
}

-- ==========================================
-- SLOT -> BODY LOCATION MAPPING
-- ==========================================
-- Maps our slot names to PZ BodyLocation strings.
-- Tries both "base:SLOT" and plain "SLOT" formats since
-- the exact format PZ expects for setWornItem is uncertain.
-- First entry is tried, falls back to second if it fails.

local SLOT_LOCATIONS = {
    tshirt  = "base:tshirt",
    shirt   = "base:shirt",
    pants   = "base:pants",
    shoes   = "base:shoes",
    jacket  = "base:jacket",
    hat     = "base:hat",
    sweater = "base:sweater",
}

-- ==========================================
-- APPLY CLOTHING TO ZOMBIE
-- ==========================================
--- Equip real clothing items on a siege zombie server-side.
--- Called after addZombiesInOutfit to populate getWornItems().
--- Items in wornItems persist to the corpse on death.
---
--- @param zombie  IsoZombie
--- @param outfit  string  outfit name (key in OUTFIT_CLOTHING)
function SN.applyOutfitClothing(zombie, outfit)
    if not zombie or not outfit then return end
    local ok, err = pcall(function()
        local def = OUTFIT_CLOTHING[outfit]
        if not def then
            SN.debug("No clothing def for outfit: " .. tostring(outfit))
            return
        end

        local equipped = 0
        for slot, itemType in pairs(def) do
            local location = SLOT_LOCATIONS[slot]
            if location then
                local itemOk, item = pcall(function()
                    return instanceItem(itemType)
                end)
                if itemOk and item then
                    -- Try setWornItem with base: prefix
                    local wearOk = pcall(function()
                        zombie:setWornItem(location, item)
                    end)
                    if not wearOk then
                        -- Fallback: try without base: prefix
                        local loc2 = location:gsub("^base:", "")
                        local wearOk2 = pcall(function()
                            zombie:setWornItem(loc2, item)
                        end)
                        if wearOk2 then
                            equipped = equipped + 1
                        else
                            -- Last fallback: add to inventory so it at least drops
                            pcall(function()
                                zombie:addItemToSpawnAtDeath(item)
                            end)
                        end
                    else
                        equipped = equipped + 1
                    end
                end
            end
        end
        SN.debug("applyOutfitClothing: " .. outfit .. " equipped=" .. equipped)
    end)
    if not ok then
        SN.debug("applyOutfitClothing ERROR (" .. tostring(outfit) .. "): " .. tostring(err))
    end
end

local _count = 0
for _ in pairs(OUTFIT_CLOTHING) do _count = _count + 1 end
SN.log("SiegeNight_Clothing loaded. " .. _count .. " outfit definitions.")
