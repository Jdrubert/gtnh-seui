-- SEUI lib/discovery.lua
-- Hardware component discovery and binding

local component = require("component")
local log = require("lib.log")

local M = {}

local hw = {
  pumps = {},           -- {address, proxy, name, tier, threads, mult}
  miners = {},          -- {address, proxy, name, tier}
  levelMaintainers = {},-- {address, proxy}
  transposers = {},     -- {address, proxy}
  fluidInterface = nil, -- {address, proxy}
  meInterface = nil,    -- {address, proxy}
  database = nil,       -- {address, proxy}
  gpu = nil,
  screen = nil,
  paramBackend = "unknown", -- "keyed" / "legacy" / "unsupported"
  lastScan = 0,
}

-- Pump tier info
local PUMP_INFO = {
  ["1"] = { threads = 1, mult = 4,   tier = 1 },
  ["2"] = { threads = 4, mult = 4,   tier = 2 },
  ["3"] = { threads = 4, mult = 64,  tier = 3 },
}

local function matchPumpTier(name)
  name = name or ""
  for tier, info in pairs(PUMP_INFO) do
    if name:match("pumpt" .. tier .. "$") then
      return info
    end
  end
  return { threads = 1, mult = 4, tier = 1 }
end

local function safeProxy(addr)
  local ok, p = pcall(component.proxy, addr)
  if ok then return p end
  return nil
end

local function backendFor(addr, proxy)
  local ok, methods = pcall(component.methods, addr)
  if ok and type(methods) == "table" then
    if methods.setParameter and methods.getParameters then return "keyed" end
    if methods.setParameters then return "legacy" end
  end
  local ok2, result = pcall(proxy.getParameters)
  if ok2 and type(result) == "table" and proxy.setParameter then return "keyed" end
  return "unsupported"
end

function M.scan()
  hw.pumps = {}
  hw.miners = {}
  hw.levelMaintainers = {}
  hw.transposers = {}

  for addr, name in component.list("gt_machine") do
    local proxy = safeProxy(addr)
    if proxy then
      local machineName = ""
      local ok, mn = pcall(proxy.getName)
      if ok then machineName = mn or "" end

      if machineName:match("projectmodulepump") then
        local info = matchPumpTier(machineName)
        table.insert(hw.pumps, {
          address = addr, proxy = proxy, name = machineName,
          tier = info.tier, threads = info.threads, mult = info.mult,
          paramBackend = backendFor(addr, proxy),
        })
      elseif machineName:match("projectmoduleminer") then
        local tier = 1
        if machineName:match("minert3") then tier = 3
        elseif machineName:match("minert2") then tier = 2 end
        table.insert(hw.miners, {
          address = addr, proxy = proxy, name = machineName, tier = tier,
          paramBackend = backendFor(addr, proxy),
        })
      end
    end
  end

  for addr in component.list("level_maintainer") do
    local p = safeProxy(addr)
    if p then
      table.insert(hw.levelMaintainers, { address = addr, proxy = p })
    end
  end

  for addr in component.list("transposer") do
    local p = safeProxy(addr)
    if p then
      table.insert(hw.transposers, { address = addr, proxy = p })
    end
  end

  -- fluid_interface (AE2FC 2-in-1 interface; the composite driver also exposes the network methods)
  hw.fluidInterface = nil
  for addr in component.list("fluid_interface") do
    local p = safeProxy(addr)
    if p then
      hw.fluidInterface = { address = addr, proxy = p }
      break
    end
  end

  -- me_interface (item network)
  hw.meInterface = nil
  for addr in component.list("me_interface") do
    local p = safeProxy(addr)
    if p then
      hw.meInterface = { address = addr, proxy = p }
      break
    end
  end

  -- me_controller independently covers whichever side is missing
  if not hw.fluidInterface or not hw.meInterface then
    for addr in component.list("me_controller") do
      local p = safeProxy(addr)
      if p then
        if not hw.meInterface then hw.meInterface = { address = addr, proxy = p } end
        if not hw.fluidInterface then hw.fluidInterface = { address = addr, proxy = p } end
        break
      end
    end
  end

  -- Some AE/AE2FC composite drivers use component names other than the fixed me_interface/fluid_interface.
  -- As a last resort, scan the whole OC network by actual method capability, to avoid the case "AE has storage but the preferredName doesn't match".
  if not hw.fluidInterface or not hw.meInterface then
    for addr in component.list() do
      local ok, methods = pcall(component.methods, addr)
      if ok and type(methods) == "table" then
        local hasFluids = methods.getFluidsInNetwork ~= nil
        local hasItems = methods.getItemsInNetworkById ~= nil or methods.getItemsInNetwork ~= nil
        if (hasFluids and not hw.fluidInterface) or (hasItems and not hw.meInterface) then
          local p = safeProxy(addr)
          if p then
            if hasFluids and not hw.fluidInterface then
              hw.fluidInterface = { address = addr, proxy = p }
              log.info("discovery", "Found fluid network component by capability: " .. addr)
            end
            if hasItems and not hw.meInterface then
              hw.meInterface = { address = addr, proxy = p }
              log.info("discovery", "Found item network component by capability: " .. addr)
            end
          end
        end
      end
      if hw.fluidInterface and hw.meInterface then break end
    end
  end

  -- database
  hw.database = nil
  for addr in component.list("database") do
    local p = safeProxy(addr)
    if p then
      hw.database = { address = addr, proxy = p }
      break
    end
  end

  -- GPU/screen
  hw.gpu = component.gpu or nil
  hw.screen = nil
  if component.screen then
    hw.screen = component.screen
  end

  -- Parameter interface detection
  M.detectParamBackend()

  hw.lastScan = require("computer").uptime()

  log.info("discovery", string.format(
    "Found %d pumps, %d miners, %d maintainers, %d transposers, fluidIF=%s, meIF=%s, backend=%s",
    #hw.pumps, #hw.miners, #hw.levelMaintainers, #hw.transposers,
    tostring(hw.fluidInterface ~= nil), tostring(hw.meInterface ~= nil),
    hw.paramBackend
  ))

  return hw
end

function M.detectParamBackend()
  hw.paramBackend = "unknown"
  if #hw.pumps == 0 and #hw.miners == 0 then
    return
  end
  local sample = hw.pumps[1] or hw.miners[1]
  if not sample then return end
  local methods = {}
  local ok, result = pcall(component.methods, sample.address)
  if ok and type(result) == "table" then
    methods = result
  else
    -- Try calling directly
    local ok2, params = pcall(sample.proxy.getParameters)
    if ok2 then
      hw.paramBackend = "keyed"
      return
    end
    hw.paramBackend = "unsupported"
    return
  end

  local hasSetParam = false
  local hasSetParams = false
  local hasGetParameters = false
  -- component.methods() returns a methodName -> direct(boolean) map.
  for methodName, _ in pairs(methods) do
    if methodName == "setParameter" then hasSetParam = true end
    if methodName == "getParameters" then hasGetParameters = true end
    if methodName == "setParameters" then hasSetParams = true end
  end

  if hasSetParam and hasGetParameters then
    hw.paramBackend = "keyed"
  elseif hasSetParams then
    hw.paramBackend = "legacy"
  else
    hw.paramBackend = "unsupported"
  end
end

function M.getHardware()
  return hw
end

function M.isComponentAvailable(typeName)
  local addr = component.list(typeName)()
  return addr ~= nil
end

return M
