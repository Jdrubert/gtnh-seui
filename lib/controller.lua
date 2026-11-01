-- SEUI lib/controller.lua
-- One non-blocking control state machine per machine, with safe write-then-read-back

local computer = require("computer")
local log = require("lib.log")
local drone = require("lib.drone")

local M = {}
local workers = {} -- address -> state

local function assignmentSignature(a)
  if not a then return nil end
  local p = a.params or {}
  return table.concat({
    tostring(a.domain), tostring(a.target and a.target.id),
    tostring(p.planetType), tostring(p.gasType), tostring(p.distance),
    tostring(p.droneTier), tostring(a.batch), tostring(a.recipe)
  }, "|")
end

local function newWorker(machine, domain)
  return {
    address = machine.address,
    proxy = machine.proxy,
    name = machine.name or "",
    domain = domain,
    threads = machine.threads or 1,
    paramBackend = machine.paramBackend or "unsupported",
    phase = "IDLE",
    enteredAt = computer.uptime(),
    deadline = 0,
    lastError = nil,
    servingTarget = nil,
    activeSignature = nil,
    pendingAssignment = nil,
  }
end

-- Sync with the new hardware snapshot; state for the same address is kept, so periodic rescans don't cause pointless stops.
function M.init(hw, config)
  local old = workers
  local nextWorkers = {}
  local count = 0

  for _, machine in ipairs(hw.pumps or {}) do
    local w = old[machine.address] or newWorker(machine, "pump")
    w.proxy, w.name, w.domain = machine.proxy, machine.name, "pump"
    w.threads = machine.threads or 1
    w.paramBackend = machine.paramBackend or "unsupported"
    nextWorkers[machine.address] = w
    count = count + 1
  end
  for _, machine in ipairs(hw.miners or {}) do
    local w = old[machine.address] or newWorker(machine, "miner")
    w.proxy, w.name, w.domain = machine.proxy, machine.name, "miner"
    w.threads = 1
    w.paramBackend = machine.paramBackend or "unsupported"
    nextWorkers[machine.address] = w
    count = count + 1
  end

  -- Machines that disappeared can no longer be called, but a warning is logged.
  for address, _ in pairs(old) do
    if not nextWorkers[address] then
      log.warn("controller", "Machine offline: " .. address)
    end
  end
  workers = nextWorkers
  log.info("controller", "Synced " .. count .. " machines")
end

local function transition(w, phase, now)
  w.phase = phase
  w.enteredAt = now or computer.uptime()
end

function M.enqueue(assignment)
  if not assignment or not assignment.worker or not assignment.target then
    return false, "invalid assignment"
  end
  local w = workers[assignment.worker.address]
  if not w then return false, "worker not found" end

  local sig = assignmentSignature(assignment)
  if w.phase == "RUNNING" and sig == w.activeSignature then
    return true -- Already running the same task, don't stop/write parameters again
  end
  if w.pendingAssignment and sig == assignmentSignature(w.pendingAssignment) then
    return true -- Already queued
  end

  w.pendingAssignment = assignment
  if w.phase == "IDLE" then
    transition(w, "REQUEST_STOP")
  elseif w.phase == "RUNNING" then
    transition(w, "REQUEST_STOP")
  elseif w.phase == "REQUEST_END" then
    -- The pending assignment is handled once it has stopped
  elseif w.phase == "FAULT" then
    -- Keep the task; it only continues after a manual Retry
    return false, "worker is faulted"
  end
  return true
end

function M.stopDomain(domain, reason)
  for _, w in pairs(workers) do
    if w.domain == domain then
      w.pendingAssignment = nil
      if w.phase == "RUNNING" or w.phase == "START" then
        transition(w, "REQUEST_END")
        log.info("controller", w.address:sub(1, 8) .. " stopped " .. domain .. ": " .. tostring(reason))
      end
    end
  end
end

