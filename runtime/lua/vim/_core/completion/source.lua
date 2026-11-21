--- Completion sources for |vim._core.completion|.  A handler runs on a coroutine:
--- it suspends with `args.await()`, then checks `args.cancelled()` and
--- `args.drifted()`.

local api = vim.api
local protocol = vim.lsp.protocol
local CompletionItemKind = protocol.CompletionItemKind

local M = {}

--- Bytes of scanned line content between yields; checked per chunk.
local SCAN_BUDGET = 128 * 1024
--- Flat per-line charge so runs of short or empty lines still yield.
local SCAN_LINE_COST = 64
--- Lines per get_lines() + matchstrlist() call, and the budget quantum.  Bigger
--- chunks cut API crossings; an oversized one overshoots its tick.
local SCAN_CHUNK = 256
--- Raised, at level 0, by a handler that gave up: an empty answer would be cached.
M.CANCELLED = 'nvim.completion.cancelled'
local CANCELLED = M.CANCELLED

--- @class vim._core.completion.HandlerArgs
--- @field bufnr integer
--- @field line string Cursor line.
--- @field col integer Cursor column (0-based byte index).
--- @field position lsp.Position
--- @field context lsp.CompletionContext How the request was triggered.
--- @field cancelled fun(): boolean True once the client cancelled this request.
--- @field yield fun() Suspends until the next main-loop tick.  Shorthand for
--- `await(1, vim.schedule)`.
--- @field await fun(argc: integer, fn: function, ...): ... Calls "fn", whose callback
--- is argument "argc", and suspends until it answers.  Not |vim.async|: `drifted()`
--- tracks this.  Check `cancelled()` and `drifted()` after.
--- @field drifted fun(): boolean True when the request yielded and its context is gone.

--- Current buffer, then other loaded, listed buffers, as 'complete' ".,b".
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

--- 'iskeyword' (\k) run ending at the cursor: the word typed so far.
--- @param line string
--- @param col integer 0-based byte cursor column
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

--- The directory the \f run in front of the cursor names, if there is one.  A
--- slash is not enough: 'isfname' takes it, so `sum/tot` looks like a path.
--- @param prefix string
--- @return string?
local function existing_dir(prefix)
  local dir = prefix:match('^.*[/\\]')
  if not dir then
    return nil
  end
  -- normalize, not expand(), which would also expand "%", "#" and globs in typed
  -- text.  Relative to the cwd, like getcompletion() below.
  local expanded = vim.fs.normalize(dir)
  return expanded ~= '' and vim.fn.isdirectory(expanded) == 1 and dir or nil
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
  local p = position --[[@as lsp.Position]]
  return p.line, start_char, p.character
end

