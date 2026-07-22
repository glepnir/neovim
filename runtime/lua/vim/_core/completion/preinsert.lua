--- Draws the 'preinsert' preview as virtual text.

local M = {}

local api = vim.api
local nvim_on = require('vim._core.util').nvim_on

local ns = api.nvim_create_namespace('nvim.completion.preinsert')

--- Buffer the preview is in; a session can end from another window.
local drawn_in = nil --- @type integer?

local function clear()
  if drawn_in then
    if api.nvim_buf_is_valid(drawn_in) then
      api.nvim_buf_clear_namespace(drawn_in, ns, 0, -1)
    end
    api.nvim__ns_set(ns, { wins = {} })
  end
  drawn_in = nil
end

local function previewing()
  local cot = vim.split(vim.o.completeopt, ',', { trimempty = true })
  if not vim.list_contains(cot, 'preinsert') then
    return false
  end
  if vim.o.autocomplete then
    return not (vim.o.ignorecase and not vim.o.infercase)
  end
  return vim.list_contains(cot, 'menuone')
end

--- Whether "s" starts with "prefix" as the engine compares them.
--- @param s string
--- @param prefix string
--- @return boolean
local function prefix_match(s, prefix)
  if vim.o.ignorecase and (not vim.o.smartcase or vim.fn.tolower(prefix) == prefix) then
    return s:sub(1, #prefix):lower() == prefix:lower()
  end
  return vim.startswith(s, prefix)
end

--- The part of the match the line does not have yet.
--- @param item table An entry from v:event.completed_item, see |complete-items|.
--- @param leader string
--- @param cursor_col integer 0-indexed byte column
--- @return string?
local function preview(item, leader, cursor_col)
  ---@type string
  local base = (item.filter_text ~= nil and item.filter_text ~= '') and item.filter_text
    or item.word
  if base == nil or base == '' then
    return nil
  end

  local start = item.startcol and (item.startcol - 1) or (cursor_col - #leader)
  if start < 0 or start > cursor_col then
    return nil
  end
  local have = api.nvim_get_current_line():sub(start + 1, cursor_col)
  if not prefix_match(base, have) then
    return nil
  end

  local rest = base:sub(#have + 1)
  if rest == '' or rest:find('\n', 1, true) then
    return nil
  end
  return rest
end

function M.enable()
  local group = api.nvim_create_augroup('nvim.completion.preinsert', {})

  nvim_on('CompleteChanged', group, { desc = "Draw the 'preinsert' preview" }, function(ev)
    clear()
    local item = vim.v.event.completed_item
    if not previewing() or type(item) ~= 'table' or next(item) == nil then
      return
    end
    local row, cursor_col = unpack(api.nvim_win_get_cursor(0)) --- @type integer, integer
    local text = preview(item, vim.v.event.complete_leader or '', cursor_col)
    if not text then
      return
    end
    -- Before the two below, so clear() takes down whichever landed.
    drawn_in = ev.buf
    api.nvim_buf_set_extmark(ev.buf, ns, row - 1, cursor_col, {
      virt_text = { { text, 'PreInsert' } },
      virt_text_pos = 'inline',
      undo_restore = false,
      invalidate = true,
    })
    api.nvim__ns_set(ns, { wins = { api.nvim_get_current_win() } })
  end)

  nvim_on('CompleteDone', group, { desc = "Remove the 'preinsert' preview" }, clear)
end

return M