local function applyParams(w, backend)
  local a = w.pendingAssignment
  if not a then return true end
  local p = a.params or {}
  local proxy = w.proxy

  if backend == "keyed" then
    if a.domain == "pump" then
      -- Compatibility mode: all recipe threads of this module chase the same target.
      for recipe = 0, (w.threads or 1) - 1 do
        local ok1, err1 = pcall(proxy.setParameter, "recipe" .. recipe .. ".planetType", p.planetType or 0)
        if not ok1 then return false, err1 end
        local ok2, err2 = pcall(proxy.setParameter, "recipe" .. recipe .. ".gasType", p.gasType or 0)
        if not ok2 then return false, err2 end
      end
      if a.batch then
        local ok3, err3 = pcall(proxy.setParameter, "batch", a.batch)
        if not ok3 then return false, err3 end
      end
    else
      local ok, err = pcall(proxy.setParameter, "distance", p.distance or 0)
      if not ok then return false, err end
      if p.parallel ~= nil then
        local ok2, err2 = pcall(proxy.setParameter, "parallel", p.parallel)
        if not ok2 then return false, err2 end
      end
    end
    return true
  end

  if backend == "legacy" then
    if a.domain == "pump" then
      for i = 0, 6, 2 do
        local ok1, err1 = pcall(proxy.setParameters, i, 0, p.planetType or 0)
        if not ok1 then return false, err1 end
        local ok2, err2 = pcall(proxy.setParameters, i, 1, p.gasType or 0)
        if not ok2 then return false, err2 end
      end
      if a.batch then
        local ok3, err3 = pcall(proxy.setParameters, 9, 1, a.batch)
        if not ok3 then return false, err3 end
      end
    else
      local ok, err = pcall(proxy.setParameters, 0, 0, p.distance or 0)
      if not ok then return false, err end
    end
    return true
  end

  return false, "unsupported parameter backend"
end

local function verifyParams(w, backend)
  local a = w.pendingAssignment
  if not a then return true end
  if backend == "legacy" then
    -- The old beta1 interface has no reliable read-back method; the UI clearly labels it legacy.
    log.warn("controller", w.address:sub(1, 8) .. " legacy backend cannot be read back reliably")
    return true
  end
  if backend ~= "keyed" then return false, "unsupported parameter backend" end

  local ok, values = pcall(w.proxy.getParameters)
  if not ok or type(values) ~= "table" then return false, "getParameters failed" end
  local p = a.params or {}

  if a.domain == "pump" then
    for recipe = 0, (w.threads or 1) - 1 do
      local kp = "recipe" .. recipe .. ".planetType"
      local kg = "recipe" .. recipe .. ".gasType"
      if tonumber(values[kp]) ~= tonumber(p.planetType) then
        return false, kp .. " mismatch: " .. tostring(values[kp])
      end
      if tonumber(values[kg]) ~= tonumber(p.gasType) then
        return false, kg .. " mismatch: " .. tostring(values[kg])
      end
    end
    if a.batch and tonumber(values.batch) ~= tonumber(a.batch) then
      return false, "batch mismatch: " .. tostring(values.batch)
    end
  else
    if tonumber(values.distance) ~= tonumber(p.distance) then
      return false, "distance mismatch: " .. tostring(values.distance)
    end
    if p.parallel ~= nil and tonumber(values.parallel) ~= tonumber(p.parallel) then
      return false, "parallel mismatch: " .. tostring(values.parallel)
    end
  end
  return true
end

local function fail(w, message, now)
  w.lastError = tostring(message)
  transition(w, "FAULT", now)
  pcall(w.proxy.setWorkAllowed, false)
  log.error("controller", w.address:sub(1, 8) .. " FAULT: " .. w.lastError)
end

local function droneBackend(assignment, config)
  if type(drone.backend) == "function" then
    return drone.backend(assignment, config)
  end
  if not assignment or assignment.domain ~= "miner" then return "none" end
  return (assignment.target.route and assignment.target.route.droneBackend) or config.droneBackend
end

local function sameFleetTask(a, b)
  if not a or not b then return false end
  local ap, bp = a.params or {}, b.params or {}
  return tostring(a.target and a.target.id) == tostring(b.target and b.target.id)
      and tonumber(ap.droneTier) == tonumber(bp.droneTier)
end

-- The transposer backend uses the Wiki's whole-fleet sync approach. As soon as any miner needs to change target, the other miners are
-- stopped too; once all miners reach PREPARE, drone.prepare is called only once, and then all enter APPLY together.
local function advanceMinerFleetPrepare(now, config, hw)
  local leader = nil
  for _, w in pairs(workers) do
    if w.domain == "miner" and w.phase == "PREPARE" and w.pendingAssignment
        and droneBackend(w.pendingAssignment, config) == "transposer" then
      leader = w
      break
    end
  end
  if not leader then return end

  local assignment = leader.pendingAssignment
  local allReady, peerFault = true, false
  for _, w in pairs(workers) do
    if w.domain == "miner" then
      if w.phase == "FAULT" then
        peerFault = true
      elseif not w.pendingAssignment then
        -- This may be an old miner still running the same task, or a miner newly added after a hardware rescan.
        -- To make sure no miner is working while drones are swapped globally, include it in the same task.
        w.pendingAssignment = assignment
        if w.phase == "RUNNING" or w.phase == "IDLE" then
          transition(w, "REQUEST_STOP", now)
        end
        allReady = false
      elseif droneBackend(w.pendingAssignment, config) ~= "transposer"
          or not sameFleetTask(w.pendingAssignment, assignment) then
        fail(w, "Inconsistent drone tasks in the miner group", now)
        peerFault = true
      elseif w.phase ~= "PREPARE" then
        allReady = false
      end
    end
  end

  if peerFault then
    for _, w in pairs(workers) do
      if w.domain == "miner" and w.phase ~= "FAULT" then
        fail(w, "Another machine in the miner group faulted, cancelling the synchronized drone swap", now)
      end
    end
    return
  end
  if not allReady then return end

  local ok, err = drone.prepare(assignment, config, hw)
  if not ok then
    for _, w in pairs(workers) do
      if w.domain == "miner" and w.phase == "PREPARE" then
        fail(w, "PREPARE: " .. tostring(err), now)
      end
    end
    return
  end
  for _, w in pairs(workers) do
    if w.domain == "miner" and w.phase == "PREPARE" then
      transition(w, "APPLY", now)
    end
  end
