-- SEUI lib/ui.lua
-- 160x50 touch UI: three pages PUMP/MINER/SYSTEM + three-column target matrix + bottom action area

local component = require("component")
local unicode = require("unicode")
local computer = require("computer")
local term = require("term")
local format = require("lib.format")
local log = require("lib.log")
local model = require("lib.model")
local controller = require("lib.controller")
local inventory = require("lib.inventory")

local M = {}

-- ========== Layout constants ==========
local W = 160
local H = 50
local COL_X = {2, 54, 106}
local COL_W = 51
local ROWS_PER_COL = 14
local BAR_W = 47

-- ========== State ==========
local ui = {
  gpu = nil,
  screen = nil,
  page = "pump",      -- pump / miner / system
  selectedId = nil,
  pageOffset = 0,     -- page offset
  modal = nil,        -- Modal edit box
  hitboxGroups = { header = {}, targets = {}, actions = {} },
  activeHitboxGroup = "actions",
  dirty = { all = true, header = true, targets = true, details = true, actions = true, system = true },
  lastAction = "idle",
  nextSchedule = 0,
  scanning = false,
  stopAllConfirm = 0, -- STOP ALL confirmation timestamp
  savedFg = 0xffffff,
  savedBg = 0x000000,
  savedResolution = nil,
}

local STATE_ZH = {UNKNOWN="Unknown",OK="OK",LOW="Low",RUN="Running",WAIT="Waiting",OFF="Off",FAULT="Fault",STALE="Stale",READY="Ready"}
local MODE_ZH = {OFF="Off",TARGET="Target",ALWAYS="Always"}
local PHASE_ZH = {IDLE="Idle",REQUEST_STOP="Stop req.",WAIT_IDLE="Wait idle",PREPARE="Prepare",APPLY="Apply",VERIFY="Verify",START="Start",RUNNING="Running",REQUEST_END="End task",FAULT="Fault"}

-- ========== Colors ==========
local C = {
  bg       = 0x1a1a2e,
  fg       = 0xc0c0c0,
  header   = 0x00bfff,
  ok       = 0x00ff00,
  low      = 0xff4444,
  run      = 0x00ffff,
  wait     = 0xffff00,
  off      = 0x556677,
  fault    = 0xff8800,
  stale    = 0xcc00ff,
  bar_bg   = 0x333344,
  bar_fill = 0x00aa00,
  bar_full = 0x00ff00,
  bar_low  = 0xff4444,
  selected = 0x224466,
  button   = 0x2a2a4a,
  button_on= 0x3a5a8a,
  modal_bg = 0x0a0a1a,
  dim      = 0x666688,
}

-- ========== Initialization ==========
function M.init(gpu, screen, config)
  ui.gpu = gpu
  ui.screen = screen
  C = config and config.color or C

  -- Save the original terminal state
  ui.savedFg, _ = gpu.getForeground()
  ui.savedBg, _ = gpu.getBackground()
  ui.savedResolution = { gpu.getResolution() }

  -- Bind the screen
  if screen then
    gpu.bind(screen.address or component.screen.address)
    if screen.setTouchModeInverted then
      screen.setTouchModeInverted(true)
    end
    if screen.setPrecise then
      screen.setPrecise(false)
    end
  end

  gpu.setResolution(W, H)
  gpu.setDepth(8)
  gpu.setBackground(C.bg)
  gpu.setForeground(C.fg)
  gpu.fill(1, 1, W, H, " ")

  ui.dirty.all = true
  log.info("ui", "UI initialized " .. W .. "x" .. H .. "x8")
end

function M.restore()
  if not ui.gpu then return end
  local gpu = ui.gpu
  gpu.setBackground(ui.savedBg)
  gpu.setForeground(ui.savedFg)
  if ui.savedResolution then
    gpu.setResolution(ui.savedResolution[1], ui.savedResolution[2])
  end
  if ui.screen and ui.screen.setTouchModeInverted then
    ui.screen.setTouchModeInverted(false)
  end
  term.clear()
  log.info("ui", "Terminal restored")
end

-- ========== Drawing primitives ==========
local function setColors(fg, bg)
  ui.gpu.setForeground(fg or C.fg)
  ui.gpu.setBackground(bg or C.bg)
end

local function drawText(x, y, text, fg, bg)
  setColors(fg, bg)
  ui.gpu.set(x, y, text)
end

local function fillRect(x, y, w, h, char, fg, bg)
  setColors(fg, bg)
  ui.gpu.fill(x, y, w, h, char or " ")
end

