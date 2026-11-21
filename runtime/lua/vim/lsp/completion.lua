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

-- A round is dropped between a keystroke and the engine by: the debounce
-- timer, a stale `generation`, Session.peek() no longer returning it, the
-- context re-read at publish time, or Session:cancel_request().

local M = {}

local api = vim.api
local nvim_on = require('vim._core.util').nvim_on
local lsp = vim.lsp
local protocol = lsp.protocol

local ns_to_ms = 0.000001

--- @alias vim.lsp.CompletionResult lsp.CompletionList | lsp.CompletionItem[]

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
--- @field secondary? table<integer, true> Clients whose items are left out
--- while another client offers any, by id.
--- @field autotrigger? table<integer, true> Clients asked on their trigger
--- characters, by id.
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
--- @field position? lsp.Position where it was asked, which the edit ranges refer to

--- @param flag string
--- @return boolean
local function has_completeopt(flag)
  -- 'completeopt' is global-local: vim.o gives what the engine reads.
  return vim.list_contains(vim.split(vim.o.completeopt, ',', { trimempty = true }), flag)
end

--- @param window integer
--- @param warmup integer
--- @return fun(sample: number): number
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
--- Round-trip time per set of clients: a round waits for its slowest, and the
--- in-process server answers far sooner than a language server.
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
--- @return number
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

--- Up to the first line break, which most texts do not have.
--- @param text string
--- @return string
local function first_line(text)
  local eol = text:find('[\r\n]')
  return eol and text:sub(1, eol - 1) or text
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
      local text = parse_snippet(
        (item.textEdit and item.textEdit.newText) or assert(nonempty(item.insertText))
      )
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
    local word = first_line(item.textEdit.newText)
    return word, word
  elseif nonempty(item.insertText) then
    -- First line only, as for textEdit: every column is measured on compl_lnum.
    local text = item.insertText --[[@as string]]
    return first_line(text), text
  end
  return item.label, item.label
end

--- Applies the given defaults to the completion item, modifying it in place.
---
--- @param item lsp.CompletionItem
--- @param defaults lsp.CompletionItemDefaults?
--- @param apply_kind lsp.CompletionItemApplyKinds?
local function apply_defaults(item, defaults, apply_kind)
  if not defaults then
    return
  end

  -- Unset means Replace for every field.
  apply_kind = apply_kind or {}

  local merge = apply_kind.commitCharacters == protocol.ApplyKind.Merge
    and defaults.commitCharacters

  item.commitCharacters = merge
      -- No dedup, it ends up as a flat string anyway.
      and vim.list_extend(item.commitCharacters or {}, merge)
    -- An empty list means no commit chars, not use the defaults.
    or (item.commitCharacters or defaults.commitCharacters)

  item.insertTextFormat = item.insertTextFormat or defaults.insertTextFormat
  item.insertTextMode = item.insertTextMode or defaults.insertTextMode

  item.data = apply_kind.data == protocol.ApplyKind.Merge
      and type(defaults.data) == 'table'
      and type(item.data) == 'table'
      and vim.tbl_extend('force', defaults.data, item.data)
    or vim.nonnil(item.data, defaults.data)

  if defaults.editRange and not item.textEdit then
    local textEdit = item.textEdit or {}
    item.textEdit = textEdit --[[@as lsp.TextEdit|lsp.InsertReplaceEdit]]
    textEdit.newText = textEdit.newText
      or item.textEditText
      or nonempty(item.insertText)
      or item.label
    -- Only for an item without a range of its own.
    if not (textEdit.range or textEdit.insert) then
      if defaults.editRange.start then
        textEdit.range = defaults.editRange
      elseif defaults.editRange.insert then
        textEdit.insert = defaults.editRange.insert
        textEdit.replace = defaults.editRange.replace
      end
    end
  end
end

--- Completion options for a buffer, fields from a dynamic registration.
---
--- @param client vim.lsp.Client
--- @param bufnr integer
--- @return lsp.CompletionOptions
local function completion_options(client, bufnr)
  local static = client.server_capabilities.completionProvider or {}
  for _, reg in ipairs(client:_get_registrations('completionProvider', bufnr) or {}) do
    local opts = reg.registerOptions
    if type(opts) == 'table' then
      return vim.tbl_extend('keep', opts, static)
    end
  end
  return static
end

--- @param result vim.lsp.CompletionResult
--- @return lsp.CompletionItem[]
function M._get_items(result)
  if result.items then
    -- When we have a list, apply the defaults and return an array of items.
    for _, item in ipairs(result.items) do
      apply_defaults(item, result.itemDefaults, result.applyKind)
    end
    result.itemDefaults = nil
    return result.items
  else
    -- Else just return the items as they are.
    ---@cast result lsp.CompletionItem[]
    return result
  end
