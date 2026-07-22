--- Completion sources for |vim._core.completion|.
---
--- A handler runs on a coroutine, so it is written as if it were synchronous:
---
--- ```lua
--- {
---   name = 'tags',
---   trigger = { identifier = true },
---   handler = function(args)
---     local name = vim.api.nvim_buf_get_name(args.bufnr)
---     -- 3: where vim.system(cmd, opts, on_exit) takes its callback.
---     local out = args.await(3, vim.system, { 'ctags', '-xf-', name }, {})
---     if args.cancelled() or args.drifted() then
---       return { isIncomplete = false, items = {} }
---     end
---     return { isIncomplete = false, items = parse(out.stdout) }
---   end,
--- }
--- ```

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
--- Thrown by a handler that gave up: the answer would be an empty list, which
--- reads as "there is nothing" and would be cached as one.  Raised at level 0,
--- so that the message the client matches on is only this.
M.CANCELLED = 'nvim.completion.cancelled'
local CANCELLED = M.CANCELLED

--- @class vim._core.completion.HandlerArgs
--- @field bufnr integer
--- @field line string Cursor line.
--- @field col integer Cursor column (0-based byte index).
--- @field position lsp.Position
--- @field context lsp.CompletionContext How the request was triggered.
--- @field explicit boolean The request named this source through ctx.mode.
--- @field cancelled fun(): boolean True once the client cancelled this request.
--- @field yield fun() Suspend until the next main-loop tick.
--- @field await fun(argc: integer, fn: function, ...): ... As
--- |vim.async.await()|, and marks the request as having suspended: check
--- `cancelled()` and `drifted()` after it returns.
--- @field drifted fun(): boolean True when the request yielded and its context is gone.
--- @field exhausted fun(): boolean True once this source is out of time; return
--- what was found and say it was truncated.  "max_items" is capped by the
--- caller, not here.

--- Current buffer, then other loaded, listed buffers. Matches 'complete'
--- ".,b"; cpt-driven selection comes with the C routing.
--- @param cur_buf integer

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
  -- normalize, not expand(): the latter also replaces "%" and "#" and globs, and
  -- this is text the user is still typing.  Resolved against the process cwd,
  -- like getcompletion() below.
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
  return position.line, start_char, position.character
end

--- Completes filenames, as |i_CTRL-X_CTRL-F| does.  An item replaces the whole
--- \f fragment.
--- @async
--- @param a vim._core.completion.HandlerArgs
--- @return lsp.CompletionItem[]

local function collect_files(a)
  local prefix = filename_prefix(a.line, a.col)
  if not a.explicit and not existing_dir(prefix) then
    return { isIncomplete = false, items = {} } -- not a path: no filesystem
  end

  -- getcompletion() globs synchronously and can't yield mid-call; yield once
  -- first so a pending redraw and a queued $/cancelRequest get through.
  a.yield()
  if a.cancelled() or a.drifted() then
    error(CANCELLED, 0)
  end

  local lnum, start_char, end_char = edit_bounds(a.line, a.col, prefix, a.position)
  -- The directory, not the fragment: what is typed past the last separator is
  -- the engine's to filter, and globbing it again per keystroke would hit the
  -- filesystem for a list it already has.
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
    if a.exhausted() then
      return { isIncomplete = true, items = items }
    end
  end
  return { isIncomplete = false, items = items }
end

