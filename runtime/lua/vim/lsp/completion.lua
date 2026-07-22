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

-- A request passes five gates between a keystroke and a list reaching the engine.
-- Each drops the round it is in; none of them is redundant, and knowing which
-- one fired is usually the fastest way into a bug here.
--
--   debounce      completion_timer      the next keystroke replaces this round
--   generation    Session:reset() and every trigger bump it; a callback
--                 carrying an older one has nothing left to publish
--   ownership     Session.peek(bufnr) == session, for a buffer switch
--   context       row, mode, and buffer re-read at publish time
--   cancel        Session:cancel_request(), best effort: a server that already
--                 answered still arrives, and generation is what stops it

local M = {}

local api = vim.api
local nvim_on = require('vim._core.util').nvim_on
local lsp = vim.lsp
local protocol = lsp.protocol

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

--- Per-buffer configuration, owned by enable()/disable().
---
--- @nodoc
--- @class vim.lsp.completion.BufHandle
--- @field clients table<integer, vim.lsp.Client>
--- @field triggers table<string, vim.lsp.Client[]>
--- @field identifier table<integer, vim.lsp.Client> Clients asked while an
--- identifier is being typed, by id.
--- @field rank? table<integer, integer> Order between clients whose items score
--- alike, by id.  Absent ids come after the rest.
--- @field secondary? table<integer, true> Clients whose items give way to
--- another's on the same word, by id.
--- @field listening? true Whether InsertCharPre is registered.
--- @field convert? fun(item: lsp.CompletionItem): table
--- @field cmp? fun(a: table, b: table): boolean
--- @field commit_characters? boolean
--- @field insert_mode? 'insert'|'replace'

--- @type table<integer, vim.lsp.completion.BufHandle>
local buf_handles = {}

--- @nodoc
--- @class vim.lsp.completion.Response
--- @field err? lsp.ResponseError
--- @field result? vim.lsp.CompletionResult

--- @param flag string
--- @return boolean
local function has_completeopt(flag)
  -- 'completeopt' is global-local; vim.o gives the effective value, which is
  -- what the engine reads.
  return vim.list_contains(vim.split(vim.o.completeopt, ',', { trimempty = true }), flag)
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
--- Round-trip time per set of clients, since one round waits for the slowest of
--- them: a buffer with only the in-process server answers in a fraction of what
--- one with a language server takes.
--- @type table<string, { rtt_ms: number, average: fun(sample: number): number }>
local rtt = {}

--- @param ids integer[]
--- @return { rtt_ms: number, average: fun(sample: number): number }
local function rtt_for_ids(ids)
  table.sort(ids)
  local key = table.concat(ids, ',')
  rtt[key] = rtt[key] or { rtt_ms = 50.0, average = exp_avg(10, 10) }
  return rtt[key]
end

