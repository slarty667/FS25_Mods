--
-- AutoWaterForAllAnimals
--
-- Refills the drinking water of EVERY owned animal husbandry once per day at 10:00 --
-- cows, sheep, pigs, horses, chickens and, crucially, custom map husbandries too
-- (e.g. The Mechet's basicCowPasture / Stabulation stalls).
--
-- This generalises the "Automatic Drinking Trough" idea, which only matched the four
-- vanilla small barns by their exact configFileNameClean. Instead of a hardcoded name
-- list we simply ask each husbandry: do you have a water storage with free space? If so,
-- top it up to full and bill the owning farm -- skipping empty pens and farms that can't
-- pay. Map-agnostic by design.
--
-- Author: Markus Uhl
--

AutoWaterForAllAnimals = {}
AutoWaterForAllAnimals.isDebugMode = false
AutoWaterForAllAnimals.refillHour = 10  -- in-game hour at which the daily top-up happens

local function debugMsg(message)
    if AutoWaterForAllAnimals.isDebugMode then
        print("[AutoWaterForAllAnimals] --> " .. tostring(message))
    end
end

-- Top up water on a single husbandry placeable. Bails out quietly when the husbandry has
-- no water storage, holds no animals, is already full, or the farm cannot afford the bill.
local function refillHusbandry(placeable)
    local spec = placeable.spec_husbandry
    if spec == nil or spec.storage == nil then
        return
    end
    local storage = spec.storage

    -- Skip empty pens so we never pay for water no animal will drink.
    if placeable.getNumOfAnimals ~= nil and placeable:getNumOfAnimals() <= 0 then
        return
    end

    -- Free water capacity == amount missing. A husbandry that does not use water reports
    -- 0 here, which makes us skip it -- no hardcoded animal-type list needed.
    local missing = storage:getFreeCapacity(FillType.WATER, true)
    if missing == nil or missing <= 0 then
        return
    end

    -- Price the refill and let the owning farm pay, but only if it stays solvent.
    local waterType = g_fillTypeManager:getFillTypeByIndex(FillType.WATER)
    local price = (waterType ~= nil and waterType.pricePerLiter or 0) * missing
    local farm = g_farmManager:getFarmById(placeable.ownerFarmId)
    if farm == nil or (farm:getBalance() - price) <= 0 then
        return
    end

    local current = storage:getFillLevel(FillType.WATER)
    storage:setFillLevel(current + missing, FillType.WATER)
    g_currentMission:addMoney(-price, placeable.ownerFarmId, MoneyType.PURCHASE_WATER, false)
    debugMsg(string.format("filled %.0f l (cost %.0f) on %s", missing, price, tostring(placeable.configFileNameClean)))
end

-- Sweep every husbandry registered in the mission. Each call is wrapped so one broken
-- husbandry (e.g. an exotic custom mod) can never abort the rest of the sweep.
local function refillAllHusbandries()
    if g_currentMission == nil or g_currentMission.husbandrySystem == nil then
        return
    end
    for _, placeable in ipairs(g_currentMission.husbandrySystem.placeables) do
        pcall(refillHusbandry, placeable)
    end
end

function AutoWaterForAllAnimals:hourChanged()
    if g_currentMission.environment.currentHour == AutoWaterForAllAnimals.refillHour then
        refillAllHusbandries()
    end
end

function AutoWaterForAllAnimals:loadMap(mapFilename)
    -- Server (incl. single player) owns the economy; clients must not double-bill.
    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.hourChanged, self)
    end
end

function AutoWaterForAllAnimals:deleteMap()
    if g_currentMission:getIsServer() then
        g_messageCenter:unsubscribe(MessageType.HOUR_CHANGED, self)
    end
end

addModEventListener(AutoWaterForAllAnimals)
