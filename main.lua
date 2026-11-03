-- SEUI main.lua
-- Space Elevator dual-business UI main entry point
-- GTNH 2.9.0-RC-1 / OpenComputers 1.12.62-GTNH
-- Compatible with both Lua 5.2 and 5.3

local component = require("component")
local computer = require("computer")
local event = require("event")
local os = require("os")
local filesystem = require("filesystem")

-- OpenOS's package.path contains ./, but the user may run /seui/main.lua from any directory.
-- process.load writes the absolute path of the current program into the environment variable _,
-- so we use it to add the script directory to the search path.
local runningProgram = os.getenv("_")
if runningProgram then
  local baseDir = filesystem.path(runningProgram)
  package.path = baseDir .. "?.lua;" .. baseDir .. "?/init.lua;" .. package.path
end

-- OpenOS caches required modules until reboot. Drop our own modules from the cache so every
-- launch starts clean (otherwise old targets, machine FAULT states and config edits carry over).
for name in pairs(package.loaded) do
  if name == "config" or name:match("^lib%.") then package.loaded[name] = nil end
end

-- Load modules
local config = require("config")
local log = require("lib.log")
local store = require("lib.store")
local discovery = require("lib.discovery")
local inventory = require("lib.inventory")
local model = require("lib.model")
local fluidCatalog = require("lib.fluid_catalog")
local scheduler = require("lib.scheduler")
local controller = require("lib.controller")
local ui = require("lib.ui")

-- ========== Application state ==========
local app = {
  running = true,
  mode = "readonly",        -- "simulate" / "readonly" / "control"
  hw = nil,                 -- hardware snapshot
  nextInventoryScan = 0,
  nextHardwareRescan = 0,
  nextTargetRescan = 0,
  nextSchedule = 0,
  needRescan = false,
  needImport = false,
  configDirty = false,
  lastSaveTime = 0,
  lastSaveAttempt = -math.huge,
  config = config,
}

-- ========== Parse command-line arguments ==========
local shell = require("shell")
local args, opts = shell.parse(...)

if opts.simulate then
  app.mode = "simulate"
elseif opts.control then
  app.mode = "control"
else
  app.mode = "readonly"
end
config.runtimeMode = app.mode

-- ========== Initialization ==========
local function initLog()
  log.init(config.logFile, config.logMaxSize, config.logKeep)
  log.info("main", "=== SEUI started === mode=" .. app.mode)
end

local function initStore()
  store.init(config.dataFile)
end