local function drawButton(x, y, w, text, enabled, action, payload)
  local h = 1
  local label = format.fitCenter(text, w)
  local bg = enabled and C.button or C.off
  local fg = enabled and C.fg or C.dim
  fillRect(x, y, w, h, " ", fg, bg)
  drawText(x, y, label, fg, bg)
  if action then
    local group = ui.hitboxGroups[ui.activeHitboxGroup] or ui.hitboxGroups.actions
    group[#group + 1] = {
      x1 = x, y1 = y, x2 = x + w - 1, y2 = y + h - 1,
      page = ui.page, enabled = enabled,
      action = action, payload = payload,
    }
  end
end

-- Register a hit area
local function addHitbox(x, y, w, h, action, payload)
  local group = ui.hitboxGroups[ui.activeHitboxGroup] or ui.hitboxGroups.actions
  group[#group + 1] = {
    x1 = x, y1 = y, x2 = x + w - 1, y2 = y + h - 1,
    page = ui.page, enabled = true,
    action = action, payload = payload,
  }
end

-- ========== State colors ==========
local function stateColor(state)
  if state == "OK" then return C.ok
  elseif state == "LOW" then return C.low
  elseif state == "RUN" then return C.run
  elseif state == "WAIT" then return C.wait
  elseif state == "OFF" then return C.off
  elseif state == "FAULT" then return C.fault
  elseif state == "STALE" then return C.stale
  elseif state == "READY" then return C.dim
  else return C.fg
  end
end

-- ========== Drawing each region ==========

function M.renderHeader(hw, config, now)
  if not ui.dirty.header and not ui.dirty.all then return end
  ui.activeHitboxGroup = "header"
  ui.hitboxGroups.header = {}

  -- y=1: title + tabs
  local title = "Space Elevator Smart Console v1.0.6"
  fillRect(1, 1, W, 1, " ", C.header, C.bg)
  drawText(2, 1, title, C.header, C.bg)
  local tabX = W - 24
  drawButton(tabX,      1, 6, "Pump", true, "tab_pump")
  drawButton(tabX + 7,  1, 7, "Miner", true, "tab_miner")
  drawButton(tabX + 15, 1, 8, "System", true, "tab_system")
  local activeX, activeW, activeLabel
  if ui.page == "pump" then activeX, activeW, activeLabel = tabX, 6, "Pump"
  elseif ui.page == "miner" then activeX, activeW, activeLabel = tabX + 7, 7, "Miner"
  else activeX, activeW, activeLabel = tabX + 15, 8, "System" end
  fillRect(activeX, 1, activeW, 1, " ", C.header, C.button_on)
  drawText(activeX, 1, format.fitCenter(activeLabel, activeW), C.header, C.button_on)

  -- y=2: device counts + schedule countdown + ME time
  local snapshot = inventory.getSnapshot()
  local meTime = string.format("ME:%.2fs", snapshot.duration or 0)
  local nextS = math.max(0, math.floor((ui.nextSchedule or 0) - now))
  local pumpCount = #hw.pumps
  local minerCount = #hw.miners
  local runtimeMode = ({simulate="Simulate",readonly="Read-only",control="Control"})[config.runtimeMode] or tostring(config.runtimeMode or "?")
  local info = string.format("Mode:%s Pumps:%d Miners:%d Scan:%ds %s Next:%ds Mem:%dKB",
    runtimeMode, pumpCount, minerCount, config.scanInterval, meTime, nextS,
    math.floor(computer.freeMemory() / 1024))
  fillRect(1, 2, W, 1, " ", C.dim, C.bg)
  drawText(2, 2, info, C.dim, C.bg)

  -- y=3: last action + Refresh
  fillRect(1, 3, W, 1, " ", C.fg, C.bg)
  drawText(2, 3, "Action: " .. (ui.lastAction or "idle"), C.fg, C.bg)

  local refreshLabel = ui.scanning and "[Scanning]" or "[Refresh]"
  local refreshX = W - 30
  drawButton(refreshX - 10, 3, 9, "Import", true, "import_targets")
  drawButton(refreshX, 3, 12, refreshLabel, not ui.scanning, "refresh")
  drawButton(refreshX + 12, 3, 9, "[Rescan]", true, "rescan")
  drawButton(refreshX + 22, 3, 8, "[Stop]", true, "stop_all")

  -- y=4: separator
  fillRect(1, 4, W, 1, "-", C.dim, C.bg)

  ui.dirty.header = false
end