end

---Returns an item's documentation value and its markup kind.
---@param item lsp.CompletionItem
---@return string
---@return lsp.MarkupKind
local function get_doc(item)
  local doc = item.documentation
  local default_kind = protocol.MarkupKind.Markdown
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
  if not protocol.CompletionItemKind[item.kind] then
    return 'Unknown'
  end
  if item.kind ~= protocol.CompletionItemKind.Color then
    return protocol.CompletionItemKind[item.kind] --[[@as string]]
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
---@param popup boolean 'completeopt' has "popup"
---@return string
---@return lsp.MarkupKind
---@return boolean complete
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
    local text = (item.textEdit and item.textEdit.newText) or nonempty(item.insertText)
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
  -- A guess (#30905), so the first character is checked before scanning; "-1"
  -- or ".5" can still be read as reaching back.
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
--- @param encoding? 'utf-8'|'utf-16'|'utf-32'
--- @param compl_col integer 0-indexed session column
--- @param cursor_col integer 0-indexed
--- @param text string? what the item puts in the buffer, snippets expanded
--- @return integer?
local function item_edit_start(item, line, lnum, encoding, compl_col, cursor_col, text)
  if line and lnum and encoding and item.textEdit then
    local range = item.textEdit.range or item.textEdit.insert
    -- Both ends on this line: a range leaving it has no column to measure.
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
--- @field prefix string what it is matched against: the line from that column, or
--- from the session column when it starts in front, to the cursor
--- @field filter string what it is filtered by
--- @field rewrite integer? 0-indexed column the edit is applied from on accept,
--- when the engine cannot start the word there

--- The "values" the engine may show for "prefix": by prefix ignoring case, or with
--- "fuzzy" by matchfuzzy().  Non-ASCII text, which lower() cannot fold, is kept.
--- @param values string[]
--- @param prefix string
--- @return table<string, true>
local function may_show(values, prefix)
  local shown = {} --- @type table<string, true>
  local multibyte = prefix:find('[\128-\255]') ~= nil
  local lower = prefix:lower()
  for _, value in ipairs(values) do
    local head = value:sub(1, #prefix)
    if multibyte or head:lower() == lower or head:find('[\128-\255]') then
      shown[value] = true
    end
  end
  if has_completeopt('fuzzy') then
    local matched = vim.fn.matchfuzzy(values, prefix) --- @type string[]
    for _, value in ipairs(matched) do
      shown[value] = true
    end
  end
  return shown
end

--- Resolves the item defaults and works out where each item replaces from.
---
--- @param result vim.lsp.CompletionResult
--- @param line string?
--- @param lnum integer? 0-indexed
--- @param cursor_col integer 0-indexed
--- @param compl_col integer 0-indexed session column
--- @param encoding? 'utf-8'|'utf-16'|'utf-32'
--- @return vim.lsp.completion.Prepared[]
local function prepare_items(result, line, lnum, cursor_col, compl_col, encoding)
  local out = {} --- @type vim.lsp.completion.Prepared[]
  for _, item in ipairs(M._get_items(result)) do
    local word, text = get_completion_word(item)
    local start = item_edit_start(item, line, lnum, encoding, compl_col, cursor_col, text)

    -- What is in front of the session column was not typed: left out of what it
    -- is filtered by, where the spec puts it in.
    -- The label without clangd's leading decoration.
    local filter = nonempty(item.filterText) or (item.label:gsub('^%s+', ''))
    local rewrite --- @type integer?
    local keep = true
    if line and start and start < compl_col then
      local pad = line:sub(start + 1, compl_col)
      local padded = filter:sub(1, #pad):lower() == pad:lower()
      if padded then
        filter = filter:sub(#pad + 1)
      end
      -- The engine keeps the text in front, so an edit changing it (`.` to `->`,
      -- or only its case) is applied on accept and the word is what VS Code
      -- filters by.  Not when what was typed there does not match.
      if word:sub(1, #pad) ~= pad then
        keep = padded or vim.fn.match(pad, [[\k]]) == -1
        rewrite, start = start, nil
        word = filter:gsub('^%s+', '')
        filter = word
      end
    end
    if line and start and start > compl_col then
      -- The engine takes no item after the column: the text up to it goes in front.
      word = line:sub(compl_col + 1, start) .. word
      filter, rewrite, start = word, start, nil
    end
    local prefix = line and line:sub(compl_col + 1, cursor_col) or ''

    if keep then
      out[#out + 1] = {
        item = item,
        word = word,
        start = start,
        rewrite = rewrite,
        prefix = prefix,
        filter = filter,
      }
    end
  end
  return out
end

--- Turns the result of a `textDocument/completion` request into vim-compatible
--- |complete-items|.
---
--- @param result vim.lsp.CompletionResult Result of `textDocument/completion`
--- @param line string current line content
--- @param compl_col integer 0-indexed session column
--- @param cursor_col integer
--- @param client_id integer? Client ID
--- @param lnum integer? 0-indexed line number
--- @param encoding? 'utf-8'|'utf-16'|'utf-32' encoding
--- @param bufnr integer? the session's buffer; the current one when absent
--- @return table[] # |complete-items|
--- @return table<table, { start: integer }> # what build_view()
--- orders them by, keyed by the item it made
function M._lsp_to_complete_items(
  result,
  line,
  compl_col,
  cursor_col,
  client_id,
  lnum,
  encoding,
  bufnr
)
  local prepared = prepare_items(result, line, lnum, cursor_col, compl_col, encoding)
  if vim.tbl_isempty(prepared) then
    return {}, {}
  end

  local candidates = {} --- @type table[]
  --- Kept beside the items, out of the "user_data" users see; build_view() sorts by it.
  --- @type table<table, { start: integer }>
  local order = {}
  local popup = has_completeopt('popup')
  -- A session leaves the filtering to the engine.
  local session = bufnr ~= nil
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

  local all_commit_chars = client and completion_options(client, bufnr).allCommitCharacters
  local all_commit_str = all_commit_chars and commit_chars_str(all_commit_chars) or nil

  -- Grouped by each item's own prefix.  One without \k filters nothing; \k, not
  -- %w, which stops at a multibyte character.
  local by_prefix = {} --- @type table<string, string[]>
  for _, entry in ipairs(prepared) do
    local values = by_prefix[entry.prefix] or {}
    by_prefix[entry.prefix] = values
    values[#values + 1] = entry.filter
  end
  local shows = {} --- @type table<string, table<string, true>|false>
  for prefix, values in pairs(session and {} or by_prefix) do
    shows[prefix] = prefix ~= '' and vim.fn.match(prefix, [[\k]]) ~= -1 and may_show(values, prefix)
  end

  for _, entry in ipairs(prepared) do
    local item = entry.item
    local word = entry.word
    local item_start = entry.start
    local filter_text = entry.filter
    local shown = shows[entry.prefix]

    -- Not a blank row that would insert nothing, nor one the menu cannot show.
    if
      word ~= ''
      and (not shown or shown[filter_text] or (item.textEdit and not item.textEdit.newText))
    then
      local hl_group = ''
      if
        ---@diagnostic disable-next-line: deprecated
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
            rewrite_col = entry.rewrite,
          },
        },
      }
      local completion_item = {
        word = word,
        filter_text = filter_text ~= word and filter_text or nil,
        -- Absent means the session column, which an item may start on either side of.
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
        -- Merged: everything downstream reads user_data.nvim.lsp, and a convert may
        -- return its own "user_data", a table or not (|complete-items|).
        completion_item.user_data = type(converted.user_data) == 'table'
            and vim.tbl_deep_extend('force', converted.user_data, user_data) --[[@as { nvim: table }]]
          or user_data
      end
      candidates[#candidates + 1] = completion_item
      order[completion_item] = { start = item_start or entry.rewrite or compl_col }
    end
  end

  if not user_cmp then
    -- Once per item rather than per comparison, which a sort does n log n times.
    local sort_text = {} --- @type table<table, string>
    for _, c in ipairs(candidates) do
      local item = c.user_data.nvim.lsp.completion_item --- @type lsp.CompletionItem
      sort_text[c] = nonempty(item.sortText) or item.label
    end
    table.sort(candidates, function(a, b)
      return sort_text[a] < sort_text[b]
    end)
  end

  return candidates, order
end

--- Read fresh each time: every column indexes `line`.
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

--- One per buffer: the positions it holds index that buffer.
---
--- @nodoc
--- @class vim.lsp.completion.Session
--- @field bufnr integer
--- @field responses table<integer, { result: vim.lsp.CompletionResult, encoding: 'utf-8'|'utf-16'|'utf-32', position?: lsp.Position }>
--- @field incomplete table<integer, true> clients that asked to be re-queried
--- @field other_items table[]? candidates the builtin sources collected, kept
--- only until vim._core.completion.source collects them here too
--- @field id integer? engine session id from nvim__complete(); this and the three
--- below describe one engine session and are set and cleared together
--- @field col integer? 1-based column the engine session is anchored at
--- @field leader string? leader as of the last CompleteChanged
--- @field anchor? string Row and column the cached responses were asked from;
--- they describe the word starting there and nothing else.
--- @field empty_for? string Leader the cache answered nothing for: a longer one
--- matches nothing either.  trigger() drops it.
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
    -- Only forgotten: insert_handle_key_post() cancels the other window's session.
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
  self.empty_for = nil
  local id = self.id
  self.id = nil
  self.col = nil
  self:cancel_request()
  if self.resolver then
    self.resolver:cleanup()
    self.resolver = nil
  end
  if stop and id then
    -- Last, once nothing is left to clean up: stopping fires CompleteDone.
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
      -- Already past ins_compl_add()'s checks; "icase" is lost, complete_info() lacks it.
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
--- @param incomplete table<integer, true?> clients whose list for this word is incomplete
--- @param callback fun(responses: table<integer, vim.lsp.completion.Response>)
--- @return function # Cancellation function
local function request(clients, bufnr, win, ctx, incomplete, callback)
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
    -- Asked about this word for the first time: nothing of its is incomplete.
    if
      ctx
      and ctx.triggerKind == protocol.CompletionTriggerKind.TriggerForIncompleteCompletions
      and not incomplete[client_id]
    then
      params.context = { triggerKind = protocol.CompletionTriggerKind.Invoked }
    end
    outstanding = outstanding + 1
    local ok, request_id = client:request('textDocument/completion', params, function(err, result)
      responses[client_id] = { err = err, result = result, position = params.position }
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
    if kind == protocol.MarkupKind.Markdown then
      vim.wo[winid].conceallevel = 2
      vim.treesitter.start(bufnr, kind)
    else
      vim.wo[winid].conceallevel = 0
      vim.treesitter.stop(bufnr)
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
--- @field doc_rtt_ms number Last request timestamp
--- @field doc_compute_new_average fun(sample: number): number Last request timestamp
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
  return self.bufnr ~= nil
    and api.nvim_buf_is_valid(self.bufnr)
    and api.nvim_get_current_buf() == self.bufnr
    and vim.startswith(api.nvim_get_mode().mode, 'i')
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
    local client = client_id and lsp.get_client_by_id(client_id)
    -- completionItem/resolve is not registrable, so supports_method() would
    -- only see the static capability.
    if not client or not completion_options(client, bufnr).resolveProvider then
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
        local windata = api.nvim__complete_set(cmp_info.selected, { info = info })
        update_popup_window(windata.winid, windata.bufnr, kind)
      end
    end, bufnr)
  end, math.floor(debounce_time))
end

--- @param t table<integer, any>
--- @return integer[]
local function sorted_keys(t)
  local keys = vim.tbl_keys(t) --- @type integer[]
  table.sort(keys)
  return keys
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
  -- In the caller's order, which the sort below falls back to.
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
  --- @type table<integer, table<table, { start: integer }>>
  local order = {}
  --- @type table<table, { start: integer, client_id: integer, sort_text: string, pos: integer }>
  local by_item = {}
  local seen = {} --- @type table<string, true>
  for _, client_id in ipairs(ids) do
    local cached = session.responses[client_id]
    converted[client_id], order[client_id] = M._lsp_to_complete_items(
      cached.result,
      line,
      compl_col,
      cursor_col,
      client_id,
      lnum,
      cached.encoding,
      session.bufnr
    )
    if not secondary[client_id] then
      for _, item in ipairs(converted[client_id]) do
        seen[item.word] = true
      end
    end
  end

  local matches = {} --- @type table[]
  for _, client_id in ipairs(ids) do
    -- As VS Code's word-based suggestions: only when no server has any.
    if not (secondary[client_id] and next(seen)) then
      for _, item in ipairs(converted[client_id]) do
        matches[#matches + 1] = item
        -- compl_col, not 0, so an item without one does not sort ahead of everything.
        local how = (order[client_id] or {})[item] or { start = compl_col }
        local lsp_item = item.user_data.nvim.lsp.completion_item --- @type lsp.CompletionItem
        by_item[item] = {
          start = how.start,
          client_id = client_id,
          sort_text = nonempty(lsp_item.sortText) or lsp_item.label,
          pos = #matches,
        }
      end
    end
  end

  local user_cmp = vim.tbl_get(buf_handles, session.bufnr, 'cmp')
  if user_cmp then
    table.sort(matches, user_cmp)
  elseif not has_completeopt('nosort') then
    -- Ends on the collected order, which the engine keeps between equal fuzzy scores.
    table.sort(matches, function(a, b)
      local x, y = by_item[a], by_item[b]
      -- Start column first: one reaching further back answers a different word.
      if (x.start or 0) ~= (y.start or 0) then
        return (x.start or 0) < (y.start or 0)
      end
      -- Then the caller's order: "sortText" only ranks a server's own items.
      local rx = rank[x.client_id] or math.huge
      local ry = rank[y.client_id] or math.huge
      if rx ~= ry then
        return rx < ry
      end
      -- Unranked clients by id, as before rank existed.
      if x.client_id ~= y.client_id then
        return x.client_id < y.client_id
      end
      if x.sort_text ~= y.sort_text then
        return x.sort_text < y.sort_text
      end
      return x.pos < y.pos
    end)
  end

  -- Builtin candidates first, as before the list was replaced, minus server words.
  local view = {} --- @type table[]
  for _, m in ipairs(session.other_items or {}) do
    if not seen[m.word] then
      view[#view + 1] = m
    end
  end
  vim.list_extend(view, matches)
  return view
end

--- Set while our nvim__complete() runs: the CompleteDone it fires keeps the cache.
local calling = false

--- Hands a new list to the completion engine.
---
--- @param session vim.lsp.completion.Session
--- @param ctx vim.lsp.completion.LineContext
local function do_publish(session, ctx)
  -- Nothing matched a shorter leader, so nothing matches this one: no conversion
  -- on every keystroke of a word without candidates.
  local leader = ctx.line:sub(ctx.word_col + 1, ctx.cursor_col)
  if
    session.empty_for
    and #leader > #session.empty_for
    and vim.startswith(leader, session.empty_for)
  then
    return
  end

  session:capture_other_items()

  if session.id then
    -- A running session pins the column, and its leader replaces the shown match,
    -- which sits in the line and would move the `\k*$` boundary.
    local col = assert(session.col)
    local line, cursor_col = ctx.line, ctx.cursor_col
    if session.leader then
      line = ctx.line:sub(1, col - 1) .. session.leader .. ctx.line:sub(cursor_col + 1)
      cursor_col = col - 1 + #session.leader
    end
    local view = build_view(session, ctx.row - 1, line, col - 1, cursor_col)
    -- An empty list ends the session (it would take <C-n>); the cache stays for <BS>.
    calling = true
    local id = #view > 0 and api.nvim__complete({ id = session.id, items = view })
      or api.nvim__complete({ id = session.id })
    calling = false
    if #view > 0 and id > 0 then
      session.empty_for = nil
      return
    end
    session.id, session.col, session.leader = nil, nil, nil
    if #view == 0 or id == 0 then
      session.empty_for = line:sub(col, cursor_col)
      return
    end
    -- Ended during the request, or another window's: start a new one below.
  end

  local col = ctx.word_col + 1
  local view = build_view(session, ctx.row - 1, ctx.line, ctx.word_col, ctx.cursor_col)
  if #view == 0 then
    session.empty_for = leader
    return -- not started on an empty list, for the same reason
  end
  session.empty_for = nil
  calling = true
  local id = api.nvim__complete({ col = col, items = view })
  calling = false
  if id == 0 then
    session.empty_for = leader -- nothing matched what is typed
  elseif id > 0 then
    session.id, session.col = id, col
    -- Seeded: the first CompleteChanged fires before the id is known.
    session.leader = ctx.line:sub(ctx.word_col + 1, ctx.cursor_col)
  end
end

--- @param session vim.lsp.completion.Session
--- @param ctx vim.lsp.completion.LineContext
local function publish(session, ctx)
  -- Reported, not raised: in a scheduled callback each keystroke would raise it again.
  local ok, err = pcall(do_publish, session, ctx)
  if not ok then
    vim.notify_once(('vim.lsp.completion: %s'):format(err), vim.log.levels.ERROR)
    session:reset(true)
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
  local ident = vim.tbl_get(buf_handles, bufnr, 'identifier') or {}
  -- Incomplete ones, and identifier clients a trigger character did not reach.
  local function asked()
    local ids = {} --- @type integer[]
    local clients = vim.tbl_get(buf_handles, bufnr, 'clients') or {} --- @type table<integer, vim.lsp.Client>
    for _, client in pairs(clients) do
      if sess.incomplete[client.id] or (sess.responses[client.id] == nil and ident[client.id]) then
        ids[#ids + 1] = client.id
      end
    end
    return ids
  end
  local debounce_ms = adaptive_debounce(sess.last_request_time, rtt_for_ids(asked()).rtt_ms)
  local function run()
    if api.nvim_get_current_buf() == bufnr and Session.peek(bufnr) == sess then
      M.get({
        ctx = { triggerKind = protocol.CompletionTriggerKind.TriggerForIncompleteCompletions },
        client_id = asked(),
      })
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
--- @param explicit? boolean The user asked: it replaces a shown list and starts
--- from nothing.  Not in "ctx", whose "Invoked" also covers typing an identifier.
local function trigger(bufnr, clients, ctx, explicit)
  reset_timer()

  local session = Session.get(bufnr)
  session:cancel_request()

  -- A trigger character or an explicit request replaces the shown list in place.
  local wanted = explicit == true
    or (ctx and ctx.triggerKind) == protocol.CompletionTriggerKind.TriggerCharacter
  if vim.fn.pumvisible() ~= 0 and not wanted and not session:has_incomplete() then
    return
  end

  -- Kept for the same word unless asked explicitly: only the clients asked answer
  -- again, and absolute ranges make another word start invalidate it all.
  local anchor = session_anchor(session, line_context())
  local retrigger = not explicit and session.anchor == anchor
  if not retrigger then
    session.responses = {}
    session.incomplete = {}
  end
  -- A round is about to change the cache, kept or not.
  session.empty_for = nil
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
  local cancel = request(clients, bufnr, win, ctx, session.incomplete, function(responses)
    settled = true
    -- Cancelling is best effort; a stale callback must not overwrite this one.
    ---@diagnostic disable-next-line: preferred-local-alias
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
            position = response.position,
          }
          session.incomplete[client_id] = result.isIncomplete or nil
        end
      end
    end

    -- nvim__complete changes text, which the <C-x><C-o> textlock forbids.
    vim.schedule(function()
      ---@diagnostic disable-next-line: preferred-local-alias
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
--- A shrinking leader re-asks only incomplete clients: the engine holds the rest.
---
--- @param leader string?
function Session:on_leader(leader)
  if not self.id then
    -- Not ours: a native <C-n> or another plugin's complete() also gets here.
    return
  end
  local prev = self.leader
  self.leader = leader
  if not (prev and leader and #leader < #prev) then
    return
  end

  if self:has_incomplete() then
    request_incomplete(self)
  end
end

--- @param bufnr integer
local function on_complete_done(bufnr)
  local completed_item = api.nvim_get_vvar('completed_item') --- @type vim.v.completed_item
  local lsp_data = vim.tbl_get(completed_item or {}, 'user_data', 'nvim', 'lsp')
  local completion_item = lsp_data and lsp_data.completion_item --- @type lsp.CompletionItem?
  local client_id = lsp_data and lsp_data.client_id --- @type integer?

  local cursor_row, cursor_col = unpack(api.nvim_win_get_cursor(0)) --- @type integer, integer
  cursor_row = cursor_row - 1

  local session = Session.peek(bufnr)
  -- CompleteDone carries no column, and the accepted match moved `\k*$`.
  local session_col = session and session.col
  local position = session and client_id and vim.tbl_get(session.responses, client_id, 'position')
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

  --- Removes what the edit's range covers past the cursor, which the engine leaves:
  --- a TextEdit's range, or under 'replace' an `lsp.InsertReplaceEdit`'s replace
  --- range.  Counted in characters, as the engine rewrote the line before the cursor.
  local function apply_replace_range()
    local edit = completion_item.textEdit
    if not edit then
      return
    end
    local range = (edit --[[@as lsp.TextEdit]]).range --- @type lsp.Range?
    local insert_replace = edit --[[@as lsp.InsertReplaceEdit]]
    local replace, insert = insert_replace.replace, insert_replace.insert
    local extra --- @type integer?
    if range then
      -- From where it was asked: what was typed since went in before the cursor.
      if position and range['end'].line == position.line then
        extra = (range['end'].character - position.character) --[[@as integer]]
      end
    elseif
      vim.tbl_get(buf_handles, bufnr, 'insert_mode') == 'replace'
      and replace
      and insert
      and replace['end'].line == insert['end'].line
    then
      extra = replace['end'].character - insert['end'].character
    end
    if not extra or extra <= 0 then
      return
    end
    local line = assert(api.nvim_buf_get_lines(bufnr, cursor_row, cursor_row + 1, true)[1])
    local from = vim.str_utfindex(line, position_encoding, cursor_col, false)
    local end_col = vim.str_byteindex(line, position_encoding, from + extra, false)
    if end_col > cursor_col then
      api.nvim_buf_set_text(bufnr, cursor_row, cursor_col, cursor_row, end_col, { '' })
    end
  end

  local rewrite_col = lsp_data.rewrite_col --- @type integer?

  local function clear_word()
    if not expand_snippet and not rewrite_col then
      return
    end
    -- An item that replaces text in front of the word carries its own column.
    local col = completed_item.startcol or session_col --- @type integer?
    local start_col = rewrite_col or (col and col - 1) --- @type integer?
    if not start_col then
      return
    end

    -- Remove the already inserted word, or put the edit in its place.
    local edit = not expand_snippet and completion_item.textEdit
    local lines = vim.split(edit and edit.newText or '', '\n', { plain = true })
    api.nvim_buf_set_text(bufnr, cursor_row, start_col, cursor_row, cursor_col, lines)
    if edit then
      local last = #lines[#lines] + (#lines == 1 and start_col or 0) --- @type integer
      api.nvim_win_set_cursor(0, { cursor_row + #lines, last })
    end
  end

  local function exec_command()
    local command = completion_item.command
    if command then
      client:exec_cmd(command, { bufnr = bufnr })
    end
  end

  --- @param edits lsp.TextEdit[]
  local function apply_additional_edits(edits)
    -- The edits can move the cursor; keep it where it was.
    lsp.util.apply_text_edits(edits, bufnr, position_encoding, nil, { keep_cursor = true })
  end

  -- Before the edits below, which move the cursor this span is measured from.
  apply_replace_range()
  clear_word()

  local edits = completion_item.additionalTextEdits
  local has_edits = edits ~= nil and next(edits) ~= nil
  if has_edits then
    apply_additional_edits(assert(edits))
  end
  if expand_snippet then
    apply_snippet(completion_item)
  end

  -- Nothing to gain if the item carried its edits, or it cannot be resolved.
  if has_edits or not resolve_provider or type(completion_item) ~= 'table' then
    exec_command()
    return
  end

  --- @param result lsp.CompletionItem
  client:request('completionItem/resolve', completion_item, function(err, result)
    if not api.nvim_buf_is_valid(bufnr) then
      return
    end
    if err then
      vim.notify_once(err.message, vim.log.levels.WARN)
    elseif result then
      if result.additionalTextEdits then
        apply_additional_edits(result.additionalTextEdits)
      end
      -- A resolved command replaces the one the item came with.
      if result.command then
        completion_item.command = result.command
      end
    end
    exec_command()
  end, bufnr)
end

--- @nodoc
--- The session's autocommands; trigger() calls it too, for 'omnifunc' without enable().
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
    elseif not calling then
      -- Not the completion ours is taking over; the cache holds then.
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

  -- Leaving the buffer in Insert mode (<Cmd>, nvim_set_current_buf()) ends the
  -- engine session without the CompleteDone above; reset only, it is cancelled.
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
    session.resolver:request(bufnr, user_data.completion_item, assert(completed_item.word))
  end
end

--- <BS> out of a word nothing matched: no session is left for CompleteChanged to
--- report it, so the list is asked for, or published from the cache, again.
--- @param bufnr integer
local function on_text_changed(bufnr)
  local session = Session.peek(bufnr)
  if not (session and session.empty_for and not session.id) then
    return
  end
  local ctx = line_context()
  if session_anchor(session, ctx) ~= session.anchor then
    return
  end
  -- Typed rather than deleted: InsertCharPre has seen it.
  if #ctx.line:sub(ctx.word_col + 1, ctx.cursor_col) >= #session.empty_for then
    return
  end
  if session:has_incomplete() then
    request_incomplete(session)
  else
    publish(session, ctx)
  end
end

--- @param handle vim.lsp.completion.BufHandle
--- @param bufnr integer
local function on_insert_char_pre(handle, bufnr)
  local session = Session.peek(bufnr)
  local char = vim.v.char

  -- Before the guards: a trigger character opens a context filtering cannot reach.
  local matched_clients = handle.triggers[char]
  local ctx = matched_clients
    and {
      triggerKind = protocol.CompletionTriggerKind.TriggerCharacter,
      triggerCharacter = char,
    }

  -- A character goes only to the clients that asked for it.
  if not matched_clients then
    -- Same anchor only: past it trigger() drops the cache, which this subset cannot refill.
    if
      session
      and session:has_incomplete()
      and session.anchor == session_anchor(session, line_context())
    then
      request_incomplete(session)
      return
    end
    if vim.fn.pumvisible() ~= 0 then
      return -- the engine filters what it has
    end
  end

  -- Per the LSP spec, identifiers are the client's: servers list only other
  -- characters.  Only at the end of a word, and not for a number.
  if not ctx and next(handle.identifier or {}) then
    local col = api.nvim_win_get_cursor(0)[2]
    local line = api.nvim_get_current_line()
    -- The leader, not the match: ins_compl_addleader() has not taken it back yet.
    if session and session.id and session.col and session.leader then
      line = line:sub(1, session.col - 1) .. session.leader .. line:sub(col + 1)
      col = session.col - 1 + #session.leader
    end
    local word = vim.fn.matchstr(line:sub(1, col) .. char, [[\k*$]])
    if word ~= '' and tonumber(word) == nil and vim.fn.match(line:sub(col + 1), [[^\k]]) ~= 0 then
      -- Every identifier client answered this word completely, so typing narrows the cache.
      local all_answered = session ~= nil
        and session.anchor == session_anchor(session, line_context())
      if all_answered and session then
        for id, c in pairs(handle.identifier) do
          -- A server without completion never answers.
          if not session.responses[id] and c:supports_method('textDocument/completion', bufnr) then
            all_answered = false
            break
          end
        end
      end
      if all_answered and session and not session:has_incomplete() then
        -- A trigger character that is also a keyword character may have left one pending.
        reset_timer()
        local generation = session.generation
        local anchor = session.anchor
        vim.schedule(function()
          if
            ---@diagnostic disable-next-line: preferred-local-alias
            generation ~= session.generation
            or Session.peek(bufnr) ~= session
            or api.nvim_get_current_buf() ~= bufnr
            or not in_insert_mode()
          then
            return
          end
          -- v:char has landed: publish only if the cache still answers this word.
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
    -- nil, not {}: on_insert_char_pre() takes any table as a client wanting it.
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
  if handle.autotrigger then
    handle.autotrigger[client_id] = nil
  end
  if not next(handle.clients) then
    buf_handles[bufnr] = nil
    -- Ended: with the handlers gone, a running session would take keys unanswered.
    Session.discard(bufnr, true)
    api.nvim_del_augroup_by_name(get_augroup(bufnr))
  else
    remove_trigger_client(handle, client_id)
  end
end

--- @inlinedoc
--- @class vim.lsp.completion.BufferOpts
--- @field autotrigger? boolean  (default: false) When true, completion triggers automatically based on the server's `triggerCharacters`.
--- @field identifier? boolean  (default: false) When true, completion also triggers while an identifier is being typed.
--- @field convert? fun(item: lsp.CompletionItem): table Transforms an LSP CompletionItem to |complete-items|.
--- @field cmp? fun(a: table, b: table): boolean Comparator for sorting merged completion items from all servers.
--- @field commit_characters? boolean  (default: true) When false, commit characters are ignored.
--- @field package _rank? integer Where this client's items go when the match scores do not separate them, lower first; clients without one come last.
--- @field package _secondary? boolean When true, this client's items are left out while another client offers any.
--- @field insert_mode? 'insert'|'replace' (default: "insert") How much of an `lsp.InsertReplaceEdit` is replaced: up to the cursor, or its whole replace range.

---@param client_id integer
---@param bufnr integer
---@param opts vim.lsp.completion.BufferOpts
local function enable_completions(client_id, bufnr, opts)
  local buf_handle = buf_handles[bufnr]
  if not buf_handle then
    buf_handle = { clients = {}, triggers = {}, identifier = {} }
    buf_handles[bufnr] = buf_handle

    -- Set up autocommands.
    local group = register_session_autocmds(bufnr)
    nvim_on('BufUnload', group, {
      buf = bufnr,
      desc = 'vim.lsp.completion: clean up on unload',
    }, function(ev)
      buf_handles[ev.buf] = nil
      Session.discard(ev.buf)
      api.nvim_del_augroup_by_id(group)
    end)
    nvim_on('LspDetach', group, {
      buf = bufnr,
      desc = 'vim.lsp.completion: clean up client on detach',
    }, function(ev)
      disable_completions(ev.data.client_id, ev.buf)
    end)
  end

  -- Per buffer, latest call wins; omitted fields keep their value.
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
    nvim_on('TextChangedI', group, { buf = bufnr }, function(ev)
      if buf_handles[ev.buf] then
        on_text_changed(ev.buf)
      end
    end)
  end

  -- On every enable: options and registered characters can change.
  local client = lsp.get_client_by_id(client_id)
  if not client then
    return -- stopped between the LspAttach and this call
  end
  buf_handle.clients[client_id] = client
  -- Omitted keeps its value, as above.
  if opts.identifier ~= nil then
    buf_handle.identifier[client_id] = opts.identifier and client or nil
  end
  buf_handle.rank = buf_handle.rank or {}
  buf_handle.secondary = buf_handle.secondary or {}
  buf_handle.autotrigger = buf_handle.autotrigger or {}
  if opts._rank ~= nil then
    buf_handle.rank[client_id] = opts._rank
  end
  if opts._secondary ~= nil then
    buf_handle.secondary[client_id] = opts._secondary or nil
  end
  if opts.autotrigger ~= nil then
    buf_handle.autotrigger[client_id] = opts.autotrigger or nil
  end
  -- Again when kept: the server may declare other characters now.
  remove_trigger_client(buf_handle, client_id)
  if buf_handle.autotrigger[client_id] then
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
--- @note `autotrigger` and `identifier` are per client, the other fields per
--- buffer.  An omitted field keeps its previous value.
---
--- @note A trigger character, or |vim.lsp.completion.get()|, requests a new list
--- even while the menu is shown.
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
--- @field client_id? integer|integer[] Only request from these clients. Defaults to all clients with completion enabled.

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
  if opts.client_id then
    local ids = type(opts.client_id) == 'table' and opts.client_id or { opts.client_id }
    --- @cast ids integer[]
    clients = vim.tbl_filter(function(client)
      return vim.list_contains(ids, client.id)
    end, clients)
  end

  -- Explicit unless the client is following up: anything else is the user asking.
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
