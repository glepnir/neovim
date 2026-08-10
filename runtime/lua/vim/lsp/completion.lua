--- @brief
--- The `vim.lsp.completion` module enables insert-mode completion driven by an LSP server. Call
--- `enable()` to make it available through Nvim builtin completion (via the |CompleteDone| event).
--- Specify `autotrigger=true` to activate "auto-completion" when you type any of the server-defined
--- `triggerCharacters`. Use CTRL-Y to select an item from the completion menu. |complete_CTRL-Y|
---
--- Example: activate LSP-driven auto-completion:
--- ```lua
--- -- Works best if 'completeopt' has "noselect".
--- -- Use CTRL-Y to select an item. |complete_CTRL-Y|
--- vim.cmd[[set completeopt+=menuone,noselect,popup]]
--- vim.lsp.start({
---   name = 'ts_ls',
---   cmd = …,
---   on_attach = function(client, bufnr)
---     vim.lsp.completion.enable(true, client.id, bufnr, {
---       autotrigger = true,
---       convert = function(item)
---         return { abbr = item.label:gsub('%b()', '') }
---       end,
---     })
---   end,
--- })
--- ```
---
--- [lsp-autocompletion]()
---
--- The LSP `triggerCharacters` field decides when to trigger autocompletion. If you want to trigger
--- on EVERY keypress you can either:
--- - Extend `client.server_capabilities.completionProvider.triggerCharacters` on `LspAttach`,
---   before you call `vim.lsp.completion.enable(… {autotrigger=true})`. See the |lsp-attach| example.
--- - Call `vim.lsp.completion.get()` from an |InsertCharPre| autocommand.
---
--- If the server provides `commitCharacters` for a completion item, typing one
--- of those characters while the item is selected accepts the completion and
--- then inserts the character. To disable this:
---
--- ```lua
--- vim.lsp.completion.enable(true, client_id, bufnr, { commit_characters = false })
--- ```

-- LSP puts filtering on the client, so Session.responses keeps a server's
-- candidates whole and publish() derives the view the engine gets.

local M = {}

local api = vim.api
local nvim_on = require('vim._core.util').nvim_on
local lsp = vim.lsp
local protocol = lsp.protocol

local rtt_ms = 50.0
local ns_to_ms = 0.000001

--- @alias vim.lsp.CompletionResult lsp.CompletionList | lsp.CompletionItem[]