local function loadOrCreateConfig()
  local data, err = store.load()
  if data then
    data = store.migrate(data)
    -- Merge stored configuration into the runtime
    if data.ui then
      ui.setState(data.ui)
    end
    if data.targets and #data.targets > 0 then
      local seenIds = {}
      for _, t in ipairs(data.targets) do
        if t.id and seenIds[t.id] then
          log.warn("main", "Ignoring duplicate saved target: " .. tostring(t.id))
          app.configDirty = true  -- the cleaned-up configuration needs to be rewritten
        else
          if t.id then seenIds[t.id] = true end
          model.addTarget(t)
        end
      end
    end
    local _, removed = fluidCatalog.populate(model)
    if removed and removed > 0 then
      log.warn("main", "Startup dedup: removed " .. removed .. " duplicate fluid targets")
      app.configDirty = true
    end
    log.info("main", "Loaded " .. #model.getTargets() .. " targets from config")
  else
    log.info("main", "No config file: " .. tostring(err))
    fluidCatalog.populate(model)
  end
end

local function injectSimulatedData()
  -- Simulate mode: inject fake data
  local fluids = {
    {label = "Hydrogen", fluid = "hydrogen", planet = 8, gas = 1},
    {label = "Helium", fluid = "helium", planet = 5, gas = 4},
    {label = "Oxygen", fluid = "oxygen", planet = 7, gas = 4},
    {label = "Nitrogen", fluid = "nitrogen", planet = 7, gas = 3},
    {label = "Fluorine", fluid = "fluorine", planet = 7, gas = 2},
    {label = "Tritium", fluid = "tritium", planet = 6, gas = 2},
    {label = "Deuterium", fluid = "deuterium", planet = 6, gas = 1},
    {label = "Helium-3", fluid = "helium-3", planet = 5, gas = 2},
    {label = "Xenon", fluid = "xenon", planet = 6, gas = 4},
    {label = "Krypton", fluid = "krypton", planet = 5, gas = 8},
    {label = "Neon", fluid = "neon", planet = 5, gas = 6},
    {label = "Argon", fluid = "argon", planet = 5, gas = 7},
    {label = "Radon", fluid = "radon", planet = 8, gas = 6},
    {label = "Methane", fluid = "methane", planet = 5, gas = 9},
    {label = "Ammonia", fluid = "ammonia", planet = 6, gas = 3},
    {label = "Ethylene", fluid = "ethylene", planet = 6, gas = 5},
    {label = "Ethane", fluid = "ethane", planet = 5, gas = 11},
    {label = "Carbon Monoxide", fluid = "carbon_monoxide", planet = 5, gas = 1},
    {label = "Carbon Dioxide", fluid = "carbon_dioxide", planet = 4, gas = 8},
    {label = "Hydrogen Sulfide", fluid = "hydrogen_sulfide", planet = 5, gas = 10},
    {label = "Hydrofluoric Acid", fluid = "hydrofluoric_acid", planet = 7, gas = 1},
    {label = "Sulfuric Acid", fluid = "sulfuric_acid", planet = 4, gas = 1},
    {label = "Salt Water", fluid = "salt_water", planet = 5, gas = 3},
    {label = "Distilled Water", fluid = "distilled_water", planet = 8, gas = 5},
    {label = "Molten Iron", fluid = "molten_iron", planet = 4, gas = 2},
    {label = "Molten Copper", fluid = "molten_copper", planet = 8, gas = 3},
    {label = "Molten Tin", fluid = "molten_tin", planet = 8, gas = 7},
    {label = "Molten Lead", fluid = "molten_lead", planet = 4, gas = 5},
    {label = "Chlorobenzene", fluid = "chlorobenzene", planet = 2, gas = 1},
    {label = "Ender Goo", fluid = "ender_goo", planet = 3, gas = 1},
    {label = "Lava", fluid = "lava", planet = 3, gas = 3},
    {label = "Natural Gas", fluid = "natural_gas", planet = 3, gas = 4},
    {label = "Oil", fluid = "oil", planet = 4, gas = 3},
    {label = "Heavy Oil", fluid = "heavy_oil", planet = 4, gas = 4},
    {label = "Light Oil", fluid = "light_oil", planet = 4, gas = 7},
    {label = "Raw Oil", fluid = "raw_oil", planet = 4, gas = 6},
    {label = "Liquid Air", fluid = "liquid_air", planet = 8, gas = 2},
    {label = "Liquid Oxygen", fluid = "liquid_oxygen", planet = 5, gas = 5},
    {label = "Unknown Liquid", fluid = "unknown_liquid", planet = 8, gas = 4},
    {label = "Silane", fluid = "silane", planet = 2, gas = 2},
  }

  for i, f in ipairs(fluids) do
    model.addTarget({
      id = "fluid:" .. f.fluid,
      domain = "pump",
      label = f.label,
      fluid = f.fluid,
      mode = "TARGET",
      target = 10e9,
      current = math.random(0, 15e9),
      weight = 0,
      order = i,
      route = { planetType = f.planet, gasType = f.gas, maxBatch = 30 },
    })
  end

  -- Fake ore/mineral data
  local ores = {
    {label = "Iron Ingot", name = "minecraft:iron_ingot", damage = 0},
    {label = "Gold Ingot", name = "minecraft:gold_ingot", damage = 0},
    {label = "Copper Ingot", name = "gregtech:gt.metaitem.01", damage = 12000},
    {label = "Tin Ingot", name = "gregtech:gt.metaitem.01", damage = 13000},
  }
  for i, o in ipairs(ores) do
    model.addTarget({
      id = "item:" .. o.name .. ":" .. o.damage,
      domain = "miner",
      label = o.label,
      item = { name = o.name, damage = o.damage },
      mode = "TARGET",
      target = 1e9,
      current = math.random(0, 15e8),
      weight = 0,
      order = i,
      route = { droneTier = 8, distance = 100 },
    })
  end

  log.info("main", "Simulate mode: injected " .. #fluids .. " fluids + " .. #ores .. " ores")
end

local function initUI()
  local gpu = component.gpu
  local screen = component.screen or nil
  if not gpu then
    error("GPU component not found")
  end
  ui.init(gpu, screen, config)
end

-- ========== Scanning ==========

local function doHardwareScan()
  log.info("main", "Starting hardware scan...")
  app.hw = discovery.scan()

  if app.mode ~= "simulate" then
    controller.init(app.hw, config)
  end

  -- The initial catalog already has 40 fluids set to OFF; on first launch we still
  -- need to automatically import the enabled targets from the level maintainers.
  local hasImported = false
  for _, t in ipairs(model.getTargets()) do
    if t.sourceRef then hasImported = true break end
  end
  if not hasImported and #app.hw.levelMaintainers > 0 then
    local n = model.importFromMaintainers(app.hw.levelMaintainers, config.importProfile)
    if n > 0 then app.configDirty = true end
  end

  ui.markDirty()
end

local function doInventoryScan()
  if app.mode == "simulate" then
    -- Simulate mode does not scan real inventory
    return
  end

  ui.setScanning(true)
  local fluidProxy = app.hw.fluidInterface and app.hw.fluidInterface.proxy or nil
  local meProxy = app.hw.meInterface and app.hw.meInterface.proxy or nil
  local minerTargets = model.getByDomain("miner")

  inventory.scan(fluidProxy, meProxy, minerTargets)

  -- Update the current stock of every target
  local snap = inventory.getSnapshot()
  local targets = model.getTargets()
  for _, t in ipairs(targets) do
    model.updateCurrent(t, snap)
  end

  ui.setScanning(false)
  ui.markDirty()
end

-- ========== Scheduling and control ==========

local function doSchedule()
  if app.mode == "simulate" or app.mode == "readonly" then
    return
  end

  if app.mode == "control" then
    local now = computer.uptime()
    local pumpFresh = inventory.isFresh(now, config.maxSnapshotAge, "pump")
    local minerFresh = inventory.isFresh(now, config.maxSnapshotAge, "miner")

    -- PUMP scheduling
    if pumpFresh then
      local pumpTargets = model.getByDomain("pump")
      local pumpAssignments = scheduler.plan("pump", pumpTargets, app.hw.pumps, now, config)
      if pumpAssignments then
        for _, a in ipairs(pumpAssignments) do controller.enqueue(a) end
      else
        controller.stopDomain("pump", "all targets satisfied")
      end
    else
      log.warn("main", "Fluid snapshot is stale, stopping new PUMP dispatches")
      if config.failClosed then controller.stopDomain("pump", "stale inventory") end
    end

    -- MINER scheduling
    if minerFresh then
      local minerTargets = model.getByDomain("miner")
      local minerAssignments = scheduler.plan("miner", minerTargets, app.hw.miners, now, config)
      if minerAssignments then
        for _, a in ipairs(minerAssignments) do controller.enqueue(a) end
      else
        controller.stopDomain("miner", "all targets satisfied")
      end
    else
      log.warn("main", "Item snapshot is stale, stopping new MINER dispatches")
      if config.failClosed then controller.stopDomain("miner", "stale inventory") end
    end
  end
end

-- ========== State derivation ==========

local function updateTargetStates()
  local now = computer.uptime()
  local ws = controller.status()
  local targets = model.getTargets()

  for _, t in ipairs(targets) do
    -- Check whether any machine is currently serving this target
    local machineActive = false
    local hasPendingTask = false
    for addr, w in pairs(ws) do
      if w.servingTarget == t.id or w.pendingTarget == t.id then
        if w.phase == "RUNNING" then
          machineActive = true
        end
        if w.hasPending then
          hasPendingTask = true
        end
      end
    end

    -- Only derive state for targets belonging to the domain of the current page
    local fresh = app.mode == "simulate" or inventory.isFresh(now, config.maxSnapshotAge, t.domain)
    model.deriveState(t, fresh, machineActive, hasPendingTask)
  end
end

-- ========== Saving configuration ==========

local function saveConfig(force)
  if not app.configDirty then return end
  local now = computer.uptime()
  if not force and now - app.lastSaveAttempt < 5 then return end
  app.lastSaveAttempt = now

  local data = {
    schemaVersion = 1,
    ui = ui.getState(),
    scheduler = {
      scanInterval = config.scanInterval,
      failClosed = config.failClosed,
    },
    targets = {},
  }

  for _, t in ipairs(model.getTargets()) do
    table.insert(data.targets, {
      id = t.id,
      domain = t.domain,
      label = t.label,
      item = t.item,
      fluid = t.fluid,
      fluidAliases = t.fluidAliases,
      mode = t.mode,
      target = t.target,
      weight = t.weight,
      order = t.order,
      lowRatio = t.lowRatio,
      highRatio = t.highRatio,
      minDwell = t.minDwell,
      route = t.route,
      sourceRef = t.sourceRef,
    })
  end

  local ok, err = store.saveAtomic(data)
  if ok then
    app.configDirty = false
    app.lastSaveTime = now
  else
    log.error("main", "Failed to save config: " .. tostring(err))
  end
end

-- ========== Main loop ==========

local function mainLoop()
  log.info("main", "Entering main loop mode=" .. app.mode)

  while app.running do
    local now = computer.uptime()

    -- Hardware rescan
    if app.needRescan or now >= app.nextHardwareRescan then
      doHardwareScan()
      app.needRescan = false
      app.nextHardwareRescan = now + config.hardwareRescan
    end

    if app.needImport then
      local n = model.importFromMaintainers(app.hw.levelMaintainers, config.importProfile)
      app.needImport = false
      if n > 0 then
        app.configDirty = true
        ui.setLastAction("imported " .. n .. " targets")
        ui.markDirty()
      end
    end

    -- Inventory scan
    if now >= app.nextInventoryScan then
      doInventoryScan()
      app.nextInventoryScan = now + config.scanInterval
    end

    -- State derivation
    updateTargetStates()

    -- Scheduling
    if now >= app.nextSchedule then
      doSchedule()
      app.nextSchedule = now + config.scheduleTick
      ui.setNextSchedule(app.nextSchedule)
    end

    -- Advance the controller (non-blocking)
    if app.mode == "control" then
      controller.tick(now, config, app.hw)
    end

    -- Save configuration
    saveConfig()

    -- Render
    local fresh = app.mode == "simulate" or inventory.isFresh(now, config.maxSnapshotAge)
    ui.render(app.hw, config, now, model.getTargets(), fresh)

    -- Wait for events
    local timeout = math.max(0.05, math.min(0.25,
      math.min(app.nextInventoryScan, app.nextSchedule) - now))
    local ev = table.pack(event.pull(timeout))

    if ev.n > 0 then
      if ev[1] == "interrupted" then
        app.running = false
        log.info("main", "Received interrupted signal, exiting")
      else
        ui.dispatch(ev, app)
      end
    end
  end
end

-- ========== Cleanup ==========

local function cleanup()
  log.info("main", "Starting cleanup...")
  -- Stop all managed machines
  if app.hw and app.mode == "control" then
    controller.stopAll("shutdown")
  end
  -- Save configuration (throttling is ignored on exit)
  saveConfig(true)
  -- Restore the terminal
  ui.restore()
  -- Close the log
  log.close()
end

local function showCrashAndWait(err)
  local message = "SEUI crash:\n" .. tostring(err)
  local path = config.crashFile or "/home/seui-crash.log"
  local f = io.open(path, "w")
  if f then
    f:write(message, "\n")
    f:close()
  end
  io.stderr:write(message .. "\n\n")
  io.stderr:write("Crash report: " .. path .. "\n")
  io.stderr:write("Press any key or touch the screen to exit.\n")
  -- Don't let the error flash by for only a few frames: stay on the restored terminal until the user confirms.
  while true do
    local ok, name = pcall(event.pull)
    if not ok or name == "key_down" or name == "touch" or name == "interrupted" then
      break
    end
  end
end

-- ========== Entry point ==========

local function run()
  initLog()
  initStore()

  -- Load configuration
  loadOrCreateConfig()

  -- Simulate mode: inject fake data
  if app.mode == "simulate" then
    model.clear()
    injectSimulatedData()
  end

  -- Initialize UI
  initUI()

  -- Hardware scan
  if app.mode ~= "simulate" then
    doHardwareScan()
  else
    -- In simulate mode, create an empty hardware snapshot
    app.hw = { pumps = {}, miners = {}, levelMaintainers = {}, transposers = {},
               fluidInterface = nil, meInterface = nil, database = nil,
               gpu = component.gpu, screen = component.screen, paramBackend = "keyed" }
  end

  -- First inventory scan
  if app.mode ~= "simulate" then
    doInventoryScan()
  end

  app.nextInventoryScan = computer.uptime() + config.scanInterval
  app.nextSchedule = computer.uptime() + config.scheduleTick
  app.nextHardwareRescan = computer.uptime() + config.hardwareRescan

  -- Main loop (with crash protection)
  local ok, err = xpcall(mainLoop, debug.traceback)
  if not ok then
    log.fatal("main", "Crash: " .. tostring(err))
    local cleanupOK, cleanupErr = pcall(cleanup)
    if not cleanupOK then
      err = tostring(err) .. "\ncleanup failed: " .. tostring(cleanupErr)
    end
    showCrashAndWait(err)
    return
  end

  cleanup()
end

run()
