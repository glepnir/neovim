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

--- The part of the match the line does not have yet.
---
--- @param item table |complete-items| entry from v:event.completed_item
--- @param leader string
--- @return string?
local function preview(item, leader)
  -- The filter text, which starts where the leader does.  An item that replaces
  -- text in front of the word inserts something the leader never had: `res.`
  -- previews "handle", and the `.` becomes `->` when the match is accepted.
  local base = item.filter_text
  if base == nil or base == '' then
    base = item.word
  end
  local have = leader

  if base == nil or base == '' or not vim.startswith(base, have) then
    return nil
  end
  local rest = base:sub(#have + 1)
  -- virt_text takes no newline, and a snippet can expand to several lines.
  if rest == '' or rest:find('\n', 1, true) then
    return nil
  end
  return rest
end

local function draw(ev)
  clear()
  local item = vim.v.event.completed_item
  if type(item) ~= 'table' or next(item) == nil then
    return -- nothing selected
  end
  local row, cursor_col = unpack(api.nvim_win_get_cursor(0)) --- @type integer, integer
  local text = preview(item, vim.v.event.complete_leader or '')
  if not text then
    return
  end
  api.nvim_buf_set_extmark(ev.buf, ns, row - 1, cursor_col, {
    virt_text = { { text, 'PreInsert' } },
    virt_text_pos = 'overlay', -- inline would move the cursor and the menu
    undo_restore = false,
    invalidate = true,
  })
  drawn_in = ev.buf
end

--- Registered only while 'preinsert' is set: CompleteChanged is on the CTRL-N
--- path, and has_event() skips building v:event when nothing listens.
local listening = false

local function sync()
  local want = enabled()
  if want == listening then
    return
  end
  if want then
    nvim_on('CompleteChanged', group, { desc = "Draw the 'preinsert' preview" }, draw)
    nvim_on('CompleteDone', group, { desc = "Remove the 'preinsert' preview" }, clear)
  else
    api.nvim_clear_autocmds({ group = group, event = { 'CompleteChanged', 'CompleteDone' } })
    clear()
  end
  listening = want
end

nvim_on('OptionSet', group, { pattern = 'completeopt' }, sync)
nvim_on('BufEnter', group, {}, sync) -- 'completeopt' is global-local
sync()
