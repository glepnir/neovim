--- Source registry for `vim.completion`.
---
--- This module validates and stores source specs, implements all builtin
--- sources for 'complete' option flags, and provides resolution for both
--- builtin and user-registered sources.

local log = require('vim._core.completion.log')

--- @alias vim.completion.SourceRefreshPolicy 'always'|'if_incomplete'|'never'
--- @alias vim.completion.SourceFilterMode 'engine'|'source'

--- @class vim.completion.SourceSpec
--- @field name string Unique source identifier.
--- @field priority? integer Higher = shown first. Default 500.
--- @field trigger_characters? string[]
--- @field keyword_pattern? string Vim regex for prefix boundary. Default `[[\k\+]]`.
--- @field min_prefix_len? integer Default 0.
--- @field max_items? integer Per-source item cap. Default 10000.
--- @field timeout? integer Per-source timeout in ms. Default 5000.
--- @field refresh? vim.completion.SourceRefreshPolicy Default `'always'`.
--- @field filter? vim.completion.SourceFilterMode Default `'engine'`.
--- @field get fun(ctx: vim.completion.Context, sink: vim.completion.SourceSink): nil|fun()
--- @field resolve? fun(item: vim.completion.Item, done: fun(err: any?, item: vim.completion.Item?))
--- @field execute? fun(ctx: vim.completion.ExecuteContext)
--- @field _order? integer Internal: stable registration order.
--- @field _keyword_regex? vim.regex Internal: compiled keyword regex.

--- @class vim.completion.Item
--- @field word string
--- @field abbr? string
--- @field kind? string
--- @field menu? string
--- @field info? string
--- @field filterText? string
--- @field sortText? string
--- @field preselect? boolean
--- @field dup? boolean
--- @field icase? boolean
--- @field user_data? any
--- @field source_name? string
--- @field _sort_key? string Internal: `tolower(filterText or word)`.
--- @field _match_score? number Internal: temporary, fuzzy only.

--- @class vim.completion.SourceSink
--- @field add fun(items: vim.completion.Item|vim.completion.Item[])
--- @field replace fun(items: vim.completion.Item[])
--- @field set_startcol fun(col: integer)  Set 0-based start column for this source.
--- @field done fun(meta?: vim.completion.SourceDoneMeta)
--- @field fail fun(err: any)

--- @class vim.completion.SourceDoneMeta
--- @field incomplete? boolean

--- @class vim.completion.Context
--- @field bufnr integer
--- @field cursor [integer, integer]
--- @field line string
--- @field prefix string
--- @field startcol integer
--- @field pattern? string  compl_pattern from C (set for specific ctrl_x modes).
--- @field reason 'manual'|'keyword'|'trigger_character'
--- @field trigger_character? string
--- @field limit integer
--- @field await fun(fn: fun(done: fun(...: any))): ...: any
--- @field cancelled fun(): boolean
--- @field on_cancel fun(fn: fun())

--- @class vim.completion.ExecuteContext
--- @field bufnr integer
--- @field item vim.completion.Item
--- @field source_name string
--- @field startcol integer
--- @field cursor [integer, integer]

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

--- @type table<integer, vim.completion.SourceHandle>
local registry = {}

--- @type table<string, integer>
local name_index = {}

local next_id = 1

--- @class vim.completion.SourceHandle
--- @field name string
--- @field _id integer
--- @field _spec vim.completion.SourceSpec
local SourceHandle = {}
SourceHandle.__index = SourceHandle

--- @return string
function SourceHandle:__tostring()
  return ('Source(%s:%d)'):format(self.name, self._id)
end

--- Unregister this source. Idempotent.
--- @return boolean removed
function SourceHandle:remove()
  if not registry[self._id] then
    return false
  end
  name_index[self.name] = nil
  registry[self._id] = nil
  log.debug('source %q removed', self.name)
  return true
end

