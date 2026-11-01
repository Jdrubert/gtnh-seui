-- SEUI lib/model.lua
-- Target model management

local format = require("lib.format")
local log = require("lib.log")

local M = {}

local targets = {}
local nextOrder = 1

local function makeTarget(t)
  t = t or {}
  local target = {
    id = t.id or ("target_" .. tostring(nextOrder)),
    domain = t.domain or "pump",
    label = t.label or t.id or "Unnamed",
    item = t.item or nil,
    fluid = t.fluid or nil,
    fluidAliases = t.fluidAliases or nil,
    mode = t.mode or "TARGET",
    current = t.current or 0,
    target = t.target or 0,
    pending = t.pending or 0,
    weight = t.weight or 0,
    order = t.order or nextOrder,
    lowRatio = t.lowRatio or 0.90,
    highRatio = t.highRatio or 1.00,
    minDwell = t.minDwell or 30,
    route = t.route or {},
    sourceRef = t.sourceRef or nil,
    runtime = {
      state = "UNKNOWN",
      runningWorkers = 0,
      lastServed = 0,
      lastError = nil,
      snapshotAt = 0,
    },
  }
  nextOrder = nextOrder + 1
  return target
end

function M.addTarget(t)
  local target = makeTarget(t)
  table.insert(targets, target)
  return target
end

function M.getTargets()
  return targets
end

function M.clear()
  targets = {}
  nextOrder = 1
end

function M.getByDomain(domain)
  local result = {}
  for _, t in ipairs(targets) do
    if t.domain == domain then
      table.insert(result, t)
    end
  end
  return result
end

function M.getById(id)
  for _, t in ipairs(targets) do
    if t.id == id then return t end
  end
  return nil
end

function M.removeById(id)
  for i, t in ipairs(targets) do
    if t.id == id then
      table.remove(targets, i)
      return true
    end
  end
  return false
end

function M.reorder()
  table.sort(targets, function(a, b) return a.order < b.order end)
end

function M.moveOrder(id, direction)
  local idx = nil
  for i, t in ipairs(targets) do
    if t.id == id then idx = i break end
  end
  if not idx then return false end

  if direction == "top" then
    local t = table.remove(targets, idx)
    table.insert(targets, 1, t)
  elseif direction == "bottom" then
    local t = table.remove(targets, idx)
    table.insert(targets, t)
  elseif direction == "up" and idx > 1 then
    targets[idx], targets[idx-1] = targets[idx-1], targets[idx]
  elseif direction == "down" and idx < #targets then
    targets[idx], targets[idx+1] = targets[idx+1], targets[idx]
  end

  -- Renumber order
  for i, t in ipairs(targets) do
    t.order = i
  end
  return true
end