function M.renderTargets(targets, snapshotFresh, now, config)
  if not ui.dirty.targets and not ui.dirty.all then return end
  ui.activeHitboxGroup = "targets"
  ui.hitboxGroups.targets = {}

  local pageTargets = {}
  local maxItems = ROWS_PER_COL * 3  -- 42

  -- Filter the current domain
  for _, t in ipairs(targets) do
    if t.domain == ui.page or ui.page == "system" then
      table.insert(pageTargets, t)
    end
  end

  -- Paging
  local total = #pageTargets
  local startIdx = ui.pageOffset * maxItems + 1
  local endIdx = math.min(startIdx + maxItems - 1, total)

  -- Clear the target area
  fillRect(1, 5, W, 28, " ", C.fg, C.bg)

  -- Draw each target
  for i = startIdx, endIdx do
    local t = pageTargets[i]
    if not t then break end

    local idx = i - startIdx + 1
    local x, y = format.intDiv(idx - 1, ROWS_PER_COL), (idx - 1) % ROWS_PER_COL
    x = COL_X[x + 1] or COL_X[1]
    y = 5 + y * 2

    -- First row: index, label, mode, amount, weight, state
    local isSelected = (ui.selectedId == t.id)
    local state = t.runtime.state or "UNKNOWN"
    local sc = stateColor(state)
    local modeChar = t.mode == "TARGET" and "T" or (t.mode == "ALWAYS" and "A" or "O")
    local amtStr = format.formatAmount(t.current) .. "/" .. format.formatAmount(t.target)
    local wStr = string.format("w%+d", t.weight or 0)

    local line1 = string.format("%02d %s %s %s %s",
      idx, format.fit(t.label, 18), modeChar, format.fit(amtStr, 22), wStr)
    line1 = format.fit(line1, COL_W - 8) .. string.format(" %-6s", STATE_ZH[state] or state)

    local bg = isSelected and C.selected or C.bg
    local fg = sc
    fillRect(x, y, COL_W, 1, " ", fg, bg)
    drawText(x, y, line1, fg, bg)

    -- Click to select
    addHitbox(x, y, COL_W, 1, "select", { id = t.id })

    -- Second row: progress bar
    local ratio = 0
    if t.target > 0 then
      ratio = math.min(1, math.max(0, (t.current + t.pending) / t.target))
    end
    local filled = math.floor(ratio * BAR_W + 0.5)
    local barColor = ratio >= 0.9 and C.bar_full or (ratio >= 0.5 and C.bar_fill or C.bar_low)

    fillRect(x, y + 1, BAR_W, 1, " ", C.fg, C.bar_bg)
    if filled > 0 then
      fillRect(x, y + 1, filled, 1, " ", C.fg, barColor)
    end

    -- Percentage text overlay
    local pctStr = string.format("%3d%%", math.floor(ratio * 100))
    drawText(x + BAR_W - 4, y + 1, pctStr, C.fg, barColor)
  end

  -- y=33: paging info
  local pages = math.max(1, math.ceil(total / maxItems))
  local pageStr = string.format("Page %d/%d  %d items (mouse wheel or PgUp/PgDn)",
    ui.pageOffset + 1, pages, total)
  fillRect(1, 33, W, 1, " ", C.dim, C.bg)
  drawText(2, 33, pageStr, C.dim, C.bg)

  -- Prev/Next buttons
  if pages > 1 then
    drawButton(W - 22, 33, 7, "[Prev]", ui.pageOffset > 0, "prev_page")
    drawButton(W - 14, 33, 7, "[Next]", ui.pageOffset < pages - 1, "next_page")
  end

  ui.dirty.targets = false
end

function M.renderDetails(targets, now)
  if not ui.dirty.details and not ui.dirty.all then return end

  fillRect(1, 34, W, 3, " ", C.fg, C.bg)

  local t = ui.selectedId and model.getById(ui.selectedId) or nil
  if not t then
    drawText(2, 35, "(No target selected - click one in the list for details)", C.dim, C.bg)
    ui.dirty.details = false
    return
  end

  local state = t.runtime.state or "UNKNOWN"
  local sc = stateColor(state)
  local ratio = model.getRatio(t)

  -- y=34: title row
  drawText(2, 34, format.fit(t.label, 30), C.header, C.bg)
  drawText(33, 34, string.format("ID:%s  Mode:%s  Weight:%+d  %s",
    t.id, MODE_ZH[t.mode] or t.mode, t.weight or 0, STATE_ZH[state] or state), sc, C.bg)

  -- y=35: amount details
  drawText(2, 35, string.format("Current:%s  Target:%s  Pending:%s  Ratio:%.1f%%",
    format.formatAmount(t.current), format.formatAmount(t.target),
    format.formatAmount(t.pending), ratio * 100), C.fg, C.bg)

  -- y=36: route parameters
  if t.domain == "pump" then
    drawText(2, 36, string.format("Planet type:%s  Gas type:%s  Batch:%s  Base rate:%s L/s",
      tostring(t.route.planetType or "?"),
      tostring(t.route.gasType or "?"),
      tostring(t.route.maxBatch or "?"), format.formatAmount(t.route.baseRate or 0)), C.dim, C.bg)
  else
    drawText(2, 36, string.format("drone:%s  dist:%s  parallel:%s",
      tostring(t.route.droneTier or "?"),
      tostring(t.route.distance or "?"),
      tostring(t.route.parallel or "auto")), C.dim, C.bg)
  end

  ui.dirty.details = false