-- TODO(mariasolos): Remove this declaration once we figure out a better way to handle
-- literal/anonymous types (see https://github.com/neovim/neovim/pull/27542/files#r1495259331).
--- @nodoc
--- @class lsp.ItemDefaults
--- @field commitCharacters string[]?
--- @field editRange lsp.Range | { insert: lsp.Range, replace: lsp.Range } | nil
--- @field insertTextFormat lsp.InsertTextFormat?
--- @field insertTextMode lsp.InsertTextMode?
--- @field data any

--- Per-buffer configuration, owned by enable()/disable().  Completion state
--- lives in a Session, which 'omnifunc' reaches without enable().
---
--- @nodoc
--- @class vim.lsp.completion.BufHandle
--- @field clients table<integer, vim.lsp.Client>
--- @field triggers table<string, vim.lsp.Client[]>
--- @field convert? fun(item: lsp.CompletionItem): table
--- @field cmp? fun(a: table, b: table): boolean
--- @field commit_characters? boolean
--- @field insert_mode? 'insert'|'replace'

--- @type table<integer, vim.lsp.completion.BufHandle>
local buf_handles = {}

--- @param flag string
--- @return boolean
local function has_completeopt(flag)
  return vim.list_contains(vim.opt.completeopt:get(), flag)
end

--- @param window integer
--- @param warmup integer
--- @return fun(sample: integer): integer
local function exp_avg(window, warmup)
  local count = 0
  local sum = 0
  local value = 0.0

  return function(sample)
    if count < warmup then
      count = count + 1
      sum = sum + sample
      value = sum / count
    else
      local factor = 2.0 / (window + 1)
      value = value * (1 - factor) + sample * factor
    end
    return value
  end
end
local compute_new_average = exp_avg(10, 10)

--- Calculates the adaptive debounce time based on the elapsed time since the last request.
---
--- @param last_request_time integer?
--- @param current_rtt_ms number
--- @return integer
local function adaptive_debounce(last_request_time, current_rtt_ms)
  if not last_request_time then
    return current_rtt_ms
  end
  local ms_since_request = (vim.uv.hrtime() - last_request_time) * ns_to_ms
  return math.max((ms_since_request - current_rtt_ms) * -1, 0)
end

--- @type uv.uv_timer_t?
local completion_timer = nil

local function reset_timer()
  if completion_timer then
    completion_timer:stop()
    completion_timer:close()
  end

  completion_timer = nil
end

--- @return uv.uv_timer_t
local function new_timer()
  return (assert(vim.uv.new_timer()))
end

--- @param input string Unparsed snippet
--- @return string # Parsed snippet if successful, else returns its input
local function parse_snippet(input)
  local ok, parsed = pcall(function()
    return lsp._snippet_grammar.parse(input)
  end)
  return ok and tostring(parsed) or input
end

--- @param item lsp.CompletionItem
local function apply_snippet(item)
  if item.textEdit then
    vim.snippet.expand(item.textEdit.newText)
  elseif item.insertText then
    vim.snippet.expand(item.insertText)
  end
end

--- Returns text that should be inserted when a selecting completion item. The
--- precedence is as follows: textEdit.newText > insertText > label
---
--- See https://microsoft.github.io/language-server-protocol/specifications/specification-current/#textDocument_completion
---
--- @param item lsp.CompletionItem
--- @return string word
--- @return string text What the item puts in the buffer, snippets expanded.
local function get_completion_word(item)
  if item.insertTextFormat == protocol.InsertTextFormat.Snippet then
    if item.textEdit or (item.insertText and item.insertText ~= '') then
      local text = parse_snippet(item.insertText or item.textEdit.newText)
      if #text < #item.label then
        return vim.fn.matchstr(text, '\\k*'), text
      end
      if item.filterText and vim.fn.match(item.label, '^\\k') == -1 then
        return item.filterText, text
      end
      return item.label, text
    else
      return item.label, item.label
    end
  elseif item.textEdit then
    local word = item.textEdit.newText
    word = string.gsub(word, '\r\n?', '\n')
    word = word:match('([^\n]*)') or word
    return word, word
  elseif item.insertText and item.insertText ~= '' then
    return item.insertText, item.insertText
  end
  return item.label, item.label
end

--- Resolves `defaults` into a copy of `item`, which is cached and converted
--- again on every refilter.
---
--- @param item lsp.CompletionItem
--- @param defaults lsp.ItemDefaults
--- @param apply_kind lsp.CompletionItemApplyKinds?
--- @return lsp.CompletionItem
local function resolve_defaults(item, defaults, apply_kind)
  local out = vim.tbl_extend('force', {}, item) --- @type lsp.CompletionItem

  -- Unset means Replace for every field.
  apply_kind = apply_kind or {}

  local merge = apply_kind.commitCharacters == protocol.ApplyKind.Merge
    and defaults.commitCharacters
  if merge then
    -- No dedup, it ends up as a flat string anyway.
    out.commitCharacters = vim.list_extend({}, item.commitCharacters or {})
    vim.list_extend(out.commitCharacters, defaults.commitCharacters)
  else
    -- An empty list means no commit chars, not use the defaults.
    out.commitCharacters = item.commitCharacters or defaults.commitCharacters
  end

  out.insertTextFormat = item.insertTextFormat or defaults.insertTextFormat
  -- Nothing reads it: Nvim does not advertise insertTextModeSupport.
  out.insertTextMode = item.insertTextMode or defaults.insertTextMode

  out.data = apply_kind.data == protocol.ApplyKind.Merge
      and type(defaults.data) == 'table'
      and type(item.data) == 'table'
      and vim.tbl_extend('force', defaults.data, item.data)
    or vim.nonnil(item.data, defaults.data)

  if defaults.editRange then
    local edit = vim.tbl_extend('force', {}, item.textEdit or {})
    -- Diverges from the spec, which says the label: that is often decorated.
    edit.newText = edit.newText or item.textEditText or item.insertText or item.label
    if defaults.editRange.start then
      edit.range = edit.range or defaults.editRange
    elseif defaults.editRange.insert then
      edit.insert = defaults.editRange.insert
      edit.replace = defaults.editRange.replace
    end
    out.textEdit = edit
  end

  return out
end

--- @param result vim.lsp.CompletionResult
--- @return lsp.CompletionItem[]
local function get_items(result)
  local items = result.items
  if not items then
    return result --[[@as lsp.CompletionItem[] ]]
  end
  local defaults = result.itemDefaults
  if not defaults then
    return items
  end
  local resolved = {} --- @type lsp.CompletionItem[]
  for i, item in ipairs(items) do
    resolved[i] = resolve_defaults(item, defaults, result.applyKind)
  end
  return resolved
end

---Returns an item's documentation value and its markup kind.
---@param item lsp.CompletionItem
---@return string
---@return lsp.MarkupKind
local function get_doc(item)
  local doc = item.documentation
  local default_kind = vim.lsp.protocol.MarkupKind.Markdown
  if not doc then
    return '', default_kind
  end
  if type(doc) == 'string' then
    return doc, default_kind
  end
  if type(doc) == 'table' and type(doc.value) == 'string' then
    return doc.value, doc.kind
  end

  vim.notify('invalid documentation value: ' .. vim.inspect(doc), vim.log.levels.WARN)
  return '', default_kind
end

--- Generate kind text for completion color items
--- Parse color from doc and return colored symbol ■
---
---@param item table completion item with kind and documentation
---@return string? kind text or "■" for colors
---@return string? highlight group for colors
local function generate_kind(item)
  if not lsp.protocol.CompletionItemKind[item.kind] then
    return 'Unknown'
  end
  if item.kind ~= lsp.protocol.CompletionItemKind.Color then
    return lsp.protocol.CompletionItemKind[item.kind]
  end
  local doc = get_doc(item)
  if #doc == 0 then
    return
  end

  -- extract hex from RGB format
  local r, g, b = doc:match('rgb%((%d+)%s*,?%s*(%d+)%s*,?%s*(%d+)%)')
  local hex = r
      and string.format(
        '%02x%02x%02x',
        vim._assert_integer(r),
        vim._assert_integer(g),
        vim._assert_integer(b)
      )
    or doc:match('#?([%da-fA-F]+)')

  if not hex then
    return
  end

  -- expand 3-digit hex to 6-digit
  if #hex == 3 then
    hex = hex:gsub('.', '%1%1')
  end

  if #hex ~= 6 then
    return
  end

  hex = hex:lower()
  local group = ('@lsp.color.%s'):format(hex)
  if next(api.nvim_get_hl(0, { name = group })) == nil then
    api.nvim_set_hl(0, group, { fg = '#' .. hex })
  end

  return '■', group
end

---Returns the [complete-items] info for an LSP completion item, its markup kind, and whether the
---info is complete.
---The info is complete when all of the fields of the item required to build it are present. If the
---info is not complete, resolving the item (via completionItem/resolve) may populate the missing
---fields.
---@param item lsp.CompletionItem
---@return string
---@return lsp.MarkupKind
---@return boolean complete
--- @param popup boolean 'completeopt' has "popup"; read once by the caller
local function complete_item_info(item, popup)
  local info, kind = get_doc(item)

  if item.detail and item.detail ~= '' then
    local detail_block = ('```%s\n%s\n```'):format(vim.bo.filetype, item.detail)
    if info == '' then
      info = detail_block
    elseif not info:find(item.detail, 1, true) then
      info = detail_block .. '\n' .. info
    end
  end

  if info == '' and popup and item.insertTextFormat == protocol.InsertTextFormat.Snippet then
    local text = item.insertText or (item.textEdit and item.textEdit.newText)
    if text then
      local snippet = parse_snippet(text)
      info = ('```%s\n%s\n```'):format(vim.bo.filetype, snippet)
    end
  end

  local complete = item.detail ~= nil and item.documentation ~= nil
  return info, kind, complete
end

--- Flatten commitCharacters array to a string; keep only the first codepoint
--- of each entry.
---
--- @param chars string[]
--- @return string
local function commit_chars_str(chars)
  if type(chars) ~= 'table' then
    return ''
  end
  local result = {} --- @type string[]
  for _, ch in ipairs(chars) do
    -- commit characters "should have `length=1`" and superfluous
    -- characters are ignored.  Keep the first codepoint.
    local b = type(ch) == 'string' and ch:byte(1)
    if b and b ~= 0 then
      local n = vim.str_utf_end(ch, 1)
      -- Only whole characters: multibyte fragments pair up across entries, NUL truncates.
      if b < 0x80 or n > 0 then
        result[#result + 1] = ch:sub(1, 1 + n)
      end
    end
  end
  return table.concat(result)
end

--- Where an item without a text edit starts: `/**` offered on `/`. #30905
--- @param text string What the item puts in the buffer.
--- @param line string
--- @param compl_col integer 0-indexed session column
--- @param cursor_col integer
--- @return integer
local function infer_start_col(text, line, compl_col, cursor_col)
  for s = math.max(0, cursor_col - #text), compl_col - 1 do
    if vim.startswith(text, line:sub(s + 1, cursor_col)) then
      return s
    end
  end
  return compl_col
end

--- The column an item replaces from, or nil when it starts at the word
--- boundary.  A text edit says so outright; without one the item may still
--- cover the characters in front of the word (`/**` offered on `/`, #30905).
---
--- @param text string? what the item puts in the buffer, snippets expanded
--- @return integer?
local function item_edit_start(item, line, lnum, encoding, compl_col, cursor_col, text)
  if line and lnum and encoding and item.textEdit then
    local range = item.textEdit.range or item.textEdit.insert
    if range and range.start.line == lnum then
      return vim.str_byteindex(line, encoding, range.start.character, false)
    end
    return nil
  end
  if line and compl_col > 0 and text then
    local inferred = infer_start_col(text, line, compl_col, cursor_col)
    if inferred < compl_col then
      return inferred
    end
  end
  return nil
end

--- Resolves the defaults of every item in `result` and works out where each one
--- replaces from.
---
--- @return { item: lsp.CompletionItem, word: string, start: integer? }[]
--- @return integer? min the earliest column any item replaces from
function M._prepare_items(result, line, lnum, cursor_col, compl_col, encoding)
  local out = {} --- @type { item: lsp.CompletionItem, word: string, start: integer? }[]
  local min --- @type integer?
  for i, item in ipairs(get_items(result)) do
    local word, text = get_completion_word(item)
    local start = item_edit_start(item, line, lnum, encoding, compl_col, cursor_col, text)
    out[i] = { item = item, word = word, start = start }
    if start and start < (min or compl_col) then
      min = start
    end
  end
  return out, min
end

--- Whether an item belongs in the view and how it ranks.  A miss drops it from
--- the view only; the cached answer keeps it, and a shorter leader brings it
--- back.  The engine only filters as the leader grows, so the first list has to
--- arrive filtered.
---
---@param value string the text the item is filtered by
---@param prefix string buffer text from the item's start column to the cursor
---@param fuzzy boolean 'completeopt' has "fuzzy"; read once by the caller
---@return boolean visible
---@return integer? score ranking within the view, `nil` when unranked
local function score_item(value, prefix, fuzzy)
  if prefix == '' then
    return true, nil
  end
  if fuzzy then
    -- Same scorer the engine uses, see fuzzy_match_str().
    local score = vim.fn.matchfuzzypos({ value }, prefix)[3] ---@type table
    return #score > 0, score[1]
  end

  if vim.o.ignorecase and (not vim.o.smartcase or not prefix:find('%u')) then
    return vim.startswith(value:lower(), prefix:lower()), nil
  end
  return vim.startswith(value, prefix), nil
end

--- Turns the result of a `textDocument/completion` request into vim-compatible
--- |complete-items|.
---
--- @param result vim.lsp.CompletionResult Result of `textDocument/completion`
--- @param compl_col integer 0-indexed session column
--- @param cursor_col integer
--- @param client_id integer? Client ID
--- @param line string? current line content
--- @param lnum integer? 0-indexed line number
--- @param encoding string? encoding
--- @param prepared table[]? output of M._prepare_items(), computed here when absent
--- @return table[]
--- @see complete-items
function M._lsp_to_complete_items(
  result,
  compl_col,
  word_col,
  cursor_col,
  client_id,
  line,
  lnum,
  encoding,
  prepared
)
  prepared = prepared or M._prepare_items(result, line, lnum, cursor_col, compl_col, encoding)
  if vim.tbl_isempty(prepared) then
    return {}
  end

  local view = {} --- @type { item: table, score: integer? }[]
  local fuzzy = has_completeopt('fuzzy')
  local popup = has_completeopt('popup')
  local bufnr = api.nvim_get_current_buf()
  local user_convert = vim.tbl_get(buf_handles, bufnr, 'convert')
  local user_cmp = vim.tbl_get(buf_handles, bufnr, 'cmp')
  local client = client_id and lsp.get_client_by_id(client_id)
  local server_supports_resolve = client and client:supports_method('completionItem/resolve')
  local use_commit = vim.tbl_get(buf_handles, bufnr, 'commit_characters') ~= false
  local commit_support = client
    and vim.tbl_get(
      client.capabilities,
      'textDocument',
      'completion',
      'completionItem',
      'commitCharactersSupport'
    )

  local all_commit_chars = client
    and vim.tbl_get(client.server_capabilities or {}, 'completionProvider', 'allCommitCharacters')
  local all_commit_str = all_commit_chars and commit_chars_str(all_commit_chars) or nil

  for _, entry in ipairs(prepared) do
    local item = entry.item
    local item_start = entry.start
    local word --- @type string?

    local prefix = line and line:sub(compl_col + 1, cursor_col) or ''

    -- The two spans differ: the word above keeps the text its own edit leaves
    -- alone, while the filter text also covers what the edit replaces, since a
    -- "filterText" describes the word boundary onwards (clangd's range covers
    -- the `.`, its filterText does not).
    local filter_pad = line and line:sub(compl_col + 1, word_col) or ''
    local filter_text = item.filterText or item.label
    if not vim.startswith(filter_text, filter_pad) then
      filter_text = filter_pad .. filter_text
    end

    local visible, score ---@type boolean, integer?
    if not prefix:find('%w') or (item.textEdit and not item.textEdit.newText) then
      visible = true
    else
      visible, score = score_item(filter_text, prefix, fuzzy)
    end

    if visible then
      word = get_completion_word(item)
      -- The engine writes from the session column, so an item starting after it
      -- carries the text in between.
      if line and item_start and item_start > compl_col then
        word = line:sub(compl_col + 1, item_start) .. word
      end

      local hl_group = ''
      if
        item.deprecated
        or vim.list_contains((item.tags or {}), protocol.CompletionTag.Deprecated)
      then
        hl_group = 'DiagnosticDeprecated'
      end
      local kind, kind_hlgroup = generate_kind(item)
      local info, info_kind, info_complete = complete_item_info(item, popup)
      local commit_chars --- @type string?
      if use_commit then
        if commit_support and item.commitCharacters then
          -- may be '': an explicit empty list also suppresses allCommitCharacters
          commit_chars = commit_chars_str(item.commitCharacters)
        else
          commit_chars = all_commit_str
        end
      end
      local completion_item = {
        word = word,
        filter_text = filter_text,
        -- Per item: an item reaching back over the `.` and one that does not can
        -- be in the same list.  Absent means the session column.
        abbr = ('%s%s'):format(item.label, vim.tbl_get(item, 'labelDetails', 'detail') or ''),
        kind = kind,
        menu = vim.tbl_get(item, 'labelDetails', 'description') or '',
        info = info,
        icase = 1,
        dup = 1,
        empty = 1,
        abbr_hlgroup = hl_group,
        kind_hlgroup = kind_hlgroup,
        preselect = item.preselect,
        commit_chars = commit_chars,
        user_data = {
          nvim = {
            lsp = {
              completion_item = item,
              info_kind = info_kind,
              completion_item_needs_resolving = server_supports_resolve and not info_complete,
              client_id = client_id,
            },
          },
        },
      }
      if user_convert then
        completion_item = vim.tbl_extend('keep', user_convert(item), completion_item)
      end
      view[#view + 1] = { item = completion_item, score = score }
    end
  end

  if not user_cmp then
    local by_sort_text = function(a, b)
      ---@type lsp.CompletionItem
      local itema = a.item.user_data.nvim.lsp.completion_item
      ---@type lsp.CompletionItem
      local itemb = b.item.user_data.nvim.lsp.completion_item
      return (itema.sortText or itema.label) < (itemb.sortText or itemb.label)
    end

    local base_prefix = line and line:sub(compl_col + 1, cursor_col) or ''
    local use_fuzzy_sort = fuzzy
      and not has_completeopt('nosort')
      and not result.isIncomplete
      and #base_prefix > 0

    table.sort(view, use_fuzzy_sort and function(a, b)
      local score_a = a.score or 0
      local score_b = b.score or 0
      if score_a ~= score_b then
        return score_a > score_b
      end
      return by_sort_text(a, b)
    end or by_sort_text)
  end

  local candidates = {} --- @type table[]
  for i, ranked in ipairs(view) do
    candidates[i] = ranked.item
  end
  return candidates
end

--- @param line string line content
--- @param lnum integer 0-indexed line number
--- @param cursor_col integer
--- @param client_id integer client ID
--- @param compl_col integer 0-indexed session column (the `\k*$` word boundary)
--- @param result vim.lsp.CompletionResult
--- @param encoding 'utf-8'|'utf-16'|'utf-32'
--- @return table[] matches
function M._convert_results(
  line,
  lnum,
  cursor_col,
  client_id,
  compl_col,
  result,
  encoding,
  prepared,
  word_col
)
  return M._lsp_to_complete_items(
    result,
    compl_col,
    word_col or compl_col,
    cursor_col,
    client_id,
    line,
    lnum,
    encoding,
    prepared
  )
end

--- What the buffer looks like right now: every column indexes `line`, so this
--- is read fresh and never carried across a tick.
---
--- @nodoc
--- @class vim.lsp.completion.LineContext
--- @field bufnr integer
--- @field row integer 1-indexed cursor row
--- @field cursor_col integer 0-indexed byte column of the cursor
--- @field line string the whole line the cursor is on
--- @field word_col integer 0-indexed byte column of the `\k*$` boundary

--- @return vim.lsp.completion.LineContext
local function line_context()
  local row, cursor_col = unpack(api.nvim_win_get_cursor(0)) --- @type integer, integer
  local line = api.nvim_get_current_line()
  return {
    bufnr = api.nvim_get_current_buf(),
    row = row,
    cursor_col = cursor_col,
    line = line,
    word_col = vim.fn.match(line:sub(1, cursor_col), '\\k*$'),
  }
end

--- @return boolean
local function in_insert_mode()
  local mode = api.nvim_get_mode().mode
  return mode == 'i' or mode == 'ic'
end

--- One completion session per buffer: everything it holds describes positions
--- in one buffer, and a client can be attached to several.  `responses` keeps
--- every candidate whole, which is what lets a shorter leader bring back the
--- ones a longer one hid.
---
--- @nodoc
--- @class vim.lsp.completion.Session
--- @field bufnr integer
--- @field responses table<integer, { result: vim.lsp.CompletionResult, encoding: string }>
--- @field incomplete table<integer, true> clients that asked to be re-queried
--- @field other_items table[]? candidates the builtin sources collected
--- TODO(glepnir): remove once vim._core.completion collects the builtin sources
--- in Lua; there is then no producer this module lacks a copy of.
--- @field id integer? engine session id from nvim__complete()
--- @field col integer? 1-based column the engine session is anchored at
--- @field leader string? leader as of the last CompleteChanged
--- @field generation integer bumped per request; an older round's publish is stale
--- @field cancel fun()? cancels the in-flight request round
--- @field last_request_time integer?
--- @field resolver CompletionResolver? handles "completionItem/resolve"
local Session = {}
Session.__index = Session

--- @type table<integer, vim.lsp.completion.Session>
local sessions = {}

--- @param bufnr integer
--- @return vim.lsp.completion.Session
function Session.get(bufnr)
  local session = sessions[bufnr]
  if not session then
    session = setmetatable({
      bufnr = bufnr,
      responses = {},
      incomplete = {},
      generation = 0,
    }, Session)
    sessions[bufnr] = session
  end
  return session
end

--- @param bufnr integer
--- @return vim.lsp.completion.Session?
function Session.peek(bufnr)
  return sessions[bufnr]
end

--- @param bufnr integer
function Session.discard(bufnr)
  local session = sessions[bufnr]
  if session then
    session:reset()
    sessions[bufnr] = nil
  end
end

--- @return boolean
function Session:has_incomplete()
  return next(self.incomplete) ~= nil
end

function Session:cancel_request()
  if self.cancel then
    self.cancel()
    self.cancel = nil
  end
end

--- Drops everything a finished completion leaves behind, the session handle
--- included: ins_compl_free() zeroes it before CompleteDone fires.
function Session:reset()
  self.last_request_time = nil
  self.leader = nil
  self.responses = {}
  self.incomplete = {}
  self.other_items = nil
  self.id = nil
  self.col = nil
  self:cancel_request()
  if self.resolver then
    self.resolver:cleanup()
    self.resolver = nil
  end
end

--- Takes the candidates the builtin sources collected.  nvim__complete()
--- replaces the whole match list, so they are read off the engine and
--- re-submitted whole with every batch; the engine filters them.
function Session:capture_other_items()
  if self.other_items then
    return
  end
  local items = {} --- @type table[]
  for _, m in ipairs(vim.fn.complete_info({ 'items' }).items) do
    if not vim.tbl_get(m, 'user_data', 'nvim', 'lsp') then
      -- These already passed ins_compl_add()'s dedup and empty-word checks, and
      -- ins_compl_build_pum() clears "icase" per 'smartcase'.
      m.dup, m.empty, m.icase = 1, 1, 1
      items[#items + 1] = m
    end
  end
  self.other_items = items
end

-- NOTE: The reason we don't use `lsp.buf_request_all` here is because we want to filter the clients
-- that received the request based on the trigger characters.
--- @param clients table<integer, vim.lsp.Client> # keys != client_id
--- @param bufnr integer
--- @param win integer
--- @param ctx? lsp.CompletionContext
--- @param callback fun(responses: table<integer, { err: lsp.ResponseError?, result: vim.lsp.CompletionResult? }>)
--- @return function # Cancellation function
local function request(clients, bufnr, win, ctx, callback)
  local responses = {} --- @type table<integer, { err: lsp.ResponseError?, result: any }>
  local request_ids = {} --- @type table<integer, integer>

  -- The documented way to opt a client out, not just for omnifunc.
  local targets = {} --- @type vim.lsp.Client[]
  for _, client in pairs(clients) do
    if client:supports_method('textDocument/completion', bufnr) then
      targets[#targets + 1] = client
    end
  end

  -- Starts at one so a synchronous answer cannot settle the round mid-loop.
  local outstanding = 1
  local function finish()
    outstanding = outstanding - 1
    if outstanding == 0 then
      callback(responses)
    end
  end

  for _, client in ipairs(targets) do
    local client_id = client.id
    local params = lsp.util.make_position_params(win, client.offset_encoding)
    --- @cast params lsp.CompletionParams
    params.context = ctx
    outstanding = outstanding + 1
    local ok, request_id = client:request('textDocument/completion', params, function(err, result)
      responses[client_id] = { err = err, result = result }
      finish()
    end, bufnr)

    if ok then
      request_ids[client_id] = request_id
    else
      responses[client_id] = {
        err = {
          code = protocol.ErrorCodes.InternalError,
          message = 'textDocument/completion was not dispatched',
        },
      }
      finish()
    end
  end

  finish() -- sentinel: empty set, or every dispatch failed

  return function()
    for client_id, request_id in pairs(request_ids) do
      local client = lsp.get_client_by_id(client_id)
      if client then
        client:cancel_request(request_id)
      end
    end
  end
end

---@param bufnr integer
---@return string
local function get_augroup(bufnr)
  return string.format('nvim.lsp.completion_%d', bufnr)
end

--- Updates the completion preview popup: configures conceal level, applies Treesitter or
--- fallback syntax, and resizes height to fit content
---
--- @param winid integer
--- @param bufnr integer
--- @param kind? string
local function update_popup_window(winid, bufnr, kind)
  if winid and api.nvim_win_is_valid(winid) and bufnr and api.nvim_buf_is_valid(bufnr) then
    if kind == lsp.protocol.MarkupKind.Markdown then
      vim.wo[winid].conceallevel = 2
      vim.treesitter.start(bufnr, kind)
    end
    local all = api.nvim_win_text_height(winid).all
    api.nvim_win_resize(winid, -1, all)
  end
end

--- Handles the LSP "completionItem/resolve"
---
--- @nodoc
--- @class CompletionResolver
--- @field timer uv.uv_timer_t? Timer used for debouncing
--- @field bufnr integer? Buffer number for which the resolution is triggered
--- @field word string? Word being completed
--- @field last_request_time integer? Last request timestamp
--- @field doc_rtt_ms integer Last request timestamp
--- @field doc_compute_new_average fun(sample: integer): integer Last request timestamp
local CompletionResolver = {}
CompletionResolver.__index = CompletionResolver

--- @nodoc
---
--- Creates a new instance of `resolve_completion_item`.
---
--- @return CompletionResolver
function CompletionResolver.new()
  local self = setmetatable({}, CompletionResolver)
  self.timer = nil
  self.bufnr = nil
  self.word = nil
  self.last_request_time = nil
  self.doc_rtt_ms = 100
  self.doc_compute_new_average = exp_avg(10, 5)
  return self
end

--- @nodoc
---
--- Cancels any pending requests.
function CompletionResolver:cancel_pending_requests()
  if self.bufnr then
    lsp.util._cancel_requests({
      method = 'completionItem/resolve',
      bufnr = self.bufnr,
    })
  end
end

--- @nodoc
---
--- Cleans up the timer and cancels any ongoing requests.
function CompletionResolver:cleanup()
  if self.timer and not self.timer:is_closing() then
    self.timer:stop()
    self.timer:close()
  end
  self.timer = nil
  self:cancel_pending_requests()
end

--- @nodoc
---
--- Checks if the completionItem/resolve request is valid by ensuring the buffer
--- and word are valid.
---
--- @return boolean, table Validity of the request and the completion info
function CompletionResolver:is_valid()
  local cmp_info = vim.fn.complete_info({ 'selected', 'completed' })
  return vim.api.nvim_buf_is_valid(self.bufnr)
    and vim.api.nvim_get_current_buf() == self.bufnr
    and vim.startswith(vim.api.nvim_get_mode().mode, 'i')
    and vim.fn.pumvisible() ~= 0
    and (vim.tbl_get(cmp_info, 'completed', 'word') or '') == self.word,
    cmp_info
end

--- @nodoc
---
--- Invokes and handles "completionItem/resolve".
---
--- @param bufnr integer The buffer number where the request is triggered
--- @param param table The parameters for the LSP request
--- @param selected_word string The word being completed
function CompletionResolver:request(bufnr, param, selected_word)
  self:cleanup()

  self.bufnr = bufnr
  self.word = selected_word
  local debounce_time = adaptive_debounce(self.last_request_time, self.doc_rtt_ms)

  self.timer = vim.defer_fn(function()
    local valid, cmp_info = self:is_valid()
    if not valid then
      self:cleanup()
      return
    end
    self:cancel_pending_requests()

    local client_id = vim.tbl_get(cmp_info.completed, 'user_data', 'nvim', 'lsp', 'client_id')
    local client = client_id and vim.lsp.get_client_by_id(client_id)
    if not client or not client:supports_method('completionItem/resolve') then
      return
    end

    local start_time = vim.uv.hrtime()
    self.last_request_time = start_time

    ---@param result lsp.CompletionItem
    client:request('completionItem/resolve', param, function(err, result)
      local end_time = vim.uv.hrtime()
      local response_time = (end_time - start_time) * ns_to_ms
      self.doc_rtt_ms = self.doc_compute_new_average(response_time)

      if err or not result or next(result) == nil then
        if err then
          vim.notify(err.message, vim.log.levels.WARN)
        end
        return
      end

      valid, cmp_info = self:is_valid()
      if not valid then
        return
      end

      local info, kind = complete_item_info(result, has_completeopt('popup'))
      if info ~= '' and info ~= cmp_info.completed.info then
        local windata = vim.api.nvim__complete_set(cmp_info.selected, { info = info })
        update_popup_window(windata.winid, windata.bufnr, kind)
      end
    end, bufnr)
  end, debounce_time)
end

local completion_ns = api.nvim_create_namespace('nvim.lsp.completion')

--- @param t table<integer, any>
--- @return integer[]
local function sorted_keys(t)
  local keys = vim.tbl_keys(t) --- @type integer[]
  table.sort(keys)
  return keys
end

--- Converts the cached answers into the list the engine gets.  Converted here
--- rather than read back through |complete_info()|, which is lossy.
---
--- @param session vim.lsp.completion.Session
--- @param ctx vim.lsp.completion.LineContext
--- @param line string the line as the engine filters against it
--- @param compl_col integer 0-indexed column the list is anchored at
--- @param cursor_col integer 0-indexed column the prefix ends at
--- @return table[]
--- @return table[] view
--- @return integer compl_col 0-indexed column the list has to be anchored at
local function build_view(session, ctx, line, word_col, cursor_col)
  local prepared = {} --- @type table<integer, table[]>
  local compl_col = word_col
  for _, client_id in ipairs(sorted_keys(session.responses)) do
    local cached = session.responses[client_id]
    local items, min =
      M._prepare_items(cached.result, line, ctx.row - 1, cursor_col, word_col, cached.encoding)
    prepared[client_id] = items
    if min and min < compl_col then
      compl_col = min
    end
  end

  local matches = {} --- @type table[]
  for _, client_id in ipairs(sorted_keys(session.responses)) do
    local cached = session.responses[client_id]
    if #prepared[client_id] > 0 then
      vim.list_extend(
        matches,
        M._convert_results(
          line,
          ctx.row - 1,
          cursor_col,
          client_id,
          compl_col,
          cached.result,
          cached.encoding,
          prepared[client_id],
          word_col
        )
      )
    end
  end

  local user_cmp = vim.tbl_get(buf_handles, session.bufnr, 'cmp')
  if user_cmp then
    -- The LSP slice only: a comparator written like the builtin one would
    -- nil-index on the first buffer word.
    table.sort(matches, user_cmp)
  end

  -- Builtin candidates first, mirroring the order they had before the engine's
  -- match list was replaced. Copied, so the kept list stays whole.
  local view = vim.list_extend({}, session.other_items or {})
  vim.list_extend(view, matches)
  return view, compl_col
end

--- Hands a new list to the completion engine.
---
--- @param session vim.lsp.completion.Session
--- @param ctx vim.lsp.completion.LineContext
local function publish(session, ctx)
  session:capture_other_items()

  if session.id then
    -- A running session pins the column, and the buffer is not a substitute for
    -- it: everything that could move the `\k*$` boundary ends the session first
    -- (ins_compl_accept_char(), ins_compl_bs()), while the shown match's text
    -- can sit in the line and move the boundary without ending anything.
    --
    -- Put the leader back in its place, so the whole conversion -- boundary,
    -- prefix, and the byte offsets a text edit range maps to -- sees what the
    -- engine filters against, and what the server was looking at when it
    -- answered.
    local col = assert(session.col)
    local line, cursor_col = ctx.line, ctx.cursor_col
    if session.leader then
      line = ctx.line:sub(1, col - 1) .. session.leader .. ctx.line:sub(cursor_col + 1)
      cursor_col = col - 1 + #session.leader
    end
    -- The word boundary sits at or after the session column; measuring it on the
    -- rebuilt line is what the items are padded against.
    local word_col = vim.fn.match(line:sub(1, cursor_col), '\\k*$')
    local view, start = build_view(session, ctx, line, math.max(col - 1, word_col), cursor_col)
    -- The engine cannot move a running session's column, so a batch reaching
    -- further back needs a new session.
    if start >= col - 1 and api.nvim__complete({ id = session.id, items = view }) ~= -1 then
      return
    end
    session.id, session.col = nil, nil
  end

  local view, start = build_view(session, ctx, ctx.line, ctx.word_col, ctx.cursor_col)
  local col = start + 1
  local id = api.nvim__complete({ col = col, items = view })
  session.id = id > 0 and id or nil
  session.col = session.id and col or nil
end

--- Defined below: their bodies need publish() and request_incomplete().
local register_session_autocmds --- @type fun(bufnr: integer): integer
local on_selection_changed --- @type fun(bufnr: integer)

--- Re-request from the clients that reported `isIncomplete`.
---
--- @param session vim.lsp.completion.Session
local function request_incomplete(session)
  reset_timer()

  local bufnr = session.bufnr
  local debounce_ms = adaptive_debounce(session.last_request_time, rtt_ms)
  local opts = {
    ctx = { triggerKind = protocol.CompletionTriggerKind.TriggerForIncompleteCompletions },
    --- @param client vim.lsp.Client
    filter = function(client)
      return session.incomplete[client.id] ~= nil
    end,
  }
  local function run()
    if api.nvim_get_current_buf() == bufnr and sessions[bufnr] == session then
      M.get(opts)
    end
  end
  if debounce_ms == 0 then
    vim.schedule(run)
  else
    completion_timer = new_timer()
    completion_timer:start(math.floor(debounce_ms), 0, vim.schedule_wrap(run))
  end
end

--- @param bufnr integer
--- @param clients table<integer, vim.lsp.Client> # keys != client_id
--- @param ctx lsp.CompletionContext
local function trigger(bufnr, clients, ctx)
  reset_timer()

  local session = Session.get(bufnr)
  session:cancel_request()

  if vim.fn.pumvisible() ~= 0 and not session:has_incomplete() then
    return
  end

  -- Any other trigger is a new context, so previous candidates don't apply.
  local retrigger = ctx
    and ctx.triggerKind == protocol.CompletionTriggerKind.TriggerForIncompleteCompletions
  if not retrigger then
    session.responses = {}
    session.incomplete = {}
  end

  session.generation = session.generation + 1
  local generation = session.generation

  if ctx and ctx.triggerKind == protocol.CompletionTriggerKind.Invoked then
    register_session_autocmds(bufnr)
  end

  local win = api.nvim_get_current_win()
  local cursor_row = api.nvim_win_get_cursor(win)[1]
  local start_time = vim.uv.hrtime() --[[@as integer]]
  session.last_request_time = start_time

  local settled = false
  local cancel = request(clients, bufnr, win, ctx, function(responses)
    settled = true
    -- Cancelling is best effort; a stale callback must not overwrite this one.
    if generation ~= session.generation then
      return
    end

    local end_time = vim.uv.hrtime()
    rtt_ms = compute_new_average((end_time - start_time) * ns_to_ms)

    session.cancel = nil

    -- Arbitrarily long after the request: the window may be gone.
    if not api.nvim_win_is_valid(win) or not in_insert_mode() then
      return
    end
    if api.nvim_win_get_cursor(win)[1] ~= cursor_row then
      return
    end

    for client_id, response in pairs(responses) do
      local client = lsp.get_client_by_id(client_id)
      local name = client and client.name or 'UNKNOWN'
      local err = response.err
      local result = response.result
      local code = err and err.code

      -- "Ignore this answer, keep what you had." Routine while typing.
      local discard = code == protocol.ErrorCodes.ContentModified
        or code == protocol.ErrorCodes.RequestCancelled
      -- Not error(): throwing here drops every client after this one.
      local malformed = type(result) == 'table' and result.items == vim.NIL

      if not discard then
        if malformed then
          vim.notify_once(
            ('%s: completion response has items=null, expected CompletionItem[]'):format(name),
            vim.log.levels.WARN
          )
        elseif err then
          vim.notify_once(
            ('%s: %s %s'):format(name, code or 'NO_CODE', err.message),
            vim.log.levels.WARN
          )
        end

        if err or malformed or vim.isnil(result) then
          -- Clear both, else the incomplete flag re-requests forever.
          session.responses[client_id] = nil
          session.incomplete[client_id] = nil
        else
          -- An empty incomplete list means request again when needed.
          session.responses[client_id] = {
            result = result,
            encoding = client and client.offset_encoding or 'utf-16',
          }
          session.incomplete[client_id] = result.isIncomplete or nil
        end
      end
    end

    -- nvim__complete changes text, forbidden under the textlock <C-x><C-o>
    -- holds.  Defer to the next tick.
    vim.schedule(function()
      if generation ~= session.generation or sessions[bufnr] ~= session then
        return -- superseded while waiting for the next tick
      end
      -- Checked a tick ago; the start path raises outside Insert mode.
      if not in_insert_mode() or api.nvim_get_current_buf() ~= bufnr then
        return
      end
      -- Read here, not a tick ago: the columns index the line as it is now.
      local ctx2 = line_context()
      if ctx2.row ~= cursor_row then
        return
      end
      publish(session, ctx2)
    end)
  end)

  -- A synchronous answer settles the round before request() returns, leaving a
  -- dead canceller here for the next trigger to call.
  if not settled then
    session.cancel = cancel
  end
end

--- Decides what a change to the leader means.
---
--- Only a shrinking leader: growing it is the engine's filter plus
--- InsertCharPre.  It converts the cached answers again rather than
--- re-requesting, except for an incomplete list, which the server truncated for
--- the longer prefix.
---
--- @param leader string?
function Session:on_leader(leader)
  local prev = self.leader
  self.leader = leader
  if not (prev and leader and #leader < #prev) then
    return
  end

  if self:has_incomplete() then
    request_incomplete(self)
    return
  end

  local bufnr = self.bufnr
  -- CompleteChanged holds textlock, so nvim__complete() would answer -1 here.
  vim.schedule(function()
    if sessions[bufnr] == self and api.nvim_get_current_buf() == bufnr and in_insert_mode() then
      publish(self, line_context())
    end
  end)
end

--- @param bufnr integer
local function on_complete_done(bufnr)
  local completed_item = api.nvim_get_vvar('completed_item')
  local lsp_data = vim.tbl_get(completed_item or {}, 'user_data', 'nvim', 'lsp')
  local completion_item = lsp_data and lsp_data.completion_item --- @type lsp.CompletionItem?
  local client_id = lsp_data and lsp_data.client_id --- @type integer?

  local cursor_row, cursor_col = unpack(api.nvim_win_get_cursor(0)) --- @type integer, integer
  cursor_row = cursor_row - 1

  local session = Session.peek(bufnr)
  -- CompleteDone carries no column, and `\k*$` would now find a different
  -- start: the accepted match is in the line.
  local session_col = session and session.col
  if session then
    session:reset()
  end

  if not completion_item or not client_id then
    return
  end

  local client = lsp.get_client_by_id(client_id)
  if not client then
    return
  end

  local expand_snippet = completion_item.insertTextFormat == protocol.InsertTextFormat.Snippet
    and (completion_item.textEdit ~= nil or completion_item.insertText ~= nil)
  local position_encoding = client.offset_encoding or 'utf-16'
  local resolve_provider = (client.server_capabilities.completionProvider or {}).resolveProvider

  --- Removes the tail an |lsp.InsertReplaceEdit| replaces.
  ---
  --- The engine applied the insert range, so only how much further the replace
  --- range reaches is left to remove.  That is taken as a count of characters
  --- rather than as the range's own end column: the engine has rewritten the
  --- line by now, so those coordinates no longer describe it, while the text
  --- past the cursor is exactly what followed the request position.
  ---
  --- Here rather than in the engine: the ranges are LSP's, and so is the choice.
  local function apply_replace_range()
    if vim.tbl_get(buf_handles, bufnr, 'insert_mode') ~= 'replace' then
      return
    end
    local edit = completion_item.textEdit --- @type lsp.InsertReplaceEdit?
    local replace, insert = edit and edit.replace, edit and edit.insert
    if not replace or not insert or replace['end'].line ~= insert['end'].line then
      return
    end
    local extra = replace['end'].character - insert['end'].character
    if extra <= 0 then
      return
    end
    local line = api.nvim_buf_get_lines(bufnr, cursor_row, cursor_row + 1, true)[1]
    local from = vim.str_utfindex(line, position_encoding, cursor_col, false)
    local end_col = vim.str_byteindex(line, position_encoding, from + extra, false)
    if end_col > cursor_col then
      api.nvim_buf_set_text(bufnr, cursor_row, cursor_col, cursor_row, end_col, { '' })
    end
  end

  local function clear_word()
    if not expand_snippet then
      return
    end
    -- Only the snippet path needs a column.  An item that replaces text in
    -- front of the word carries its own; the rest start where the session did.
    local start_col = session_col
    if not start_col then
      return
    end

    -- Remove the already inserted word.
    api.nvim_buf_set_text(bufnr, cursor_row, start_col - 1, cursor_row, cursor_col, { '' })
  end

  local function apply_snippet_and_command()
    if expand_snippet then
      apply_snippet(completion_item)
    end

    local command = completion_item.command
    if command then
      client:exec_cmd(command, { bufnr = bufnr })
    end
  end

  -- An import line or a same-line qualifier moves where the snippet expands.
  --- @param edits lsp.TextEdit[]
  local function apply_additional_edits(edits)
    local row, col = unpack(api.nvim_win_get_cursor(0)) --- @type integer, integer
    local mark = api.nvim_buf_set_extmark(bufnr, completion_ns, row - 1, col, {})
    lsp.util.apply_text_edits(edits, bufnr, position_encoding)
    local pos = api.nvim_buf_get_extmark_by_id(bufnr, completion_ns, mark, {})
    api.nvim_buf_del_extmark(bufnr, completion_ns, mark)
    if pos[1] then
      api.nvim_win_set_cursor(0, { pos[1] + 1, pos[2] })
    end
  end

  -- Before the edits below: they may move the cursor, and this span is measured
  -- from where the match was accepted.
  apply_replace_range()
  clear_word()

  local edits = completion_item.additionalTextEdits
  local has_edits = edits ~= nil and next(edits) ~= nil
  if has_edits then
    apply_additional_edits(edits)
  end
  apply_snippet_and_command()

  if has_edits or not resolve_provider or type(completion_item) ~= 'table' then
    return
  end

  -- A snippet that waits for resolve is lost if the buffer moves meanwhile.
  local changedtick = vim.b[bufnr].changedtick

  --- @param result lsp.CompletionItem
  client:request('completionItem/resolve', completion_item, function(err, result)
    if err then
      vim.notify_once(err.message, vim.log.levels.WARN)
      return
    end
    if not result or changedtick ~= vim.b[bufnr].changedtick then
      return
    end
    if result.additionalTextEdits then
      apply_additional_edits(result.additionalTextEdits)
    end
    if result.command and not completion_item.command then
      client:exec_cmd(result.command, { bufnr = bufnr })
    end
  end, bufnr)
end

--- The session lifecycle.  Not in enable(): 'omnifunc' reaches trigger()
--- without it.
---
--- @param bufnr integer
--- @return integer group
function register_session_autocmds(bufnr)
  local group = api.nvim_create_augroup(get_augroup(bufnr), { clear = false })
  if #api.nvim_get_autocmds({ buf = bufnr, event = 'CompleteDone', group = group }) > 0 then
    return group
  end

  nvim_on('CompleteDone', group, { buf = bufnr }, function(ev)
    local reason = api.nvim_get_vvar('event').reason ---@type string
    if reason == 'accept' then
      on_complete_done(ev.buf)
    elseif reason ~= 'replace' then
      -- 'replace' means ins_compl_start_session() is tearing down the old
      -- session to start a new one; the cached responses are still valid.
      local session = Session.peek(ev.buf)
      if session then
        session:reset()
      end
    end
  end)

  -- A <BS> fires no InsertCharPre.  The popup belongs to enable().
  nvim_on('CompleteChanged', group, {
    buf = bufnr,
    desc = 'vim.lsp.completion: refresh the candidates and the info popup',
  }, function(ev)
    local session = Session.peek(ev.buf)
    if session then
      session:on_leader(vim.v.event.complete_leader)
    end
    if buf_handles[ev.buf] then
      on_selection_changed(ev.buf)
    end
  end)

  nvim_on('InsertLeave', group, { buf = bufnr }, function(ev)
    reset_timer()
    local session = Session.peek(ev.buf)
    if session then
      session:reset()
    end
  end)

  return group
end

--- Highlights the info popup and requests documentation via
--- completionItem/resolve.  A feature of enable().
---
--- @param bufnr integer
function on_selection_changed(bufnr)
  if not has_completeopt('popup') then
    return
  end
  local completed_item = vim.v.event.completed_item or {}
  local user_data = vim.tbl_get(completed_item, 'user_data', 'nvim', 'lsp')
  if not user_data then
    return
  end
  if (completed_item.info or '') ~= '' then
    local data = vim.fn.complete_info({ 'selected' })
    update_popup_window(data.preview_winid, data.preview_bufnr, user_data.info_kind)
  end

  if user_data.completion_item_needs_resolving then
    local session = Session.get(bufnr)
    session.resolver = session.resolver or CompletionResolver.new()
    session.resolver:request(bufnr, user_data.completion_item, completed_item.word)
  end
end

--- @param handle vim.lsp.completion.BufHandle
--- @param bufnr integer
local function on_insert_char_pre(handle, bufnr)
  local session = Session.get(bufnr)
  if session:has_incomplete() then
    request_incomplete(session)
    return
  end

  if vim.fn.pumvisible() ~= 0 then
    return
  end

  local char = vim.v.char
  local matched_clients = handle.triggers[char]
  -- Discard pending trigger char, complete the "latest" one.
  -- Can happen if a mapping inputs multiple trigger chars simultaneously.
  reset_timer()
  if matched_clients then
    completion_timer = new_timer()
    completion_timer:start(25, 0, function()
      reset_timer()
      vim.schedule(function()
        trigger(api.nvim_get_current_buf(), matched_clients, {
          triggerKind = protocol.CompletionTriggerKind.TriggerCharacter,
          triggerCharacter = char,
        })
      end)
    end)
  end
end

--- @param client_id integer
--- @param bufnr integer
local function disable_completions(client_id, bufnr)
  local handle = buf_handles[bufnr]
  if not handle then
    return
  end

  local session = Session.peek(bufnr)
  if session then
    session.responses[client_id] = nil
    session.incomplete[client_id] = nil
  end

  handle.clients[client_id] = nil
  if not next(handle.clients) then
    buf_handles[bufnr] = nil
    -- Nothing left to publish, and the handlers go with the group below.
    Session.discard(bufnr)
    api.nvim_del_augroup_by_name(get_augroup(bufnr))
  else
    for char, clients in pairs(handle.triggers) do
      --- @param c vim.lsp.Client
      handle.triggers[char] = vim.tbl_filter(function(c)
        return c.id ~= client_id
      end, clients)
    end
  end
end

--- @inlinedoc
--- @class vim.lsp.completion.BufferOpts
--- @field autotrigger? boolean  (default: false) When true, completion triggers automatically based on the server's `triggerCharacters`.
--- @field convert? fun(item: lsp.CompletionItem): table Transforms an LSP CompletionItem to |complete-items|.
--- @field cmp? fun(a: table, b: table): boolean Comparator for sorting merged completion items from all servers.
--- @field commit_characters? boolean  (default: true) When false, commit characters are ignored.
--- @field insert_mode? 'insert'|'replace'  (default: "insert") What an item carrying an
--- |lsp.InsertReplaceEdit| does with the text after the cursor: "insert" leaves it alone,
--- "replace" removes what the item's replace range covers.

---@param client_id integer
---@param bufnr integer
---@param opts vim.lsp.completion.BufferOpts
local function enable_completions(client_id, bufnr, opts)
  local buf_handle = buf_handles[bufnr]
  if not buf_handle then
    buf_handle = {
      clients = {},
      triggers = {},
      convert = opts.convert,
      cmp = opts.cmp,
      commit_characters = opts.commit_characters ~= false,
      insert_mode = opts.insert_mode,
    }
    buf_handles[bufnr] = buf_handle

    -- Attach to buffer events.
    api.nvim_buf_attach(bufnr, false, {
      on_detach = function(_, buf)
        buf_handles[buf] = nil
        Session.discard(buf)
      end,
      on_reload = function(_, buf)
        M.enable(true, client_id, buf, opts)
      end,
    })

    -- Set up autocommands.
    local group = register_session_autocmds(bufnr)
    nvim_on('LspDetach', group, {
      buf = bufnr,
      desc = 'vim.lsp.completion: clean up client on detach',
    }, function(ev)
      disable_completions(ev.data.client_id, ev.buf)
    end)

    if opts.autotrigger then
      nvim_on('InsertCharPre', group, { buf = bufnr }, function(ev)
        local handle = buf_handles[ev.buf]
        if handle then
          on_insert_char_pre(handle, ev.buf)
        end
      end)
    end
  end

  if not buf_handle.clients[client_id] then
    local client = assert(lsp.get_client_by_id(client_id), 'invalid client ID')

    -- Add the new client to the buffer's clients.
    buf_handle.clients[client_id] = client

    -- Add the new client to the clients that should be triggered by its trigger characters.
    --- @type string[]
    local triggers = vim.tbl_get(
      client.server_capabilities,
      'completionProvider',
      'triggerCharacters'
    ) or {}
    for _, char in ipairs(triggers) do
      local clients_for_trigger = buf_handle.triggers[char]
      if not clients_for_trigger then
        clients_for_trigger = {}
        buf_handle.triggers[char] = clients_for_trigger
      end
      local client_exists = vim.iter(clients_for_trigger):any(function(c)
        return c.id == client_id
      end)
      if not client_exists then
        table.insert(clients_for_trigger, client)
      end
    end
  end
end

--- Enables or disables completions from the given language client in the given
--- buffer. Effects of enabling completions are:
---
--- - Calling |vim.lsp.completion.get()| uses the enabled clients to retrieve completion candidates.
--- - Selecting a completion item shows a preview popup ("completionItem/resolve") if 'completeopt'
---   has "popup".
--- - Accepting a completion item using `<c-y>` applies side effects like expanding snippets,
---   text edits (e.g. insert import statements) and executing associated commands. This works for
---   completions triggered via autotrigger, 'omnifunc' or [vim.lsp.completion.get()].
---
--- Examples: |lsp-attach| |lsp-completion|
---
--- @note |vim.lsp.omnifunc()| (|i_CTRL-X_CTRL-O|) queries every client that advertises completion,
--- including clients that were disabled by `enable(false)`. To suppress completions for a client,
--- clear its capability on |LspAttach|: `client.server_capabilities.completionProvider = nil`.
---
--- @note Behavior of `autotrigger=true` is controlled by the LSP `triggerCharacters` field. You
--- can override it on LspAttach, see |lsp-autocompletion|.
---
--- @param enable boolean True to enable, false to disable
--- @param client_id integer Client ID
--- @param bufnr integer Buffer handle, or 0 for the current buffer
--- @param opts? vim.lsp.completion.BufferOpts
function M.enable(enable, client_id, bufnr, opts)
  bufnr = vim._resolve_bufnr(bufnr)

  if enable then
    enable_completions(client_id, bufnr, opts or {})
  else
    disable_completions(client_id, bufnr)
  end
end

--- @inlinedoc
--- @class vim.lsp.completion.get.Opts
--- @field ctx? lsp.CompletionContext Completion context. Defaults to a trigger kind of `invoked`.
--- @field filter? fun(client: vim.lsp.Client): boolean Restricts the request to
--- enabled clients for which this returns true. Defaults to all enabled clients.

--- Triggers LSP completion once in the current buffer, if LSP completion is enabled
--- (see |lsp-attach| |lsp-completion|).
---
--- Use CTRL-Y to select an item from the completion menu. |complete_CTRL-Y|
---
--- To invoke manually with CTRL-space, use this mapping:
--- ```lua
--- -- Use CTRL-space to trigger LSP completion.
--- -- Use CTRL-Y to select an item. |complete_CTRL-Y|
--- vim.keymap.set('i', '<c-space>', function()
---   vim.lsp.completion.get()
--- end)
--- ```
---
--- @param opts? vim.lsp.completion.get.Opts
function M.get(opts)
  opts = opts or {}
  local ctx = opts.ctx or { triggerKind = protocol.CompletionTriggerKind.Invoked }
  local bufnr = api.nvim_get_current_buf()
  local clients = (buf_handles[bufnr] or {}).clients or {}
  if opts.filter then
    local filtered = {} --- @type table<integer, vim.lsp.Client>
    for id, client in pairs(clients) do
      if opts.filter(client) then
        filtered[id] = client
      end
    end
    clients = filtered
  end

  trigger(bufnr, clients, ctx)
end

--- Implements 'omnifunc' compatible LSP completion.
---
--- @see |complete-functions|
--- @see |complete-items|
--- @see |CompleteDone|
---
--- @param findstart integer 0 or 1, decides behavior
--- @param base integer findstart=0, text to match against
---
--- @return integer|table Decided by {findstart}:
--- - findstart=1: column where the completion starts, or -2 or -3
--- - findstart=0: list of matches (actually just calls |complete()|)
function M._omnifunc(findstart, base)
  lsp.log.debug('omnifunc.findstart', { findstart = findstart, base = base })
  local bufnr = api.nvim_get_current_buf()
  local clients = lsp.get_clients({ bufnr = bufnr, method = 'textDocument/completion' })
  if #clients == 0 then
    return findstart == 1 and -1 or {}
  end

  trigger(bufnr, clients, { triggerKind = protocol.CompletionTriggerKind.Invoked })

  -- Return -2 to signal that we should continue completion so that we can
  -- async complete.
  return -2
end

return M