end

function M.tick(now, config, hw)
  local idleTimeout = config.idleTimeout or 30
  advanceMinerFleetPrepare(now, config, hw)
  for _, w in pairs(workers) do
    local backend = w.paramBackend or hw.paramBackend or "unsupported"
    if w.phase == "REQUEST_STOP" or w.phase == "REQUEST_END" then
      local ending = w.phase == "REQUEST_END"
      local ok, err = pcall(w.proxy.setWorkAllowed, false)
      if not ok then
        fail(w, "setWorkAllowed(false): " .. tostring(err), now)
      else
        w.stopOnly = ending and w.pendingAssignment == nil
        w.deadline = now + idleTimeout
        transition(w, "WAIT_IDLE", now)
      end

    elseif w.phase == "WAIT_IDLE" then
      local ok, active = pcall(w.proxy.isMachineActive)
      if not ok then
        fail(w, "isMachineActive: " .. tostring(active), now)
      elseif not active then
        if w.pendingAssignment then
          transition(w, "PREPARE", now)
        else
          w.servingTarget, w.activeSignature = nil, nil
          transition(w, "IDLE", now)
        end
      elseif now > w.deadline then
        fail(w, "WAIT_IDLE timeout " .. idleTimeout .. "s", now)
      end

    elseif w.phase == "PREPARE" then
      if droneBackend(w.pendingAssignment, config) ~= "transposer" then
        local ok, err = drone.prepare(w.pendingAssignment, config, hw)
        if not ok then fail(w, "PREPARE: " .. tostring(err), now)
        else transition(w, "APPLY", now) end
      end -- the transposer backend is advanced uniformly by advanceMinerFleetPrepare

    elseif w.phase == "APPLY" then
      local ok, err = applyParams(w, backend)
      if not ok then fail(w, "APPLY: " .. tostring(err), now)
      else transition(w, "VERIFY", now) end

    elseif w.phase == "VERIFY" then
      local ok, err = verifyParams(w, backend)
      if not ok then fail(w, "VERIFY: " .. tostring(err), now)
      else transition(w, "START", now) end

    elseif w.phase == "START" then
      local ok, err = pcall(w.proxy.setWorkAllowed, true)
      if not ok then
        fail(w, "setWorkAllowed(true): " .. tostring(err), now)
      else
        local a = w.pendingAssignment
        w.servingTarget = a.target.id
        w.activeSignature = assignmentSignature(a)
        w.pendingAssignment = nil
        w.lastError = nil
        if a.target.runtime then a.target.runtime.lastServed = now end
        transition(w, "RUNNING", now)
        log.info("controller", w.address:sub(1, 8) .. " RUNNING " .. w.servingTarget)
      end
    end
  end
end

function M.retry(address)
  local w = workers[address]
  if not w or w.phase ~= "FAULT" then return false end
  w.lastError = nil
  transition(w, "REQUEST_STOP")
  return true
end

function M.stopAll(reason)
  log.warn("controller", "STOP ALL: " .. tostring(reason))
  for _, w in pairs(workers) do
    pcall(w.proxy.setWorkAllowed, false)
    w.pendingAssignment = nil
    w.servingTarget = nil
    w.activeSignature = nil
    w.lastError = "STOP ALL: " .. tostring(reason)
    transition(w, "FAULT")
  end
end

function M.status()
  local result = {}
  for address, w in pairs(workers) do
    result[address] = {
      phase = w.phase,
      domain = w.domain,
      servingTarget = w.servingTarget,
      pendingTarget = w.pendingAssignment and w.pendingAssignment.target.id or nil,
      hasPending = w.pendingAssignment ~= nil,
      lastError = w.lastError,
    }
  end
  return result
end

function M.getAllWorkers() return workers end
function M.getWorker(address) return workers[address] end

return M
