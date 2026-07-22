--- In-process LSP server for "textDocument/completion", fed by
--- |vim._core.completion.source|.  One client serves every buffer.
---
--- ```lua
--- local completion = require('vim._core.completion')
--- completion.enable(true, 0, { sources = { completion.source.keyword } })
--- ```

local async = vim.async
local api = vim.api
local protocol = vim.lsp.protocol

local M = {}

--- Milliseconds a whole request may take, however many sources it consults.
local REQUEST_TIMEOUT_MS = 200

--- |vim._core.completion.source|, so that a caller needs one require.
M.source = require('vim._core.completion.source')

--- Sources per buffer, as enable() was given them.
--- @type table<integer, vim._core.completion.Source[]>
local buf_sources = {}

--- The completion server, started with the first buffer that needs it.
--- @type integer?
local client_id

--- Set by M.cmd(): the server's side of |client/registerCapability|, which is
--- how a set of trigger characters reaches the client after initialize.
--- @type fun(characters: string[])?
local send_registration

--- Clients enable() turned on itself, per buffer: one the caller enabled
--- through |vim.lsp.completion.enable()| is not ours to turn off.
--- @type table<integer, table<integer, true>>
local owned = {}

api.nvim_create_autocmd('BufWipeout', {
  group = api.nvim_create_augroup('nvim.completion', {}),
  callback = function(ev)
    buf_sources[ev.buf] = nil
    owned[ev.buf] = nil
    if not next(buf_sources) and client_id then
      local client = vim.lsp.get_client_by_id(client_id)
      if client then
        client:stop()
      end
      client_id = nil
    end
  end,
})

--- @class vim._core.completion.Context : lsp.CompletionContext
--- @field mode? string Explicit source for this request, bypassing the
--- configured list and any source gate: "keyword" or "files".

--- @param a vim._core.completion.HandlerArgs
--- @return boolean
local function still_relevant(a)
  if api.nvim_get_current_buf() ~= a.bufnr or api.nvim_get_mode().mode:sub(1, 1) ~= 'i' then
    return false
  end
  -- The anchor, not the cursor: a session without "noinsert" writes the shown
  -- match into the line as it is browsed, and that is not a context change.  A
  -- leader that really moved cancels the request instead.
  local pos = api.nvim_win_get_cursor(0)
  local anchor = a.col - #vim.fn.matchstr(a.line:sub(1, a.col), [[\k*$]])
  return pos[1] - 1 == a.position.line
    and api.nvim_get_current_line():sub(1, anchor) == a.line:sub(1, anchor)
end

