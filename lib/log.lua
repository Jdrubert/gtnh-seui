-- SEUI lib/log.lua
-- Log rotation and UI log buffer

local fs = require("filesystem")
local computer = require("computer")

local M = {}

local LOG_MAX = 65536
local LOG_KEEP = 3
local LOG_FILE = "/var/log/seui.log"
local UI_BUFFER_MAX = 50

local entries = {}     -- UI log buffer
local file = nil
local filePath = LOG_FILE
local bytesWritten = 0

function M.init(path, maxSize, keep)
  filePath = path or filePath
  LOG_MAX = maxSize or LOG_MAX
  LOG_KEEP = keep or LOG_KEEP
  -- Make sure the directory exists
  local dir = fs.path(filePath)
  if dir and not fs.exists(dir) then
    fs.makeDirectory(dir)
  end
  file = io.open(filePath, "a")
  bytesWritten = 0
  if file then
    file:seek("end")
    bytesWritten = file:seek("end")
  end
end

local function rotate()
  if file then file:close() file = nil end
  for i = LOG_KEEP - 1, 1, -1 do
    local oldName = filePath .. "." .. i
    local newName = filePath .. "." .. (i + 1)
    if fs.exists(oldName) then
      if fs.exists(newName) then fs.remove(newName) end
      fs.rename(oldName, newName)
    end
  end
  if fs.exists(filePath) then
    fs.rename(filePath, filePath .. ".1")
  end
  file = io.open(filePath, "a")
  bytesWritten = 0
end

local function write(level, domain, msg)
  local ts = os.date("%H:%M:%S")
  local line = string.format("[%s] %s/%s: %s", ts, domain or "?", level, msg)

  -- UI buffer
  table.insert(entries, line)
  if #entries > UI_BUFFER_MAX then
    table.remove(entries, 1)
  end

  -- File
  if file then
    file:write(line .. "\n")
    file:flush()
    bytesWritten = bytesWritten + #line + 1
    if bytesWritten >= LOG_MAX then
      rotate()
    end
  end
end

function M.info(domain, msg)    write("INFO",  domain, msg) end
function M.warn(domain, msg)    write("WARN",  domain, msg) end
function M.error(domain, msg)   write("ERROR", domain, msg) end
function M.fatal(domain, msg)   write("FATAL", domain, msg) end

function M.getEntries() return entries end
function M.getRecent(n)
  local start = math.max(1, #entries - n + 1)
  local result = {}
  for i = start, #entries do
    table.insert(result, entries[i])
  end
  return result
end

function M.close()
  if file then file:close() file = nil end
end

return M
