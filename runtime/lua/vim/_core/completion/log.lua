--- Internal log for the completion pipeline.
---
--- Ring buffer + level gating.  No file I/O.

local LOG_LEVELS = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }
local level = LOG_LEVELS.WARN

--- @type string[]
local ring = {}
local RING_SIZE = 200

--- @param lvl integer
--- @param fmt string
--- @param ... any
local function write(lvl, fmt, ...)
  if lvl < level then
    return
  end
  local msg = fmt:format(...)
  ring[#ring + 1] = msg
  if #ring > RING_SIZE then
    table.remove(ring, 1)
  end
end

local M = {}

for name, lvl in pairs(LOG_LEVELS) do
  M[name:lower()] = function(fmt, ...)
    write(lvl, fmt, ...)
  end
end

--- @param name 'trace'|'debug'|'info'|'warn'|'error'
function M.set_level(name)
  level = LOG_LEVELS[name:upper()] or LOG_LEVELS.WARN
end

--- @return string[]
function M.get()
  return vim.deepcopy(ring)
end

function M.clear()
  ring = {}
end

return M
