--- Draws the 'preinsert' preview as virtual text.

local M = {}

local api = vim.api
local nvim_on = require('vim._core.util').nvim_on

local ns = api.nvim_create_namespace('nvim.completion.preinsert')

--- Buffer the preview is in; a session can end from another window.
local drawn_in = nil --- @type integer?

local function clear()
  if drawn_in and api.nvim_buf_is_valid(drawn_in) then
    api.nvim_buf_clear_namespace(drawn_in, ns, 0, -1)
  end
  drawn_in = nil
end

--- Mirrors ins_compl_has_preinsert(), which decides whether the engine leaves
--- the room this draws into.
local function previewing()
  local cot = vim.split(vim.o.completeopt, ',', { trimempty = true })
  if not vim.list_contains(cot, 'preinsert') then
    return false
  end
  return not (vim.o.autocomplete and vim.o.ignorecase and not vim.o.infercase)
end

--- The part of the match the line does not have yet: shown only when accepting
--- it would just insert that at the cursor, as VS Code's ghost text.
--- @param item vim.v.completed_item
--- @param leader string
--- @param cursor_col integer 0-indexed byte column
--- @return string?
local function preview(item, leader, cursor_col)
  local word = item.word
  local start = item.startcol and (item.startcol - 1) or (cursor_col - #leader)
  if word == nil or start < 0 or start > cursor_col then
    return nil
  end
  local have = api.nvim_get_current_line():sub(start + 1, cursor_col)
  -- Folded, multibyte too: an item may match by its own "icase".
  local head = vim.fn.strcharpart(word, 0, vim.fn.strchars(have)) --- @type string
  local rest = word:sub(#head + 1)
  if vim.fn.tolower(head) ~= vim.fn.tolower(have) or rest == '' or rest:find('\n', 1, true) then
    return nil -- virt_text takes no newline
  end
  return rest
end

--- @param ev vim.api.keyset.create_autocmd.callback_args CompleteChanged
function M.draw(ev)
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
  -- Set first, so clear() finds the mark whatever fails below.
  drawn_in = ev.buf
  api.nvim_buf_set_extmark(ev.buf, ns, row - 1, cursor_col, {
    virt_text = { { text, 'PreInsert' } },
    virt_text_pos = 'inline', -- overlay would cover what follows the cursor
    undo_restore = false,
    invalidate = true,
  })
  -- A mark is the buffer's; a second window on it would draw the preview too.
  api.nvim__ns_set(ns, { wins = { api.nvim_get_current_win() } })
end

nvim_on('CompleteDone', api.nvim_create_augroup('nvim.completion.preinsert', {}), {
  desc = "Remove the 'preinsert' preview",
}, clear)

return M
