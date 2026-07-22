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

--- Whether "s" starts with "prefix" the way the engine compares them: every item
--- carries "icase", so 'ignorecase' decides, and 'smartcase' turns it back off
--- once the leader holds an upper-case character.
--- @param s string
--- @param prefix string
--- @return boolean
local function prefix_match(s, prefix)
  if vim.o.ignorecase and (not vim.o.smartcase or not prefix:find('%u')) then
    return s:sub(1, #prefix):lower() == prefix:lower()
  end
  return vim.startswith(s, prefix)
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
  -- No fallback to the word when there is a filter text: an item is filtered by
  -- it, so a mismatch means there is no tail to show.  The word would preview
  -- "->member" at the cursor, reading as `p.->member`.
  local base = (item.filter_text ~= nil and item.filter_text ~= '') and item.filter_text
    or item.word
  if base == nil or base == '' then
    return nil
  end

  -- What the line already holds of it.  Not the leader: an item that replaces
  -- text in front of the word is filtered by that text too, so it starts before
  -- the leader does.
  local start = item.startcol and (item.startcol - 1) or (cursor_col - #leader)
  if start < 0 or start > cursor_col then
    return nil
  end
  local have = api.nvim_get_current_line():sub(start + 1, cursor_col)

  if not prefix_match(base, have) then
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
  local text = preview(item, vim.v.event.complete_leader or '', cursor_col)
  if not text then
    return
  end
  api.nvim_buf_set_extmark(ev.buf, ns, row - 1, cursor_col, {
    virt_text = { { text, 'PreInsert' } },
    -- Inline, so that it does not cover what follows the cursor.
    virt_text_pos = 'inline',
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