--- @param params lsp.CompletionParams
--- @return integer bufnr
--- @return string line
--- @return integer col 0-based byte column
local function resolve_position(params)
  -- By URI: the request names its buffer, and nothing here says the caller is
  -- still in it by the time a handler resumes.
  local uri = vim.tbl_get(params, 'textDocument', 'uri')
  local bufnr = uri and vim.uri_to_bufnr(uri) or api.nvim_get_current_buf()
  if not api.nvim_buf_is_loaded(bufnr) then
    bufnr = api.nvim_get_current_buf()
  end
  local pos = params.position
  local line = api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ''
  local ok, byte_col = pcall(vim.str_byteindex, line, 'utf-16', pos.character, false)
  return bufnr, line, ok and byte_col or math.min(pos.character, #line)
end

--- @async
--- Takes a source out of the buffer it raised in.
--- Hands the client the characters every buffer's sources ask for.
---
--- No documentSelector -- it matches on a glob of the file name, which an
--- unnamed buffer has none of -- so this is the union over every buffer the
--- server was enabled for, as a client's declared characters always are.
local function register_characters()
  local own = {} --- @type string[]
  local seen = {} --- @type table<string, true>
  for buf, sources_ in pairs(buf_sources) do
    if api.nvim_buf_is_valid(buf) then
      for _, s in ipairs(sources_) do
        for _, c in ipairs(s.client_id == client_id and (s.trigger or {}).characters or {}) do
          if not seen[c] then
            seen[c] = true
            own[#own + 1] = c
          end
        end
      end
    end
  end
  -- Asserted rather than skipped: this is the only way the characters reach the
  -- client, and a silent miss reads as "the trigger just does not work".
  local register = assert(send_registration, 'the completion server is not running')
  register(own)
end

--- @param bufnr integer
--- @param name string
local function drop_source(bufnr, name)
  for i, s in ipairs(buf_sources[bufnr] or {}) do
    if s.name == name then
      table.remove(buf_sources[bufnr], i)
      -- Its characters go with it, or the client would go on waking for one
      -- nothing answers.
      register_characters()
      return
    end
  end
end

--- @param params lsp.CompletionParams
--- @param sources? vim._core.completion.Source[] The buffer's own by default;
--- given only by tests that want a fixed set.
--- @param cancelled? fun(): boolean
--- @return lsp.CompletionList
local function do_complete(params, sources, cancelled)
  cancelled = cancelled or function()
    return false
  end
  local bufnr, line, col = resolve_position(params)

  local ctx = params.context --[[@as vim._core.completion.Context?]]

  --- @type vim._core.completion.Source[]?
  local explicit_run
  if ctx and ctx.mode then
    for _, s in ipairs(buf_sources[bufnr] or {}) do
      if s.name == ctx.mode then
        explicit_run = { s }
        break
      end
    end
    if not explicit_run then
      error(('no such source for this buffer: %s'):format(ctx.mode))
    end
  end
  local named = explicit_run or sources or buf_sources[bufnr] or {}
  -- Only the ones this server handles: the rest name a client that answers for
  -- itself.
  local run = vim.tbl_filter(function(s)
    return s.handler ~= nil
  end, named)

  local yielded = false
  local deadline = 0 -- per source, read by args.exhausted()
  local budget = vim.uv.hrtime() + REQUEST_TIMEOUT_MS * 1000000

  --- @type vim._core.completion.HandlerArgs
  local args = {
    bufnr = bufnr,
    line = line,
    col = col,
    position = params.position,
    explicit = explicit_run ~= nil,
    context = ctx or { triggerKind = protocol.CompletionTriggerKind.Invoked },
    cancelled = cancelled,
  }
  function args.await(argc, fn, ...)
    yielded = true
    return async.await(argc, fn, ...)
  end
  function args.yield()
    args.await(1, vim.schedule)
  end
  function args.drifted()
    return yielded and not still_relevant(args)
  end
  function args.exhausted()
    -- hrtime, not uv.now(): the loop clock only moves when the loop does, and a
    -- handler between two yields is not letting it.
    return vim.uv.hrtime() >= deadline
  end

  local items = {} --- @type lsp.CompletionItem[]
  local seen = {} --- @type table<string, true>
  local truncated = false
  for _, s in ipairs(run) do
    if cancelled() or args.drifted() then
      break -- the caller discards the response
    end
    -- Per source, and never past the round's own budget: what a keystroke waits
    -- for is the whole answer, not one source's share of it.
    local now = vim.uv.hrtime()
    if now >= budget then
      truncated = true
      break -- calling a handler here only spends more of what is gone
    end
    deadline = math.min(now + (s.timeout or 100) * 1000000, budget)
    local quota = s.max_items or math.huge
    local produced = 0

    -- Caught so that one source does not take the others' items with it, and
    -- taken out so that the report is not a message the user sees once while it
    -- goes on answering nothing.  CANCELLED is the round giving up on purpose.
    local ok, list = pcall(s.handler, args)
    if not ok then
      if type(list) == 'string' and list:find(M.source.CANCELLED, 1, true) then
        error(list, 0)
      end
      drop_source(bufnr, s.name)
      vim.notify(
        ('vim._core.completion: source %s raised and was removed: %s'):format(s.name, list),
        vim.log.levels.ERROR
      )
      list = { isIncomplete = false, items = {} }
    end
    -- Resolved before the items leave their list: an "itemDefaults" belongs to
    -- the list it came with, and the merged one carries none.
    local batch = vim.lsp.completion._get_items(list)
    truncated = truncated or list.isIncomplete == true
    for _, it in ipairs(batch) do
      if produced >= quota then
        truncated = true
        break
      end
      -- Dedupe on the inserted text; sortText follows emission order.
      -- Items are fresh per request, so mutating them is safe.
      local key = (it.textEdit and it.textEdit.newText) or it.insertText or it.label
      if not seen[key] then
        seen[key] = true
        produced = produced + 1
        it.sortText = ('%08d'):format(#items + 1)
        items[#items + 1] = it
      end
    end
  end

  -- Incomplete when something was left behind: the client re-requests as the
  -- leader grows, and a narrower prefix eventually fits.  Nothing is resumed --
  -- each response replaces the list whole.
  return { isIncomplete = truncated, items = items }
end

function M.cmd(dispatchers)
  local closing = false
  local next_id = 0

  -- One server serves every buffer, so there is one of these; shut_down() drops
  -- it again.
  local registered = nil --- @type string?
  send_registration = function(characters)
    if closing then
      return
    end
    -- Only when they changed: the client re-runs its per-buffer defaults for
    -- every registration, and _register_dynamic() replaces this id anyway.
    local key = table.concat(characters, '\0')
    if key == registered then
      return
    end
    registered = key
    dispatchers.server_request('client/registerCapability', {
      registrations = {
        {
          id = 'nvim.completion',
          method = 'textDocument/completion',
          registerOptions = { triggerCharacters = characters, resolveProvider = false },
        },
      },
    })
  end
  local mine = send_registration

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
    -- Only if it is still ours: a client that exits after another one started
    -- would otherwise take the live hook with it.
    if send_registration == mine then
      send_registration = nil
    end
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
      -- No trigger characters here: this is answered once for the whole client,
      -- and they belong to a buffer's sources.  enable() registers them per
      -- buffer through client/registerCapability instead.
      respond(rid, notify_reply_callback, callback, nil, {
        capabilities = { completionProvider = { resolveProvider = false } },
      })
    elseif method == 'textDocument/completion' then
      local tok = { cancelled = false }
      pending[rid] = tok
      local task = async.run(function()
        return do_complete(params, nil, function()
          return tok.cancelled
        end)
      end)
      task:on_complete(function(err, result)
        pending[rid] = nil
        if tok.cancelled then
          -- The same answer a handler that gave up gets: an empty list would
          -- read as "there is nothing" and be cached as one.  Replying at all
          -- is what lets client.lua settle its 'cancel' entry.
          respond(rid, notify_reply_callback, callback, {
            code = protocol.ErrorCodes.RequestCancelled,
            message = 'cancelled',
          }, nil)
        elseif err then
          -- A handler that gave up says so: the client keeps its cache for this
          -- word instead of taking an empty list as the answer.
          local gave_up = type(err) == 'string' and err:find(M.source.CANCELLED, 1, true)
          respond(rid, notify_reply_callback, callback, {
            code = gave_up and protocol.ErrorCodes.RequestCancelled
              or protocol.ErrorCodes.InternalError,
            message = tostring(err),
          }, nil)
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

--- Enables completion sources for a buffer.  There is no default set.
---
--- ```lua
--- local completion = require('vim._core.completion')
--- local source = completion.source
---
--- completion.enable(true, 0, { sources = { source.keyword, source.files } })
---
--- vim.api.nvim_create_autocmd('LspAttach', {
---   callback = function(args)
---     local sources = completion.get_sources(args.buf)
---     sources[#sources + 1] = source.lsp({ client_id = args.data.client_id })
---     completion.enable(true, args.buf, { sources = sources })
---   end,
--- })
--- ```
---
--- The sources given replace the ones a previous call gave, and a client no
--- longer named is turned off again -- only if this turned it on: one the
--- caller enabled through |vim.lsp.completion.enable()| is left alone.  Use
--- |vim._core.completion.get_sources()| to add to what a buffer already has.
---
--- Each source says when it is consulted, see |vim._core.completion.Trigger|,
--- and which client answers it.  |i_CTRL-X_CTRL-O| consults every source.
---
--- @param enable? boolean
--- @param bufnr? integer Buffer, or 0/nil for the current one.
--- @param opts? { sources: vim._core.completion.Source[] } Required to enable.
function M.enable(enable, bufnr, opts)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  if enable ~= false and not api.nvim_buf_is_loaded(bufnr) then
    return -- nothing to complete in, and vim.lsp.start() needs it loaded
  end
  -- send_registration too: it goes when the server starts shutting down, a tick
  -- before the client leaves the registry, and a call landing in between should
  -- start a new server rather than fail.
  local client = client_id and send_registration and vim.lsp.get_client_by_id(client_id)

  if enable == false then
    for id in pairs(owned[bufnr] or {}) do
      vim.lsp.completion.enable(false, id, bufnr)
    end
    owned[bufnr] = nil
    buf_sources[bufnr] = nil
    if client then
      vim.lsp.completion.enable(false, client_id, bufnr)
      vim.lsp.buf_detach_client(bufnr, client_id)
      if not next(buf_sources) then
        client:stop()
        client_id = nil
      end
    end
    return
  end

  vim.validate('opts.sources', opts and opts.sources, 'table')
  if vim.o.autocomplete then
    vim.notify_once(
      "vim._core.completion: 'autocomplete' opens a session on every character too",
      vim.log.levels.WARN
    )
  end

  -- One server for every buffer: started once, attached to each.
  if not client then
    local previous_id = client_id
    api.nvim_buf_call(bufnr, function()
      client_id = vim.lsp.start({ name = 'nvim.completion', cmd = M.cmd })
    end)
    if not client_id then
      -- Reported rather than raised: this runs from the caller's autocommand.
      vim.notify_once('vim._core.completion: could not start the server', vim.log.levels.ERROR)
      return
    end
    -- Other buffers still name the server that went away, and the union below
    -- reads every one of them.  Their handles keep pointing at the old client
    -- until each is enabled again, which is what the caller does on LspAttach.
    for _, sources_ in pairs(buf_sources) do
      for _, s in ipairs(sources_) do
        if s.client_id == previous_id then
          s.client_id = client_id
        end
      end
    end
  elseif not vim.lsp.buf_is_attached(bufnr, client_id) then
    vim.lsp.buf_attach_client(bufnr, client_id)
  end

  -- Copied, not written through: source.keyword and friends are shared tables,
  -- and "client_id" is this buffer's.
  local sources = {} --- @type vim._core.completion.Source[]
  local at = {} --- @type table<string, integer>
  for _, s in ipairs(opts.sources) do
    vim.validate('source.name', s.name, 'string')
    local entry = s
    if s.handler then
      entry = vim.tbl_extend('force', {}, s, { client_id = client_id })
    else
      -- No handler, so a client has to answer for it.
      vim.validate('source.client_id', s.client_id, 'number')
      if not vim.lsp.get_client_by_id(s.client_id) then
        entry = nil -- the client is gone; nothing would answer
      end
    end
    if entry then
      -- By name, last one wins: re-attaching a source means the new one.
      if at[entry.name] then
        sources[at[entry.name]] = entry
      else
        sources[#sources + 1] = entry
        at[entry.name] = #sources
      end
    end
  end
  -- A client the buffer no longer names is not ours to trigger for any more --
  -- unless it was never ours to begin with.
  local previous = buf_sources[bufnr] or {}
  buf_sources[bufnr] = sources
  local kept = {} --- @type table<integer, true>
  for _, s in ipairs(sources) do
    kept[s.client_id] = true
  end
  for _, s in ipairs(previous) do
    if
      s.client_id
      and not kept[s.client_id]
      and s.client_id ~= client_id
      and (owned[bufnr] or {})[s.client_id]
    then
      vim.lsp.completion.enable(false, s.client_id, bufnr)
      owned[bufnr][s.client_id] = nil
    end
  end

  -- Triggering is vim.lsp.completion's, for this client as for any other.
  local characters = {} --- @type table<integer, string[]>
  local identifier = {} --- @type table<integer, true>
  local declared = {} --- @type table<integer, true>
  local rank = {} --- @type table<integer, integer>
  for i, s in ipairs(buf_sources[bufnr]) do
    local trigger = s.trigger or {}
    local id = assert(s.client_id)
    characters[id] = characters[id] or {}
    rank[id] = rank[id] or i
    identifier[id] = trigger.identifier or identifier[id]
    if s.handler then
      vim.list_extend(characters[id], trigger.characters or {})
    else
      -- A server's characters are its own; "characters = {}" ignores them.
      declared[id] = trigger.characters == nil or #trigger.characters > 0 or declared[id]
    end
  end

  register_characters()

  owned[bufnr] = owned[bufnr] or {}
  for id, chars in pairs(characters) do
    owned[bufnr][id] = true
    vim.lsp.completion.enable(true, id, bufnr, {
      autotrigger = #chars > 0 or declared[id] == true,
      identifier = identifier[id] == true,
      rank = rank[id],
      -- A word this server found is a word from the buffer; a language server
      -- naming the same one says more about it.
      secondary = id == client_id,
    })
  end

end

--- What |vim._core.completion.enable()| was last given for a buffer, so a caller
--- adding one source does not have to remember the rest.
---
--- ```lua
--- local sources = completion.get_sources(args.buf)
--- sources[#sources + 1] = completion.source.lsp({ client_id = args.data.client_id })
--- completion.enable(true, args.buf, { sources = sources })
--- ```
---
--- @param bufnr? integer
--- @return vim._core.completion.Source[]
function M.get_sources(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and api.nvim_get_current_buf() or bufnr
  -- deepcopy keeps a function by reference, so a handler survives the copy.
  return vim.deepcopy(buf_sources[bufnr] or {})
end

--- Sends a request, as |vim.lsp.completion.get()| does.  A "ctx.mode" naming no
--- source of this buffer is reported through a message, the request being on
--- its way by the time anything can be returned.
---
--- @param opts? vim.lsp.completion.get.Opts
function M.get(opts)
  opts = opts or {}
  local ctx = opts.ctx --[[@as vim._core.completion.Context?]]
  if ctx and ctx.mode then
    -- Ours, and not part of |lsp.CompletionContext|: a real server would get a
    -- field it cannot read, and the answer is this server's anyway.  The kind
    -- goes in because the context has to be a valid one either way.
    local given = opts.filter
    opts = vim.tbl_extend('force', {}, opts, {
      ctx = vim.tbl_extend('keep', ctx, {
        triggerKind = protocol.CompletionTriggerKind.Invoked,
      }),
      filter = function(client)
        return client.id == client_id and (given == nil or given(client))
      end,
    })
  end
  vim.lsp.completion.get(opts)
end

M._do_complete = do_complete

return M
