--- In-process LSP server for "textDocument/completion": buffer words
--- (|i_CTRL-N|) and filenames (|i_CTRL-X_CTRL-F|). First step of moving the
--- insexpand.c collectors to Lua. Scans run on a coroutine and yield between
--- batches, so large buffers don't block input or redraw.
---
--- Not started by default:
---
--- ```lua
--- vim.lsp.start({
---   name = 'nvim.completion',
---   cmd = require('vim._core.completion.dispatch').cmd,
---   -- Optional: sources consulted for plain requests, in order.
---   init_options = { sources = { 'keyword', 'files' } },
--- })
--- ```

local async = require('vim._async')
local api = vim.api
local protocol = vim.lsp.protocol
local CompletionItemKind = protocol.CompletionItemKind

--- Bytes of scanned line content between yields; checked per chunk.
local SCAN_BUDGET = 128 * 1024
--- Flat per-line charge so runs of short or empty lines still yield.
local SCAN_LINE_COST = 64
--- Lines per get_lines() + matchstrlist() call: the budget quantum. Bigger
--- chunks cut API crossings; one oversized chunk can overshoot its tick.
local SCAN_CHUNK = 256
--- Max items per response; past this the list is marked incomplete.
local MAX_ITEMS = 1000

local M = {}

--- @class vim.lsp.completion._server.Context : lsp.CompletionContext
--- @field mode? string Explicit source for this request, bypassing the
--- configured list and any source gate: "keyword" or "files".

--- @class vim.lsp.completion._server.CollectArgs
--- @field bufnr integer
--- @field line string Cursor line.
--- @field col integer Cursor column (0-based byte index).
--- @field position lsp.Position
--- @field explicit boolean Request named one source (ctx.mode); skip its gate.
--- @field trigger_char boolean Request fired by a trigger character.
--- @field cancelled fun(): boolean True once the client cancelled this request.
--- @field yield fun() Suspend until the next main-loop tick.
--- @field drifted fun(): boolean True when the request yielded and its context is gone.