--- @param clients table<integer, vim.lsp.Client> # keys != client_id
--- @return { rtt_ms: number, average: fun(sample: number): number }
local function rtt_for(clients)
  local ids = {} --- @type integer[]
  for _, c in pairs(clients) do
    ids[#ids + 1] = c.id
  end
  return rtt_for_ids(ids)
end

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

--- @param s string?
--- @return string?
--- table.sort() is not stable, and the tiebreak below runs out before two items
--- from one client do: their emission order is the last thing that separates
--- them.
--- @generic T
--- @param list T[]
--- @param cmp fun(a: T, b: T): boolean
local function stable_sort(list, cmp)
  local at = {} --- @type table<any, integer>
  for i, v in ipairs(list) do
    at[v] = i
  end
  table.sort(list, function(a, b)
    if cmp(a, b) then
      return true
    end
    if cmp(b, a) then
      return false
    end
    return at[a] < at[b]
  end)
end

local function nonempty(s)
  return s ~= '' and s or nil
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
    if item.textEdit or nonempty(item.insertText) then
      local text = parse_snippet(nonempty(item.insertText) or item.textEdit.newText)
      if #text < #item.label then
        return vim.fn.matchstr(text, '\\k*'), text
      end
      local filter_text = nonempty(item.filterText)
      if filter_text and vim.fn.match(item.label, '^\\k') == -1 then
        return filter_text, text
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
  elseif nonempty(item.insertText) then
    -- One line, like the textEdit branch: a word off compl_lnum breaks every
    -- column the session is measured in.
    local word = item.insertText:gsub('\r\n?', '\n'):match('([^\n]*)')
    return word, item.insertText
  end
  return item.label, item.label
end

--- Resolves `defaults` into a copy of `item`.
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
    -- "newText" is required and "" is a legitimate delete, so it is taken as it
    -- is; the two the spec calls falsy when empty are not.  The label last,
    -- which the spec does not say for "textEditText" but leaves nothing else.
    edit.newText = edit.newText
      or nonempty(item.textEditText)
      or nonempty(item.insertText)
      or item.label
    -- Only when the item has no range of its own, and never both forms on one
    -- item: item_edit_start() reads "range" first while apply_replace_range()
    -- reads "replace", so a mixed item would be anchored by one and trimmed by
    -- the other.
    local has_range = edit.range ~= nil or edit.insert ~= nil
    if not has_range and defaults.editRange.start then
      edit.range = defaults.editRange
    elseif not has_range and defaults.editRange.insert then
      edit.insert = defaults.editRange.insert
      edit.replace = defaults.editRange.replace
    end
    out.textEdit = edit
  end

  return out
end

--- The items of "result" with its "itemDefaults" resolved into each of them.
---
--- Needed before items from more than one list are put together: a default
--- belongs to the list it came with.
---
--- What this client offers for this buffer.
---
--- A dynamic registration wins over the initialize response: a server that
--- registers "textDocument/completion" for some documents and not others is
--- describing this buffer, while the static capability describes all of them.
---
---@param client vim.lsp.Client
---@param bufnr integer
---@return lsp.CompletionOptions
local function completion_options(client, bufnr)
  local static = client.server_capabilities.completionProvider or {}
  -- nil, not an empty list, when nothing is registered for this buffer.
  for _, reg in ipairs(client:_get_registrations('completionProvider', bufnr) or {}) do
    local regoptions = reg.registerOptions
    if regoptions and regoptions ~= vim.NIL then
      -- Registration wins per field: a server that registers only to scope
      -- itself still means what it said at initialize.
      return vim.tbl_extend('keep', regoptions, static)
    end
  end
  return static
end

--- @param result vim.lsp.CompletionResult
--- @return lsp.CompletionItem[]
function M._get_items(result)
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

--- Whether the engine would compare "prefix" case-insensitively, as
--- ignorecase() does: 'smartcase' looks for an upper-case character, and
--- vim.fn.tolower() shares the case tables with it while %u folds bytes.
---
--- The comparison itself stays byte-wise, like the STRNICMP() in
--- ins_compl_equal(): only ASCII folds there either.
--- @param prefix string
--- @return boolean
local function fold_case(prefix)
  return vim.o.ignorecase and (not vim.o.smartcase or vim.fn.tolower(prefix) == prefix)
end

--- Whether an item belongs in the view and how it ranks.  It is dropped from the
--- view only: the cached answer keeps it, and a shorter leader brings it back.
---
---@param value string the text the item is filtered by
---@param prefix string buffer text from the item's start column to the cursor
---@param fuzzy boolean 'completeopt' has "fuzzy"
---@param scores table<string, integer>? scores for the batch, keyed prefix..NUL..value
---@return boolean visible
---@return integer? score `nil` when unranked
local function score_item(value, prefix, fuzzy, scores)
  if fuzzy then
    -- Looked up rather than scored: matchfuzzypos() crosses into VimL, so the
    -- caller runs it once per prefix for the whole batch.
    local score = scores and scores[prefix .. '\0' .. value]
    return score ~= nil, score
  end
  if fold_case(prefix) then
    return vim.startswith(value:lower(), prefix:lower()), nil
  end
  return vim.startswith(value, prefix), nil
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
    local text = nonempty(item.insertText) or (item.textEdit and item.textEdit.newText)
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
---
--- @param text string what the item puts in the buffer
--- @param line string
--- @param compl_col integer 0-indexed session column
--- @param cursor_col integer 0-indexed
--- @return integer
local function infer_start_col(text, line, compl_col, cursor_col)
  -- A guess, and one that only pays off when the text starts with something the
  -- line has in front of the word: a word made of \k characters never does, and
  -- checking that first skips the scan for every buffer word.  See #30905 --
  -- "-1" or ".5" can still be read as reaching back.
  local first = text:sub(1, 1)
  local reach = line:sub(math.max(1, cursor_col - #text + 1), compl_col)
  if first == '' or reach:find(first, 1, true) == nil then
    return compl_col
  end
  for s = math.max(0, cursor_col - #text), compl_col - 1 do
    if vim.startswith(text, line:sub(s + 1, cursor_col)) then
      return s
    end
  end
  return compl_col
end

--- The column an item replaces from, or nil when it starts at the word boundary.
---
--- @param item lsp.CompletionItem
--- @param line string?
--- @param lnum integer? 0-indexed
--- @param encoding string?
--- @param compl_col integer 0-indexed session column
--- @param cursor_col integer 0-indexed
--- @param text string? what the item puts in the buffer, snippets expanded
--- @return integer?
local function item_edit_start(item, line, lnum, encoding, compl_col, cursor_col, text)
  if line and lnum and encoding and item.textEdit then
    local range = item.textEdit.range or item.textEdit.insert
    -- Both ends: the column below drives backspace_until_column(), and a range
    -- leaving the line describes a position this cannot measure.
    if range and range.start.line == lnum and range['end'].line == lnum then
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

--- @nodoc
--- @class vim.lsp.completion.Prepared
--- @field item lsp.CompletionItem
--- @field word string what accepting it inserts
--- @field start integer? 0-indexed column it replaces from, when it has one
--- @field prefix string line text from that column to the cursor
--- @field filter string what it is filtered by, spanning what it replaces

--- Resolves the item defaults and works out where each item replaces from.
---
--- @param result vim.lsp.CompletionResult
--- @param line string?
--- @param lnum integer? 0-indexed
--- @param cursor_col integer 0-indexed
--- @param compl_col integer 0-indexed session column
--- @param encoding string?
--- @return vim.lsp.completion.Prepared[]
function M._prepare_items(result, line, lnum, cursor_col, compl_col, encoding)
  local out = {} --- @type vim.lsp.completion.Prepared[]
  for i, item in ipairs(M._get_items(result)) do
    local word, text = get_completion_word(item)
    local start = item_edit_start(item, line, lnum, encoding, compl_col, cursor_col, text)

    -- The item's own column, on either side of compl_col: one reaching back is
    -- filtered by what it replaces, one starting later by less -- what lies in
    -- between is text it leaves alone, which is how the engine's per-item leader
    -- reads it too.
    local prefix = line and line:sub((start or compl_col) + 1, cursor_col) or ''

    -- The spec has a replace range denote the word an item is filtered by, but
    -- servers routinely send a "filterText" that only describes the word, so
    -- what a reaching-back item replaces goes back in front of it.
    local filter = nonempty(item.filterText) or item.label
    if line and start and start < compl_col then
      local pad = line:sub(start + 1, compl_col)
      if not vim.startswith(filter, pad) then
        filter = pad .. filter
      end
    end

    out[i] = { item = item, word = word, start = start, prefix = prefix, filter = filter }
  end
  return out
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
--- @param bufnr integer? the session's buffer; the current one when absent
--- @return table[]
--- @see complete-items
function M._lsp_to_complete_items(
  result,
  compl_col,
  cursor_col,
  client_id,
  line,
  lnum,
  encoding,
  bufnr
)
  local prepared = M._prepare_items(result, line, lnum, cursor_col, compl_col, encoding)
  if vim.tbl_isempty(prepared) then
    return {}
  end

  local candidates = {} --- @type table[]
  local scores = {} --- @type table<table, integer>
  local min_start = nil ---@type integer?
  local fuzzy = has_completeopt('fuzzy')
  local popup = has_completeopt('popup')
  bufnr = bufnr or api.nvim_get_current_buf()
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
    and completion_options(client, bufnr).allCommitCharacters
  local all_commit_str = all_commit_chars and commit_chars_str(all_commit_chars) or nil

  --- Fuzzy scores for the whole batch: matchfuzzypos() crosses into VimL, so a
  --- word list of thousands is one call per prefix rather than one per item.
  --- Grouped by prefix, since an item reaching in front of the word is filtered
  --- from its own column rather than the session's leader.
  --- @type table<string, integer>?
  local fuzzy_scores
  --- Whether a prefix holds anything to filter by: \k, not %w, since an
  --- identifier can hold characters neither is about and %w stops at the first
  --- byte of a multibyte one.  Answered once per prefix, of which there are as
  --- many as there are start columns.
  --- @type table<string, boolean>
  local filterable = {}

  local by_prefix = {} --- @type table<string, string[]>
  for _, entry in ipairs(prepared) do
    local prefix = entry.prefix
    if filterable[prefix] == nil then
      filterable[prefix] = prefix ~= '' and vim.fn.match(prefix, [[\k]]) ~= -1
    end
    if fuzzy and filterable[prefix] then
      by_prefix[prefix] = by_prefix[prefix] or {}
      table.insert(by_prefix[prefix], entry.filter)
    end
  end
  if fuzzy then
    fuzzy_scores = {}
    for prefix, words in pairs(by_prefix) do
      local matched = vim.fn.matchfuzzypos(words, prefix)
      for i, word in ipairs(matched[1] --[[@as string[] ]]) do
        fuzzy_scores[prefix .. '\0' .. word] = (matched[3] --[[@as integer[] ]])[i]
      end
    end
  end

  for _, entry in ipairs(prepared) do
    local item = entry.item
    local word = entry.word
    local item_start = entry.start

    if item_start and item_start < compl_col and (not min_start or item_start < min_start) then
      min_start = item_start
    end

    local prefix, filter_text = entry.prefix, entry.filter

    local visible, score ---@type boolean, integer?
    if word == '' then
      visible = false -- a blank row that would insert nothing
    elseif not filterable[prefix] or (item.textEdit and not item.textEdit.newText) then
      visible = true
    else
      visible, score = score_item(filter_text, prefix, fuzzy, fuzzy_scores)
    end

    if visible then
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
      local user_data = {
        nvim = {
          lsp = {
            completion_item = item,
            info_kind = info_kind,
            completion_item_needs_resolving = server_supports_resolve and not info_complete,
            client_id = client_id,
          },
        },
      }
      local completion_item = {
        word = word,
        filter_text = filter_text,
        -- Absent means the session column; "col" is only where the menu is
        -- anchored, so an item can start on either side of it.
        startcol = (item_start and item_start ~= compl_col) and item_start + 1 or nil,
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
        user_data = user_data,
      }
      if user_convert then
        local converted = user_convert(item)
        completion_item = vim.tbl_extend('keep', converted, completion_item)
        -- Merged rather than kept: everything downstream reads
        -- user_data.nvim.lsp, and "keep" would let a convert that returns its
        -- own "user_data" drop it.  The type check is for a convert that
        -- returns a non-table one, which |complete-items| allows.
        completion_item.user_data = type(converted.user_data) == 'table'
            and vim.tbl_deep_extend('force', converted.user_data, user_data)
          or user_data
      end
      candidates[#candidates + 1] = completion_item
      scores[completion_item] = score
      -- Out with the item, so that build_view() can order across clients: two
      -- filtered from the same column are scored against the same prefix.  Not
      -- while the list is incomplete: reordering a list the server says is
      -- partial makes it jump as the rest arrives.
      user_data.nvim.lsp.score = not result.isIncomplete and score or nil
      user_data.nvim.lsp.start = item_start or compl_col
    end
  end

  if not user_cmp then
    local by_sort_text = function(a, b)
      ---@type lsp.CompletionItem
      local itema = a.user_data.nvim.lsp.completion_item
      ---@type lsp.CompletionItem
      local itemb = b.user_data.nvim.lsp.completion_item
      return (nonempty(itema.sortText) or itema.label) < (nonempty(itemb.sortText) or itemb.label)
    end

    local base_prefix = line and line:sub((min_start or compl_col) + 1, cursor_col) or ''
    local by_score = fuzzy
      and not has_completeopt('nosort')
      and not result.isIncomplete
      and #base_prefix > 0

    table.sort(candidates, by_score and function(a, b)
      if (scores[a] or 0) ~= (scores[b] or 0) then
        return (scores[a] or 0) > (scores[b] or 0)
      end
      return by_sort_text(a, b)
    end or by_sort_text)
  end

  return candidates
end

--- Every column indexes `line`, so this is read fresh and never carried across a
--- tick.
---
--- @nodoc
--- @class vim.lsp.completion.LineContext
--- @field bufnr integer
--- @field row integer 1-indexed cursor row
--- @field cursor_col integer 0-indexed byte column of the cursor
--- @field line string
--- @field word_col integer 0-indexed byte column of the `\k*$` boundary

--- What a cached response describes.
--- @param ctx vim.lsp.completion.LineContext
--- @return string
local function anchor_of(ctx)
  return ('%d:%d'):format(ctx.row, ctx.word_col)
end

--- The same, for a session that is running: its column is pinned, and the line
--- holds the shown match rather than the leader, so \k*$ would follow the match.
--- @param session vim.lsp.completion.Session?
--- @param ctx vim.lsp.completion.LineContext
--- @return string
local function session_anchor(session, ctx)
  if session and session.col then
    return ('%d:%d'):format(ctx.row, session.col - 1)
  end
  return anchor_of(ctx)
end

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

--- One per buffer: every position it holds indexes one buffer, and a client can
--- be attached to several.
---
--- @nodoc
--- @class vim.lsp.completion.Session
--- @field bufnr integer
--- @field responses table<integer, { result: vim.lsp.CompletionResult, encoding: string }>
--- @field incomplete table<integer, true> clients that asked to be re-queried
--- @field other_items table[]? candidates the builtin sources collected, kept
--- only until vim._core.completion.source collects them here too
--- @field id integer? engine session id from nvim__complete()
--- @field col integer? 1-based column the engine session is anchored at
--- @field leader string? leader as of the last CompleteChanged
--- @field anchor? string Row and column the cached responses were asked from;
--- they describe the word starting there and nothing else.
--- @field generation integer version of everything above; a callback carrying an
--- older one has nothing left to publish
--- @field cancel fun()? cancels the in-flight request round
--- @field last_request_time integer?
--- @field resolver CompletionResolver?
local Session = {}
Session.__index = Session

--- @type vim.lsp.completion.Session?
local active_session = nil

--- @nodoc
--- @param bufnr integer
--- @return vim.lsp.completion.Session
function Session.get(bufnr)
  if active_session and active_session.bufnr ~= bufnr then
    -- The stop is a formality here -- ins_compl_stop_session() wants the
    -- session's own window, which is no longer current -- but the cache and the
    -- id have to go.  insert_handle_key_post() cancels the engine session on
    -- the next key for the same reason.
    active_session:reset(true)
    active_session = nil
  end
  if not active_session then
    active_session = setmetatable({
      bufnr = bufnr,
      responses = {},
      incomplete = {},
      generation = 0,
    }, Session)
  end
  return active_session
end

--- @nodoc
--- @param bufnr integer
--- @return vim.lsp.completion.Session?
function Session.peek(bufnr)
  return (active_session and active_session.bufnr == bufnr) and active_session or nil
end

--- @nodoc
--- @param bufnr integer
--- @param stop? boolean see Session:reset()
function Session.discard(bufnr, stop)
  if active_session and active_session.bufnr == bufnr then
    active_session:reset(stop)
    active_session = nil
  end
end

--- @nodoc
--- @return boolean
function Session:has_incomplete()
  return next(self.incomplete) ~= nil
end

--- @nodoc
function Session:cancel_request()
  if self.cancel then
    self.cancel()
    self.cancel = nil
  end
end

--- @nodoc
--- Drops what a finished completion leaves behind, the session handle included.
--- @param stop? boolean also end the engine session; not from CompleteDone,
---                      which is the engine telling us it ended one
function Session:reset(stop)
  -- Nothing of the round in flight is worth publishing any more.
  self.generation = self.generation + 1
  self.last_request_time = nil
  self.leader = nil
  self.responses = {}
  self.incomplete = {}
  self.other_items = nil
  self.anchor = nil
  local id = self.id
  self.id = nil
  self.col = nil
  self:cancel_request()
  if self.resolver then
    self.resolver:cleanup()
    self.resolver = nil
  end
  if stop and id then
    -- Last, once nothing is left to clean up: it answers -1 rather than raising
    -- when it cannot act, but a CompleteDone handler firing from it can raise.
    api.nvim__complete({ id = id })
  end
end

--- @nodoc
--- Takes the candidates the builtin sources collected: nvim__complete() replaces
--- the whole match list, so they go back in with every batch.
function Session:capture_other_items()
  if self.other_items then
    return
  end
  local items = {} --- @type table[]
  for _, m in ipairs(vim.fn.complete_info({ 'items' }).items) do
    if not vim.tbl_get(m, 'user_data', 'nvim', 'lsp') then
      -- Already past ins_compl_add()'s checks, and the engine drops an empty
      -- word.  "icase" is lost, which complete_info() does not report.
      m.dup, m.empty = 1, 1
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
--- @param callback fun(responses: table<integer, vim.lsp.completion.Response>)
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

--- The argument order |complete-items| tests are written against.
---
--- @param line string
--- @param lnum integer 0-indexed
--- @param cursor_col integer 0-indexed
--- @param client_id integer
--- @param compl_col integer 0-indexed session column
--- @param result vim.lsp.CompletionResult
--- @param encoding 'utf-8'|'utf-16'|'utf-32'
--- @return table[]
function M._convert_results(line, lnum, cursor_col, client_id, compl_col, result, encoding)
  return M._lsp_to_complete_items(result, compl_col, cursor_col, client_id, line, lnum, encoding)
end

--- Converts the cached answers into the list the engine gets.
---
--- @param session vim.lsp.completion.Session
--- @param lnum integer 0-indexed row
--- @param line string the line as the engine filters against it
--- @param compl_col integer 0-indexed column the list is anchored at
--- @param cursor_col integer 0-indexed column the prefix ends at
--- @return table[]
local function build_view(session, lnum, line, compl_col, cursor_col)
  -- Collected in the caller's order, which the sort below keeps for two items
  -- nothing else separates: client id would put whoever started first in front.
  local rank = vim.tbl_get(buf_handles, session.bufnr, 'rank') or {}
  local ids = sorted_keys(session.responses)
  table.sort(ids, function(a, b)
    local ra, rb = rank[a] or math.huge, rank[b] or math.huge
    if ra ~= rb then
      return ra < rb
    end
    return a < b
  end)

  local secondary = vim.tbl_get(buf_handles, session.bufnr, 'secondary') or {}
  local converted = {} --- @type table<integer, table[]>
  local seen = {} --- @type table<string, true>
  for _, client_id in ipairs(ids) do
    local cached = session.responses[client_id]
    converted[client_id] = M._lsp_to_complete_items(
      cached.result,
      compl_col,
      cursor_col,
      client_id,
      line,
      lnum,
      cached.encoding,
      session.bufnr
    )
    -- Collected first, from every client but the secondary ones: which of them
    -- comes first in "ids" says nothing about whose word wins.
    if not secondary[client_id] then
      for _, item in ipairs(converted[client_id]) do
        seen[item.word] = true
      end
    end
  end

  local matches = {} --- @type table[]
  for _, client_id in ipairs(ids) do
    for _, item in ipairs(converted[client_id]) do
      -- A word a server offered says more than a buffer word spelling the same;
      -- two items from one server are two candidates, "dup" being theirs to set.
      if not (secondary[client_id] and seen[item.word]) then
        matches[#matches + 1] = item
      end
    end
  end

  local user_cmp = vim.tbl_get(buf_handles, session.bufnr, 'cmp')
  if user_cmp then
    table.sort(matches, user_cmp)
  elseif not has_completeopt('nosort') then
    -- Across clients rather than client by client: how well an item matches
    -- outranks which source it came from, and the source only decides where the
    -- scores do not.
    -- By batch, not by pair: a key that only some pairs consult is not an
    -- ordering, and table.sort() on one of those gives back anything.  A round
    -- where someone called its list partial goes by rank alone, which is also
    -- what keeps that list from being reordered as the rest of it arrives.
    local scored = true
    for _, m in ipairs(matches) do
      if not m.user_data.nvim.lsp.score then
        scored = false
        break
      end
    end

    stable_sort(matches, function(a, b)
      local x, y = a.user_data.nvim.lsp, b.user_data.nvim.lsp
      -- The column it is filtered from, before anything else: one reaching
      -- further back answers a different word, and the two scores are against
      -- different text.
      if (x.start or 0) ~= (y.start or 0) then
        return (x.start or 0) < (y.start or 0)
      end
      if scored and x.score ~= y.score then
        return x.score > y.score
      end
      -- Then the caller's order, before "sortText": that one ranks a server's
      -- items among its own, and means nothing held against another server's.
      local rx = rank[x.client_id] or math.huge
      local ry = rank[y.client_id] or math.huge
      if rx ~= ry then
        return rx < ry
      end
      local sx = nonempty(x.completion_item.sortText) or x.completion_item.label
      local sy = nonempty(y.completion_item.sortText) or y.completion_item.label
      return sx < sy
    end)
  end

  -- Builtin candidates first, as they were before the list was replaced.
  local view = vim.list_extend({}, session.other_items or {})
  vim.list_extend(view, matches)
  return view
end

--- Hands a new list to the completion engine.
---
--- @param session vim.lsp.completion.Session
--- @param ctx vim.lsp.completion.LineContext
local function do_publish(session, ctx)
  session:capture_other_items()

  if session.id then
    -- A running session pins the column: the shown match's text sits in the
    -- line and moves the `\k*$` boundary without ending anything.  The leader
    -- goes back in its place, so the conversion sees what the engine filters
    -- against and what the server answered for.
    local col = assert(session.col)
    local line, cursor_col = ctx.line, ctx.cursor_col
    if session.leader then
      line = ctx.line:sub(1, col - 1) .. session.leader .. ctx.line:sub(cursor_col + 1)
      cursor_col = col - 1 + #session.leader
    end
    local view = build_view(session, ctx.row - 1, line, col - 1, cursor_col)
    -- Never left running on an empty list: such a session still takes <C-n> and
    -- <C-e> from the engine, so a word nobody has a candidate for would swallow
    -- them.  What is still incomplete is asked again by the next character.
    if #view == 0 then
      session:reset(true)
      return
    end
    if api.nvim__complete({ id = session.id, items = view }) ~= -1 then
      return
    end
    -- It ended while the request was in flight, or the window it belongs to is
    -- not the one entered now; start a new one below.
    session.id, session.col, session.leader = nil, nil, nil
  end

  local col = ctx.word_col + 1
  local view = build_view(session, ctx.row - 1, ctx.line, ctx.word_col, ctx.cursor_col)
  if #view == 0 then
    return -- not started on an empty list, for the same reason
  end
  local id = api.nvim__complete({ col = col, items = view })
  if id > 0 then
    session.id, session.col = id, col
    -- Seeded rather than waited for: the first CompleteChanged fires inside the
    -- call above, before there is an id for Session:on_leader() to recognise.
    -- set_completion() takes compl_orig_text from the same span, and
    -- ins_compl_leader() answers with it until something is typed.
    session.leader = ctx.line:sub(ctx.word_col + 1, ctx.cursor_col)
  end
end

--- @param session vim.lsp.completion.Session
--- @param ctx vim.lsp.completion.LineContext
local function publish(session, ctx)
  -- Reported, not raised: this runs from a scheduled callback, where an error is
  -- a red message and the next keystroke would take the same path again.
  local ok, err = pcall(do_publish, session, ctx)
  if not ok then
    vim.notify_once(('vim.lsp.completion: %s'):format(err), vim.log.levels.ERROR)
    -- Not reset(true): stopping the session fires CompleteDone, and a handler
    -- raising from there would come back out of this one.
    pcall(session.reset, session, true)
  end
end

--- Defined below: their bodies need publish() and request_incomplete().
local register_session_autocmds --- @type fun(bufnr: integer): integer
local on_selection_changed --- @type fun(bufnr: integer)

--- Re-request from the clients that reported `isIncomplete`.
---
--- @param sess vim.lsp.completion.Session
local function request_incomplete(sess)
  reset_timer()

  local bufnr = sess.bufnr
  -- The clients the filter below lets through, so the estimate and the update
  -- land in the same bucket.
  local ident = vim.tbl_get(buf_handles, sess.bufnr, 'identifier') or {}
  local asked = {} --- @type integer[]
  for _, client in pairs(vim.tbl_get(buf_handles, sess.bufnr, 'clients') or {}) do
    if sess.incomplete[client.id] or (sess.responses[client.id] == nil and ident[client.id]) then
      asked[#asked + 1] = client.id
    end
  end
  local debounce_ms = adaptive_debounce(sess.last_request_time, rtt_for_ids(asked).rtt_ms)
  local opts = {
    ctx = { triggerKind = protocol.CompletionTriggerKind.TriggerForIncompleteCompletions },
    --- @param client vim.lsp.Client
    filter = function(client)
      -- Or never asked about this word, and meant to answer for one: a trigger
      -- character only reaches the clients that declared it, so the rest have
      -- nothing to filter yet.  A client that opted out of identifiers is not
      -- one of them.
      return sess.incomplete[client.id] ~= nil
        or (sess.responses[client.id] == nil and ident[client.id] ~= nil)
    end,
  }
  local function run()
    if api.nvim_get_current_buf() == bufnr and Session.peek(bufnr) == sess then
      M.get(opts)
    end
  end
  if debounce_ms == 0 then
    vim.schedule(run)
  else
    completion_timer = new_timer()
    completion_timer:start(
      math.floor(debounce_ms),
      0,
      vim.schedule_wrap(function()
        reset_timer()
        run()
      end)
    )
  end
end

--- @param bufnr integer
--- @param clients table<integer, vim.lsp.Client> # keys != client_id
--- @param ctx lsp.CompletionContext
--- @param explicit? boolean The user asked for this list, so it outranks one
--- already on screen and starts from nothing rather than from what is cached.
--- Not derivable from "ctx": "Invoked" covers typing an identifier as well as
--- asking outright, and only the caller knows which it was.
local function trigger(bufnr, clients, ctx, explicit)
  reset_timer()

  local session = Session.get(bufnr)
  session:cancel_request()

  -- A trigger character opens a context the menu cannot filter its way into, and
  -- an explicit request asks for another list outright; either is served with
  -- the menu up, since ins_compl_replace_list() swaps it without tearing the
  -- session down.
  local wanted = explicit == true
    or (ctx and ctx.triggerKind) == protocol.CompletionTriggerKind.TriggerCharacter
  if vim.fn.pumvisible() ~= 0 and not wanted and not session:has_incomplete() then
    return
  end

  -- Only the clients being asked answer for themselves; the rest keep what they
  -- gave for this same word.  Items carry absolute ranges, so a word starting
  -- somewhere else invalidates them all.
  -- Kept for anything but a list the user asked for: an identifier round is
  -- another look at the same word, and reports "Invoked" only because that kind
  -- covers typing one.
  local anchor = session_anchor(session, line_context())
  local retrigger = not explicit and session.anchor == anchor
  if not retrigger then
    session.responses = {}
    session.incomplete = {}
  end
  session.anchor = anchor

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

    session.cancel = nil

    local back = line_context()
    if back.row ~= cursor_row or session_anchor(session, back) ~= session.anchor then
      return -- the word this round asked about is no longer the one at the cursor
    end

    local end_time = vim.uv.hrtime()
    local r = rtt_for(clients)
    r.rtt_ms = r.average((end_time - start_time) * ns_to_ms)

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

    -- nvim__complete changes text, which the <C-x><C-o> textlock forbids.
    vim.schedule(function()
      if generation ~= session.generation or Session.peek(bufnr) ~= session then
        return -- superseded while waiting for the next tick
      end
      -- Checked a tick ago; the start path raises outside Insert mode.
      if not in_insert_mode() or api.nvim_get_current_buf() ~= bufnr then
        return
      end
      local ctx2 = line_context()
      if ctx2.row ~= cursor_row or session_anchor(session, ctx2) ~= session.anchor then
        return -- a key in between moved off the word this round was about
      end
      publish(session, ctx2)
    end)
  end)

  -- A synchronous answer settles the round before request() returns.
  if not settled then
    session.cancel = cancel
  end
end

--- @nodoc
--- Only a shrinking leader is handled here: growing it is the engine's filter
--- plus InsertCharPre.  The cached answers are converted again rather than
--- re-requested, unless the list was incomplete.
---
--- @param leader string?
function Session:on_leader(leader)
  if not self.id then
    -- Not our completion: Session:reset() leaves the object in place, so this
    -- is also reached for a native <C-n> or another plugin's complete().
    return
  end
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
  local generation = self.generation
  -- CompleteChanged holds textlock, so nvim__complete() would answer -1 here.
  vim.schedule(function()
    -- The generation too: Session:reset() empties the responses without
    -- replacing the session, and publishing then submits an empty list.
    if generation ~= self.generation or Session.peek(bufnr) ~= self then
      return
    end
    if api.nvim_get_current_buf() ~= bufnr or not in_insert_mode() then
      return
    end
    local ctx = line_context()
    if session_anchor(self, ctx) ~= self.anchor then
      return -- a key in between moved off the word the cache is about
    end
    publish(self, ctx)
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
    and (completion_item.textEdit ~= nil or nonempty(completion_item.insertText) ~= nil)
  local position_encoding = client.offset_encoding or 'utf-16'
  local resolve_provider = completion_options(client, bufnr).resolveProvider

  --- Removes the tail an |lsp.InsertReplaceEdit| replaces.  As a count of
  --- characters, not the range's own end column: the engine has rewritten the
  --- line, while the text past the cursor still follows the request position.
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
    -- An item that replaces text in front of the word carries its own column.
    local start_col = completed_item.startcol or session_col
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

  -- Before the edits below, which move the cursor this span is measured from.
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

  --- @param result lsp.CompletionItem
  client:request('completionItem/resolve', completion_item, function(err, result)
    if err then
      vim.notify_once(err.message, vim.log.levels.WARN)
      return
    end
    -- Not gated on 'changedtick': the edits are anchored where the server
    -- computed them and apply_additional_edits() follows the cursor with an
    -- extmark, so typing in a snippet tabstop meanwhile must not drop an
    -- auto-import.
    if not result or not api.nvim_buf_is_valid(bufnr) then
      return
    end
    if result.additionalTextEdits then
      apply_additional_edits(result.additionalTextEdits)
    end
    -- Not when the item carried one: apply_snippet_and_command() ran it, and a
    -- resolve that fills the item in returns the same command.
    if result.command and not completion_item.command then
      client:exec_cmd(result.command, { bufnr = bufnr })
    end
  end, bufnr)
end

--- @nodoc
--- The session lifecycle.  Not in enable(): 'omnifunc' reaches trigger() without
--- it.
---
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
      -- 'replace' means nvim__complete() is taking the completion over to start
      -- a new one; the cache holds.
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

  -- A switch that stays in Insert mode -- a <Cmd> map, or nvim_set_current_buf()
  -- from an autocommand -- cancels the engine session with the other buffer
  -- already current, so the CompleteDone above never runs for this one.  The id
  -- would then be waiting here for a later native <C-n> to be taken over.  Not
  -- stopped: insert_handle_key_post() cancelled it on the way out.
  nvim_on('BufLeave', group, { buf = bufnr }, function(ev)
    local session = Session.peek(ev.buf)
    if session then
      session:reset()
    end
  end)

  return group
end

--- @nodoc
--- Highlights the info popup and resolves documentation.  A feature of enable().
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

  local session = Session.peek(bufnr)
  if session and user_data.completion_item_needs_resolving then
    session.resolver = session.resolver or CompletionResolver.new()
    session.resolver:request(bufnr, user_data.completion_item, completed_item.word)
  end
end

--- @param handle vim.lsp.completion.BufHandle
--- @param bufnr integer
local function on_insert_char_pre(handle, bufnr)
  local session = Session.peek(bufnr)
  local char = vim.v.char

  -- Classified before the guards: a trigger character opens a context the menu
  -- cannot filter its way into.
  local matched_clients = handle.triggers[char]
  local ctx = matched_clients
    and {
      triggerKind = protocol.CompletionTriggerKind.TriggerCharacter,
      triggerCharacter = char,
    }

  -- A character goes only to the clients that asked for it.
  if not matched_clients then
    -- Asking only the subset that reported "incomplete" would leave the rest
    -- with nothing: trigger() drops the whole cache once the anchor moves.
    local same_word = session and session.anchor == session_anchor(session, line_context())
    if same_word and session and session:has_incomplete() then
      request_incomplete(session)
      return
    end
    if vim.fn.pumvisible() ~= 0 then
      return -- the engine filters what it has
    end
  end

  -- Typing an identifier is the client's own business, per the LSP
  -- specification: a server lists only the characters that fall outside one.
  -- The word has to end where the cursor will be, since typing into the middle
  -- of one is an edit, and a number is not a name.
  if not ctx and next(handle.identifier or {}) then
    local col = api.nvim_win_get_cursor(0)[2]
    local line = api.nvim_get_current_line()
    -- The leader in place of the match: this runs before ins_compl_addleader()
    -- takes it back, so the line still holds what is only being shown.
    if session and session.id and session.col and session.leader then
      line = line:sub(1, session.col - 1) .. session.leader .. line:sub(col + 1)
      col = session.col - 1 + #session.leader
    end
    local word = vim.fn.matchstr(line:sub(1, col) .. char, [[\k*$]])
    if
      word ~= ''
      and tonumber(word) == nil
      and vim.fn.match(line:sub(col + 1), [[^\k]]) ~= 0
    then
      -- Every one of them answered for this word, completely: another character
      -- narrows what is here rather than bringing more.  Not "someone answered"
      -- -- a trigger character only asks the clients that declared it, so the
      -- rest have nothing cached for the word it started.
      local all_answered = session ~= nil
        and session.anchor == session_anchor(session, line_context())
      if all_answered and session then
        for id, c in pairs(handle.identifier) do
          -- Only ones that would answer: a server without completion never
          -- lands in "responses", so waiting for it waits forever.
          if
            not session.responses[id]
            and c:supports_method('textDocument/completion', bufnr)
          then
            all_answered = false
            break
          end
        end
      end
      if all_answered and session and not session:has_incomplete() then
        -- As the request below would: a trigger character that is also a
        -- keyword character can leave one pending, and it would fire on top.
        reset_timer()
        local generation = session.generation
        local anchor = session.anchor
        vim.schedule(function()
          if
            generation ~= session.generation
            or Session.peek(bufnr) ~= session
            or api.nvim_get_current_buf() ~= bufnr
            or not in_insert_mode()
          then
            return
          end
          -- v:char has landed by now, so this is the word it made: only publish
          -- when it is still the one the cache answered for.
          local ctx2 = line_context()
          if session_anchor(session, ctx2) == anchor then
            publish(session, ctx2)
          end
        end)
        return
      end
      matched_clients = vim.tbl_values(handle.identifier)
      ctx = { triggerKind = protocol.CompletionTriggerKind.Invoked }
    end
  end

  -- Discard pending trigger char, complete the "latest" one.
  -- Can happen if a mapping inputs multiple trigger chars simultaneously.
  reset_timer()
  if matched_clients then
    completion_timer = new_timer()
    completion_timer:start(25, 0, function()
      reset_timer()
      vim.schedule(function()
        trigger(api.nvim_get_current_buf(), matched_clients, ctx)
      end)
    end)
  end
end

--- @param handle vim.lsp.completion.BufHandle
--- @param client_id integer
local function remove_trigger_client(handle, client_id)
  for char, clients in pairs(handle.triggers) do
    --- @param c vim.lsp.Client
    local rest = vim.tbl_filter(function(c)
      return c.id ~= client_id
    end, clients)
    -- nil, not an empty list: on_insert_char_pre() reads any table as "some
    -- client wants this character" and then requests from nobody.
    handle.triggers[char] = next(rest) and rest or nil
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
  handle.identifier[client_id] = nil
  if handle.rank then
    handle.rank[client_id] = nil
  end
  if handle.secondary then
    handle.secondary[client_id] = nil
  end
  if not next(handle.clients) then
    buf_handles[bufnr] = nil
    -- Ended, not just forgotten: the handlers go with the group below, so a
    -- session left running would take keys with nobody to answer for it.
    Session.discard(bufnr, true)
    api.nvim_del_augroup_by_name(get_augroup(bufnr))
  else
    remove_trigger_client(handle, client_id)
  end
end

--- @inlinedoc
--- @class vim.lsp.completion.BufferOpts
--- @field autotrigger? boolean  (default: false) When true, completion triggers automatically based on the server's `triggerCharacters`.
--- @field identifier? boolean  (default: false) When true, completion also triggers while an identifier is being typed, which the LSP specification leaves to the client.
--- @field convert? fun(item: lsp.CompletionItem): table Transforms an LSP CompletionItem to |complete-items|.
--- @field cmp? fun(a: table, b: table): boolean Comparator for sorting merged completion items from all servers.
--- @field commit_characters? boolean  (default: true) When false, commit characters are ignored.
--- @field rank? integer Where this client's items go when the match scores do not separate them, lower first; clients without one come last.  Omitting it keeps what a previous call set.
--- @field secondary? boolean When true, an item of this client's is dropped if another client already offered the same word.  Omitting it keeps what a previous call set.
--- @field insert_mode? 'insert'|'replace' (default: "insert") How much of an |lsp.InsertReplaceEdit| is replaced: up to the cursor, or its whole replace range.

---@param client_id integer
---@param bufnr integer
---@param opts vim.lsp.completion.BufferOpts
local function enable_completions(client_id, bufnr, opts)
  local buf_handle = buf_handles[bufnr]
  if not buf_handle then
    buf_handle = { clients = {}, triggers = {}, identifier = {} }
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

  end

  -- The buffer's own, so the latest call wins rather than the first.  Omitted
  -- fields keep their value.
  for _, k in ipairs({ 'convert', 'cmp', 'commit_characters', 'insert_mode' }) do
    if opts[k] ~= nil then
      buf_handle[k] = opts[k]
    end
  end

  -- Not only on the first client: one that wants neither can come first.
  if (opts.autotrigger or opts.identifier) and not buf_handle.listening then
    buf_handle.listening = true
    local group = api.nvim_create_augroup(get_augroup(bufnr), { clear = false })
    nvim_on('InsertCharPre', group, { buf = bufnr }, function(ev)
      local handle = buf_handles[ev.buf]
      if handle then
        on_insert_char_pre(handle, ev.buf)
      end
    end)
  end

  -- Not only on the first enable: a client can be enabled again with other
  -- options, and a server can register different characters for this buffer.
  local client = lsp.get_client_by_id(client_id)
  if not client then
    return -- stopped between the LspAttach and this call
  end
  buf_handle.clients[client_id] = client
  buf_handle.identifier[client_id] = opts.identifier and client or nil
  -- Omitted keeps its value, like the buffer's own fields above: a caller
  -- enabling a client for another reason does not reorder what someone else set.
  buf_handle.rank = buf_handle.rank or {}
  buf_handle.secondary = buf_handle.secondary or {}
  if opts.rank ~= nil then
    buf_handle.rank[client_id] = opts.rank
  end
  if opts.secondary ~= nil then
    buf_handle.secondary[client_id] = opts.secondary or nil
  end
  remove_trigger_client(buf_handle, client_id)
  if opts.autotrigger then
    for _, char in ipairs(completion_options(client, bufnr).triggerCharacters or {}) do
      buf_handle.triggers[char] = buf_handle.triggers[char] or {}
      table.insert(buf_handle.triggers[char], client)
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
--- @note `autotrigger` and `identifier` are per client; the rest of {opts} is
--- the buffer's, and a field omitted keeps the value a previous call gave it.
---
--- @note A trigger character is served even with the menu up, since it opens a
--- context the menu cannot filter its way into.  |vim.lsp.completion.get()| is
--- not: what is on screen is filtered locally.
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
--- @field filter? fun(client: vim.lsp.Client): boolean Only request from enabled clients this returns true for. Defaults to all of them.

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

  -- Explicit unless it is the client following up on its own: this is the
  -- public entry point, so anything else here is the user asking.
  local following_up = ctx.triggerKind
    == protocol.CompletionTriggerKind.TriggerForIncompleteCompletions
  trigger(bufnr, clients, ctx, not following_up)
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

  trigger(bufnr, clients, { triggerKind = protocol.CompletionTriggerKind.Invoked }, true)

  -- Return -2 to signal that we should continue completion so that we can
  -- async complete.
  return -2
end

return M
