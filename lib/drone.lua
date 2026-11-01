-- SEUI lib/drone.lua
-- Space Mining Module drone supply backend

local log = require("lib.log")

local M = {}

local DRONE_ITEM = "gtnhintergalactic:item.MiningDrone"

local function validateSides(config)
  local droneSide = tonumber(config.droneSide)
  local inputSide = tonumber(config.inputSide)
  if not droneSide or not inputSide or droneSide < 0 or droneSide > 5 or inputSide < 0 or inputSide > 5 then
    return nil, nil, "droneSide/inputSide must be sides direction values 0..5"
  end
  if droneSide == inputSide then
    return nil, nil, "droneSide and inputSide must not be the same"
  end
  return droneSide, inputSide
end

local function readStacks(transposer, side)
  local ok, iter = pcall(transposer.getAllStacks, side)
  if not ok or not iter then return nil, "Unable to read drone inventory" end
  local ok2, stacks = pcall(iter.getAll)
  if not ok2 or type(stacks) ~= "table" then return nil, "Drone inventory iteration failed" end
  return stacks
end

local function findFleetDroneSlot(stacks, tier, required, allowRandom)
  -- Same as the original Wiki program: read the shared ender chest only once, from the first transposer, and remember the slot and count;
  -- then every transposer takes 1 item from that same slot. Do not re-read the other transposers'
  -- getAllStacks after each transfer; the remote view of a same-channel ender chest can lag by one tick, which caused the earlier false "inventory changed" reports.
  for slot, stack in pairs(stacks) do
    if stack and stack.name == DRONE_ITEM
        and tonumber(stack.damage or -1) == tier - 1
        and (tonumber(stack.size) or 0) >= required then
      return tonumber(slot) + 1, tonumber(stack.size), tier, false
    end
  end
  if allowRandom then
    for slot, stack in pairs(stacks) do
      if stack and stack.name == DRONE_ITEM and (tonumber(stack.size) or 0) >= required then
        return tonumber(slot) + 1, tonumber(stack.size), (tonumber(stack.damage) or 0) + 1, true
      end
    end
  end
  return nil, 0, nil, false
end

-- Wiki sync mode: all miners chase the same target; all transposers face the same direction and connect to the same-channel ender chest.
-- This function returns and redistributes drones for the whole miner group in one pass; the caller must first confirm that every miner has fully stopped.
local function prepareTransposerFleet(assignment, config, hw)
  local transposers = hw.transposers or {}
  if #transposers == 0 then return false, "No transposer found" end
  if hw.miners and #hw.miners > 0 and #transposers ~= #hw.miners then
    return false, string.format("Miner/transposer count mismatch: miners=%d transposers=%d", #hw.miners, #transposers)
  end

  local droneSide, inputSide, sideErr = validateSides(config)
  if not droneSide then return false, sideErr end
  local tier = tonumber(assignment.params and assignment.params.droneTier) or 1

  -- First return all old drones. moved=0 with an empty input bus is not a fault, but a call error must fail.
  for _, transposer in ipairs(transposers) do
    local ok, err = pcall(transposer.proxy.transferItem, inputSide, droneSide)
    if not ok then return false, "Failed to return old drones: " .. tostring(err) end
  end

  -- Following the Wiki layout, only read the shared ender chest as seen by the first transposer and lock one target-tier slot.
  local firstStacks, firstErr = readStacks(transposers[1].proxy, droneSide)
  if not firstStacks then return false, firstErr end
  local selectedSlot, available, selectedTier, random = findFleetDroneSlot(
    firstStacks, tier, #transposers, config.allowRandomDrone)
  if not selectedSlot then
    return false, string.format("Not enough MK-%d mining drones: need at least %d in a single stack", tier, #transposers)
  end
  if random then
    log.warn("drone", string.format("MK-%d unavailable, switching the whole miner group to MK-%d", tier, selectedTier))
  end

  -- Every miner takes exactly one drone, all from the same slot, so drones of another tier in the chest are never mixed in.
  local remaining = available
  for _, transposer in ipairs(transposers) do
    if remaining <= 0 then return false, "Drone count exhausted" end
    local ok, moved = pcall(transposer.proxy.transferItem, droneSide, inputSide, 1, selectedSlot)
    if not ok or not moved or tonumber(moved) < 1 then
      return false, "Drone transfer failed: " .. tostring(moved)
    end
    remaining = remaining - 1
  end

  log.info("drone", string.format("Dispatched 1 drone each to %d miners (MK-%d, shared slot %d)",
    #transposers, selectedTier, selectedSlot))
  return true
end

local function prepareME(assignment, config, hw)
  local tier = tonumber(assignment.params and assignment.params.droneTier) or 1
  local mapping = (config.droneDatabaseSlots or {})[tier]
  if not mapping or not mapping[1] or not mapping[2] then
    return false, "droneDatabaseSlots not configured for MK-" .. tostring(tier)
  end
  if not hw.database then return false, "database is offline" end
  if not hw.meInterface then return false, "me_interface is offline" end
  local me = hw.meInterface.proxy
  if not me.setInterfaceConfiguration then
    return false, "The selected me_interface has no setInterfaceConfiguration"
  end

  local ok1, err1 = pcall(me.setInterfaceConfiguration, 1, hw.database.address, mapping[1], 64)
  if not ok1 then return false, tostring(err1) end
  local ok2, err2 = pcall(me.setInterfaceConfiguration, 2, hw.database.address, mapping[2], 64)
  if not ok2 then return false, tostring(err2) end
  return true
end

function M.backend(assignment, config)
  if not assignment or assignment.domain ~= "miner" then return "none" end
  return (assignment.target.route and assignment.target.route.droneBackend) or config.droneBackend
end

function M.prepare(assignment, config, hw)
  if not assignment or assignment.domain ~= "miner" then return true end
  local backend = M.backend(assignment, config)
  if backend == "transposer" then
    return prepareTransposerFleet(assignment, config, hw)
  elseif backend == "me_interface" then
    return prepareME(assignment, config, hw)
  elseif backend == "manual" then
    return true
  end
  return false, "Unknown drone backend: " .. tostring(backend)
end

return M