--- Current buffer, then other loaded, listed buffers. Matches 'complete'
--- ".,b"; cpt-driven selection comes with the C routing.
--- @param cur_buf integer
--- @return integer[]
local function target_buffers(cur_buf)
  local bufs = { cur_buf }
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if buf ~= cur_buf and vim.bo[buf].buflisted and api.nvim_buf_is_loaded(buf) then
      bufs[#bufs + 1] = buf
    end
  end
  return bufs
end

--- Whether a suspended request is still worth serving: the guard
--- completion.lua applies before consuming a response, plus the request
--- buffer still being current -- matchstrlist() resolves \k against the
--- *current* buffer's 'iskeyword'. Only meaningful after a suspension
--- (args.drifted gates on that), which keeps _do_complete callable outside
--- Insert mode, e.g. from tests.
--- @param a vim.lsp.completion._server.CollectArgs
--- @return boolean
local function still_relevant(a)
  return api.nvim_get_current_buf() == a.bufnr
    and api.nvim_get_mode().mode:sub(1, 1) == 'i'
    and api.nvim_win_get_cursor(0)[1] - 1 == a.position.line
end

--- Keyword (\k) run ending at the cursor.
--- @param line string
--- @param col integer 0-based byte column
--- @return string
local function keyword_prefix(line, col)
  return vim.fn.matchstr(line:sub(1, col), [[\k*$]])
end

--- 'isfname' (\f) run ending at the cursor: path fragment typed so far.
--- @param line string
--- @param col integer 0-based byte column
--- @return string
local function filename_prefix(line, col)
  return vim.fn.matchstr(line:sub(1, col), [[\f*$]])
end

--- textEdit bounds for replacing `prefix`.
--- @param line string
--- @param col integer 0-based byte cursor column
--- @param prefix string
--- @param position lsp.Position
--- @return integer lnum
--- @return integer start_char utf-16 column of the prefix start
--- @return integer end_char utf-16 column at the cursor
local function edit_bounds(line, col, prefix, position)
  local start_char = vim.str_utfindex(line, 'utf-16', col - #prefix, false)
  return position.line, start_char, position.character
end

--- Expands filenames via getcompletion(), the same expand_wildcards() engine
--- as |i_CTRL-X_CTRL-F|. Items replace the whole \f fragment through a
--- textEdit. Plain requests only glob when the fragment contains a path
--- separator; an explicit mode always globs, like native.
--- @async
--- @param a vim.lsp.completion._server.CollectArgs
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_files(a)
  local prefix = filename_prefix(a.line, a.col)
  if not a.explicit and not prefix:find('[/\\]') then
    return {}, false -- plain word: don't hit the filesystem
  end

  -- getcompletion() globs synchronously and can't yield mid-call; yield once
  -- first so a pending redraw and a queued $/cancelRequest get through.
  a.yield()
  if a.cancelled() or a.drifted() then
    return {}, false -- the caller discards the response; skip the glob
  end

  local lnum, start_char, end_char = edit_bounds(a.line, a.col, prefix, a.position)
  -- pcall: the fragment is user-typed; glob metachars in it can error.
  local ok, matches = pcall(vim.fn.getcompletion, prefix .. '*', 'file')
  if not ok or type(matches) ~= 'table' then
    return {}, false
  end

  local range = {
    start = { line = lnum, character = start_char },
    ['end'] = { line = lnum, character = end_char },
  }

  local items = {} --- @type lsp.CompletionItem[]
  for n, m in ipairs(matches) do
    items[n] = {
      label = m,
      kind = CompletionItemKind.File,
      filterText = m,
      textEdit = { range = range, newText = m },
    }
    if n >= MAX_ITEMS then
      return items, true
    end
  end
  return items, false
end

--- Scans buffers for words matching the keyword prefix, in native search
--- order: current buffer from the cursor with wraparound, then other buffers
--- top to bottom. Found order is conveyed through sortText. The base
--- occurrence at the cursor is skipped. The prefix test and the short-base
--- floor ("\<\k\k", "\<c\k") are compiled into the pattern, like
--- get_normal_compl_info() does, so matching runs in the regex engine.
--- @async
--- @param a vim.lsp.completion._server.CollectArgs
--- @return lsp.CompletionItem[]
--- @return boolean truncated
local function collect_keyword(a)
  if not a.explicit and a.trigger_char then
    return {}, false -- '/' fired this request; a word dump would bury the paths
  end
  local prefix = keyword_prefix(a.line, a.col)
  local plen = #prefix
  -- 'ignorecase' + 'smartcase', as searchit() compiles it via ignorecase().
  -- Uppercase detection must be multibyte: vim.fn.tolower() shares the case
  -- tables with mb_isupper(); %u and :lower() fold bytes, not codepoints.
  -- TODO: 'infercase' (native re-cases via ins_compl_infercase_gettext()).
  local icase = vim.o.ignorecase
  if icase and vim.o.smartcase and prefix ~= vim.fn.tolower(prefix) then
    icase = false
  end
  -- Codepoint count: a single multibyte base must pick the \<c\k form.
  local base_chars = plen > 0 and vim.str_utfindex(prefix, 'utf-32') or 0
  -- \c/\C pins case folding (matchstrlist() honors 'ignorecase'); \V
  -- neutralizes magic in the base ('iskeyword' may hold . or *); \k\* takes
  -- the whole run, where native extracts the word at the match instead.
  local pat = (icase and [[\c]] or [[\C]])
    .. (
      plen == 0 and [[\<\k\k\+]]
      or ([[\V\<]] .. prefix:gsub('\\', '\\\\') .. (base_chars == 1 and [[\k\+]] or [[\k\*]]))
    )
  local base_lnum = a.position.line + 1
  local base_scol = a.col - plen

  local words = {} --- @type string[]
  local seen = {} --- @type table<string, true>
  local truncated = false

  -- Records a chunk's matches; first find wins for duplicates. On the
  -- cursor line `part` keeps matches after the cursor ('right') or before
  -- the base ('left'); the base occurrence falls in neither.
  --- @param lines string[]
  --- @param part 'left'|'right'|nil
  --- @return boolean stop
  local function visit(lines, part)
    -- The builtin annotation says string[]; the real return is dicts.
    --- @type {byteidx: integer, text: string}[]
    local ms = vim.fn.matchstrlist(lines, pat)
    for _, m in ipairs(ms) do
      local in_part = part == nil
        or (part == 'right' and m.byteidx >= a.col)
        or (part == 'left' and m.byteidx < base_scol)
      if in_part and not seen[m.text] then
        seen[m.text] = true
        words[#words + 1] = m.text
        if #words >= MAX_ITEMS then
          truncated = true
          return true
        end
      end
    end
    return false
  end

  local stop = false
  -- Accumulated across buffers, so many small buffers yield as reliably as
  -- one large buffer.
  local spent = 0
  for _, buf in ipairs(target_buffers(a.bufnr)) do
    -- target_buffers() ran before the first yield; the buffer may have been
    -- unloaded or wiped since. is_loaded is false for both and never throws.
    if api.nvim_buf_is_loaded(buf) then
      local cnt = api.nvim_buf_line_count(buf)
      -- Range segments, not per-line entries: an O(lines) plan table would
      -- stall one tick before the budgeted scan even starts.
      --- @type {from: integer, to: integer, part: ('left'|'right')?}[]
      local segs = buf == a.bufnr
          and {
            { from = base_lnum, to = base_lnum, part = 'right' },
            { from = base_lnum + 1, to = cnt },
            { from = 1, to = base_lnum - 1 },
            { from = base_lnum, to = base_lnum, part = 'left' },
          }
        or { { from = 1, to = cnt } }
      local dead = false
      for _, sg in ipairs(segs) do
        local l = sg.from
        while l <= sg.to do
          local last = math.min(l + SCAN_CHUNK - 1, sg.to)
          -- Charge requested lines, not returned: strict=false clamps a
          -- range past a buffer that shrank while suspended, and scanning
          -- the void must still spend budget and yield.
          local lines = api.nvim_buf_get_lines(buf, l - 1, last, false)
          if visit(lines, sg.part) then
            stop = true
            break
          end
          spent = spent + (last - l + 1) * SCAN_LINE_COST
          for _, raw in ipairs(lines) do
            spent = spent + #raw
          end
          if spent >= SCAN_BUDGET then
            spent = 0
            a.yield()
            -- State only changes while suspended; everything until the next
            -- yield runs in this tick.
            if a.cancelled() or a.drifted() then
              return {}, false -- the caller discards the response
            end
            if not api.nvim_buf_is_loaded(buf) then
              dead = true -- buffer died while suspended
              break
            end
          end
          l = last + 1
        end
        if stop or dead then
          break
        end
      end
    end
    if stop then
      break
    end
  end

  -- Plain labels: every match starts with the base, so the client's keyword
  -- boundary places the insertion. In a mixed response the client re-anchors
  -- them to the files textEdit boundary and pads the gap into the word.
  local items = {} --- @type lsp.CompletionItem[]
  for idx, word in ipairs(words) do
    items[idx] = {
      label = word,
      kind = CompletionItemKind.Text,
    }
  end
  return items, truncated
end

--- Source name to collector. Follow-up sources land as new entries here;
--- custom sources are separate in-process servers, not entries.
--- @type table<string, fun(a: vim.lsp.completion._server.CollectArgs): lsp.CompletionItem[], boolean>
local collectors = {
  keyword = collect_keyword,
  files = collect_files,
}

--- @param params lsp.CompletionParams
--- @return integer bufnr
--- @return string line
--- @return integer col 0-based byte column
local function resolve_position(params)
  -- The URI is ignored: completion.lua builds params from the current window
  -- and the in-process cmd delivers the request in the same tick, so curbuf
  -- *is* the request buffer (and unnamed buffers can't round-trip through a
  -- URI anyway).
  local bufnr = api.nvim_get_current_buf()
  local pos = params.position
  local line = api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ''
  local ok, byte_col = pcall(vim.str_byteindex, line, 'utf-16', pos.character, false)
  return bufnr, line, ok and byte_col or math.min(pos.character, #line)
end

--- @async
--- @param params lsp.CompletionParams
--- @param sources? (fun(a: vim.lsp.completion._server.CollectArgs): lsp.CompletionItem[], boolean)[]
--- @param cancelled? fun(): boolean
--- @return lsp.CompletionList
local function do_complete(params, sources, cancelled)
  cancelled = cancelled or function()
    return false
  end
  local bufnr, line, col = resolve_position(params)

  local ctx = params.context --[[@as vim.lsp.completion._server.Context?]]

  --- @type (fun(a: vim.lsp.completion._server.CollectArgs): lsp.CompletionItem[], boolean)[]?
  local explicit_run
  if ctx and ctx.mode then
    local collector = collectors[ctx.mode]
    if not collector then
      error(('unknown completion mode: %s'):format(ctx.mode))
    end
    explicit_run = { collector }
  end
  local run = explicit_run or sources or { collect_keyword }

  local yielded = false
  --- @type vim.lsp.completion._server.CollectArgs
  local args = {
    bufnr = bufnr,
    line = line,
    col = col,
    position = params.position,
    explicit = explicit_run ~= nil,
    trigger_char = ctx ~= nil
      and ctx.triggerKind == protocol.CompletionTriggerKind.TriggerCharacter,
    cancelled = cancelled,
  }
  function args.yield()
    yielded = true
    async.await(1, vim.schedule)
  end
  function args.drifted()
    return yielded and not still_relevant(args)
  end

  local items = {} --- @type lsp.CompletionItem[]
  local seen = {} --- @type table<string, true>
  local truncated = false
  for _, collect in ipairs(run) do
    if cancelled() or args.drifted() then
      break -- the caller discards the response
    end
    local batch, trunc = collect(args)
    truncated = truncated or trunc
    for _, it in ipairs(batch) do
      -- Dedupe on the inserted text; sortText follows emission order.
      -- Items are fresh per request, so mutating them is safe.
      local key = (it.textEdit and it.textEdit.newText) or it.label
      if not seen[key] then
        seen[key] = true
        it.sortText = ('%08d'):format(#items + 1)
        items[#items + 1] = it
        if #items >= MAX_ITEMS then
          return { isIncomplete = true, items = items }
        end
      end
    end
  end

  -- Incomplete only when truncated: a complete result lets the client filter
  -- locally.
  return { isIncomplete = truncated, items = items }
end

local server_capabilities = {
  completionProvider = {
    -- Autotrigger for paths: separators are not in \k, so plain typing
    -- would never fire a request inside one. '\' only on Windows, where
    -- 'isfname' includes it; elsewhere it's escape-sequence noise.
    triggerCharacters = vim.fn.has('win32') == 1 and { '/', '\\' } or { '/' },
    resolveProvider = false,
  },
}

--- `cmd` for |vim.lsp.start()|: runs the server in-process.
---
--- init_options:
--- - sources: (string[]) Sources consulted, in order, for requests without
---   an explicit mode. Default: { 'keyword' }. An empty list disables all.
--- @param dispatchers vim.lsp.rpc.Dispatchers
--- @return vim.lsp.rpc.Client
function M.cmd(dispatchers)
  local closing = false
  local next_id = 0
  local sources = { collect_keyword }
  --- Cancellation tokens for in-flight completion requests, keyed by the
  --- request id handed to the client. $/cancelRequest flips the flag; the
  --- scan coroutine polls it after every yield.
  --- @type table<integer, {cancelled: boolean}>
  local pending = {}
  local srv = {}

  --- Delivers a reply the way a real transport does (rpc.lua wraps both
  --- callbacks in vim.schedule): next tick, notify_reply_callback first --
  --- client.lua settles its request bookkeeping there -- then the handler
  --- with the request id. Same-tick delivery would land before
  --- rpc.request() even returns.
  --- @param rid integer
  --- @param nrc? fun(message_id: integer)
  --- @param callback fun(err?: lsp.ResponseError, result: any, request_id: integer)
  --- @param err? lsp.ResponseError
  --- @param result any
  local function respond(rid, nrc, callback, err, result)
    vim.schedule(function()
      if closing then
        return -- the client is gone; a real channel would already be closed
      end
      if nrc then
        nrc(rid)
      end
      callback(err, result, rid)
    end)
  end

  --- Flips every in-flight token so suspended scans stop at their next
  --- resume instead of finishing for a dead client.
  local function cancel_all()
    for _, tok in pairs(pending) do
      tok.cancelled = true
    end
    pending = {}
  end

  --- Exactly-once teardown. client.lua runs its final cleanup (detach
  --- buffers, drop the client from the registry) from the exit dispatcher,
  --- and a force-stop reaches this only through terminate().
  local function shut_down()
    if closing then
      return
    end
    closing = true
    cancel_all()
    dispatchers.on_exit(0, 0)
  end

  function srv.request(method, params, callback, notify_reply_callback)
    if closing then
      return false
    end
    next_id = next_id + 1
    local rid = next_id

    if method == 'initialize' then
      local opts = params and params.initializationOptions or {}
      local resolved = {}
      for i, name in ipairs(opts.sources or {}) do
        if not collectors[name] then
          respond(rid, notify_reply_callback, callback, {
            code = protocol.ErrorCodes.InvalidParams,
            message = ('unknown completion source: %s'):format(name),
          }, nil)
          return true, rid
        end
        resolved[i] = collectors[name]
      end
      if opts.sources then
        sources = resolved
      end
      local caps = server_capabilities
      if not vim.tbl_contains(sources, collect_files) then
        -- files not configured: '/' requests would never produce anything
        caps = vim.deepcopy(server_capabilities)
        caps.completionProvider.triggerCharacters = nil
      end
      respond(rid, notify_reply_callback, callback, nil, { capabilities = caps })
    elseif method == 'textDocument/completion' then
      local tok = { cancelled = false }
      pending[rid] = tok
      async.run(function()
        return do_complete(params, sources, function()
          return tok.cancelled
        end)
      end, function(err, result)
        pending[rid] = nil
        if tok.cancelled then
          -- Reply with an empty *result*: the spec reserves RequestCancelled
          -- for error replies, and completion.lua notifies on every error.
          -- Replying at all is what lets client.lua settle its 'cancel'
          -- entry for this request.
          respond(rid, notify_reply_callback, callback, nil, { isIncomplete = false, items = {} })
        elseif err then
          respond(
            rid,
            notify_reply_callback,
            callback,
            { code = protocol.ErrorCodes.InternalError, message = tostring(err) },
            nil
          )
        else
          respond(rid, notify_reply_callback, callback, nil, result)
        end
      end)
    elseif method == 'shutdown' then
      respond(rid, notify_reply_callback, callback, nil, nil)
    else
      respond(rid, notify_reply_callback, callback, {
        code = protocol.ErrorCodes.MethodNotFound,
        message = ('method not supported: %s'):format(method),
      }, nil)
    end

    return true, rid
  end

  function srv.notify(method, params)
    if method == 'exit' then
      shut_down()
      return true
    end
    if closing then
      return false
    end
    if method == '$/cancelRequest' then
      -- Sent by completion.lua on every retrigger (Context:cancel_pending).
      local tok = params and pending[params.id]
      if tok then
        tok.cancelled = true
      end
    end
    return true
  end

  function srv.is_closing()
    return closing
  end

  srv.terminate = shut_down

  return srv
end

M._do_complete = do_complete

return M
