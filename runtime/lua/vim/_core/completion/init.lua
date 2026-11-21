--- In-process LSP server for "textDocument/completion", fed by
--- |vim._core.completion.source|.  One client serves every buffer.

local async = vim.async
local api = vim.api
local protocol = vim.lsp.protocol

local M = {}

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

--- @param a vim._core.completion.HandlerArgs
--- @return boolean
local function still_relevant(a)
  if api.nvim_get_current_buf() ~= a.bufnr or api.nvim_get_mode().mode:sub(1, 1) ~= 'i' then
    return false
  end
  -- The anchor, not the cursor: browsing writes the shown match into the line.
  local pos = api.nvim_win_get_cursor(0)
  local anchor = a.col - #vim.fn.matchstr(a.line:sub(1, a.col), [[\k*$]])
  return pos[1] - 1 == (a.position --[[@as lsp.Position]]).line
    and api.nvim_get_current_line():sub(1, anchor) == a.line:sub(1, anchor)
end

--- @param params lsp.CompletionParams
--- @return integer bufnr
--- @return string line
--- @return integer col 0-based byte column
local function resolve_position(params)
  -- By URI: the caller may have left the buffer by the time a handler resumes.
  local uri = vim.tbl_get(params, 'textDocument', 'uri')
  local bufnr = uri and vim.uri.to_buf(uri) or api.nvim_get_current_buf()
  if not api.nvim_buf_is_loaded(bufnr) then
    bufnr = api.nvim_get_current_buf()
  end
  -- Cast: LuaLS resolves only the first base of lsp.CompletionParams.
  local pos = (params --[[@as lsp.TextDocumentPositionParams]]).position
  local line = api.nvim_buf_get_lines(bufnr, pos.line, pos.line + 1, false)[1] or ''
  local ok, byte_col = pcall(vim.str_byteindex, line, 'utf-16', pos.character, false)
  return bufnr, line, ok and byte_col or math.min(pos.character, #line)
end

--- Registers the union of every buffer's trigger characters: a documentSelector
--- matches file names, which an unnamed buffer lacks.
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
  -- Asserted: a silent miss would just leave the triggers dead.
  local register = assert(send_registration, 'the completion server is not running')
  register(own)
end

--- Takes a source out of the buffer it raised in.
--- @param bufnr integer
--- @param name string
local function drop_source(bufnr, name)
  for i, s in ipairs(buf_sources[bufnr] or {}) do
    if s.name == name then
      table.remove(buf_sources[bufnr], i)
      -- Its characters go with it, or the client keeps waking for them.
      register_characters()
      return
    end
  end
end

--- @async
--- @param params lsp.CompletionParams
--- @param cancelled? fun(): boolean
--- @return lsp.CompletionList
local function do_complete(params, cancelled)
  cancelled = cancelled or function()
    return false
  end
  local bufnr, line, col = resolve_position(params)

  local ctx = params.context
  -- Only sources this server handles, and for a trigger character those declaring
  -- it: the client registers all buffers' characters as one set.
  local char = ctx
    and ctx.triggerKind == protocol.CompletionTriggerKind.TriggerCharacter
    and ctx.triggerCharacter
  local run = vim.tbl_filter(function(s)
    return s.handler ~= nil
      and (not char or vim.list_contains((s.trigger or {}).characters or {}, char))
  end, buf_sources[bufnr] or {}) --[[@as vim._core.completion.Source[] ]]

  local yielded = false

  -- Typed after the fields below are added, or each reads as missing.
  local args = {
    bufnr = bufnr,
    line = line,
    col = col,
    position = (params --[[@as lsp.TextDocumentPositionParams]]).position,
    context = ctx or { triggerKind = protocol.CompletionTriggerKind.Invoked },
    cancelled = cancelled,
  }
  -- Both set "yielded", which drifted() reads; vim.async directly would not.
  --- @async
  function args.await(argc, fn, ...)
    yielded = true
    return async.await(argc, fn, ...)
  end
  --- @async
  function args.yield()
    args.await(1, vim.schedule)
  end
  function args.drifted()
    return yielded and not still_relevant(args)
  end
  --- @cast args vim._core.completion.HandlerArgs

  local items = {} --- @type lsp.CompletionItem[]
  local seen = {} --- @type table<string, true>
  local incomplete = false
  for _, s in ipairs(run) do
    if cancelled() or args.drifted() then
      break -- the caller discards the response
    end
    local quota = s.max_items or math.huge
    local produced = 0

    -- Caught, so one source does not lose the others' items, and removed, so it is
    -- reported once rather than answering nothing.  CANCELLED gives up on purpose.
    local ok, list = pcall(assert(s.handler), args)
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
    -- Before the items leave their list: the merged list has no "itemDefaults".
    local batch = vim.lsp.completion._get_items(list)
    incomplete = incomplete or list.isIncomplete == true
    for _, it in ipairs(batch) do
      if produced >= quota then
        incomplete = true
        break
      end
      -- Deduplicated by inserted text.  Fresh per request, so setting sortText is safe.
      local key = (it.textEdit and it.textEdit.newText) or it.insertText or it.label
      if not seen[key] then
        seen[key] = true
        produced = produced + 1
        it.sortText = ('%08d'):format(#items + 1)
        items[#items + 1] = it
      end
    end
  end

  -- Incomplete when a source is, or was capped: the client asks again as the leader changes.
  return { isIncomplete = incomplete, items = items } --[[@as lsp.CompletionList]]
end

function M.cmd(dispatchers)
  local closing = false
  local next_id = 0

  -- One server for every buffer, so one registration; shut_down() drops it.
  local registered = nil --- @type string?
  send_registration = function(characters)
    if closing then
      return
    end
    -- Only on change: every registration re-runs the client's per-buffer defaults.
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

  --- Cancellation flags by request id, set by $/cancelRequest.
  --- @type table<integer, {cancelled: boolean}>
  local pending = {}
  local srv = {}

  --- Replies next tick, notify_reply_callback first, as rpc.lua does: same-tick
  --- delivery would land before rpc.request() returns.
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

  --- Exactly-once teardown; a force-stop reaches it only through terminate().
  local function shut_down()
    if closing then
      return
    end
    closing = true
    -- Only if still ours: an old client exiting must not take the new one's hook.
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
      -- No trigger characters: they are per buffer, registered by enable().
      respond(rid, notify_reply_callback, callback, nil, {
        capabilities = { completionProvider = { resolveProvider = false } },
      })
    elseif method == 'textDocument/completion' then
      local tok = { cancelled = false }
      pending[rid] = tok
      local task = async.run(function()
        -- Cast: async.run()'s generic return does not reach do_complete()'s annotation.
        return do_complete(params, function()
          return tok.cancelled
        end) --[[@as any]]
      end)
      task:on_complete(function(err, result)
        pending[rid] = nil
        if tok.cancelled then
          -- As for a handler that gave up: an empty list would be cached.  Replying lets
          -- client.lua settle its 'cancel' entry.
          respond(rid, notify_reply_callback, callback, {
            code = protocol.ErrorCodes.RequestCancelled,
            message = 'cancelled',
          }, nil)
        elseif err then
          -- A handler that gave up says so, and the client keeps its cache.
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
--- The sources replace those of a previous call; a client no longer named is
--- turned off if this turned it on.  |i_CTRL-X_CTRL-O| consults every source.
---
--- @param enable? boolean
--- @param bufnr? integer Buffer, or 0/nil for the current one.
--- @param opts? { sources: vim._core.completion.Source[] } Required to enable.
function M.enable(enable, bufnr, opts)
  bufnr = vim._resolve_bufnr(bufnr)
  if enable ~= false and not api.nvim_buf_is_loaded(bufnr) then
    return -- nothing to complete in, and vim.lsp.start() needs it loaded
  end
  -- send_registration too: it goes a tick before the client leaves the registry,
  -- and a call in between should start a new server.
  local client = client_id and send_registration and vim.lsp.get_client_by_id(client_id)

  if enable == false then
    for id in pairs(owned[bufnr] or {}) do
      vim.lsp.completion.enable(false, id, bufnr)
    end
    owned[bufnr] = nil
    buf_sources[bufnr] = nil
    if client then
      -- Non-nil: "client" was looked up by it.
      local id = assert(client_id)
      vim.lsp.completion.enable(false, id, bufnr)
      vim.lsp.buf_detach_client(bufnr, id)
      if not next(buf_sources) then
        client:stop()
        client_id = nil
      end
    end
    return
  end

  vim.validate('opts.sources', opts and opts.sources, 'table')
  --- @cast opts { sources: vim._core.completion.Source[] }
  if vim.o.autocomplete then
    vim.notify_once(
      "vim._core.completion: 'autocomplete' opens a session on every character too",
      vim.log.levels.WARN
    )
  end

  -- One server for every buffer: started once, attached to each.
  if not client then
    local previous_id = client_id
    client_id = vim.lsp.start({
      name = 'nvim.completion',
      cmd = M.cmd,
      -- Here, not in protocol.lua: only this server needs dynamic registration.
      capabilities = {
        textDocument = { completion = { dynamicRegistration = true } },
      },
    }, { bufnr = bufnr })
    if not client_id then
      -- Reported rather than raised: this runs from the caller's autocommand.
      vim.notify_once('vim._core.completion: could not start the server', vim.log.levels.ERROR)
      return
    end
    -- Other buffers still name the old server until LspAttach enables them again.
    for _, sources_ in pairs(buf_sources) do
      for _, s in ipairs(sources_) do
        if s.client_id == previous_id then
          s.client_id = client_id
        end
      end
    end
  else
    -- Non-nil: the branch above either started one or found the existing one.
    local id = assert(client_id)
    if not vim.lsp.buf_is_attached(bufnr, id) then
      vim.lsp.buf_attach_client(bufnr, id)
    end
  end

  -- Copied: the source tables are shared, and "client_id" is this buffer's.
  local sources = {} --- @type vim._core.completion.Source[]
  local at = {} --- @type table<string, integer>
  for _, s in ipairs(opts.sources) do
    vim.validate('source.name', s.name, 'string')
    local entry = s --- @type vim._core.completion.Source?
    if s.handler then
      entry = vim.tbl_extend('force', {}, s, { client_id = client_id }) --[[@as vim._core.completion.Source]]
    else
      -- No handler, so a client has to answer for it.
      vim.validate('source.client_id', s.client_id, 'number')
      if not vim.lsp.get_client_by_id(assert(s.client_id)) then
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
  -- Stop triggering for clients the buffer no longer names, if we did before.
  local previous = buf_sources[bufnr] or {}
  buf_sources[bufnr] = sources
  local kept = {} --- @type table<integer, true>
  for _, s in ipairs(sources) do
    -- Every source here has one: enable() filled it in or validated it.
    kept[assert(s.client_id)] = true
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
  for i, s in ipairs(sources) do
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

  local own = owned[bufnr] or {}
  owned[bufnr] = own
  for id, chars in pairs(characters) do
    own[id] = true
    vim.lsp.completion.enable(true, id, bufnr, {
      autotrigger = #chars > 0 or declared[id] == true,
      identifier = identifier[id] == true,
      _rank = rank[id],
      -- Buffer words only when no language server offers anything.
      _secondary = id == client_id,
    })
  end
end

--- What |vim._core.completion.enable()| was last given for a buffer.
---
--- @param bufnr? integer
--- @return vim._core.completion.Source[]
function M.get_sources(bufnr)
  bufnr = vim._resolve_bufnr(bufnr)
  -- deepcopy keeps a function by reference, so a handler survives the copy.
  return vim.deepcopy(buf_sources[bufnr] or {})
end

return M