-- Import targets from level_maintainer
function M.importFromMaintainers(maintainers, profile)
  local imported = 0
  local seen = {}
  for _, existing in ipairs(targets) do seen[existing.id] = existing end

  for _, m in ipairs(maintainers) do
    for slot = 1, 5 do
      local ok, slotData = pcall(m.proxy.getSlot, slot)
      if ok and slotData and slotData.isEnable then
        local isFluid = slotData.isFluid or false
        local id, label, name, damage, fluidName

        if isFluid then
          fluidName = (slotData.fluid and slotData.fluid.name) or slotData.name or "unknown"
          id = "fluid:" .. fluidName
          label = slotData.label or fluidName
        else
          local rawName = slotData.name or "unknown"
          damage = slotData.damage or 0
          local nameFromID, damageFromID = rawName:match("^(.+):(%d+)$")
          if nameFromID and damageFromID then
            name = nameFromID
            damage = tonumber(damageFromID) or damage
          else
            name = rawName
          end
          if slotData.damage and slotData.damage > 0 then
            damage = slotData.damage
          end
          id = "item:" .. name .. ":" .. damage
          label = slotData.label or name
        end

        if not seen[id] or type(seen[id]) == "table" then
          local packed = slotData.batch or 0
          local decoded = format.decodePackedBatch(packed, isFluid, profile)
          local quantity = tonumber(slotData.quantity) or 0

          local target = {
            id = id,
            domain = isFluid and "pump" or "miner",
            label = label,
            fluid = isFluid and fluidName or nil,
            item = (not isFluid) and { name = name, damage = damage } or nil,
            mode = "TARGET",
            target = quantity,
            sourceRef = { address = m.address, slot = slot },
            route = decoded,
          }
          -- Fill in the route fields for fluid targets
          if isFluid and decoded.planetType then
            target.route.planetType = decoded.planetType
            target.route.gasType = decoded.gasType
          end

          local existing = type(seen[id]) == "table" and seen[id] or nil
          -- The built-in 40-fluid catalog uses stable route IDs; the requester's registry names may differ.
          if isFluid and not existing then
            for _, candidate in ipairs(targets) do
              if candidate.domain == "pump" and candidate.route
                  and tonumber(candidate.route.planetType) == tonumber(target.route.planetType)
                  and tonumber(candidate.route.gasType) == tonumber(target.route.gasType) then
                existing = candidate
                break
              end
            end
          end
          if existing then
            -- An explicit re-import only overwrites fields owned by the requester and keeps weight/order.
            existing.label = target.label
            existing.fluid = target.fluid or existing.fluid
            if isFluid then
              existing.fluidAliases = existing.fluidAliases or {}
              local aliasSeen = false
              for _, alias in ipairs(existing.fluidAliases) do
                if alias == target.fluid then aliasSeen = true break end
              end
              if target.fluid and not aliasSeen then table.insert(existing.fluidAliases, target.fluid) end
            end
            existing.mode = "TARGET"
            existing.target = target.target
            local baseRate = existing.route and existing.route.baseRate
            existing.route = target.route
            if baseRate then existing.route.baseRate = baseRate end
            existing.sourceRef = target.sourceRef
          else
            M.addTarget(target)
          end
          seen[id] = true
          imported = imported + 1
        end
      end
    end
  end

  log.info("model", string.format("Imported %d targets from maintainers (profile=%s)", imported, profile))
  return imported
end

-- Update the current stock of a target
function M.updateCurrent(target, snapshot)
  if target.domain == "pump" and target.fluid then
    local amount = snapshot.fluids[target.fluid] or 0
    for _, alias in ipairs(target.fluidAliases or {}) do
      amount = math.max(amount, snapshot.fluids[alias] or 0)
    end
    target.current = amount
  elseif target.domain == "miner" and target.item then
    local key = format.itemKey(target.item.name, target.item.damage or 0)
    target.current = snapshot.items[key] or 0
  end
  target.runtime.snapshotAt = snapshot.timestamp
end

-- Compute the deficit ratio
function M.getRatio(target)
  local available = math.max(0, target.current + target.pending)
  if target.target > 0 then
    return available / target.target
  end
  return 0
end

-- Derive state
function M.deriveState(target, snapshotFresh, machineActive, hasPendingTask)
  local rt = target.runtime

  if not snapshotFresh then
    rt.state = "STALE"
    return
  end

  if target.mode == "OFF" then
    rt.state = "OFF"
    return
  end

  if target.mode == "TARGET" and target.target <= 0 then
    rt.state = "OFF"
    return
  end

  if machineActive then
    rt.state = "RUN"
    return
  end

  if hasPendingTask then
    rt.state = "WAIT"
    return
  end

  local ratio = M.getRatio(target)
  if target.mode == "TARGET" then
    if ratio >= target.highRatio then
      rt.state = "OK"
    elseif ratio < target.lowRatio then
      rt.state = "LOW"
    else
      rt.state = "OK"
    end
  elseif target.mode == "ALWAYS" then
    rt.state = "READY"
  end
end

return M
