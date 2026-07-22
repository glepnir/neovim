--- Draws the 'preinsert' preview as virtual text, for every completion source.

local api = vim.api
local nvim_on = require('vim._core.util').nvim_on

local ns = api.nvim_create_namespace('nvim.completion.preinsert')
local group = api.nvim_create_augroup('nvim.completion.preinsert', {})

--- Buffer the preview is drawn in; a session can end from another window.
local drawn_in = nil --- @type integer?

local function clear()
  if drawn_in and api.nvim_buf_is_valid(drawn_in) then
    api.nvim_buf_clear_namespace(drawn_in, ns, 0, -1)
  end
  drawn_in = nil
end

local function enabled()
  return vim.o.completeopt:find('preinsert', 1, true) ~= nil
end

--- The part of the match the line does not have yet.  Against "filter_text"
--- where there is one, since that spans what an item replaces in front of the
--- word: `res.` previews "handle", not "->handle".
---
--- @param item table |complete-items| entry from v:event.completed_item
--- @param leader string
--- @param cursor_col integer 0-indexed byte column
--- @return string?
local function preview(item, leader, cursor_col)
  local word = item.word
  if word == nil or word == '' then
    return nil
  end

  local base = item.filter_text
  if base ~= nil and base ~= '' and cursor_col >= #leader then
    local start = item.startcol and (item.startcol - 1) or (cursor_col - #leader)
    if start >= 0 and start <= cursor_col then
      local have = api.nvim_get_current_line():sub(start + 1, cursor_col)
      if vim.startswith(base, have) then
        local rest = base:sub(#have + 1)
        return rest ~= '' and rest or nil
      end
    end
  end

  -- A 'complete' source anchors its matches without saying where, so its word
  -- carries what it reaches back over.
  if not vim.startswith(word, leader) then
    return nil
  end
  local rest = word:sub(#leader + 1)
  return rest ~= '' and rest or nil
end

nvim_on('CompleteChanged', group, { desc = "Draw the 'preinsert' preview" }, function(ev)
  clear()
  if not enabled() then
    return
  end
  local item = vim.v.event.completed_item
  if type(item) ~= 'table' or next(item) == nil then
    return -- nothing selected
  end
  local row, cursor_col = unpack(api.nvim_win_get_cursor(0)) --- @type integer, integer
  local text = preview(item, vim.v.event.complete_leader or '', cursor_col)
  if not text then
    return
  end
  api.nvim_buf_set_extmark(ev.buf, ns, row - 1, cursor_col, {
    virt_text = { { text, 'PreInsert' } },
    virt_text_pos = 'overlay',
    undo_restore = false,
    invalidate = true,
  })
  drawn_in = ev.buf
end)

nvim_on('CompleteDone', group, { desc = "Remove the 'preinsert' preview" }, clear)

nvim_on('OptionSet', group, {
  pattern = 'completeopt',
  desc = "Remove the 'preinsert' preview when the option is turned off",
}, function()
  if not enabled() then
    clear()
  end
end)