end

function M.renderActions(config)
  if not ui.dirty.actions and not ui.dirty.all then return end
  ui.activeHitboxGroup = "actions"
  ui.hitboxGroups.actions = {}

  fillRect(1, 37, W, 14, " ", C.fg, C.bg)

  if ui.page == "system" then
    M.renderSystemPage(config)
    ui.dirty.actions = false
    return
  end

  -- ===== Action buttons =====
  local y = 37

  drawText(2, y, "Priority", C.dim, C.bg)
  drawButton(12, y, 5, "[Top]", true, "priority", { dir = "top" })
  drawButton(18, y, 5, "[Up]",  true, "priority", { dir = "up" })
  drawButton(24, y, 7, "[Down]", true, "priority", { dir = "down" })
  drawButton(32, y, 8, "[Bottom]", true, "priority", { dir = "bottom" })

  -- MODE
  y = y + 2
  drawText(2, y, "Mode", C.dim, C.bg)
  drawButton(12, y, 6, "[Off]", true, "mode", { mode = "OFF" })
  drawButton(19, y, 9, "[Target]", true, "mode", { mode = "TARGET" })
  drawButton(29, y, 8, "[Always]", true, "mode", { mode = "ALWAYS" })

  -- VALUE
  drawText(40, y, "Target", C.dim, C.bg)
  drawButton(47, y, 7, "[Cur]", true, "set_current")
  drawButton(55, y, 7, "[Edit]", true, "edit_value")

  -- WEIGHT
  drawText(65, y, "Weight", C.dim, C.bg)
  drawButton(73, y, 5, "[-10]", true, "weight", { delta = -10 })
  drawButton(79, y, 5, "[-5]",  true, "weight", { delta = -5 })
  drawButton(85, y, 5, "[-1]",  true, "weight", { delta = -1 })
  drawButton(91, y, 5, "[+1]",  true, "weight", { delta = 1 })
  drawButton(97, y, 5, "[+5]",  true, "weight", { delta = 5 })
  drawButton(103, y, 6, "[+10]", true, "weight", { delta = 10 })

  local selected = ui.selectedId and model.getById(ui.selectedId) or nil
  if selected and selected.domain == "pump" then
    drawButton(112, y, 10, "[Planet]", true, "edit_route", { field = "planetType" })
    drawButton(123, y, 8, "[Gas]", true, "edit_route", { field = "gasType" })
  elseif selected and selected.domain == "miner" then
    drawButton(112, y, 10, "[DRONE]", true, "edit_route", { field = "droneTier" })
    drawButton(123, y, 10, "[DIST]", true, "edit_route", { field = "distance" })
  end

  -- Quick target value presets
  y = y + 2
  local presets = {
    { label = "=10M",  val = 1e7 },
    { label = "=50M",  val = 5e7 },
    { label = "=100M", val = 1e8 },
    { label = "=500M", val = 5e8 },
    { label = "=1G",   val = 1e9 },
    { label = "=5G",   val = 5e9 },
    { label = "=10G",  val = 1e10 },
    { label = "=50G",  val = 5e10 },
    { label = "=100G", val = 1e11 },
    { label = "=500G", val = 5e11 },
    { label = "=1T",   val = 1e12 },
    { label = "=500T", val = 5e14 },
  }
  for i, p in ipairs(presets) do
    local x = 2 + (i - 1) * 13
    if x + 12 > W then break end
    drawButton(x, y, 11, "[" .. p.label .. "]", true, "set_target", { val = p.val })
  end

  -- Increase
  y = y + 1
  local adds = {
    { label = "+10M",  val = 1e7 },  { label = "+50M",  val = 5e7 },
    { label = "+100M", val = 1e8 },  { label = "+500M", val = 5e8 },
    { label = "+1G",   val = 1e9 },  { label = "+5G",   val = 5e9 },
    { label = "+10G",  val = 1e10 }, { label = "+50G",  val = 5e10 },
    { label = "+100G", val = 1e11 }, { label = "+500G", val = 5e11 },
    { label = "+1T",   val = 1e12 }, { label = "+500T", val = 5e14 },
  }
  for i, p in ipairs(adds) do
    local x = 2 + (i - 1) * 13
    if x + 12 > W then break end
    drawButton(x, y, 11, "[" .. p.label .. "]", true, "add_target", { val = p.val })
  end

  -- Decrease
  y = y + 1
  local subs = {
    { label = "-10M",  val = 1e7 },  { label = "-50M",  val = 5e7 },
    { label = "-100M", val = 1e8 },  { label = "-500M", val = 5e8 },
    { label = "-1G",   val = 1e9 },  { label = "-5G",   val = 5e9 },
    { label = "-10G",  val = 1e10 }, { label = "-50G",  val = 5e10 },
    { label = "-100G", val = 1e11 }, { label = "-500G", val = 5e11 },
    { label = "-1T",   val = 1e12 }, { label = "-500T", val = 5e14 },
  }
  for i, p in ipairs(subs) do
    local x = 2 + (i - 1) * 13
    if x + 12 > W then break end
    drawButton(x, y, 11, "[" .. p.label .. "]", true, "sub_target", { val = p.val })
  end

  -- STOP ALL confirmation
  if ui.stopAllConfirm > 0 and computer.uptime() < ui.stopAllConfirm then
    drawButton(W - 20, y - 3, 18, "[CONFIRM STOP?]", true, "stop_all_confirm")
  end

  ui.dirty.actions = false