--- @param policy string
local function validate_refresh(policy)
  if policy ~= 'always' and policy ~= 'if_incomplete' and policy ~= 'never' then
    error(("spec.refresh: expected 'always', 'if_incomplete', or 'never', got %q"):format(policy))
  end
end

--- @param mode string
local function validate_filter(mode)
  if mode ~= 'engine' and mode ~= 'source' then
    error(("spec.filter: expected 'engine' or 'source', got %q"):format(mode))
  end
end

--- @param pattern string
--- @return vim.regex
local function compile_keyword_regex(pattern)
  local ok, rx = pcall(vim.regex, pattern .. '$')
  if not ok then
    error(('spec.keyword_pattern: invalid regex %q'):format(pattern))
  end
  return rx
end

--- @param spec vim.completion.SourceSpec
local function validate_spec(spec)
  vim.validate('spec', spec, 'table')
  vim.validate('spec.name', spec.name, 'string')
  vim.validate('spec.get', spec.get, 'function')
  vim.validate('spec.priority', spec.priority, 'number', true)
  vim.validate('spec.trigger_characters', spec.trigger_characters, 'table', true)
  vim.validate('spec.keyword_pattern', spec.keyword_pattern, 'string', true)
  vim.validate('spec.min_prefix_len', spec.min_prefix_len, 'number', true)
  vim.validate('spec.max_items', spec.max_items, 'number', true)
  vim.validate('spec.timeout', spec.timeout, 'number', true)
  vim.validate('spec.resolve', spec.resolve, 'function', true)
  vim.validate('spec.execute', spec.execute, 'function', true)
  if spec.refresh ~= nil then
    validate_refresh(spec.refresh)
  end
  if spec.filter ~= nil then
    validate_filter(spec.filter)
  end
  if name_index[spec.name] then
    error(('completion source %q is already registered'):format(spec.name))
  end
end

local M = {}

--- Register a new completion source.
--- @param spec vim.completion.SourceSpec
--- @return vim.completion.SourceHandle
function M.add(spec)
  validate_spec(spec)

  local id = next_id
  next_id = next_id + 1
  local kw = spec.keyword_pattern or [[\k\+]]

  local handle = setmetatable({
    name = spec.name,
    _id = id,
    _spec = {
      name = spec.name,
      priority = spec.priority or 500,
      trigger_characters = spec.trigger_characters,
      keyword_pattern = kw,
      min_prefix_len = spec.min_prefix_len or 0,
      max_items = spec.max_items or 10000,
      timeout = spec.timeout or 5000,
      refresh = spec.refresh or 'always',
      filter = spec.filter or 'engine',
      get = spec.get,
      resolve = spec.resolve,
      execute = spec.execute,
      _order = id,
      _keyword_regex = compile_keyword_regex(kw),
    },
  }, SourceHandle)

  registry[id] = handle
  name_index[spec.name] = id
  log.debug('source %q registered (id=%d, priority=%d)', spec.name, id, handle._spec.priority)
  return handle
end

--- Return all registered source handles, sorted by priority descending
--- then registration order ascending.
--- @return vim.completion.SourceHandle[]
function M.get()
  local list = vim.tbl_values(registry)
  table.sort(list, function(a, b)
    if a._spec.priority ~= b._spec.priority then
      return a._spec.priority > b._spec.priority
    end
    return a._id < b._id
  end)
  return list
end

