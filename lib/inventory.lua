-- SEUI lib/inventory.lua
-- ME inventory scan: fluids are fetched in one call, items are fetched in bulk by registry id.
-- Each domain keeps its last successful snapshot, so a failure on either side never wrongly writes the stock as 0.

local log = require("lib.log")
local format = require("lib.format")
local computer = require("computer")

local M = {}
local snapshot = {
  fluids = {}, items = {},
  fluidTimestamp = 0, itemTimestamp = 0,
  timestamp = 0, duration = 0,
  fluidError = "not scanned", itemError = "not scanned",
  error = "not scanned",
}

local function stackAmount(stack)
  return tonumber(stack and (stack.size or stack.amount) or 0) or 0
end

local function scanFluids(proxy)
  if not proxy or not proxy.getFluidsInNetwork then return nil, "no fluid network component" end
  local ok, list = pcall(proxy.getFluidsInNetwork)
  if not ok then return nil, tostring(list) end
  if type(list) ~= "table" then return nil, "getFluidsInNetwork returned non-table" end
  local result = {}
  for _, fluid in ipairs(list) do
    if fluid and fluid.name then result[fluid.name] = stackAmount(fluid) end
  end
  return result
end

local function scanItemsFallback(proxy, targets)
  if not proxy or not proxy.getItemsInNetwork then return nil, "no item network component" end
  local result = {}
  for _, target in ipairs(targets or {}) do
    if target.item and target.item.name then
      local filter = {name = target.item.name}
      if (target.item.damage or 0) > 0 then filter.damage = target.item.damage end
      local ok, list = pcall(proxy.getItemsInNetwork, filter)
      if not ok then return nil, tostring(list) end
      for _, stack in ipairs(list or {}) do
        if stack and stack.name then
          local key = format.itemKey(stack.name, stack.damage or 0)
          result[key] = (result[key] or 0) + stackAmount(stack)
        end
      end
    end
  end
  return result
end

local function scanItems(proxy, targets)
  if not proxy then return nil, "no item network component" end
  local names, seen = {}, {}
  for _, target in ipairs(targets or {}) do
    local name = target.item and target.item.name
    if name and not seen[name] then seen[name] = true table.insert(names, name) end
  end
  if #names == 0 then return {} end
  if not proxy.getItemsInNetworkById then return scanItemsFallback(proxy, targets) end

  local ok, list = pcall(proxy.getItemsInNetworkById, names)
  if not ok then
    log.warn("inventory", "Bulk item query failed, falling back to per-item queries: " .. tostring(list))
    return scanItemsFallback(proxy, targets)
  end
  if type(list) ~= "table" then return nil, "getItemsInNetworkById returned non-table" end

  local result = {}
  for _, stack in ipairs(list) do
    if stack and stack.name then
      local key = format.itemKey(stack.name, stack.damage or 0)
      result[key] = (result[key] or 0) + stackAmount(stack)
    end
  end
  return result
end

function M.scan(fluidProxy, itemProxy, minerTargets)
  local t0 = computer.uptime()
  local fluids, fluidErr = scanFluids(fluidProxy)
  local items, itemErr = scanItems(itemProxy, minerTargets)
  local now = computer.uptime()

  snapshot.duration = now - t0
  snapshot.timestamp = now
  snapshot.fluidError, snapshot.itemError = fluidErr, itemErr

  if fluids then
    snapshot.fluids = fluids
    snapshot.fluidTimestamp = now
  else
    log.error("inventory", "Fluid scan failed, keeping the old snapshot: " .. tostring(fluidErr))
  end
  if items then
    snapshot.items = items
    snapshot.itemTimestamp = now
  else
    log.error("inventory", "Item scan failed, keeping the old snapshot: " .. tostring(itemErr))
  end

  if fluidErr or itemErr then
    local errors = {}
    if fluidErr then table.insert(errors, "fluid:" .. fluidErr) end
    if itemErr then table.insert(errors, "item:" .. itemErr) end
    snapshot.error = table.concat(errors, " ")
  else
    snapshot.error = nil
  end
  return snapshot
end

function M.getFluidAmount(name) return snapshot.fluids[name] or 0 end
function M.getItemAmount(name, damage) return snapshot.items[format.itemKey(name, damage or 0)] or 0 end
function M.getSnapshot() return snapshot end
function M.getDuration() return snapshot.duration end

function M.isFresh(now, maxAge, domain)
  maxAge = maxAge or 15
  if domain == "pump" then
    return snapshot.fluidError == nil and now - snapshot.fluidTimestamp < maxAge
  elseif domain == "miner" then
    return snapshot.itemError == nil and now - snapshot.itemTimestamp < maxAge
  end
  return snapshot.fluidError == nil and snapshot.itemError == nil
     and now - math.min(snapshot.fluidTimestamp, snapshot.itemTimestamp) < maxAge
end

return M
