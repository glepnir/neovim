--- Draws the 'preinsert' preview as virtual text.

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

--- Mirrors ins_compl_has_preinsert().
local function previewing()
  -- vim.o, not vim.opt: 'completeopt' is global-local.
  local cot = vim.split(vim.o.completeopt, ',', { trimempty = true })
  return vim.list_contains(cot, 'preinsert')
    and vim.list_contains(cot, 'menuone')
    and not (vim.o.autocomplete and vim.o.ignorecase and not vim.o.infercase)
end

--- Whether "s" starts with "prefix" as the engine compares them.
--- @param s string
--- @param prefix string
--- @return boolean
local function prefix_match(s, prefix)
  -- tolower(), not %u: it folds bytes.  The compare is byte-wise like STRNICMP.
  if vim.o.ignorecase and (not vim.o.smartcase or vim.fn.tolower(prefix) == prefix) then
    return s:sub(1, #prefix):lower() == prefix:lower()
  end
  return vim.startswith(s, prefix)
end

--- The part of the match the line does not have yet.
---
--- @param item table |complete-items| entry from v:event.completed_item
--- @param leader string
--- @param cursor_col integer 0-indexed byte column
--- @return string?
local function preview(item, leader, cursor_col)
  -- filter_text spans what the item replaces: `res.` previews "handle", not
  -- "->handle".
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
    return nil -- virt_text takes no newline
  end
  return rest
end

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
  api.nvim_buf_set_extmark(ev.buf, ns, row - 1, cursor_col, {
    virt_text = { { text, 'PreInsert' } },
    virt_text_pos = 'inline', -- overlay would cover what follows the cursor
    undo_restore = false,
    invalidate = true,
  })
  drawn_in = ev.buf
end)

nvim_on('CompleteDone', group, { desc = "Remove the 'preinsert' preview" }, clear)