end

function M.renderSystemPage(config)
  local hw = require("lib.discovery").getHardware()
  local snap = inventory.getSnapshot()
  local ws = controller.status()

  local y = 37

  -- Component health
  drawText(2, y, "=== Component health ===", C.header, C.bg)
  y = y + 1

  local lines = {
    string.format("GPU:        %s  Screen: %s", tostring(ui.gpu ~= nil), tostring(ui.screen ~= nil)),
    string.format("fluid_if:   %s  me_if:  %s",
      tostring(hw.fluidInterface ~= nil), tostring(hw.meInterface ~= nil)),
    string.format("pumps: %d  miners: %d  maintainers: %d  transposers: %d",
      #hw.pumps, #hw.miners, #hw.levelMaintainers, #hw.transposers),
    string.format("param backend: %s", hw.paramBackend or "unknown"),
    string.format("snapshot: %s  age: %.1fs  duration: %.3fs",
      snap.error and "ERROR" or "OK",
      computer.uptime() - (snap.timestamp or 0),
      snap.duration or 0),
  }

  if snap.error then
    table.insert(lines, "snapshot error: " .. snap.error)
  end

  -- Component budget: the OC CPU has a cap on network components (T1=8 T2=12 T3=16).
  -- Near the cap, newly attached pumps/miners "disappear" from component.list; this is a hardware-level limit, not a program bug.
  local okCount, compCount = pcall(computer.componentCount)
  if okCount and type(compCount) == "number" then
    table.insert(lines, string.format(
      "components: %d  (CPU limit: T1=8 T2=12 T3=16; exceeding it shuts the computer down)", compCount))
  end

  for _, line in ipairs(lines) do
    drawText(2, y, format.fit(line, 78), C.fg, C.bg)
    y = y + 1
  end

  -- Machine status (right side)
  local my = 37
  drawText(80, my, "=== Machine status ===", C.header, C.bg)
  my = my + 1

  -- Sort by address so the list stays stable with many machines; there is no fixed machine limit, the right column is filled down to the bottom of the screen.
  local machines = {}
  for addr, w in pairs(ws) do
    machines[#machines + 1] = { address = addr, worker = w }
  end
  table.sort(machines, function(a, b) return a.address < b.address end)

  local hidden = 0
  for _, m in ipairs(machines) do
    local addr, w = m.address, m.worker
    local rows = w.lastError and 2 or 1
    if my + rows - 1 > H then
      hidden = hidden + 1
    else
      local short = addr:sub(1, 8)
      local line = string.format("%s  %-12s  %s",
        short, w.phase, w.servingTarget and w.servingTarget:sub(1, 20) or "-")
      drawText(80, my, format.fit(line, 78), stateColor(w.phase == "FAULT" and "FAULT" or "RUN"), C.bg)
      if w.phase == "FAULT" then
        addHitbox(80, my, 78, 1, "retry_worker", { address = addr })
      end
      if w.lastError then
        my = my + 1
        drawText(80, my, "  err: " .. format.fit(w.lastError, 72), C.fault, C.bg)
      end
      my = my + 1
    end
  end
  if hidden > 0 and my <= H then
    drawText(80, my, string.format("  ... %d more machines not shown (screen height limit)", hidden), C.dim, C.bg)
    my = my + 1
  end

  -- Log (bottom)
  y = math.max(y, my) + 1
  if y <= H then
    drawText(2, y, "=== Recent log ===", C.header, C.bg)
    y = y + 1
  end

  local entries = log.getRecent(8)
  for _, entry in ipairs(entries) do
    if y <= H then
      drawText(2, y, format.fit(entry, W - 2), C.dim, C.bg)
      y = y + 1
    end
  end
end

-- ========== Modal edit box ==========
function M.openNumberModal(title, initialText, onSubmit)
  ui.modal = {
    kind = "number",
    title = title,
    text = tostring(initialText or ""),
    cursor = #(tostring(initialText or "")) + 1,
    onSubmit = onSubmit,
    error = nil,
  }
  ui.dirty.all = true
end

function M.renderModal()
  if not ui.modal then return end

  -- Modal box: centered 40x6
  local mw, mh = 50, 7
  local mx = math.floor((W - mw) / 2) + 1
  local my = math.floor((H - mh) / 2) + 1

  -- Background
  fillRect(mx, my, mw, mh, " ", C.fg, C.modal_bg)

  -- Border
  drawText(mx, my, "+" .. string.rep("-", mw - 2) .. "+", C.header, C.modal_bg)
  drawText(mx, my + mh - 1, "+" .. string.rep("-", mw - 2) .. "+", C.header, C.modal_bg)
  for y = my + 1, my + mh - 2 do
    drawText(mx, y, "|", C.header, C.modal_bg)
    drawText(mx + mw - 1, y, "|", C.header, C.modal_bg)
  end

  -- Title
  drawText(mx + 2, my + 1, format.fit(ui.modal.title, mw - 4), C.header, C.modal_bg)

  -- Input box
  local inputY = my + 3
  fillRect(mx + 2, inputY, mw - 4, 1, " ", C.fg, C.bg)
  drawText(mx + 2, inputY, ui.modal.text, C.fg, C.bg)
  -- Draw the cursor position with inverted colors
  if ui.modal.cursor and ui.modal.cursor <= #ui.modal.text then
    local before = ui.modal.text:sub(1, ui.modal.cursor - 1)
    local char = ui.modal.text:sub(ui.modal.cursor, ui.modal.cursor)
    if char and #char > 0 then
      drawText(mx + 2 + #before, inputY, char, C.bg, C.fg)
    end
  end

  -- Error
  if ui.modal.error then
    drawText(mx + 2, inputY + 1, format.fit(ui.modal.error, mw - 4), C.fault, C.modal_bg)
  end

  -- Hint
  drawText(mx + 2, my + mh - 2, "Enter=Submit  Esc=Cancel  Backspace=Del", C.dim, C.modal_bg)
end

function M.closeModal()
  ui.modal = nil
  ui.dirty.all = true
end

-- ========== Main render ==========
function M.render(hw, config, now, targets, snapshotFresh)
  if ui.dirty.all then
    fillRect(1, 1, W, H, " ", C.fg, C.bg)
    ui.dirty.all = false
    ui.dirty.header = true
    ui.dirty.targets = true
    ui.dirty.details = true
    ui.dirty.actions = true
  end

  M.renderHeader(hw, config, now)
  M.renderTargets(targets, snapshotFresh, now, config)
  M.renderDetails(targets, now)
  M.renderActions(config)
  M.renderModal()
end

function M.markDirty()
  ui.dirty.all = true
  ui.dirty.header = true
  ui.dirty.targets = true
  ui.dirty.details = true
  ui.dirty.actions = true
end

-- ========== Event dispatch ==========
function M.dispatch(ev, app)
  local name = ev[1]
  if not name then return end

  if name == "touch" then
    if ui.screen and ui.screen.address and ev[2] ~= ui.screen.address then return end
    M.handleTouch(ev[3], ev[4], ev[5], ev[6], app)
  elseif name == "scroll" then
    if ui.screen and ui.screen.address and ev[2] ~= ui.screen.address then return end
    M.handleScroll(ev[3], ev[4], ev[5], app)
  elseif name == "key_down" then
    M.handleKeyDown(ev[3], ev[4], ev[6], app)
  elseif name == "clipboard" then
    M.handleClipboard(ev[3], app)
  elseif name == "component_added" or name == "component_removed"
      or name == "component_available" or name == "component_unavailable" then
    -- Hardware change marks a rescan
    app.needRescan = true
  end
end

function M.handleTouch(x, y, button, username, app)
  -- Modal box takes priority
  if ui.modal then
    -- Clicking outside the modal = cancel
    -- Simplified here: the modal can only be used with the keyboard
    return
  end

  -- Higher layers first: actions > targets > header.
  for _, groupName in ipairs({"actions", "targets", "header"}) do
    local group = ui.hitboxGroups[groupName] or {}
    for i = #group, 1, -1 do
      local hb = group[i]
      if hb.page == ui.page or hb.page == nil then
        if x >= hb.x1 and x <= hb.x2 and y >= hb.y1 and y <= hb.y2 then
          if not hb.enabled then return end
          M.handleAction(hb.action, hb.payload, button, username, app)
          return
        end
      end
    end
  end
end

function M.handleScroll(x, y, direction, app)
  if direction > 0 then
    -- Scroll up = previous page
    if ui.pageOffset > 0 then
      ui.pageOffset = ui.pageOffset - 1
      ui.dirty.targets = true
    end
  else
    -- Scroll down = next page
    local targets = model.getByDomain(ui.page)
    local maxItems = ROWS_PER_COL * 3
    local pages = math.max(1, math.ceil(#targets / maxItems))
    if ui.pageOffset < pages - 1 then
      ui.pageOffset = ui.pageOffset + 1
      ui.dirty.targets = true
    end
  end
end

function M.handleKeyDown(char, code, username, app)
  local typed = ""
  if type(char) == "number" and char > 0 then
    local ok, value = pcall(unicode.char, char)
    if ok then typed = value end
  elseif type(char) == "string" then
    typed = char
  end
  if ui.modal then
    -- Modal input
    if code == 28 then -- Enter
      local val, err = format.parseSize(ui.modal.text)
      if not val then
        ui.modal.error = err or "parse error"
        ui.dirty.all = true
        return
      end
      if ui.modal.onSubmit then
        ui.modal.onSubmit(val)
      end
      M.closeModal()
    elseif code == 1 then -- Esc
      M.closeModal()
    elseif code == 14 then -- Backspace
      if #ui.modal.text > 0 then
        ui.modal.text = ui.modal.text:sub(1, #ui.modal.text - 1)
        ui.modal.cursor = #ui.modal.text + 1
        ui.modal.error = nil
        ui.dirty.all = true
      end
    else
      -- Ordinary characters
      if typed ~= "" and string.byte(typed) and string.byte(typed) >= 32 then
        ui.modal.text = ui.modal.text .. typed
        ui.modal.cursor = #ui.modal.text + 1
        ui.modal.error = nil
        ui.dirty.all = true
      end
    end
    return
  end

  -- With a target selected, typing a digit directly opens the target-amount input box; no need to click "Edit" first.
  if ui.selectedId and typed:match("^[0-9%.]$") then
    M.openNumberModal("Type target amount directly (M/G/T supported)", typed, function(val)
      local t = model.getById(ui.selectedId)
      if t then
        t.target = val
        if t.mode == "OFF" and val > 0 then t.mode = "TARGET" end
        app.configDirty = true
        ui.lastAction = "target=" .. format.formatAmount(val)
      end
    end)
    return
  end

  -- Non-modal shortcuts (with no target selected, 1/2/3 switch pages)
  if code == 2 then -- key 1 = PUMP
    ui.page = "pump"
    ui.pageOffset = 0
    M.markDirty()
  elseif code == 3 then -- key 2 = MINER
    ui.page = "miner"
    ui.pageOffset = 0
    M.markDirty()
  elseif code == 4 then -- key 3 = SYSTEM
    ui.page = "system"
    M.markDirty()
  end
end

function M.handleClipboard(text, app)
  if ui.modal and text then
    ui.modal.text = ui.modal.text .. text
    ui.modal.cursor = #ui.modal.text + 1
    ui.modal.error = nil
    ui.dirty.all = true
  end
end

-- ========== Action handling ==========
function M.handleAction(action, payload, button, username, app)
  -- Permission check
  if app.config.authorizedUsers then
    local authorized = false
    if username then
      for _, u in ipairs(app.config.authorizedUsers) do
        if u == username then authorized = true break end
      end
    end
    if not authorized then
      log.warn("ui", "Unauthorized user: " .. tostring(username))
      return
    end
  end

  if action == "tab_pump" then
    ui.page = "pump"
    ui.pageOffset = 0
    app.configDirty = true
    M.markDirty()

  elseif action == "tab_miner" then
    ui.page = "miner"
    ui.pageOffset = 0
    app.configDirty = true
    M.markDirty()

  elseif action == "tab_system" then
    ui.page = "system"
    app.configDirty = true
    M.markDirty()

  elseif action == "refresh" then
    app.nextInventoryScan = 0  -- trigger a scan immediately
    ui.lastAction = "refresh requested"

  elseif action == "import_targets" then
    app.needImport = true
    ui.lastAction = "level maintainer import requested"

  elseif action == "rescan" then
    app.needRescan = true
    ui.lastAction = "rescan requested"

  elseif action == "stop_all" then
    -- second confirmation
    local now = computer.uptime()
    if ui.stopAllConfirm > 0 and now < ui.stopAllConfirm then
      controller.stopAll("user requested")
      ui.stopAllConfirm = 0
      ui.lastAction = "STOP ALL executed"
    else
      ui.stopAllConfirm = now + (app.config.stopAllConfirmTime or 3)
      ui.lastAction = "STOP ALL armed (click again to confirm)"
    end
    M.markDirty()

  elseif action == "stop_all_confirm" then
    controller.stopAll("user confirmed")
    ui.stopAllConfirm = 0
    ui.lastAction = "STOP ALL confirmed"
    M.markDirty()

  elseif action == "retry_worker" then
    if payload and payload.address and controller.retry(payload.address) then
      ui.lastAction = "retry " .. payload.address:sub(1, 8)
      M.markDirty()
    end

  elseif action == "select" then
    ui.selectedId = payload.id
    ui.dirty.details = true
    ui.dirty.targets = true
    app.configDirty = true

  elseif action == "priority" then
    if ui.selectedId then
      model.moveOrder(ui.selectedId, payload.dir)
      ui.dirty.targets = true
      ui.dirty.details = true
      ui.lastAction = "priority " .. payload.dir
      app.configDirty = true
    end

  elseif action == "mode" then
    if ui.selectedId then
      local t = model.getById(ui.selectedId)
      if t then
        t.mode = payload.mode
        ui.dirty.targets = true
        ui.dirty.details = true
        ui.lastAction = "mode=" .. payload.mode .. " for " .. t.id
        app.configDirty = true
      end
    end

  elseif action == "set_current" then
    if ui.selectedId then
      local t = model.getById(ui.selectedId)
      if t then
        t.target = t.current
        ui.dirty.targets = true
        ui.dirty.details = true
        ui.lastAction = "target set to current: " .. format.formatAmount(t.target)
        app.configDirty = true
      end
    end

  elseif action == "edit_value" then
    if ui.selectedId then
      local t = model.getById(ui.selectedId)
      if t then
        M.openNumberModal("Target value (e.g. 10M, 1.5G, 500T)", tostring(math.floor(t.target)),
          function(val)
            t.target = val
            ui.dirty.targets = true
            ui.dirty.details = true
            ui.lastAction = "target edited: " .. format.formatAmount(val)
            app.configDirty = true
          end)
      end
    end

  elseif action == "weight" then
    if ui.selectedId then
      local t = model.getById(ui.selectedId)
      if t then
        t.weight = (t.weight or 0) + payload.delta
        ui.dirty.details = true
        ui.dirty.targets = true
        ui.lastAction = "weight " .. (payload.delta >= 0 and "+" or "") .. payload.delta
        app.configDirty = true
      end
    end

  elseif action == "edit_route" then
    if ui.selectedId then
      local t = model.getById(ui.selectedId)
      if t and payload and payload.field then
        local field = payload.field
        M.openNumberModal("Route parameter: " .. field, tostring(t.route[field] or 0), function(val)
          t.route[field] = math.floor(val)
          ui.dirty.targets = true
          ui.dirty.details = true
          ui.lastAction = field .. "=" .. tostring(math.floor(val))
          app.configDirty = true
        end)
      end
    end

  elseif action == "set_target" then
    if ui.selectedId then
      local t = model.getById(ui.selectedId)
      if t then
        t.target = payload.val
        ui.dirty.targets = true
        ui.dirty.details = true
        ui.lastAction = "target = " .. format.formatAmount(payload.val)
        app.configDirty = true
      end
    end

  elseif action == "add_target" then
    if ui.selectedId then
      local t = model.getById(ui.selectedId)
      if t then
        t.target = math.max(0, (t.target or 0) + payload.val)
        ui.dirty.targets = true
        ui.dirty.details = true
        ui.lastAction = "target += " .. format.formatAmount(payload.val)
        app.configDirty = true
      end
    end

  elseif action == "sub_target" then
    if ui.selectedId then
      local t = model.getById(ui.selectedId)
      if t then
        t.target = math.max(0, (t.target or 0) - payload.val)
        ui.dirty.targets = true
        ui.dirty.details = true
        ui.lastAction = "target -= " .. format.formatAmount(payload.val)
        app.configDirty = true
      end
    end

  elseif action == "prev_page" then
    if ui.pageOffset > 0 then
      ui.pageOffset = ui.pageOffset - 1
      ui.dirty.targets = true
    end

  elseif action == "next_page" then
    local targets = model.getByDomain(ui.page)
    local maxItems = ROWS_PER_COL * 3
    local pages = math.max(1, math.ceil(#targets / maxItems))
    if ui.pageOffset < pages - 1 then
      ui.pageOffset = ui.pageOffset + 1
      ui.dirty.targets = true
    end
  end
end

function M.setNextSchedule(t)
  ui.nextSchedule = t
  ui.dirty.header = true
end

function M.setScanning(s)
  ui.scanning = s
  ui.dirty.header = true
end

function M.setLastAction(s)
  ui.lastAction = s
  ui.dirty.header = true
end

function M.getState()
  return {
    page = ui.page,
    selectedId = ui.selectedId,
    pageOffset = ui.pageOffset,
  }
end

function M.setState(state)
  state = state or {}
  if state.page == "pump" or state.page == "miner" or state.page == "system" then
    ui.page = state.page
  end
  ui.selectedId = state.selectedId
  ui.pageOffset = tonumber(state.pageOffset) or 0
  M.markDirty()
end

return M