--- Completes words from the buffers, in |i_CTRL-N| order: the current one from
--- the cursor with wraparound, then the others top to bottom.  Found order is
--- conveyed through sortText.
--- @async
--- @param a vim._core.completion.HandlerArgs
--- @return lsp.CompletionList
local function collect_keyword(a)
  -- The mirror of collect_files()'s gate, so exactly one of the two answers a
  -- path: a word dump would bury the files, whatever kind of request it is.
  if not a.explicit and existing_dir(filename_prefix(a.line, a.col)) then
    return { isIncomplete = false, items = {} }
  end
  -- Every word, not the ones matching the leader: the engine filters what it is
  -- given, so a list narrowed here would have to be fetched again on every
  -- keystroke and refetched wider on <BS>.
  --
  -- Unless the last round ran out before the end, which is what this kind means:
  -- a narrower scan reaches words the budget never got to.
  local prefix = keyword_prefix(a.line, a.col)
  local plen = #prefix
  local narrow = plen > 0
    and a.context.triggerKind
      == vim.lsp.protocol.CompletionTriggerKind.TriggerForIncompleteCompletions
  local pat = [[\<\k\k\+]]
  if narrow then
    -- 'ignorecase' + 'smartcase', as searchit() compiles it via ignorecase().
    -- vim.fn.tolower() shares the case tables with mb_isupper(); %u folds bytes.
    local icase = vim.o.ignorecase
    if icase and vim.o.smartcase and prefix ~= vim.fn.tolower(prefix) then
      icase = false
    end
    -- \V neutralizes magic in the base, which 'iskeyword' may hold; \k\* takes
    -- the whole run, where native extracts the word at the match instead, and
    -- \k\+ for a single character keeps the base itself out of its own results.
    local chars = vim.str_utfindex(prefix, 'utf-32')
    pat = (icase and [[\c]] or [[\C]])
      .. [[\V\<]]
      .. prefix:gsub('\\', '\\\\')
      .. (chars == 1 and [[\k\+]] or [[\k\*]])
  end
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
        if a.exhausted() then
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
              error(CANCELLED, 0)
            end
            if a.exhausted() then
              truncated, stop = true, true
              break
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
  -- boundary places the insertion.  Each item carries its own
  -- start column, so a mixed response needs no re-anchoring here.
  local items = {} --- @type lsp.CompletionItem[]
  for idx, word in ipairs(words) do
    items[idx] = {
      label = word,
      kind = CompletionItemKind.Text,
    }
  end
  -- TODO: 'infercase'; CTRL_X_EVAL does not reach ins_compl_add_infercase().
  return { isIncomplete = truncated or narrow, items = items }
end

--- Source name to handler. Follow-up sources land as new entries here;
--- custom sources are separate in-process servers, not entries.

--- When a source is consulted on its own.  What fires a request also decides who
--- answers it: typing a word is no reason to look for a path.
---
--- A source is asked on every request its client gets, not only the ones this
--- describes: "trigger" says when the client fires, and a handler still has to
--- read `a.context` to tell what brought it there.
---
--- @class vim._core.completion.Trigger
--- @field identifier? boolean While an identifier is being typed, which the LSP
--- specification leaves to the client.
--- @field characters? string[] As a server's "triggerCharacters", for a source
--- with a handler.  Without one they are the server's own, and only the presence
--- of this is read: absent to fire on them, an empty list not to.  A non-empty
--- list there is the same as absent.

--- A source and the limits its handler runs under.
---
--- @class vim._core.completion.Source
--- @field name string Looked up by |vim._core.completion| and by the "mode" of
--- a completion request.
--- @field handler? fun(a: vim._core.completion.HandlerArgs): lsp.CompletionList
--- Handles the request in the completion server; without one it goes to
--- "client_id" and that server handles it.  Raising takes the source out of that
--- buffer -- |vim._core.completion.get_sources()| stops naming it -- and reports
--- why; give up for one round by raising CANCELLED instead.
--- @field client_id? integer Required without a handler; |enable()| fills in the
--- completion server otherwise.
--- @field trigger? vim._core.completion.Trigger Absent: |i_CTRL-X_CTRL-O| only.
--- @field max_items? integer Cap, as the "^N" suffix in 'complete'.  No default.
--- @field timeout? integer Milliseconds it may spend, 100 by default.  Capped
--- by what is left of the request's own budget.

--- One LSP server, for |LspAttach|.  Answers nil for the completion server
--- itself, which that event also fires for.
---
--- No handler: the server answers the request.  Its "triggerCharacters" fire it
--- by default; "trigger" says whether an identifier does too, and can turn the
--- characters off with an empty list.
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
  -- The separator only; what lies between two of them is a word.  Backslash on
  -- Windows, where 'isfname' includes it.
  trigger = { characters = vim.fn.has('win32') == 1 and { '/', '\\' } or { '/' } },
}

return M