--- Resolve active source specs for a buffer filter.
--- @param filter? vim.completion.SourceFilter
--- @return vim.completion.SourceSpec[]
function M.resolve(filter)
  local include = filter and filter.include or nil
  local exclude = filter and filter.exclude or nil

  local specs = {} --- @type vim.completion.SourceSpec[]
  for id, handle in pairs(registry) do
    -- Skip builtin sources — they are resolved via resolve_cpt().
    if not handle._builtin then
      if (not include or include[id]) and (not exclude or not exclude[id]) then
        specs[#specs + 1] = handle._spec
      end
    end
  end

  table.sort(specs, function(a, b)
    if a.priority ~= b.priority then
      return a.priority > b.priority
    end
    return a._order < b._order
  end)

  return specs
end

--- @return boolean
function M.has_sources()
  return next(registry) ~= nil
end

--- Look up a source spec by name (including builtins).
--- @param name string
--- @return vim.completion.SourceSpec?
function M.get_by_name(name)
  local id = name_index[name]
  if id and registry[id] then
    return registry[id]._spec
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Builtin source implementations ('complete' option flags)
-- ---------------------------------------------------------------------------

local kw_regex = vim.regex([[\k\+]])

--- Scan a buffer for keyword words matching a prefix.
--- @param bufnr integer
--- @param prefix string
--- @return string[]
local function scan_buffer_words(bufnr, prefix)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return {}
  end

  local words = {} --- @type string[]
  local seen = {} --- @type table<string, true>
  local prefix_lower = vim.fn.tolower(prefix)
  local prefix_len = #prefix
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for _, line in ipairs(lines) do
    local pos = 0
    while pos < #line do
      -- vim.regex():match_str() takes a single string argument and
      -- ignores any second argument silently.  To resume scanning
      -- from `pos`, slice the line and add the offset back.  Without
      -- this, match_str always returns the same first match and the
      -- while loop spins forever.
      local s, e = kw_regex:match_str(line:sub(pos + 1))
      if s == nil then
        break
      end
      s = s + pos
      e = e + pos
      local word = line:sub(s + 1, e)
      if #word >= prefix_len and not seen[word] then
        if prefix_len == 0 or vim.fn.tolower(word):sub(1, prefix_len) == prefix_lower then
          seen[word] = true
          words[#words + 1] = word
        end
      end
      pos = e
    end
  end

  return words
end

--- '.' current buffer
--- @param ctx vim.completion.Context
--- @param sink vim.completion.SourceSink
local function get_current_buffer(ctx, sink)
  local words = scan_buffer_words(ctx.bufnr, ctx.prefix)
  for _, w in ipairs(words) do
    sink.add({ word = w })
  end
  sink.done()
end

--- 'w' other windows' buffers
--- @param ctx vim.completion.Context
--- @param sink vim.completion.SourceSink
local function get_windows_buffers(ctx, sink)
  local seen_bufs = { [ctx.bufnr] = true } --- @type table<integer, true>
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not seen_bufs[buf] then
      seen_bufs[buf] = true
      local words = scan_buffer_words(buf, ctx.prefix)
      for _, w in ipairs(words) do
        sink.add({ word = w })
      end
    end
  end
  sink.done()
end

--- 'b' all loaded buffers (excluding current)
--- @param ctx vim.completion.Context
--- @param sink vim.completion.SourceSink
local function get_loaded_buffers(ctx, sink)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= ctx.bufnr and vim.api.nvim_buf_is_loaded(buf) then
      local words = scan_buffer_words(buf, ctx.prefix)
      for _, w in ipairs(words) do
        sink.add({ word = w })
      end
    end
  end
  sink.done()
end

--- 'u' unloaded buffers
--- @param ctx vim.completion.Context
--- @param sink vim.completion.SourceSink
local function get_unloaded_buffers(ctx, sink)
  local prefix_lower = vim.fn.tolower(ctx.prefix)
  local prefix_len = #ctx.prefix
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not vim.api.nvim_buf_is_loaded(buf) then
      local fname = vim.api.nvim_buf_get_name(buf)
      if fname ~= '' then
        local ok, lines = pcall(vim.fn.readfile, fname)
        if ok then
          local seen = {} --- @type table<string, true>
          for _, line in ipairs(lines) do
            for word in line:gmatch('%w+') do
              if
                #word >= prefix_len
                and not seen[word]
                and vim.fn.tolower(word):sub(1, prefix_len) == prefix_lower
              then
                seen[word] = true
                sink.add({ word = word })
              end
            end
          end
        end
      end
    end
  end
  sink.done()
end

--- 't' / ']' tags
--- @param ctx vim.completion.Context
--- @param sink vim.completion.SourceSink
local function get_tags(ctx, sink)
  if ctx.prefix == '' then
    sink.done()
    return
  end
  local ok, tags = pcall(vim.fn.taglist, '^' .. vim.fn.escape(ctx.prefix, '\\'))
  if ok and type(tags) == 'table' then
    local seen = {} --- @type table<string, true>
    for _, tag in ipairs(tags) do
      local word = tag.name
      if word and not seen[word] then
        seen[word] = true
        sink.add({ word = word, kind = tag.kind or '' })
      end
    end
  end
  sink.done()
end

--- 'k' dictionary
--- @param ctx vim.completion.Context
--- @param sink vim.completion.SourceSink
local function get_dictionary(ctx, sink)
  if ctx.prefix == '' then
    sink.done()
    return
  end
  local dict = vim.opt_local.dictionary:get()
  if type(dict) == 'table' then
    local prefix_lower = vim.fn.tolower(ctx.prefix)
    local prefix_len = #ctx.prefix
    for _, file in ipairs(dict) do
      local ok, lines = pcall(vim.fn.readfile, file)
      if ok then
        for _, line in ipairs(lines) do
          local word = line:match('^%S+')
          if
            word
            and #word >= prefix_len
            and vim.fn.tolower(word):sub(1, prefix_len) == prefix_lower
          then
            sink.add({ word = word })
          end
        end
      end
    end
  end
  sink.done()
end

--- 's' thesaurus
--- @param ctx vim.completion.Context
--- @param sink vim.completion.SourceSink
local function get_thesaurus(ctx, sink)
  if ctx.prefix == '' then
    sink.done()
    return
  end
  local files = vim.opt_local.thesaurus:get()
  if type(files) == 'table' then
    local prefix_lower = vim.fn.tolower(ctx.prefix)
    for _, file in ipairs(files) do
      local ok, lines = pcall(vim.fn.readfile, file)
      if ok then
        for _, line in ipairs(lines) do
          if vim.fn.tolower(line):find(prefix_lower, 1, true) then
            for word in line:gmatch('%S+') do
              sink.add({ word = word })
            end
          end
        end
      end
    end
  end
  sink.done()
end

--- 'f' buffer names
--- @param ctx vim.completion.Context
--- @param sink vim.completion.SourceSink
local function get_bufnames(ctx, sink)
  local prefix_lower = vim.fn.tolower(ctx.prefix)
  local prefix_len = #ctx.prefix
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' then
        local tail = vim.fn.fnamemodify(name, ':t')
        if
          tail
          and #tail >= prefix_len
          and vim.fn.tolower(tail):sub(1, prefix_len) == prefix_lower
        then
          sink.add({ word = tail })
        end
      end
    end
  end
  sink.done()
end

--- File path completion (for C-x C-f).
--- compl_col is already adjusted by C (get_filename_compl_info) to the
--- start of the file path, so ctx.prefix contains the path prefix.
--- @param ctx vim.completion.Context
--- @param sink vim.completion.SourceSink
local function get_filepath(ctx, sink)
  local prefix = ctx.prefix
  local ok, files = pcall(vim.fn.getcompletion, prefix, 'file')
  if ok and type(files) == 'table' then
    for _, f in ipairs(files) do
      sink.add({ word = f })
    end
  end
  sink.done()
end

-- ---------------------------------------------------------------------------
-- Builtin source registration
-- ---------------------------------------------------------------------------

--- @type table<string, vim.completion.SourceHandle>
local builtin_handles = {}

--- Register a builtin source (not exposed to users, skipped by resolve()).
--- @param flag string  The 'complete' option flag character.
--- @param spec vim.completion.SourceSpec
local function register_builtin(flag, spec)
  -- Bypass validate_spec name-uniqueness check for builtins.
  local id = next_id
  next_id = next_id + 1
  local kw = spec.keyword_pattern or [[\k\+]]

  local handle = setmetatable({
    name = spec.name,
    _id = id,
    _builtin = true,
    _spec = {
      name = spec.name,
      priority = spec.priority or 500,
      trigger_characters = spec.trigger_characters,
      keyword_pattern = kw,
      min_prefix_len = spec.min_prefix_len or 0,
      max_items = spec.max_items or 10000,
      -- Sync builtin sources (buffer/tag/dict scans): 1000ms cap.
      -- Scanning tens of thousands of lines typically takes well under
      -- this; the cap catches pathological cases where a huge dict file
      -- or scan target would otherwise hold up the session.
      timeout = spec.timeout or 1000,
      refresh = spec.refresh or 'never',
      filter = spec.filter or 'engine',
      get = spec.get,
      _order = id,
      _keyword_regex = compile_keyword_regex(kw),
    },
  }, SourceHandle)

  registry[id] = handle
  name_index[spec.name] = id
  builtin_handles[flag] = handle
end

register_builtin('.', { name = 'cpt_.', priority = 100, get = get_current_buffer })
register_builtin('w', { name = 'cpt_w', priority = 90, get = get_windows_buffers })
register_builtin('b', { name = 'cpt_b', priority = 80, get = get_loaded_buffers })
register_builtin('u', { name = 'cpt_u', priority = 70, get = get_unloaded_buffers })
register_builtin('t', { name = 'cpt_t', priority = 60, get = get_tags })
register_builtin(']', { name = 'cpt_]', priority = 60, get = get_tags })
register_builtin('k', { name = 'cpt_k', priority = 50, get = get_dictionary })
register_builtin('s', { name = 'cpt_s', priority = 40, get = get_thesaurus })
register_builtin('f', { name = 'cpt_f', priority = 30, get = get_bufnames })
-- 'i', 'd': include/define — future work
-- 'F{func}', 'o': completefunc/omnifunc — future work

-- ---------------------------------------------------------------------------
-- ctrl_x-only sources (not tied to 'complete' option)
-- ---------------------------------------------------------------------------

--- Register an internal source used only by specific ctrl_x modes.
--- Marked _builtin so resolve() skips it in normal C-N/C-P.
--- Looked up by name via get_by_name() for ctrl_x dispatch.
--- @param spec vim.completion.SourceSpec
local function register_ctrl_x_source(spec)
  local id = next_id
  next_id = next_id + 1
  local kw = spec.keyword_pattern or [[\k\+]]

  local handle = setmetatable({
    name = spec.name,
    _id = id,
    _builtin = true, -- skip in resolve()
    _spec = {
      name = spec.name,
      priority = spec.priority or 500,
      keyword_pattern = kw,
      min_prefix_len = spec.min_prefix_len or 0,
      max_items = spec.max_items or 10000,
      -- Sync ctrl_x source (filepath/whole-line/...).  1000ms is plenty
      -- for filesystem globs and single-buffer scans.
      timeout = spec.timeout or 1000,
      refresh = spec.refresh or 'never',
      filter = spec.filter or 'engine',
      get = spec.get,
      _order = id,
      _keyword_regex = compile_keyword_regex(kw),
    },
  }, SourceHandle)

  registry[id] = handle
  name_index[spec.name] = id
end

register_ctrl_x_source({ name = 'filepath', priority = 100, get = get_filepath })

-- ---------------------------------------------------------------------------
-- LSP source — queries attached LSP clients for completion
-- ---------------------------------------------------------------------------

local lsp_protocol = vim.lsp.protocol

--- @type table<integer, string>?
local lsp_kind_map

local function get_kind_map()
  if lsp_kind_map then
    return lsp_kind_map
  end
  lsp_kind_map = {}
  for name, val in pairs(lsp_protocol.CompletionItemKind) do
    if type(val) == 'number' then
      lsp_kind_map[val] = name
    end
  end
  return lsp_kind_map
end

--- Compute the minimum textEdit start column across all items.
--- @param items lsp.CompletionItem[]
--- @param lnum integer 0-based
--- @param line string
--- @param encoding string
--- @return integer?
local function min_edit_startcol(items, lnum, line, encoding)
  local min_char = nil
  for _, item in ipairs(items) do
    if item.textEdit then
      local start_char = nil
      if item.textEdit.range and item.textEdit.range.start.line == lnum then
        start_char = item.textEdit.range.start.character
      elseif item.textEdit.insert and item.textEdit.insert.start.line == lnum then
        start_char = item.textEdit.insert.start.character
      end
      if start_char and (not min_char or start_char < min_char) then
        min_char = start_char
      end
    end
  end
  if min_char then
    return vim.str_byteindex(line, encoding, min_char, false)
  end
  return nil
end

--- Apply itemDefaults to a single item (modifies in place).
--- @param item lsp.CompletionItem
--- @param defaults? lsp.ItemDefaults
local function apply_defaults(item, defaults)
  if not defaults then
    return
  end
  item.insertTextFormat = item.insertTextFormat or defaults.insertTextFormat
  item.insertTextMode = item.insertTextMode or defaults.insertTextMode
  item.data = item.data or defaults.data
  if defaults.editRange and not item.textEdit then
    local te = {}
    te.newText = item.textEditText or item.insertText or item.label
    if defaults.editRange.start then
      te.range = defaults.editRange
    elseif defaults.editRange.insert then
      te.insert = defaults.editRange.insert
      te.replace = defaults.editRange.replace
    end
    item.textEdit = te
  end
end

--- Convert a single LSP CompletionItem → vim.completion.Item.
--- @param lsp_item lsp.CompletionItem
--- @param client_id integer
--- @param server_startcol integer 0-based byte offset
--- @param lnum integer 0-based
--- @param line string
--- @param encoding string
--- @return vim.completion.Item
local function lsp_item_to_item(lsp_item, client_id, server_startcol, lnum, line, encoding)
  local kind_map = get_kind_map()
  local word

  if lsp_item.insertTextFormat == lsp_protocol.InsertTextFormat.Snippet then
    word = lsp_item.label
  elseif lsp_item.textEdit then
    word = lsp_item.textEdit.newText or lsp_item.label
    word = word:match('^([^\r\n]*)') or word

    -- If this item's textEdit starts after server_startcol, prepend the gap.
    local item_start_char = nil
    if lsp_item.textEdit.range and lsp_item.textEdit.range.start.line == lnum then
      item_start_char = lsp_item.textEdit.range.start.character
    elseif lsp_item.textEdit.insert and lsp_item.textEdit.insert.start.line == lnum then
      item_start_char = lsp_item.textEdit.insert.start.character
    end
    if item_start_char then
      local item_byte = vim.str_byteindex(line, encoding, item_start_char, false)
      if item_byte > server_startcol then
        word = line:sub(server_startcol + 1, item_byte) .. word
      end
    end
  elseif lsp_item.insertText and lsp_item.insertText ~= '' then
    word = lsp_item.insertText
  else
    word = lsp_item.label
  end

  local detail = vim.tbl_get(lsp_item, 'labelDetails', 'detail') or ''
  local desc = vim.tbl_get(lsp_item, 'labelDetails', 'description') or lsp_item.detail or ''

  return {
    word = word,
    abbr = lsp_item.label .. detail,
    kind = kind_map[lsp_item.kind] or '',
    menu = desc,
    icase = true,
    dup = true,
    user_data = {
      nvim = {
        lsp = {
          completion_item = lsp_item,
          client_id = client_id,
        },
      },
    },
  }
end

--- LSP completion source.  Queries all attached LSP clients that support
--- textDocument/completion.  Uses ctx.await() to yield — truly async.
--- @param ctx vim.completion.Context
--- @param sink vim.completion.SourceSink
local function get_lsp(ctx, sink)
  local clients = vim.lsp.get_clients({
    bufnr = ctx.bufnr,
    method = 'textDocument/completion',
  })

  if #clients == 0 then
    sink.done()
    return
  end

  local win = vim.api.nvim_get_current_win()
  local lnum = ctx.cursor[1] - 1

  for _, client in ipairs(clients) do
    if ctx.cancelled() then
      sink.done()
      return
    end

    local encoding = client.offset_encoding or 'utf-16'
    local params = vim.lsp.util.make_position_params(win, encoding)
    --- @cast params lsp.CompletionParams

    if ctx.trigger_character then
      params.context = {
        triggerKind = lsp_protocol.CompletionTriggerKind.TriggerCharacter,
        triggerCharacter = ctx.trigger_character,
      }
    else
      params.context = {
        triggerKind = lsp_protocol.CompletionTriggerKind.Invoked,
      }
    end

    local err, result = ctx.await(function(done)
      local ok, req_id = client:request('textDocument/completion', params, function(e, r)
        done(e, r)
      end, ctx.bufnr)
      if not ok then
        done('request failed', nil)
      end
      ctx.on_cancel(function()
        if req_id then
          pcall(function()
            client:cancel_request(req_id)
          end)
        end
      end)
    end)

    if ctx.cancelled() then
      sink.done()
      return
    end

    if err then
      log.warn('LSP client %s error: %s', client.name, tostring(err))
    elseif result then
      local raw_items = result.items or result
      local defaults = result.itemDefaults

      for _, item in ipairs(raw_items) do
        apply_defaults(item, defaults)
      end

      local server_startcol = min_edit_startcol(raw_items, lnum, ctx.line, encoding)
      if server_startcol and server_startcol ~= ctx.startcol then
        sink.set_startcol(server_startcol)
      end

      local effective_startcol = server_startcol or ctx.startcol

      for _, lsp_item in ipairs(raw_items) do
        local item =
          lsp_item_to_item(lsp_item, client.id, effective_startcol, lnum, ctx.line, encoding)
        sink.add(item)
      end

      if result.isIncomplete then
        sink.done({ incomplete = true })
        return
      end
    end
  end

  sink.done()
end

-- LSP source: always active (not tied to a 'complete' option flag).
-- Registered as a non-builtin internal source so it's included by
-- resolve() for every buffer, alongside any user-registered sources.
do
  local id = next_id
  next_id = next_id + 1
  local kw = [[\k\+]]

  local handle = setmetatable({
    name = 'lsp',
    _id = id,
    _spec = {
      name = 'lsp',
      priority = 1000,
      keyword_pattern = kw,
      min_prefix_len = 0,
      max_items = 10000,
      -- LSP is async.  5000ms is a generous upper bound; in practice
      -- responses arrive in 50-500ms.  This cap catches genuinely hung
      -- servers without cutting off slow-but-working ones.
      timeout = 5000,
      refresh = 'always',
      filter = 'engine',
      get = get_lsp,
      _order = id,
      _keyword_regex = compile_keyword_regex(kw),
    },
  }, SourceHandle)

  registry[id] = handle
  name_index['lsp'] = id
end

--- Resolve 'complete' option flags to builtin source specs.
--- @param cpt string[]  e.g. {".", "w", "b", "t"}
--- @return vim.completion.SourceSpec[]
function M.resolve_cpt(cpt)
  local specs = {} --- @type vim.completion.SourceSpec[]
  for _, flag in ipairs(cpt) do
    local c = flag:sub(1, 1)
    local handle = builtin_handles[c]
    if handle then
      specs[#specs + 1] = handle._spec
    end
  end
  return specs
end

--- @nodoc
function M._clear()
  -- Remove only non-builtin sources.
  for id, handle in pairs(registry) do
    if not handle._builtin then
      registry[id] = nil
      name_index[handle.name] = nil
    end
  end
  -- Reset next_id to after builtins.
  local max_id = 0
  for id in pairs(registry) do
    if id > max_id then
      max_id = id
    end
  end
  next_id = max_id + 1
end

return M