--- Completes filenames, as |i_CTRL-X_CTRL-F| does.  An item replaces the whole
--- \f fragment.
--- @async
--- @param a vim._core.completion.HandlerArgs
--- @return lsp.CompletionList
local function collect_files(a)
  local prefix = filename_prefix(a.line, a.col)
  if not existing_dir(prefix) then
    return { isIncomplete = false, items = {} } -- not a path: no filesystem
  end

  -- getcompletion() cannot yield mid-call: let a redraw or cancel through first.
  a.yield()
  if a.cancelled() or a.drifted() then
    error(CANCELLED, 0)
  end

  local lnum, start_char, end_char = edit_bounds(a.line, a.col, prefix, a.position)
  -- The directory, not the fragment: the engine filters what follows the separator.
  local dir = existing_dir(prefix) or ''
  -- pcall: the fragment is user-typed; glob metachars in it can error.
  local ok, matches = pcall(vim.fn.getcompletion, dir .. '*', 'file')
  if not ok or type(matches) ~= 'table' then
    return { isIncomplete = false, items = {} }
  end
  -- "*" skips them, and |i_CTRL-X_CTRL-F| does not.
  if prefix:sub(#dir + 1, #dir + 1) == '.' then
    local dot_ok, dotted = pcall(vim.fn.getcompletion, dir .. '.*', 'file')
    if dot_ok and type(dotted) == 'table' then
      vim.list_extend(matches, dotted)
    end
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
  end
  return { isIncomplete = false, items = items }
end

--- One UTF-8 character.
local UTF8_CHAR = '[%z\1-\127\194-\244][\128-\191]*'

--- Case of "c" changed as mb_tolower() and mb_toupper() do.
--- @param c string one character
--- @return string
local function lower(c)
  return #c == 1 and c:lower() or vim.fn.tolower(c)
end
--- @param c string one character
--- @return string
local function upper(c)
  return #c == 1 and c:upper() or vim.fn.toupper(c)
end

--- "word" with 'infercase' applied for "typed", as ins_compl_infercase_gettext().
--- @param word string
--- @param typed string[] characters typed
--- @return string
local function infer_case(word, typed)
  local chars = {} --- @type string[]
  for c in word:gmatch(UTF8_CHAR) do
    chars[#chars + 1] = c
  end
  local n = math.min(#chars, #typed)
  local has_lower = false
  for i = 1, n do
    local t, c = assert(typed[i]), assert(chars[i])
    if upper(t) ~= t then
      has_lower = true
      if lower(c) ~= c then
        for k = #typed + 1, #chars do
          chars[k] = lower(chars[k])
        end
        break
      end
    end
  end
  if not has_lower then
    local was_letter = false
    for i = 1, n do
      local t, c = assert(typed[i]), assert(chars[i])
      local is_upper, is_lower = lower(t) ~= t, upper(t) ~= t
      if was_letter and is_upper and upper(c) ~= c then
        for k = #typed + 1, #chars do
          chars[k] = upper(chars[k])
        end
        break
      end
      was_letter = is_upper or is_lower
    end
  end
  for i = 1, n do
    local t, c = assert(typed[i]), assert(chars[i])
    if upper(t) ~= t then
      chars[i] = lower(c)
    elseif lower(t) ~= t then
      chars[i] = upper(c)
    end
  end
  return table.concat(chars)
end

--- Words from the buffers in |i_CTRL-N| order, which sortText carries.
--- @async
--- @param a vim._core.completion.HandlerArgs
--- @return lsp.CompletionList
local function collect_keyword(a)
  -- Mirrors collect_files()'s gate: words would bury the files of a path.
  if existing_dir(filename_prefix(a.line, a.col)) then
    return { isIncomplete = false, items = {} }
  end
  -- Only words starting with what is typed, as native, so the list is incomplete:
  -- the client asks again as the leader changes.
  local prefix = keyword_prefix(a.line, a.col)
  local plen = #prefix
  -- 'ignorecase' and 'smartcase' as searchit() applies them, but 'infercase' turns
  -- 'smartcase' off, as in get_next_default_completion().  tolower() folds multibyte.
  local has_upper = prefix ~= vim.fn.tolower(prefix)
  --- @param buf integer
  --- @return boolean
  local function ignores_case(buf)
    return vim.o.ignorecase and not (vim.o.smartcase and has_upper and not vim.bo[buf].infercase)
  end
  local infer = vim.bo[a.bufnr].infercase
  local icase = ignores_case(a.bufnr)
  local pat = [[\<\k\k\+]]
  if plen > 0 then
    -- \V: the base may hold magic characters.  \k\+ after one character keeps the
    -- base itself out of its results.
    local chars = vim.str_utfindex(prefix, 'utf-32')
    pat = (icase and [[\c]] or [[\C]])
      .. [[\V\<]]
      .. prefix:gsub('\\', '\\\\')
      .. (chars == 1 and [[\k\+]] or [[\k\*]])
  end
  local base_lnum = (a.position --[[@as lsp.Position]]).line + 1
  local base_scol = a.col - plen

  local words = {} --- @type string[]
  local seen = {} --- @type table<string, true>
  -- A buffer searched case-sensitively, unlike this one: drop its case-only matches.
  local exact = false

  --- Records a chunk's matches, the first find winning.  On the cursor line `part`
  --- keeps those after the cursor ('right') or before the base ('left').
  --- @param lines string[]
  --- @param part 'left'|'right'|nil
  local function visit(lines, part)
    -- The builtin annotation says string[]; the real return is dicts.
    local ms = vim.fn.matchstrlist(lines, pat) --[[@as {byteidx: integer, text: string}[] ]]
    for _, m in ipairs(ms) do
      local in_part = part == nil
        or (part == 'right' and m.byteidx >= a.col)
        or (part == 'left' and m.byteidx < base_scol)
      if in_part and not seen[m.text] and not (exact and not vim.startswith(m.text, prefix)) then
        seen[m.text] = true
        words[#words + 1] = m.text
      end
    end
  end

  -- Across buffers, so many small ones yield like one large one.
  local spent = 0 --- @type integer
  for _, buf in ipairs(target_buffers(a.bufnr)) do
    -- Unloaded or wiped since target_buffers(), before the first yield.
    if api.nvim_buf_is_loaded(buf) then
      exact = plen > 0 and icase and not ignores_case(buf)
      local cnt = api.nvim_buf_line_count(buf)
      -- Ranges, not lines: a per-line plan would stall before the scan can yield.
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
        local l = sg.from --- @type integer
        while l <= sg.to do
          local last = math.min(l + SCAN_CHUNK - 1, sg.to) --- @type integer
          -- Charge requested lines: strict=false clamps a buffer that shrank while suspended.
          local lines = api.nvim_buf_get_lines(buf, l - 1, last, false)
          visit(lines, sg.part)
          spent = spent + (last - l + 1) * SCAN_LINE_COST
          for _, raw in ipairs(lines) do
            spent = spent + #raw
          end
          if spent >= SCAN_BUDGET then
            spent = 0
            a.yield()
            -- State changes only while suspended.
            if a.cancelled() or a.drifted() then
              error(CANCELLED, 0)
            end
            if not api.nvim_buf_is_loaded(buf) then
              dead = true -- buffer died while suspended
              break
            end
          end
          l = last + 1
        end
        if dead then
          break
        end
      end
    end
  end

  -- As native: case inferred only for an icase match; duplicates dropped.
  if icase and plen > 0 and infer then
    local typed = {} --- @type string[]
    for c in prefix:gmatch(UTF8_CHAR) do
      typed[#typed + 1] = c
    end
    local folded = vim.fn.tolower(prefix)
    local cased, kept = {}, {} --- @type string[], table<string, true>
    for _, word in ipairs(words) do
      if vim.fn.tolower(word:sub(1, #prefix)) == folded then
        word = infer_case(word, typed)
      end
      if not kept[word] then
        kept[word] = true
        cased[#cased + 1] = word
      end
    end
    words = cased
  end

  -- Plain labels: each starts with the base, placed by the client's keyword boundary.
  local items = {} --- @type lsp.CompletionItem[]
  for idx, word in ipairs(words) do
    items[idx] = {
      label = word,
      kind = CompletionItemKind.Text,
    }
  end
  return { isIncomplete = plen > 0, items = items }
end

--- When a source's client fires a request.  A handler is asked on every request
--- its client gets, so it reads `a.context` for what brought it.
---
--- @class vim._core.completion.Trigger
--- @field identifier? boolean While an identifier is typed, left to the client by LSP.
--- @field characters? string[] As a server's "triggerCharacters".  Without a handler
--- only an empty list is read, turning the server's own off.

--- A source and the limits its handler runs under.
---
--- @class vim._core.completion.Source
--- @field name string
--- @field handler? fun(a: vim._core.completion.HandlerArgs): lsp.CompletionList
--- Answers in the completion server; without one "client_id" answers.  An error
--- removes the source from the buffer; CANCELLED gives up one round.
--- @field client_id? integer Required without a handler; |enable()| fills in the
--- completion server otherwise.
--- @field trigger? vim._core.completion.Trigger Absent: |i_CTRL-X_CTRL-O| only.
--- @field max_items? integer Cap, as the "^N" suffix in 'complete'.  No default.

--- A source for one LSP server, from |LspAttach|; nil for the completion server.
--- The server answers; "trigger" can add identifiers or turn its characters off.
---
--- @param opts { client_id: integer, name?: string, trigger?: vim._core.completion.Trigger }
--- @return vim._core.completion.Source?
function M.lsp(opts)
  local client = assert(vim.lsp.get_client_by_id(opts.client_id))
  if client.name == 'nvim.completion' then
    return nil
  end
  return {
    name = opts.name or ('lsp:%s:%d'):format(client.name, opts.client_id),
    client_id = opts.client_id,
    trigger = opts.trigger or { identifier = true },
  }
end

--- Words from the current buffer, then from the other loaded, listed ones.
--- @type vim._core.completion.Source
M.keyword = {
  name = 'keyword',
  handler = collect_keyword,
  trigger = { identifier = true },
}

--- Paths, as |i_CTRL-X_CTRL-F| gives them.
--- @type vim._core.completion.Source
M.files = {
  name = 'files',
  handler = collect_files,
  -- The separator only.  Backslash on Windows, where 'isfname' has it.
  trigger = { characters = vim.fn.has('win32') == 1 and { '/', '\\' } or { '/' } },
}

return M
