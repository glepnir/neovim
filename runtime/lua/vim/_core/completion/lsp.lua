--- In-process LSP server for builtin completion sources.
---
--- Provides buffer words, tags, dictionary, filenames etc. as LSP
--- `textDocument/completion` responses — no child process, no IPC.
--- Uses the `cmd = function(dispatchers)` pattern (like phoenix.nvim).
---
--- Usage:
---   require('vim._core.completion.builtin_lsp').setup()
---
--- This registers a "builtin" LSP client that attaches to every buffer.
--- The completion source framework's LSP source then queries it like
--- any other language server — yielding via ctx.await() makes it async.

local M = {}

local kw_regex = vim.regex([[\k\+]])

--- Scan a single buffer for keyword matches.
--- @param bufnr integer
--- @param prefix string
--- @param seen table<string, true>
--- @param items table[]
--- @param limit integer
local function scan_buffer(bufnr, prefix, seen, items, limit)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local prefix_lower = vim.fn.tolower(prefix)
  local prefix_len = #prefix
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  for _, line in ipairs(lines) do
    if #items >= limit then
      return
    end
    local line_len = #line
    local pos = 0
    while pos < line_len do
      -- vim.regex():match_str() takes a single string argument; it does
      -- NOT accept a start offset.  Pass a substring from `pos` onward.
      local s, e = kw_regex:match_str(line:sub(pos + 1))
      if s == nil then
        break
      end
      -- Translate sub-relative 0-based byte offsets back to absolute.
      local abs_s = pos + s
      local abs_e = pos + e
      local word = line:sub(abs_s + 1, abs_e)
      if #word >= prefix_len and not seen[word] then
        if prefix_len == 0 or vim.fn.tolower(word):sub(1, prefix_len) == prefix_lower then
          seen[word] = true
          items[#items + 1] = {
            label = word,
            kind = 1, -- Text
          }
        end
      end
      -- Guard against zero-width matches causing infinite loop.
      pos = (abs_e > abs_s) and abs_e or (abs_s + 1)
    end
  end
end

--- Scan all relevant buffers (current + loaded).
--- @param params lsp.CompletionParams
--- @return lsp.CompletionList
local function complete_words(params)
  local uri = params.textDocument.uri
  local bufnr = vim.uri_to_bufnr(uri)
  local line = vim.api.nvim_buf_get_lines(
    bufnr,
    params.position.line,
    params.position.line + 1,
    false
  )[1] or ''
  local col = params.position.character
  -- Walk backward to find keyword start
  local prefix_start = col
  while prefix_start > 0 do
    local c = line:sub(prefix_start, prefix_start)
    if not c:match('[%w_]') and not vim.fn.match(c, [[\k]]) then
      break
    end
    prefix_start = prefix_start - 1
  end
  local prefix = line:sub(prefix_start + 1, col)

  local seen = {} --- @type table<string, true>
  local items = {} --- @type table[]
  local limit = 5000

  -- Current buffer first
  scan_buffer(bufnr, prefix, seen, items, limit)

  -- Other loaded buffers
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= bufnr and vim.api.nvim_buf_is_loaded(buf) then
      scan_buffer(buf, prefix, seen, items, limit)
      if #items >= limit then
        break
      end
    end
  end

  return { isIncomplete = false, items = items }
end

--- Scan tags.
--- @param params lsp.CompletionParams
--- @return lsp.CompletionList
local function complete_tags(params)
  local uri = params.textDocument.uri
  local bufnr = vim.uri_to_bufnr(uri)
  local line = vim.api.nvim_buf_get_lines(
    bufnr,
    params.position.line,
    params.position.line + 1,
    false
  )[1] or ''
  local col = params.position.character
  local prefix_start = col
  while prefix_start > 0 do
    local c = line:sub(prefix_start, prefix_start)
    if not c:match('[%w_]') then
      break
    end
    prefix_start = prefix_start - 1
  end
  local prefix = line:sub(prefix_start + 1, col)

  local items = {} --- @type table[]
  if prefix ~= '' then
    local ok, tags = pcall(vim.fn.taglist, '^' .. vim.fn.escape(prefix, '\\'))
    if ok and type(tags) == 'table' then
      local seen = {} --- @type table<string, true>
      for _, tag in ipairs(tags) do
        if not seen[tag.name] then
          seen[tag.name] = true
          items[#items + 1] = {
            label = tag.name,
            kind = 6, -- Variable (closest generic)
            detail = tag.kind or nil,
          }
        end
      end
    end
  end

  return { isIncomplete = false, items = items }
end

--- Create the in-process LSP server dispatch function.
--- @param dispatchers vim.lsp.rpc.Dispatchers
--- @return vim.lsp.rpc.PublicClient
local function create_server(dispatchers)
  local closing = false
  local srv = {} --- @type vim.lsp.rpc.PublicClient
  local request_id = 0

  function srv.request(method, params, callback, _notify_callback)
    request_id = request_id + 1
    local id = request_id

    if method == 'initialize' then
      callback(nil, {
        capabilities = {
          completionProvider = {
            -- No trigger characters — we rely on the completion framework
            -- to decide when to request. Could add '.' '/' etc. if desired.
            triggerCharacters = {},
            resolveProvider = false,
          },
          -- We only do completion, nothing else.
          textDocumentSync = {
            openClose = true,
            change = 0, -- None — we read buffers directly
          },
        },
      })
      return true, id
    end

    if method == 'shutdown' then
      callback(nil, vim.NIL)
      return true, id
    end

    if method == 'textDocument/completion' then
      -- Run asynchronously so we don't block the main loop.
      vim.schedule(function()
        if closing then
          return
        end
        -- Combine word + tag results
        local word_result = complete_words(params)
        local tag_result = complete_tags(params)
        vim.list_extend(word_result.items, tag_result.items)
        callback(nil, word_result)
      end)
      return true, id
    end

    -- Unknown method — just succeed silently
    callback(nil, nil)
    return true, id
  end

  function srv.notify(method, _params)
    if method == 'exit' then
      dispatchers.on_exit(0, 15)
    end
  end

  function srv.is_closing()
    return closing
  end

  function srv.terminate()
    closing = true
  end

  return srv
end

--- @type boolean
local initialized = false

function M.setup()
  if initialized then
    return
  end
  initialized = true

  -- Register the LSP config.
  -- Use `cmd` as a function to create an in-process server.
  vim.lsp.config['builtin_compl'] = {
    name = 'builtin_compl',
    cmd = create_server,
    filetypes = {}, -- empty = must be started manually or via autocmd
    root_markers = {},
  }

  -- Auto-attach to every buffer.
  vim.api.nvim_create_autocmd('BufEnter', {
    group = vim.api.nvim_create_augroup('builtin_compl_lsp', { clear = true }),
    callback = function(ev)
      -- Skip special buffers
      local bt = vim.bo[ev.buf].buftype
      if bt ~= '' then
        return
      end

      -- Check if a builtin_compl client is already attached
      local clients = vim.lsp.get_clients({ name = 'builtin_compl', bufnr = ev.buf })
      if #clients > 0 then
        return
      end

      vim.lsp.start({
        name = 'builtin_compl',
        cmd = create_server,
        root_dir = vim.fn.getcwd(),
      }, {
        bufnr = ev.buf,
        reuse_client = function(client, config)
          return client.name == config.name
        end,
      })
    end,
  })
end

return M
