local api = vim.api
local lsp = vim.lsp

local M = {}

--- @class vim.lsp.mouse.Opts
--- @field delay integer Debounce delay in milliseconds. (default: `500`)
--- @field close_events vim.api.keyset.events[] Autocmd events that dismiss the float. (default: `InsertEnter`, `CursorMoved`, `BufLeave`, `WinLeave`, `WinScrolled`)

local _augroup = api.nvim_create_augroup('nvim.lsp.mouse', { clear = true })
local _enabled = false

--- @type table<string, table|false>
local _saved_maps = {}

--- @type { timer: uv.uv_timer_t?, winid: integer?, bufnr: integer? }
local state = {}

--- @type vim.lsp.mouse.Opts
local config = {
  delay = 500,
  close_events = { 'InsertEnter', 'CursorMoved', 'BufLeave', 'WinLeave', 'WinScrolled' },
}

local function close_float()
  local winid = state.winid or (state.bufnr and vim.b[state.bufnr].lsp_floating_preview)
  if winid and api.nvim_win_is_valid(winid) then
    api.nvim_win_close(winid, true)
  end
  state.winid = nil
  state.bufnr = nil
end

local function cancel()
  if state.timer then
    if state.timer:is_active() then
      state.timer:stop()
    end
    if not state.timer:is_closing() then
      state.timer:close()
    end
    state.timer = nil
  end
end

local function reset()
  cancel()
  close_float()
end

local function same_mouse_pos(a, b)
  return a.winid == b.winid and a.line == b.line and a.column == b.column
end

---@param mpos vim.fn.getmousepos.ret
local function try_show(mpos)
  if
    not api.nvim_win_is_valid(mpos.winid) or api.nvim_win_get_config(mpos.winid).relative ~= ''
  then
    return
  end

  local bufnr = api.nvim_win_get_buf(mpos.winid)
  local row = mpos.line - 1
  local col = math.max(0, mpos.column - 1)
  close_float()

  if #vim.diagnostic.get(bufnr, { lnum = row }) > 0 then
    local _, winid = vim.diagnostic.open_float({
      bufnr = bufnr,
      pos = { row, col },
      scope = 'cursor',
      relative = 'mouse',
      focusable = false,
      close_events = config.close_events,
    })
    if winid then
      state.winid = winid
      return
    end
  end

  if #lsp.get_clients({ bufnr = bufnr, method = 'textDocument/hover' }) == 0 then
    return
  end

  state.bufnr = bufnr
  lsp.buf.hover({
    silent = true,
    relative = 'mouse',
    close_events = config.close_events,
    param = function(client)
      local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
      return {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = {
          line = row,
          character = vim.str_utfindex(line, client.offset_encoding, math.min(col, #line), false),
        },
      }
    end,
    should_display = function()
      return same_mouse_pos(vim.fn.getmousepos(), mpos)
    end,
  })
end

local function on_mouse_move()
  reset()
  local mpos = vim.fn.getmousepos()
  if mpos.winid == 0 or mpos.line == 0 then
    return
  end
  if
    not api.nvim_win_is_valid(mpos.winid) or api.nvim_win_get_config(mpos.winid).relative ~= ''
  then
    return
  end

  local bufnr = api.nvim_win_get_buf(mpos.winid)
  local row = mpos.line - 1
  local col = math.max(0, mpos.column - 1)

  local has_diag = #vim.diagnostic.get(bufnr, { lnum = row }) > 0
  if not has_diag then
    local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
    if col >= #line or vim.fn.match(line:sub(col + 1, col + 1), '\\k') == -1 then
      return
    end
  end

  state.timer = vim.defer_fn(function()
    state.timer = nil
    if not same_mouse_pos(vim.fn.getmousepos(), mpos) then
      return
    end
    try_show(mpos)
  end, config.delay)
end

local function feed_saved(mode)
  local saved = _saved_maps[mode]
  if not saved then
    return
  end
  if saved.callback then
    saved.callback()
    return
  end
  if not saved.rhs or saved.rhs == '' then
    return
  end
  local keys = saved.expr == 1 and api.nvim_eval(saved.rhs)
    or api.nvim_replace_termcodes(saved.rhs, true, false, true)
  api.nvim_feedkeys(keys, 'n', false)
end

local function save_maps()
  for _, mode in ipairs({ 'n', 'v' }) do
    local m = vim.fn.maparg('<MouseMove>', mode, false, true)
    _saved_maps[mode] = (m and m.lhs ~= nil and m.lhs ~= '') and m or false
  end
end

local function restore_maps()
  for mode, saved in pairs(_saved_maps) do
    if saved then
      vim.fn.mapset(saved)
    else
      pcall(vim.keymap.del, mode, '<MouseMove>')
    end
  end
  _saved_maps = {}
end

--- Enable or disable LSP mouse hover and diagnostic popups.
---
--- Requires 'mousemoveevent' to be set:
--- ```lua
--- vim.o.mousemoveevent = true
--- ```
---
--- @param enabled? boolean
--- @param opts? vim.lsp.mouse.Opts
function M.enable(enabled, opts)
  if enabled == nil then
    enabled = true
  end
  vim.validate('enabled', enabled, 'boolean')
  vim.validate('opts', opts, 'table', true)
  if opts then
    config = vim.tbl_extend('force', config, opts)
  end

  reset()
  _enabled = false
  api.nvim_clear_autocmds({ group = _augroup })
  restore_maps()

  if not enabled then
    return
  end

  if not vim.o.mousemoveevent then
    vim.notify("vim.lsp.mouse: requires 'mousemoveevent'.", vim.log.levels.WARN)
    return
  end

  save_maps()

  vim.keymap.set({ 'n', 'v' }, '<MouseMove>', function()
    on_mouse_move()
    feed_saved(api.nvim_get_mode().mode:sub(1, 1))
  end, { silent = true, desc = 'vim.lsp.mouse: hover/diagnostic on mouse move' })

  if #config.close_events > 0 then
    api.nvim_create_autocmd(config.close_events, {
      group = _augroup,
      callback = reset,
    })
  end

  _enabled = true
end

--- @return boolean
function M.is_enabled()
  return _enabled
end

return M
